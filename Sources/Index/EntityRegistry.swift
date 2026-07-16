import Foundation

/// The **system of record for entity identity** (Fable A/F2). Entities get stable ids here — the
/// SQLite `entities` table is a cache — so identity survives `rm index.db`, and hand-authored
/// merge/split decisions never orphan when extraction re-runs. Stores **rules, not assignments**:
/// canonical name + aliases + pair-level verdicts; mention→entity assignments are recomputed from
/// these each enrich.
///
/// Discipline: single-writer (the app), atomic temp+rename, lives in the vault (backed up with the
/// transcripts). Group provenance per entity supports the I6 delete-a-group cascade and the I4
/// per-field privacy rules.
final class EntityRegistry {
    struct Entity: Codable {
        var id: String
        var name: String          // display (most frequent original spelling)
        var kind: String          // "person" | "org"
        var aliases: [String]     // normalized surface forms that resolve to this id
        var groups: [String]      // workspaces this identity has appeared in (provenance)
        var confirmed: Bool       // user-confirmed (only confirmed aliases seed ASR — Fable F)
    }
    struct Verdict: Codable { var a: String; var b: String; var same: Bool; var by: String }

    private struct Doc: Codable { var version: Int; var entities: [Entity]; var verdicts: [Verdict] }

    let url: URL
    private(set) var entities: [Entity] = []
    private(set) var verdicts: [Verdict] = []
    private var dirty = false

    /// Shared instance rooted in the current output folder (vault). Recreated when the folder moves.
    static var shared = EntityRegistry(url: EntityRegistry.defaultURL)
    static var defaultURL: URL {
        AppSettings.outputFolder.appendingPathComponent(".calltranscriber-registry.json")
    }

    init(url: URL) { self.url = url; load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return }
        entities = doc.entities
        verdicts = doc.verdicts
    }

    func save() {
        guard dirty else { return }
        let doc = Doc(version: 1, entities: entities, verdicts: verdicts)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: url, options: .atomic)   // single-writer, atomic
        }
        dirty = false
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a surface form to an entity id, allocating a new identity if unknown. **Deterministic
    /// auto-merge only**: exact normalized-name or alias match (wrong merges are catastrophic and
    /// hard to notice; fuzzy proposals go to a review queue, not here). Records group provenance.
    @discardableResult
    func resolve(surface: String, kind: String, group: String) -> String {
        let norm = Self.normalize(surface)
        if let i = entities.firstIndex(where: { e in
            e.kind == kind && (e.aliases.contains(norm) || Self.normalize(e.name) == norm)
        }) {
            if !entities[i].groups.contains(group) { entities[i].groups.append(group); dirty = true }
            if !entities[i].aliases.contains(norm) { entities[i].aliases.append(norm); dirty = true }
            return applyMerges(entities[i].id)
        }
        let id = Self.newID()
        entities.append(Entity(id: id, name: surface, kind: kind, aliases: [norm], groups: [group], confirmed: false))
        dirty = true
        return id
    }

    /// A confirmed same/distinct verdict between two identities (reversible: change or delete it).
    func recordVerdict(_ a: String, _ b: String, same: Bool, by: String = "user") {
        verdicts.removeAll { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
        verdicts.append(Verdict(a: a, b: b, same: same, by: by))
        dirty = true
    }

    /// Follows confirmed "same" verdicts to a canonical id (union-find-lite). "distinct" verdicts
    /// block a merge and are how a wrong auto-merge is reversed.
    private func applyMerges(_ id: String) -> String {
        var current = id
        var guardCount = 0
        while guardCount < 64, let v = verdicts.first(where: { $0.same && $0.b == current }) {
            current = v.a; guardCount += 1
        }
        return current
    }

    /// Only user-confirmed aliases feed ASR contextual vocabulary (Fable F — an unreviewed alias
    /// must not steer future transcription and contaminate the source of truth).
    func confirmedAliases(group: String) -> [String] {
        entities.filter { $0.confirmed && $0.groups.contains(group) }.map(\.name)
    }

    /// Entity ids whose name/aliases match any content term of a query — query-side entity linking
    /// (the thing that makes entity-anchored retrieval fire).
    func link(query: String, group: String) -> [String] {
        let terms = Set(FTSQuery.terms(query))
        guard !terms.isEmpty else { return [] }
        return entities.filter { e in
            e.groups.contains(group) &&
            (terms.contains(Self.normalize(e.name)) || e.aliases.contains(where: terms.contains)
             || e.name.lowercased().split(separator: " ").contains { terms.contains(String($0)) })
        }.map { applyMerges($0.id) }
    }

    /// Drops entities whose provenance is only the deleted group (I6 × registry). Keeps ones seen
    /// elsewhere, just removing that group from their provenance.
    func purge(group: String) {
        entities = entities.compactMap { e in
            guard e.groups.contains(group) else { return e }
            let remaining = e.groups.filter { $0 != group }
            if remaining.isEmpty { return nil }
            var kept = e; kept.groups = remaining; return kept
        }
        dirty = true
        save()
    }

    /// Time-ordered unique id (ULID-ish: millisecond timestamp prefix + random) so ids sort by
    /// creation and never collide.
    private static func newID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0...UInt64.max)
        return String(format: "%013x", ms) + String(format: "%016x", rand)
    }
}
