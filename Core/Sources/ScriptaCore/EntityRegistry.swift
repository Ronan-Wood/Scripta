import Foundation
import ScriptaShared

/// The **system of record for entity identity** (Fable A/F2). Entities get stable ids here — the
/// SQLite `entities` table is a cache — so identity survives `rm index.db`, and hand-authored
/// merge/split decisions never orphan when extraction re-runs. Stores **rules, not assignments**:
/// canonical name + aliases + pair-level verdicts; mention→entity assignments are recomputed from
/// these each enrich.
///
/// Discipline: single-writer (the app), atomic temp+rename, lives in the vault (backed up with the
/// transcripts). Group provenance per entity supports the I6 delete-a-group cascade and the I4
/// per-field privacy rules.
///
/// Thread-safety: an internal `NSLock` serializes ALL access to the mutable state, because the
/// registry is read on the main actor (the Knowledge hub) while background indexing mutates it —
/// reconcile on the watcher's utility queue, and the post-recording extract pass in `Task.detached`.
/// Without the lock those overlap as a data race: torn reads, or an EXC_BAD_ACCESS when a
/// concurrent `append` reallocates the array mid-iteration. Mirrors IndexStore / TranscriptStore.
public final class EntityRegistry {
    public struct Entity: Codable {
        public var id: String
        public var name: String          // display (most frequent original spelling)
        public var kind: String          // "person" | "org" | "term" (vocabulary)
        public var aliases: [String]     // normalized surface forms that resolve to this id
        public var groups: [String]      // workspaces this identity has appeared in ("" = global)
        public var confirmed: Bool       // user-confirmed (only confirmed aliases seed ASR — Fable F)
        /// One-line meaning, for vocabulary terms ("TIM — tenants in the market"). Optional and
        /// additive, so registries written before it decode unchanged.
        public var gloss: String? = nil
    }
    struct Verdict: Codable { var a: String; var b: String; var same: Bool; var by: String }

    private struct Doc: Codable { var version: Int; var entities: [Entity]; var verdicts: [Verdict] }

    let url: URL
    /// Guards `entities`, `verdicts`, and `dirty`. NSLock is NON-reentrant, so a method that already
    /// holds it must call the private `*Locked` variants (e.g. `saveLocked`, `termsLocked`), never
    /// another public method — doing so would deadlock.
    private let lock = NSLock()
    private var entities: [Entity] = []
    private var verdicts: [Verdict] = []
    private var dirty = false

