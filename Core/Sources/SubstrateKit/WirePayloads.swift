import Foundation

// MARK: - The engine's wire shape, decoded
//
// `substrate/substrate/render.py` is the AUTHORITY on every name and type below, with
// `substrate/substrate/introspect.py` for `status` / `list_scopes`, `substrate/refresh_state.py`
// for the `refresh` block, `substrate/freshness.py` for `drift`, and
// `substrate/substrate/mcp/server.py` for `expand`'s envelope and its `note`. Nothing here is
// inferred from what the view layer would like to receive.
//
// THESE ARE NOT THE VIEW TYPES, and the separation is the point. `Passage`, `EngineEnvelope` and
// `ExclusionFilter` are ours to shape; this file is `render.py`'s. A field renamed there changes
// exactly one file — this one — plus the mapping beside it, instead of reaching into every view
// that reads a passage.
//
// VOCABULARY STAYS STRINGLY HERE ON PURPOSE. `status`, `doc_type` and `confidence` decode as
// `String`, not as `PassageStatus`/`PassageDocType`/`PassageConfidence`. If they were typed at this
// layer, one new status value in `spine.py` would make the WHOLE payload undecodable — a transport
// failure — when the honest outcome is a mapping refusal naming the token nobody taught us. The
// enums are applied in `SubstrateMapping.swift`, where a refusal can say which value it choked on.

// MARK: - Passage

/// One hit as `render.passage` emits it.
///
/// `kind` is present only on `outline_records` (`render.outline_record` sets `rec["kind"] =
/// "outline"`); a passage has no such key, so it is optional here and omitted on re-encode.
///
/// `document_class` is `string | null`, and the null is a VALUE: the index row carries no class at
/// all. It is decoded as `String?` and mapped to `PassageDocumentClass.unreported`, never defaulted
/// to `reference-frozen` — see `SubstrateMapping.swift`.
public struct WirePassage: Codable, Equatable, Sendable {
    /// The scope-qualified handle to pass back to `expand`. `null` when the query addressed an
    /// index by path and there is no scope to resolve a ref through.
    public let expandRef: String?
    public let citation: String
    public let path: String
    public let page: Int?
    public let nChars: Int
    /// What KIND of artifact this came out of (`classes.POLICIES`). `null` when the index row
    /// carries no class — an absence, and NOT recoverable as "the note declared nothing", which the
    /// markdown reader already collapsed into `reference-frozen` at ingest.
    public let documentClass: String?
    public let status: String
    public let docType: String
    public let confidence: String
    public let domains: [String]
    public let vault: String?
    /// A LIST as of schema v8 — `[]` when this note replaced nothing, never null.
    public let supersedes: [String]
    public let snippet: String
    /// The whole text on the `expand` path, `null` on a search result. One key set either way.
    public let text: String?
    /// Content was withheld from THIS payload: true for a cut snippet, false when `text` is full.
    public let truncated: Bool
    /// `"outline"` on an orientation record, absent on a passage.
    public let kind: String?

    public init(expandRef: String?, citation: String, path: String, page: Int?, nChars: Int,
                documentClass: String?, status: String, docType: String, confidence: String,
                domains: [String], vault: String?, supersedes: [String], snippet: String,
                text: String?, truncated: Bool, kind: String? = nil) {
        self.expandRef = expandRef
        self.citation = citation
        self.path = path
        self.page = page
        self.nChars = nChars
        self.documentClass = documentClass
        self.status = status
        self.docType = docType
        self.confidence = confidence
        self.domains = domains
        self.vault = vault
        self.supersedes = supersedes
        self.snippet = snippet
        self.text = text
        self.truncated = truncated
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case expandRef = "expand_ref"
        case citation, path, page
        case nChars = "n_chars"
        case documentClass = "document_class"
        case status
        case docType = "doc_type"
        case confidence, domains, vault, supersedes, snippet, text, truncated, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expandRef = try c.decodeIfPresent(String.self, forKey: .expandRef)
        citation = try c.decode(String.self, forKey: .citation)
        path = try c.decode(String.self, forKey: .path)
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        nChars = try c.decode(Int.self, forKey: .nChars)
        // `decodeIfPresent` collapses "key absent" and "key is null" — both correct. An engine too
        // old to emit the key has reported no class, which maps to the same `unreported`.
        documentClass = try c.decodeIfPresent(String.self, forKey: .documentClass)
        status = try c.decode(String.self, forKey: .status)
        docType = try c.decode(String.self, forKey: .docType)
        confidence = try c.decode(String.self, forKey: .confidence)
        domains = try c.decode([String].self, forKey: .domains)
        vault = try c.decodeIfPresent(String.self, forKey: .vault)
        supersedes = try c.decode([String].self, forKey: .supersedes)
        snippet = try c.decode(String.self, forKey: .snippet)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeExplicitNull(expandRef, forKey: .expandRef)
        try c.encode(citation, forKey: .citation)
        try c.encode(path, forKey: .path)
        try c.encodeExplicitNull(page, forKey: .page)
        try c.encode(nChars, forKey: .nChars)
        try c.encodeExplicitNull(documentClass, forKey: .documentClass)
        try c.encode(status, forKey: .status)
        try c.encode(docType, forKey: .docType)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(domains, forKey: .domains)
        try c.encodeExplicitNull(vault, forKey: .vault)
        try c.encode(supersedes, forKey: .supersedes)
        try c.encode(snippet, forKey: .snippet)
        try c.encodeExplicitNull(text, forKey: .text)
        try c.encode(truncated, forKey: .truncated)
        // The ONE key that is genuinely absent rather than null: `render.passage` never writes it,
        // `render.outline_record` always does.
        try c.encodeIfPresent(kind, forKey: .kind)
    }
}

