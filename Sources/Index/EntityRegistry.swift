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
        var kind: String          // "person" | "org" | "term" (vocabulary)
        var aliases: [String]     // normalized surface forms that resolve to this id
        var groups: [String]      // workspaces this identity has appeared in ("" = global)
        var confirmed: Bool       // user-confirmed (only confirmed aliases seed ASR — Fable F)
        /// One-line meaning, for vocabulary terms ("TIM — tenants in the market"). Optional and
        /// additive, so registries written before it decode unchanged.
        var gloss: String? = nil
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

    /// Marks the entity matching a surface as user-confirmed (ground truth) — e.g. a name the user
    /// entered as a participant. Confirmed names are the only ones that feed ASR (Fable F).
    func confirm(surface: String, group: String) {
        let norm = Self.normalize(surface)
        if let i = entities.firstIndex(where: { $0.aliases.contains(norm) || Self.normalize($0.name) == norm }) {
            if !entities[i].confirmed { entities[i].confirmed = true; dirty = true }
            if !entities[i].groups.contains(group) { entities[i].groups.append(group); dirty = true }
        }
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

    // MARK: - Vocabulary (kind "term" — the correction loop's write target)

    /// Vocabulary terms visible in a workspace: its own plus global ("") entries.
    func terms(group: String) -> [Entity] {
        entities.filter { $0.kind == "term" && ($0.groups.contains(group) || $0.groups.contains("")) }
    }

    /// Adds (or extends) a vocabulary term. User-initiated, so confirmed by definition — every
    /// consumer (ASR bias, alias expansion, gloss injection) may trust it immediately.
    @discardableResult
    func addTerm(canonical: String, aliases: [String], gloss: String?, group: String) -> String {
        let trimmed = canonical.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let norm = Self.normalize(trimmed)
        let normAliases = ([trimmed] + aliases).map(Self.normalize).filter { !$0.isEmpty }
        if let i = entities.firstIndex(where: { e in
            e.kind == "term" && (e.aliases.contains(norm) || Self.normalize(e.name) == norm)
        }) {
            for a in normAliases where !entities[i].aliases.contains(a) { entities[i].aliases.append(a) }
            if let gloss, !gloss.isEmpty { entities[i].gloss = gloss }
            if !entities[i].groups.contains(group) { entities[i].groups.append(group) }
            entities[i].confirmed = true
            dirty = true; save()
            return entities[i].id
        }
        let id = Self.newID()
        entities.append(Entity(id: id, name: trimmed, kind: "term", aliases: normAliases,
                               groups: [group], confirmed: true, gloss: gloss))
        dirty = true; save()
        return id
    }

    /// ASR bias strings from the vocabulary: canonical spellings plus multi-word aliases
    /// (single-word normalized aliases add nothing the canonical doesn't).
    func termVocab(group: String) -> [String] {
        terms(group: group).flatMap { [$0.name] + $0.aliases.filter { $0.contains(" ") } }
    }

    /// Time-ordered unique id (ULID-ish: millisecond timestamp prefix + random) so ids sort by
    /// creation and never collide.
    private static func newID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0...UInt64.max)
        return String(format: "%013x", ms) + String(format: "%016x", rand)
    }
}