    public init(url: URL) { self.url = url; load() }

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return }
        entities = doc.entities
        verdicts = doc.verdicts
    }

    /// A value snapshot of every entity, copied under the lock, for callers that need to scan the
    /// whole set off the main actor (vocabulary mining, the DB term sync). Reading the `entities`
    /// array directly would race the background writers.
    public func allEntities() -> [Entity] {
        lock.lock(); defer { lock.unlock() }
        return entities
    }

    public func save() {
        lock.lock(); defer { lock.unlock() }
        saveLocked()
    }

    private func saveLocked() {
        guard dirty else { return }
        let doc = Doc(version: 1, entities: entities, verdicts: verdicts)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: url, options: .atomic)   // single-writer, atomic
        }
        dirty = false
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a surface form to an entity id, allocating a new identity if unknown. **Deterministic
    /// auto-merge only**: exact normalized-name or alias match (wrong merges are catastrophic and
    /// hard to notice; fuzzy proposals go to a review queue, not here). Records group provenance.
    @discardableResult
    public func resolve(surface: String, kind: String, group: String) -> String {
        lock.lock(); defer { lock.unlock() }
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
    public func confirm(surface: String, group: String) {
        lock.lock(); defer { lock.unlock() }
        let norm = Self.normalize(surface)
        if let i = entities.firstIndex(where: { $0.aliases.contains(norm) || Self.normalize($0.name) == norm }) {
            if !entities[i].confirmed { entities[i].confirmed = true; dirty = true }
            if !entities[i].groups.contains(group) { entities[i].groups.append(group); dirty = true }
        }
    }

    /// A confirmed same/distinct verdict between two identities (reversible: change or delete it).
    public func recordVerdict(_ a: String, _ b: String, same: Bool, by: String = "user") {
        lock.lock(); defer { lock.unlock() }
        verdicts.removeAll { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
        verdicts.append(Verdict(a: a, b: b, same: same, by: by))
        dirty = true
    }

    /// Follows confirmed "same" verdicts to a canonical id (union-find-lite). "distinct" verdicts
    /// block a merge and are how a wrong auto-merge is reversed. Lock-free: only ever called from
    /// methods that already hold the lock.
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
    public func confirmedAliases(group: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entities.filter { $0.confirmed && $0.groups.contains(group) }.map(\.name)
    }

    /// Drops entities whose provenance is only the deleted group (I6 × registry). Keeps ones seen
    /// elsewhere, just removing that group from their provenance.
    /// The registry half of the I6 delete-a-group cascade — WorkspaceDeleter calls this so a
    /// wiped workspace's identities don't linger in the registry file.
    public func purge(group: String) {
        lock.lock(); defer { lock.unlock() }
        var removedIDs: [String] = []
        var changed = false
        entities = entities.compactMap { e in
            guard e.groups.contains(group) else { return e }
            changed = true
            let remaining = e.groups.filter { $0 != group }
            if remaining.isEmpty { removedIDs.append(e.id); return nil }
            var kept = e; kept.groups = remaining; return kept
        }
        // Drop verdicts referencing purged ids: a dangling "same" verdict would make applyMerges
        // permanently redirect a surviving entity to a dead canonical, resurrecting the wiped
        // identity through the mentions cache. Aliases learned in the wiped group on SURVIVING
        // shared entities are deliberately not trimmed — alias provenance isn't tracked.
        if !removedIDs.isEmpty {
            let dead = Set(removedIDs)
            verdicts.removeAll { dead.contains($0.a) || dead.contains($0.b) }
        }
        guard changed else { return }   // nothing purged: don't touch/create the registry file
        dirty = true
        saveLocked()
    }

    /// Deterministic identity-review pairs: same-kind entities in a workspace where one's
    /// normalized name is a token-subset of the other's ("dana" ⊂ "dana whitfield") with no
    /// recorded verdict. The clarifying question generated from DATA, not model judgment —
    /// and because the verdict persists, each pair is asked once, ever.
    public func collisionCandidates(group: String, limit: Int = 3) -> [(a: Entity, b: Entity)] {
        lock.lock(); defer { lock.unlock() }
        let scoped = entities.filter { $0.kind != "term" && $0.groups.contains(group) }
        var out: [(Entity, Entity)] = []
        for i in scoped.indices {
            for j in scoped.indices where j > i {
                let a = scoped[i], b = scoped[j]
                guard a.kind == b.kind else { continue }
                guard !verdicts.contains(where: { v in
                    (v.a == a.id && v.b == b.id) || (v.a == b.id && v.b == a.id)
                }) else { continue }
                let ta = Set(Self.normalize(a.name).split(separator: " ").map(String.init))
                let tb = Set(Self.normalize(b.name).split(separator: " ").map(String.init))
                guard !ta.isEmpty, !tb.isEmpty, ta != tb else { continue }
                if ta.isSubset(of: tb) || tb.isSubset(of: ta) {
                    out.append((a, b))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    // MARK: - Vocabulary (kind "term" — the correction loop's write target)

    /// Vocabulary terms visible in a workspace: its own plus global ("") entries.
    public func terms(group: String) -> [Entity] {
        lock.lock(); defer { lock.unlock() }
        return termsLocked(group: group)
    }

    /// Lock-free variant for callers already inside the lock (NSLock is non-reentrant).
    private func termsLocked(group: String) -> [Entity] {
        entities.filter { $0.kind == "term" && ($0.groups.contains(group) || $0.groups.contains("")) }
    }

    /// Adds (or extends) a vocabulary term. User-initiated, so confirmed by definition — every
    /// consumer (ASR bias, alias expansion, gloss injection) may trust it immediately.
    @discardableResult
    public func addTerm(canonical: String, aliases: [String], gloss: String?, group: String) -> String {
        lock.lock(); defer { lock.unlock() }
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
            dirty = true; saveLocked()
            return entities[i].id
        }
        let id = Self.newID()
        entities.append(Entity(id: id, name: trimmed, kind: "term", aliases: normAliases,
                               groups: [group], confirmed: true, gloss: gloss))
        dirty = true; saveLocked()
        return id
    }

    /// ASR bias strings from the vocabulary: canonical spellings plus multi-word aliases
    /// (single-word normalized aliases add nothing the canonical doesn't).
    public func termVocab(group: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return termsLocked(group: group).flatMap { [$0.name] + $0.aliases.filter { $0.contains(" ") } }
    }

    /// Time-ordered unique id (ULID-ish: millisecond timestamp prefix + random) so ids sort by
    /// creation and never collide.
    private static func newID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0...UInt64.max)
        return String(format: "%013x", ms) + String(format: "%016x", rand)
    }
}