// MARK: - Refresh

/// `refresh_state.report` — what the unattended refresh agent last did to this scope.
///
/// It reports the AGENT, not the vault: a `refreshed` outcome means the agent recomposed
/// successfully at that timestamp, not that the vault has not moved since. `drift` is the live
/// answer to the other question.
public struct WireRefreshReport: Codable, Sendable {
    /// False when nobody has recorded this scope, when the record is unreadable, or when the query
    /// addressed an index by path and so has no scope to look one up for.
    public let known: Bool
    public let outcome: String?
    /// When the agent last LOOKED at this scope.
    public let attempted: String?
    /// When it last left the scope verified. Carried forward across failures, so the gap between
    /// the two is how long this scope has been going wrong.
    public let succeeded: String?
    public let frozen: FrozenVerdict
    public let frozenSince: String?
    public let note: String?

    /// Whether the server actually sent this block, for round-trip fidelity ONLY.
    ///
    /// Deliberately excluded from `==`: an older server that omits `refresh` entirely must be
    /// indistinguishable, to every consumer, from one that sent `known: false`. The flag exists so
    /// re-encoding a captured payload does not invent a key the engine did not write.
    public let wasSent: Bool

    /// What an omitted block means. Not `frozen: false` — there is no basis for that.
    public static let absent = WireRefreshReport(
        known: false, outcome: nil, attempted: nil, succeeded: nil,
        frozen: .noBasis, frozenSince: nil, note: nil, wasSent: false
    )

    public init(known: Bool, outcome: String?, attempted: String?, succeeded: String?,
                frozen: FrozenVerdict, frozenSince: String?, note: String?, wasSent: Bool = true) {
        self.known = known
        self.outcome = outcome
        self.attempted = attempted
        self.succeeded = succeeded
        self.frozen = frozen
        self.frozenSince = frozenSince
        self.note = note
        self.wasSent = wasSent
    }

    enum CodingKeys: String, CodingKey {
        case known, outcome, attempted, succeeded, frozen
        case frozenSince = "frozen_since"
        case note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decode(Bool.self, forKey: .known)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        attempted = try c.decodeIfPresent(String.self, forKey: .attempted)
        succeeded = try c.decodeIfPresent(String.self, forKey: .succeeded)
        // `decodeIfPresent` collapses "key absent" and "key is null" — both correct here. A server
        // too old to send `frozen` has said nothing about it, which is exactly `.noBasis`.
        frozen = FrozenVerdict(try c.decodeIfPresent(Bool.self, forKey: .frozen))
        frozenSince = try c.decodeIfPresent(String.self, forKey: .frozenSince)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        wasSent = true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(known, forKey: .known)
        try c.encodeExplicitNull(outcome, forKey: .outcome)
        try c.encodeExplicitNull(attempted, forKey: .attempted)
        try c.encodeExplicitNull(succeeded, forKey: .succeeded)
        try c.encodeExplicitNull(frozen.wireValue, forKey: .frozen)
        try c.encodeExplicitNull(frozenSince, forKey: .frozenSince)
        try c.encodeExplicitNull(note, forKey: .note)
    }
}

extension WireRefreshReport: Equatable {
    /// Content only — see `wasSent`.
    public static func == (lhs: WireRefreshReport, rhs: WireRefreshReport) -> Bool {
        lhs.known == rhs.known && lhs.outcome == rhs.outcome && lhs.attempted == rhs.attempted
            && lhs.succeeded == rhs.succeeded && lhs.frozen == rhs.frozen
            && lhs.frozenSince == rhs.frozenSince && lhs.note == rhs.note
    }
}

extension KeyedDecodingContainer {
    /// The refresh block, or what its absence means. One call site per payload so the "absent reads
    /// as `known: false`" rule cannot be implemented differently in three places.
    func decodeRefresh(forKey key: Key) throws -> WireRefreshReport {
        try decodeIfPresent(WireRefreshReport.self, forKey: key) ?? .absent
    }
}

// MARK: - Retrieval mode

/// `render.engine_health` — the condition of the ARMS THEMSELVES, a different axis from what they
/// did on this query. Always present in `retrieval_mode`, always with all four keys.
///
/// This block is what retired the client's parse of `unavailable`'s prose. The engine builds each
/// entry there with the arm's name first, and the Swift side used to recover the arm by splitting on
/// the leading token — a contract in a sentence, which nobody can see break. `arms` is the same fact
/// as structure, and `render.engine_health` forces `unreachable` whenever `unavailable` is non-empty
/// even when it could attribute nothing, so the two carriers cannot contradict each other.
public struct WireEngineHealth: Codable, Equatable, Sendable {
    /// `false` when the caller reported no wiring. NOT folded into `ready`.
    public let known: Bool
    /// `"ready"`, `"lexical_only"`, `"unreachable"` — `null` iff `known` is false.
    public let state: String?
    /// Per-arm BUILD state (`stack.ARM_*`): `"wired"`, `"unavailable"`, `"off"`. `null` iff `known`
    /// is false. Every arm always appears when it is present at all.
    public let arms: [String: String]?
    /// `null` only in the `ready` case — a healthy stack does not need a sentence.
    public let note: String?

    /// `stack.ARM_UNAVAILABLE`, named once. The one value in `arms` the mapping acts on, so it is a
    /// constant with a contract test behind it rather than a literal at the comparison.
    public static let armUnavailable = "unavailable"

    public init(known: Bool, state: String?, arms: [String: String]?, note: String?) {
        self.known = known
        self.state = state
        self.arms = arms
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case known, state, arms, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decode(Bool.self, forKey: .known)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        arms = try c.decodeIfPresent([String: String].self, forKey: .arms)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(known, forKey: .known)
        try c.encodeExplicitNull(state, forKey: .state)
        try c.encodeExplicitNull(arms, forKey: .arms)
        try c.encodeExplicitNull(note, forKey: .note)
    }
}

/// `render.retrieval_mode` — which arms actually ran and what that is measured to be worth.
public struct WireRetrievalMode: Codable, Equatable, Sendable {
    /// The embedder KEY that ran, or `null`. Null is absence, not the string `"lexical-only"`.
    public let embedder: String?
    /// The embedder's STATE WORD, in the same vocabulary the other two arms use: `"ran"`, `"off"`,
    /// `"fell_back"`. It exists because `embedder` alone could not say it — a key that empties on a
    /// fallback is byte-identical to an arm nobody asked for, so the arm the coverage guard degrades
    /// most often was the one arm incapable of reporting that it had. Refines `embedder` strictly:
    /// `"ran"` iff that key is non-null.
    public let embedderState: String
    /// A STATE WORD, not a model name: `"ran"`, `"off"`, `"fell_back"`
    /// (`retriever._capability`).
    public let hyde: String
    /// A state word: `"ran"`, `"skipped"` (the adaptive gate declined), `"off"`, `"fell_back"`.
    public let reranker: String
    public let expectedMRR: MeasuredMRR
    /// A `retriever.UNMEASURED_REASONS` token, or `null` — and `null` iff `expectedMRR` is a number.
    /// Stringly here like every other vocabulary: an unknown token must refuse in the mapping, by
    /// name, rather than make the whole payload undecodable.
    public let unmeasuredReason: String?
    /// The eval cohort `expectedMRR` was measured on. Travels with every number so nothing compares
    /// across cohorts.
    public let cohort: String
    public let degraded: Bool
    /// Arms that dropped mid-run, with reasons. A field, not a log.
    public let fallbacks: [String]
    /// Arms that were REQUESTED and could not start — the one thing `Capability` cannot say,
    /// because such an arm reports `off`, which is byte-identical to an arm nobody asked for.
    /// Free prose built by `stack.py`, each entry led by the arm's name. KEPT FOR WHAT IS UNIQUELY
    /// ITS OWN — the model, and the host it was looked for at — which is what a human acts on. The
    /// arm NAMES come from `health.arms` instead; nothing here is parsed any more.
    public let unavailable: [String]
    /// The same condition as structure, for all three arms at once. Always sent.
    public let health: WireEngineHealth

    public init(embedder: String?, embedderState: String, hyde: String, reranker: String,
                expectedMRR: MeasuredMRR, unmeasuredReason: String?, cohort: String,
                degraded: Bool, fallbacks: [String], unavailable: [String],
                health: WireEngineHealth) {
        self.embedder = embedder
        self.embedderState = embedderState
        self.hyde = hyde
        self.reranker = reranker
        self.expectedMRR = expectedMRR
        self.unmeasuredReason = unmeasuredReason
        self.cohort = cohort
        self.degraded = degraded
        self.fallbacks = fallbacks
        self.unavailable = unavailable
        self.health = health
    }

    enum CodingKeys: String, CodingKey {
        case embedder
        case embedderState = "embedder_state"
        case hyde, reranker
        case expectedMRR = "expected_mrr"
        case unmeasuredReason = "unmeasured_reason"
        case cohort, degraded, fallbacks, unavailable, health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        embedder = try c.decodeIfPresent(String.self, forKey: .embedder)
        // REQUIRED, both of them. An engine that omits either is older than this contract, and the
        // honest outcome is one loud `.undecodablePayload` naming the key — not an envelope that
        // quietly re-derives the embedder's state from a model key, which is the exact
        // understatement `embedder_state` was added to end.
        embedderState = try c.decode(String.self, forKey: .embedderState)
        hyde = try c.decode(String.self, forKey: .hyde)
        reranker = try c.decode(String.self, forKey: .reranker)
        expectedMRR = MeasuredMRR(try c.decodeIfPresent(Double.self, forKey: .expectedMRR))
        unmeasuredReason = try c.decodeIfPresent(String.self, forKey: .unmeasuredReason)
        cohort = try c.decode(String.self, forKey: .cohort)
        degraded = try c.decode(Bool.self, forKey: .degraded)
        fallbacks = try c.decode([String].self, forKey: .fallbacks)
        unavailable = try c.decode([String].self, forKey: .unavailable)
        health = try c.decode(WireEngineHealth.self, forKey: .health)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeExplicitNull(embedder, forKey: .embedder)
        try c.encode(embedderState, forKey: .embedderState)
        try c.encode(hyde, forKey: .hyde)
        try c.encode(reranker, forKey: .reranker)
        try c.encodeExplicitNull(expectedMRR.wireValue, forKey: .expectedMRR)
        try c.encodeExplicitNull(unmeasuredReason, forKey: .unmeasuredReason)
        try c.encode(cohort, forKey: .cohort)
        try c.encode(degraded, forKey: .degraded)
        try c.encode(fallbacks, forKey: .fallbacks)
        try c.encode(unavailable, forKey: .unavailable)
        try c.encode(health, forKey: .health)
    }
}

// MARK: - Applied filters

/// `render.applied_filters` — what this result set left out, said out loud.
public struct WireAppliedFilters: Codable, Equatable, Sendable {
    public let statusesIncluded: [String]
    /// The complement, carried alongside on purpose: a caller who does not know the status
    /// vocabulary cannot derive it, and "archived and superseded notes were withheld" is the
    /// difference between a gap in the corpus and a gap in the query.
    public let statusesExcluded: [String]
    /// Whether a conversation-class passage could be in these results. Not "did one SQL clause
    /// run" — a filter naming `reference-frozen` withholds every conversation by being the filter.
    public let sourcesExcluded: Bool
    /// The note-JOB axis (`spine.DOC_TYPES`). A different axis from `documentClass`.
    public let docType: String?
    /// What KIND of artifact (`classes.POLICIES`): reference-frozen, conversation.
    public let documentClass: String?
    /// Anything else that narrowed this result set — a clamped `k`, today. Always present, empty
    /// when there is nothing to say.
    public let notes: [String]

    public init(statusesIncluded: [String], statusesExcluded: [String], sourcesExcluded: Bool,
                docType: String?, documentClass: String?, notes: [String]) {
        self.statusesIncluded = statusesIncluded
        self.statusesExcluded = statusesExcluded
        self.sourcesExcluded = sourcesExcluded
        self.docType = docType
        self.documentClass = documentClass
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case statusesIncluded = "statuses_included"
        case statusesExcluded = "statuses_excluded"
        case sourcesExcluded = "sources_excluded"
        case docType = "doc_type"
        case documentClass = "document_class"
        case notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusesIncluded = try c.decode([String].self, forKey: .statusesIncluded)
        statusesExcluded = try c.decode([String].self, forKey: .statusesExcluded)
        sourcesExcluded = try c.decode(Bool.self, forKey: .sourcesExcluded)
        docType = try c.decodeIfPresent(String.self, forKey: .docType)
        documentClass = try c.decodeIfPresent(String.self, forKey: .documentClass)
        notes = try c.decode([String].self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(statusesIncluded, forKey: .statusesIncluded)
        try c.encode(statusesExcluded, forKey: .statusesExcluded)
        try c.encode(sourcesExcluded, forKey: .sourcesExcluded)
        try c.encodeExplicitNull(docType, forKey: .docType)
        try c.encodeExplicitNull(documentClass, forKey: .documentClass)
        try c.encode(notes, forKey: .notes)
    }
}

// MARK: - search

/// `render.search_payload` — the whole envelope.
public struct WireSearchResult: Codable, Equatable, Sendable {
    /// `null` for a query that addressed an index by path. `scope` and `indexVersion` travel
    /// together because either alone is unfalsifiable when one server serves several indexes.
    public let scope: String?
    public let db: String?
    public let query: String
    public let passages: [WirePassage]
    /// Orientation records — which SECTIONS matched, alongside an unchanged passage ranking.
    public let outlineRecords: [WirePassage]
    public let retrievalMode: WireRetrievalMode
    public let filters: WireAppliedFilters
    public let indexVersion: String
    public let refresh: WireRefreshReport

    public init(scope: String?, db: String?, query: String, passages: [WirePassage],
                outlineRecords: [WirePassage], retrievalMode: WireRetrievalMode,
                filters: WireAppliedFilters, indexVersion: String, refresh: WireRefreshReport) {
        self.scope = scope
        self.db = db
        self.query = query
        self.passages = passages
        self.outlineRecords = outlineRecords
        self.retrievalMode = retrievalMode
        self.filters = filters
        self.indexVersion = indexVersion
        self.refresh = refresh
    }

    enum CodingKeys: String, CodingKey {
        case scope, db, query, passages
        case outlineRecords = "outline_records"
        case retrievalMode = "retrieval_mode"
        case filters
        case indexVersion = "index_version"
        case refresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        db = try c.decodeIfPresent(String.self, forKey: .db)
        query = try c.decode(String.self, forKey: .query)
        passages = try c.decode([WirePassage].self, forKey: .passages)
        outlineRecords = try c.decode([WirePassage].self, forKey: .outlineRecords)
        retrievalMode = try c.decode(WireRetrievalMode.self, forKey: .retrievalMode)
        filters = try c.decode(WireAppliedFilters.self, forKey: .filters)
        indexVersion = try c.decode(String.self, forKey: .indexVersion)
        refresh = try c.decodeRefresh(forKey: .refresh)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeExplicitNull(scope, forKey: .scope)
        try c.encodeExplicitNull(db, forKey: .db)
        try c.encode(query, forKey: .query)
        try c.encode(passages, forKey: .passages)
        try c.encode(outlineRecords, forKey: .outlineRecords)
        try c.encode(retrievalMode, forKey: .retrievalMode)
        try c.encode(filters, forKey: .filters)
        try c.encode(indexVersion, forKey: .indexVersion)
        if refresh.wasSent { try c.encode(refresh, forKey: .refresh) }
    }
}

// MARK: - documents (browse)

/// `render.document_record` — one note as a browser sees it.
///
/// DELIBERATELY NOT A `WirePassage`. A passage carries a snippet cut for a query; a browse row has
/// no query behind it, so there is no snippet and `passageCount` says how much there is instead —
/// a size, which cannot be mistaken for a summary the way an arbitrary first sentence could.
public struct WireDocumentRecord: Codable, Equatable, Sendable {
    public let docID: String
    /// `null` for a note whose frontmatter names no title.
    public let title: String?
    /// The handle `expand` reads the note with. `null` for a note with no passages — a real state
    /// (an empty note is still in the corpus and still appears in this list), not an error.
    public let expandRef: String?
    public let passageCount: Int
    /// WHICH vault in the inheritance chain this note composed from. `null` on a row the index
    /// carries no provenance for.
    public let vault: String?
    public let tier: Int?
    /// The note's own file, in the vault — not the derived artifact under the index root.
    public let sourcePath: String?
    public let documentClass: String?
    public let status: String
    public let docType: String
    public let confidence: String
    public let domains: [String]
    /// A LIST as of schema v8 — `[]` when this note replaced nothing, never null.
    public let supersedes: [String]
    /// The live note that replaced this dead one. Scalar, because a dead note has exactly one.
    public let supersededBy: String?

    public init(docID: String, title: String?, expandRef: String?, passageCount: Int,
                vault: String?, tier: Int?, sourcePath: String?, documentClass: String?,
                status: String, docType: String, confidence: String, domains: [String],
                supersedes: [String], supersededBy: String?) {
        self.docID = docID
        self.title = title
        self.expandRef = expandRef
        self.passageCount = passageCount
        self.vault = vault
        self.tier = tier
        self.sourcePath = sourcePath
        self.documentClass = documentClass
        self.status = status
        self.docType = docType
        self.confidence = confidence
        self.domains = domains
        self.supersedes = supersedes
        self.supersededBy = supersededBy
    }

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case title
        case expandRef = "expand_ref"
        case passageCount = "passage_count"
        case vault, tier
        case sourcePath = "source_path"
        case documentClass = "document_class"
        case status
        case docType = "doc_type"
        case confidence, domains, supersedes
        case supersededBy = "superseded_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docID = try c.decode(String.self, forKey: .docID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        expandRef = try c.decodeIfPresent(String.self, forKey: .expandRef)
        passageCount = try c.decode(Int.self, forKey: .passageCount)
        vault = try c.decodeIfPresent(String.self, forKey: .vault)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        documentClass = try c.decodeIfPresent(String.self, forKey: .documentClass)
        status = try c.decode(String.self, forKey: .status)
        docType = try c.decode(String.self, forKey: .docType)
        confidence = try c.decode(String.self, forKey: .confidence)
        domains = try c.decode([String].self, forKey: .domains)
        supersedes = try c.decode([String].self, forKey: .supersedes)
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(docID, forKey: .docID)
        try c.encodeExplicitNull(title, forKey: .title)
        try c.encodeExplicitNull(expandRef, forKey: .expandRef)
        try c.encode(passageCount, forKey: .passageCount)
        try c.encodeExplicitNull(vault, forKey: .vault)
        try c.encodeExplicitNull(tier, forKey: .tier)
        try c.encodeExplicitNull(sourcePath, forKey: .sourcePath)
        try c.encodeExplicitNull(documentClass, forKey: .documentClass)
        try c.encode(status, forKey: .status)
        try c.encode(docType, forKey: .docType)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(domains, forKey: .domains)
        try c.encode(supersedes, forKey: .supersedes)
        try c.encodeExplicitNull(supersededBy, forKey: .supersededBy)
    }
}

/// `render.documents_payload` — the browse envelope.
///
/// `search`'s outer shape MINUS `retrieval_mode`, and the absence is load-bearing: nothing
/// retrieved, so there are no arms to report, and a null `expected_mrr` attached here would invite
/// the reading that the LIST is unmeasured rather than inapplicable.
public struct WireDocumentsResult: Codable, Equatable, Sendable {
    public let scope: String?
    public let db: String?
    public let documents: [WireDocumentRecord]
    /// How many came back on this page, against how many MATCHED. Both, because a page shorter
    /// than the limit and a corpus that is genuinely that size are otherwise indistinguishable.
    public let returned: Int
    public let total: Int
    public let filters: WireAppliedFilters
    public let indexVersion: String
    public let refresh: WireRefreshReport

    public init(scope: String?, db: String?, documents: [WireDocumentRecord], returned: Int,
                total: Int, filters: WireAppliedFilters, indexVersion: String,
                refresh: WireRefreshReport) {
        self.scope = scope
        self.db = db
        self.documents = documents
        self.returned = returned
        self.total = total
        self.filters = filters
        self.indexVersion = indexVersion
        self.refresh = refresh
    }

    enum CodingKeys: String, CodingKey {
        case scope, db, documents, returned, total, filters
        case indexVersion = "index_version"
        case refresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        db = try c.decodeIfPresent(String.self, forKey: .db)
        documents = try c.decode([WireDocumentRecord].self, forKey: .documents)
        returned = try c.decode(Int.self, forKey: .returned)
        total = try c.decode(Int.self, forKey: .total)
        filters = try c.decode(WireAppliedFilters.self, forKey: .filters)
        indexVersion = try c.decode(String.self, forKey: .indexVersion)
        refresh = try c.decodeRefresh(forKey: .refresh)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeExplicitNull(scope, forKey: .scope)
        try c.encodeExplicitNull(db, forKey: .db)
        try c.encode(documents, forKey: .documents)
        try c.encode(returned, forKey: .returned)
        try c.encode(total, forKey: .total)
        try c.encode(filters, forKey: .filters)
        try c.encode(indexVersion, forKey: .indexVersion)
        if refresh.wasSent { try c.encode(refresh, forKey: .refresh) }
    }
}

// MARK: - drift

/// `freshness.drift` — the vault compared against what the index holds.
public struct WireDriftDetail: Codable, Equatable, Sendable {
    /// Something DEFINITELY differs. Read WITH `checkable`: `stale: false, checkable: false` is
    /// "no change found, and some notes were not examined".
    public let stale: Bool
    /// False when at least one indexed note could not be read.
    public let checkable: Bool
    /// Composed by the manifest, absent from the index.
    public let added: [String]
    public let removed: [String]
    public let changed: [String]
    public let checked: Int
    /// Notes whose stored checksum is a DECLARED one, so a body edit is invisible from the index.
    /// The honest boundary of what `stale: false` means.
    public let unverifiable: Int
    public let unreadable: [String]

    public init(stale: Bool, checkable: Bool, added: [String], removed: [String],
                changed: [String], checked: Int, unverifiable: Int, unreadable: [String]) {
        self.stale = stale
        self.checkable = checkable
        self.added = added
        self.removed = removed
        self.changed = changed
        self.checked = checked
        self.unverifiable = unverifiable
        self.unreadable = unreadable
    }

    /// The two fields read together, which `freshness.drift` says a consumer MUST do. Derived from
    /// engine values only — no threshold, no policy.
    public enum Verdict: Equatable, Sendable {
        /// Notes were added, removed or changed since this index was built.
        case moved
        /// Every composed note was examined and none differ.
        case unchangedAndComplete
        /// Nothing was found to differ, but some notes could not be examined.
        case unchangedButIncomplete
    }

    public var verdict: Verdict {
        if stale { return .moved }
        return checkable ? .unchangedAndComplete : .unchangedButIncomplete
    }
}

/// `status.drift` — A SUM TYPE, and this is the specific bug `introspect.py` was written to
/// prevent.
///
/// `status_payload` puts `{"error": "..."}` in the drift slot when the scope cannot be RESOLVED —
/// the vault is gone, a manifest is malformed — precisely because "a missing key reads as 'nothing
/// has changed'". A struct of optionals here would decode that error payload as all-nil, which is
/// the same false-clean reading one layer up. So the two shapes are two cases, and a consumer
/// cannot read one without deciding what to do about the other.
public enum WireDriftReport: Codable, Equatable, Sendable {
    case checked(WireDriftDetail)
    /// The scope could not be drift-checked at all. NOTE THE COARSENESS: the whole
    /// added/changed/removed breakdown is replaced by this message, so `status` says UNCHECKABLE
    /// for an authoring fault too.
    case unavailable(String)

    private enum ErrorKey: String, CodingKey { case error }

    public init(from decoder: Decoder) throws {
        // The `error` key is the discriminator, exactly as `introspect.status_payload` writes it.
        // Tried FIRST: an error payload has none of the detail keys, so attempting the detail shape
        // first would fail with a keyNotFound that says nothing about what actually happened.
        if let c = try? decoder.container(keyedBy: ErrorKey.self),
           let message = try? c.decode(String.self, forKey: .error) {
            self = .unavailable(message)
            return
        }
        self = .checked(try WireDriftDetail(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .checked(let detail):
            try detail.encode(to: encoder)
        case .unavailable(let message):
            var c = encoder.container(keyedBy: ErrorKey.self)
            try c.encode(message, forKey: .error)
        }
    }
}

// MARK: - status

/// `introspect.arms` — which arms this PROCESS is wired with. Distinct from what any one query
/// achieved, which is `retrieval_mode`'s job.
public struct WireRetrievalArms: Codable, Equatable, Sendable {
    public let embedder: String?
    public let hyde: String?
    public let reranker: String?
    public let unavailable: [String]

    public init(embedder: String?, hyde: String?, reranker: String?, unavailable: [String]) {
        self.embedder = embedder
        self.hyde = hyde
        self.reranker = reranker
        self.unavailable = unavailable
    }

    enum CodingKeys: String, CodingKey { case embedder, hyde, reranker, unavailable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        embedder = try c.decodeIfPresent(String.self, forKey: .embedder)
        hyde = try c.decodeIfPresent(String.self, forKey: .hyde)
        reranker = try c.decodeIfPresent(String.self, forKey: .reranker)
        unavailable = try c.decode([String].self, forKey: .unavailable)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeExplicitNull(embedder, forKey: .embedder)
        try c.encodeExplicitNull(hyde, forKey: .hyde)
        try c.encodeExplicitNull(reranker, forKey: .reranker)
        try c.encode(unavailable, forKey: .unavailable)
    }
}

/// `introspect.vector_status` — COMPLETENESS of the configured embedder's coverage, not presence.
/// The whole block is `null` when no vector arm is wired.
public struct WireVectorStatus: Codable, Equatable, Sendable {
    public let model: String
    public let stored: Int
    public let chunks: Int
    /// `chunks > 0 && stored >= chunks`. An EMPTY index is not complete coverage — zero chunks is
    /// the absence of coverage, not the completion of it.
    public let complete: Bool
    public let note: String?

    public init(model: String, stored: Int, chunks: Int, complete: Bool, note: String?) {
        self.model = model
        self.stored = stored
        self.chunks = chunks
        self.complete = complete
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case model, stored, chunks, complete, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        stored = try c.decode(Int.self, forKey: .stored)
        chunks = try c.decode(Int.self, forKey: .chunks)
        complete = try c.decode(Bool.self, forKey: .complete)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(stored, forKey: .stored)
        try c.encode(chunks, forKey: .chunks)
        try c.encode(complete, forKey: .complete)
        try c.encodeExplicitNull(note, forKey: .note)
    }
}

/// `introspect.status_payload` — everything `status` reports for one composed scope.
public struct WireStatusResult: Codable, Equatable, Sendable {
    public let scope: String
    public let db: String
    public let vault: String
    public let composed: String
    public let indexVersion: String
    public let documents: Int
    public let passages: Int
    public let outlines: Int
    public let schemaVersion: Int
    public let byVault: [String: Int]
    public let byTier: [String: Int]
    public let byStatus: [String: Int]
    public let byDocType: [String: Int]
    public let byConfidence: [String: Int]
    public let retrievalArms: WireRetrievalArms
    /// `null` when no vector arm is wired at all.
    public let vectors: WireVectorStatus?
    public let refresh: WireRefreshReport
    public let drift: WireDriftReport

    public init(scope: String, db: String, vault: String, composed: String, indexVersion: String,
                documents: Int, passages: Int, outlines: Int, schemaVersion: Int,
                byVault: [String: Int], byTier: [String: Int], byStatus: [String: Int],
                byDocType: [String: Int], byConfidence: [String: Int],
                retrievalArms: WireRetrievalArms, vectors: WireVectorStatus?,
                refresh: WireRefreshReport, drift: WireDriftReport) {
        self.scope = scope
        self.db = db
        self.vault = vault
        self.composed = composed
        self.indexVersion = indexVersion
        self.documents = documents
        self.passages = passages
        self.outlines = outlines
        self.schemaVersion = schemaVersion
        self.byVault = byVault
        self.byTier = byTier
        self.byStatus = byStatus
        self.byDocType = byDocType
        self.byConfidence = byConfidence
        self.retrievalArms = retrievalArms
        self.vectors = vectors
        self.refresh = refresh
        self.drift = drift
    }

    enum CodingKeys: String, CodingKey {
        case scope, db, vault, composed
        case indexVersion = "index_version"
        case documents, passages, outlines
        case schemaVersion = "schema_version"
        case byVault = "by_vault"
        case byTier = "by_tier"
        case byStatus = "by_status"
        case byDocType = "by_doc_type"
        case byConfidence = "by_confidence"
        case retrievalArms = "retrieval_arms"
        case vectors, refresh, drift
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        db = try c.decode(String.self, forKey: .db)
        vault = try c.decode(String.self, forKey: .vault)
        composed = try c.decode(String.self, forKey: .composed)
        indexVersion = try c.decode(String.self, forKey: .indexVersion)
        documents = try c.decode(Int.self, forKey: .documents)
        passages = try c.decode(Int.self, forKey: .passages)
        outlines = try c.decode(Int.self, forKey: .outlines)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        byVault = try c.decode([String: Int].self, forKey: .byVault)
        byTier = try c.decode([String: Int].self, forKey: .byTier)
        byStatus = try c.decode([String: Int].self, forKey: .byStatus)
        byDocType = try c.decode([String: Int].self, forKey: .byDocType)
        byConfidence = try c.decode([String: Int].self, forKey: .byConfidence)
        retrievalArms = try c.decode(WireRetrievalArms.self, forKey: .retrievalArms)
        vectors = try c.decodeIfPresent(WireVectorStatus.self, forKey: .vectors)
        refresh = try c.decodeRefresh(forKey: .refresh)
        drift = try c.decode(WireDriftReport.self, forKey: .drift)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(db, forKey: .db)
        try c.encode(vault, forKey: .vault)
        try c.encode(composed, forKey: .composed)
        try c.encode(indexVersion, forKey: .indexVersion)
        try c.encode(documents, forKey: .documents)
        try c.encode(passages, forKey: .passages)
        try c.encode(outlines, forKey: .outlines)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(byVault, forKey: .byVault)
        try c.encode(byTier, forKey: .byTier)
        try c.encode(byStatus, forKey: .byStatus)
        try c.encode(byDocType, forKey: .byDocType)
        try c.encode(byConfidence, forKey: .byConfidence)
        try c.encode(retrievalArms, forKey: .retrievalArms)
        try c.encodeExplicitNull(vectors, forKey: .vectors)
        if refresh.wasSent { try c.encode(refresh, forKey: .refresh) }
        try c.encode(drift, forKey: .drift)
    }
}

// MARK: - list_scopes

/// One row of `introspect.scopes_payload`.
public struct WireScopeRow: Codable, Equatable, Sendable {
    public let scope: String
    public let db: String
    public let vault: String
    public let composed: String
    public let indexPresent: Bool
    public let refresh: WireRefreshReport
    /// The vaults this scope composes, resolved fresh from the manifest. `null` when resolution
    /// failed, in which case `error` says why.
    public let sources: [String]?
    /// Present ONLY on a resolution failure — a scope whose inheritance no longer resolves is
    /// listed WITH its fault, because omitting it would read as "that scope was never composed".
    public let error: String?

    public init(scope: String, db: String, vault: String, composed: String, indexPresent: Bool,
                refresh: WireRefreshReport, sources: [String]?, error: String?) {
        self.scope = scope
        self.db = db
        self.vault = vault
        self.composed = composed
        self.indexPresent = indexPresent
        self.refresh = refresh
        self.sources = sources
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case scope, db, vault, composed
        case indexPresent = "index_present"
        case refresh, sources, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        db = try c.decode(String.self, forKey: .db)
        vault = try c.decode(String.self, forKey: .vault)
        composed = try c.decode(String.self, forKey: .composed)
        indexPresent = try c.decode(Bool.self, forKey: .indexPresent)
        refresh = try c.decodeRefresh(forKey: .refresh)
        sources = try c.decodeIfPresent([String].self, forKey: .sources)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(db, forKey: .db)
        try c.encode(vault, forKey: .vault)
        try c.encode(composed, forKey: .composed)
        try c.encode(indexPresent, forKey: .indexPresent)
        if refresh.wasSent { try c.encode(refresh, forKey: .refresh) }
        try c.encodeExplicitNull(sources, forKey: .sources)
        // `error` is the one key `scopes_payload` sets conditionally, in its except branch. Omitted
        // here when absent for the same reason.
        try c.encodeIfPresent(error, forKey: .error)
    }
}

public struct WireScopeList: Codable, Equatable, Sendable {
    public let scopes: [WireScopeRow]
    public let registry: String

    public init(scopes: [WireScopeRow], registry: String) {
        self.scopes = scopes
        self.registry = registry
    }

    enum CodingKeys: String, CodingKey { case scopes, registry }
}

// MARK: - expand

/// `mcp/server._note_text` — the whole note behind a passage, read from the VAULT rather than from
/// the derived copy in the index.
public struct WireNote: Codable, Equatable, Sendable {
    public let path: String
    public let text: String
    public let nChars: Int
    public let truncated: Bool
    public let stale: StaleVerdict

    public init(path: String, text: String, nChars: Int, truncated: Bool, stale: StaleVerdict) {
        self.path = path
        self.text = text
        self.nChars = nChars
        self.truncated = truncated
        self.stale = stale
    }

    enum CodingKeys: String, CodingKey {
        case path, text
        case nChars = "n_chars"
        case truncated, stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        text = try c.decode(String.self, forKey: .text)
        nChars = try c.decode(Int.self, forKey: .nChars)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        stale = StaleVerdict(try c.decodeIfPresent(Bool.self, forKey: .stale))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(text, forKey: .text)
        try c.encode(nChars, forKey: .nChars)
        try c.encode(truncated, forKey: .truncated)
        try c.encodeExplicitNull(stale.wireValue, forKey: .stale)
    }
}

/// `mcp/server._tool_expand` — the same passage envelope with the whole text, plus the note when
/// `mode: "note"` was asked for.
public struct WireExpandResult: Codable, Equatable, Sendable {
    public let scope: String
    public let mode: String
    public let indexVersion: String
    public let passage: WirePassage
    /// Present only for `mode: "note"`.
    public let note: WireNote?

    public init(scope: String, mode: String, indexVersion: String, passage: WirePassage,
                note: WireNote?) {
        self.scope = scope
        self.mode = mode
        self.indexVersion = indexVersion
        self.passage = passage
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case scope, mode
        case indexVersion = "index_version"
        case passage, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        mode = try c.decode(String.self, forKey: .mode)
        indexVersion = try c.decode(String.self, forKey: .indexVersion)
        passage = try c.decode(WirePassage.self, forKey: .passage)
        note = try c.decodeIfPresent(WireNote.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(mode, forKey: .mode)
        try c.encode(indexVersion, forKey: .indexVersion)
        try c.encode(passage, forKey: .passage)
        // Genuinely absent on the `passage` mode, not null.
        try c.encodeIfPresent(note, forKey: .note)
    }
}
