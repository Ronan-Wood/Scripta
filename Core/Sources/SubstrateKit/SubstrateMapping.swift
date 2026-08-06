import Foundation

// MARK: - Wire → vocabulary
//
// The second half of decode-then-map. `WireSearchResult` is `render.py`'s shape; `Passage`,
// `EngineEnvelope` and `ExclusionFilter` are ours. This file is the ONLY place the two meet, so a
// field renamed in the engine costs one edit here instead of reaching into every reader.
//
// Everything below is a translation of a value the engine sent. Nothing is computed, inferred from
// a threshold, or defaulted into the healthy reading — where the wire cannot answer, the mapping
// refuses or makes the caller say so in the signature. Doc 3 §6 (an in-app query and the equivalent
// CLI query must return the same passages, capability and index_version) is only checkable while
// that stays true.

/// What the wire said that this module has no vocabulary for.
public enum SubstrateMappingRefusal: Error, Equatable, CustomStringConvertible {
    /// A spine value that is not in the enum. NOT swallowed into a default: the engine's vocabulary
    /// lives in `spine.py`, and a value added there must be added here rather than silently read as
    /// the nearest neighbour.
    case unknownToken(field: String, value: String, known: [String])

    /// A passage with no `expand_ref` — the query addressed an index by path, so nothing can
    /// identify or re-fetch it. `render.expand_ref` returns null there deliberately: "a handle that
    /// cannot round-trip is worse than an absent one — it looks usable."
    case unaddressablePassage(citation: String)

    public var description: String {
        switch self {
        case .unknownToken(let field, let value, let known):
            return "the engine sent \(field) = \"\(value)\", which this build has no vocabulary "
                + "for. Known: \(known.joined(separator: ", ")). Teach the enum before mapping it."
        case .unaddressablePassage(let citation):
            return "the passage \"\(citation)\" carries no expand_ref, so it cannot be identified "
                + "or expanded. That happens when a query addresses an index by path rather than "
                + "by scope name."
        }
    }
}

private func mapToken<T: RawRepresentable & CaseIterable>(
    _ raw: String, field: String, to: T.Type
) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: raw) else {
        throw SubstrateMappingRefusal.unknownToken(
            field: field, value: raw, known: T.allCases.map(\.rawValue)
        )
    }
    return value
}

/// The class the engine reported, or the absence of one.
///
/// `null` is `.unreported`, NOT `.referenceFrozen`. It says this index row carries no class at all,
/// which is a narrower claim than "the note declared nothing" — the markdown reader already
/// defaulted an undeclared `class:` at ingest, and that is the defaulting that once relabelled six
/// migrated conversations under a fully green compose. A token this build has no class for refuses
/// by name; `mapToken` cannot be used because `PassageDocumentClass` is deliberately not
/// `RawRepresentable` — a raw value would make `unreported` decodable from a wire string.
///
/// ONE HOME, shared by the passage and the browse row. It was copied into both, and the second copy
/// had already grown its own doc comment — which is how copies of a rule start disagreeing.
private func mapDocumentClass(_ token: String?) throws -> PassageDocumentClass {
    guard let token else { return .unreported }
    guard let klass = PassageDocumentClass.named(token) else {
        throw SubstrateMappingRefusal.unknownToken(
            field: "document_class", value: token, known: PassageDocumentClass.wireTokens)
    }
    return klass
}

// MARK: - Passage

extension WirePassage {
    /// One wire passage as a `Passage`.
    ///
    /// `documentClass` USED TO BE A PARAMETER, because `render.passage` did not emit the key and the
    /// caller had to state an axis nobody could know. It does emit it now, so the parameter is gone
    /// and the axis comes off the wire like every other one — the change `RenderContractTests` was
    /// written to demand.
    public func mapped() throws -> Passage {
        guard let expandRef else {
            throw SubstrateMappingRefusal.unaddressablePassage(citation: citation)
        }
        return Passage(
            id: expandRef,
            snippet: snippet,
            citation: citation,
            // `Hit.vault` is nullable and `Passage.vault` is not. Empty rather than a stand-in
            // word: the vault segment is provenance, and inventing one is worse than showing none.
            vault: vault ?? "",
            status: try mapToken(status, field: "status", to: PassageStatus.self),
            docType: try mapToken(docType, field: "doc_type", to: PassageDocType.self),
            confidence: try mapToken(confidence, field: "confidence", to: PassageConfidence.self),
            documentClass: try mapDocumentClass(documentClass),
            domains: domains,
            supersedes: supersedes
        )
    }

}

// MARK: - Vault document

extension WireDocumentRecord {
    /// One wire row as a `VaultDocument`.
    ///
    /// UNLIKE `WirePassage.mapped()`, A MISSING `expandRef` IS NOT A REFUSAL — and the reason is
    /// IDENTITY, not addressability. `Passage.id` IS the expandRef, so a passage without one cannot
    /// be constructed at all and the throw is the only honest answer. `VaultDocument.id` is the
    /// `doc_id`, so here the missing ref is one absent FIELD on a row that still exists, and it is
    /// reported. Throwing would drop that note out of the list of what the vault contains, which is
    /// precisely the claim this list exists to make correctly.
    ///
    /// Every token still goes through `mapToken`, so a spine word this build has no case for
    /// refuses by name rather than arriving as a plausible neighbour.
    public func mapped() throws -> VaultDocument {
        VaultDocument(
            id: docID,
            title: title,
            expandRef: expandRef,
            passageCount: passageCount,
            // Empty rather than a stand-in word, exactly as `Passage.vault` is.
            vault: vault ?? "",
            tier: tier,
            status: try mapToken(status, field: "status", to: PassageStatus.self),
            docType: try mapToken(docType, field: "doc_type", to: PassageDocType.self),
            confidence: try mapToken(confidence, field: "confidence", to: PassageConfidence.self),
            documentClass: try mapDocumentClass(documentClass),
            domains: domains,
            supersedes: supersedes,
            supersededBy: supersededBy
        )
    }

}

extension WireDocumentsResult {
    /// Every row, or the first refusal. ALL-OR-NOTHING on purpose: a list that silently dropped the
    /// rows it could not read would understate the corpus, and understating the corpus is the one
    /// thing a browse must not do — a reader concludes a note is absent rather than unreadable.
    public func mappedDocuments() throws -> [VaultDocument] {
        try documents.map { try $0.mapped() }
    }
}

// MARK: - Applied filters

extension WireAppliedFilters {
    /// `render.applied_filters` as the disclosure the reader sees.
    ///
    /// The `sources` axis comes from `sources_excluded`, not from the status list, because they are
    /// different axes — which is the whole reason `RetrievalClass` carries `sources` as a fifth case
    /// rather than a fifth status.
    public func mapped() throws -> ExclusionFilter {
        var searched = Set<RetrievalClass>()
        for status in statusesIncluded {
            searched.insert(try mapToken(status, field: "statuses_included",
                                         to: RetrievalClass.self))
        }
        if !sourcesExcluded { searched.insert(.sources) }
        return ExclusionFilter(searched: searched, notes: notes)
    }
}

// MARK: - Capability envelope

extension WireRetrievalMode {
    /// The three arms as `EngineArm`s.
    ///
    /// TWO TRANSLATIONS HERE ARE FORCED BY THE ENGINE'S OWN DESIGN, not chosen:
    ///
    /// 1. `"fell_back"` on the wire is `EngineArmState.fellBack`, whose `label` is `"fell back"` —
    ///    a SPACE, because that string is display text. The two used to be one `rawValue`, which
    ///    made `EngineArmState(rawValue: "fell_back")` return nil on every fallen-back arm; the type
    ///    no longer has a raw value, and `byWireToken` is the only door in.
    /// 2. An arm that was requested and could not start reports `off`, byte-identical to an arm
    ///    nobody asked for. `health.arms` is where that distinction survives, so an `off` arm the
    ///    BUILD map calls `unavailable` is promoted. This used to split `unavailable`'s prose on its
    ///    leading token — a contract living in an engine sentence, which nobody can see break.
    ///
    /// THE EMBEDDER NO LONGER UNDERSTATES. Its state used to be derived from `embedder != nil`, so
    /// an embedder that fell back mid-run — which empties that key — read as `off`, the same as one
    /// nobody asked for. `embedder_state` is that arm's own state word and is used directly.
    ///
    /// When `health.arms` is absent (`known: false`, a caller that reported no wiring) no arm is
    /// promoted, and nothing is silently lost: `health` itself maps to `.unreported`, whose note
    /// says in the engine's own words that it cannot answer for a requested arm.
    public func mappedArms() throws -> [EngineArm] {
        [
            EngineArm.embedder(embedder,
                               try armState(embedderState, field: "embedder_state",
                                            arm: "embedder")),
            EngineArm.hyde(nil, try armState(hyde, field: "hyde", arm: "hyde")),
            EngineArm.reranker(nil, try armState(reranker, field: "reranker", arm: "reranker")),
        ]
    }

    private func armState(_ word: String, field: String, arm: String) throws -> EngineArmState {
        guard let state = EngineArmState.byWireToken[word] else {
            throw SubstrateMappingRefusal.unknownToken(
                field: field, value: word, known: EngineArmState.wireTokens
            )
        }
        let requestedButDead = health.arms?[arm] == WireEngineHealth.armUnavailable
        return (state == .off && requestedButDead) ? .unavailable : state
    }

    /// Why there is no measured number, as a value rather than a token.
    ///
    /// `nil` when the engine sent none — which, given the engine's own invariant, means either that
    /// there IS a number or that the engine predates the field. Both are honest absences of a
    /// reason; neither is a reason this side invented.
    public func mappedUnmeasuredReason() throws -> UnmeasuredReason? {
        guard let unmeasuredReason else { return nil }
        return try mapToken(unmeasuredReason, field: "unmeasured_reason", to: UnmeasuredReason.self)
    }
}

// MARK: - Engine health

extension WireEngineHealth {
    /// `render.engine_health` as the condition the envelope reports.
    ///
    /// `known: false` is `.unreported` and NOT `.ready`. That is the whole reason the engine sends
    /// the flag separately: a caller that never said which arms it wired has not reported a healthy
    /// stack, and reading it as one is the same defect as `refresh.frozen` defaulting to `false`.
    ///
    /// `unreachable` does NOT become an installed-vs-down verdict, because the engine refuses to
    /// make one: its probe collapses a refused connection, a timeout and a missing model into a
    /// single answer. `EngineHealth.notInstalled` therefore has no wire source and is never produced
    /// here — inferring it from `unreachable` would be the client claiming a fact nothing measured.
    public func mapped() throws -> EngineHealth {
        guard known else { return .unreported(note) }
        switch state {
        case "ready": return .ready
        case "lexical_only": return .lexicalOnly(note)
        case "unreachable": return .unreachable(note)
        default:
            // Includes `state: null` with `known: true`, which the engine's own contract forbids.
            // A contradiction refuses by name rather than picking whichever half looks healthier.
            throw SubstrateMappingRefusal.unknownToken(
                field: "retrieval_mode.health.state", value: state ?? "null",
                known: ["ready", "lexical_only", "unreachable"]
            )
        }
    }
}

extension WireSearchResult {
    /// The capability half of this payload.
    ///
    /// BOTH FIELDS THAT USED TO HAVE NO WIRE SOURCE NOW HAVE ONE. `unmeasuredReason` is
    /// `retrieval_mode.unmeasured_reason`, a closed token rather than a sentence this side composed;
    /// `health` is `retrieval_mode.health`, and it is passed rather than left at its `.ready`
    /// default — which was a false-healthy reading of a payload that had never been asked.
    ///
    /// One distinction is still NOT on the wire and is not invented here: `EngineHealth`'s
    /// installed-vs-down split. The engine reports `unreachable` and a note saying it cannot
    /// attribute the cause, so `.notInstalled` is never produced by this mapping.
    public func mappedEnvelope() throws -> EngineEnvelope {
        EngineEnvelope(
            scope: Self.mappedScope(scope),
            arms: try retrievalMode.mappedArms(),
            expectedMRR: retrievalMode.expectedMRR.wireValue,
            frozen: refresh.frozen.wireValue,
            unmeasuredReason: try retrievalMode.mappedUnmeasuredReason(),
            cohort: retrievalMode.cohort,
            fallbacks: retrievalMode.fallbacks,
            // ONLY UPWARD. `EngineEnvelope` derives `degraded` from the arms as well as the
            // fallbacks, because a `.fellBack` arm with an empty `fallbacks` array used to render a
            // known-degraded run as clean. Passing the engine's `false` through explicitly would
            // switch that derivation off — the caller-outranks-inference door, walked through by
            // default. So `true` is forwarded (the engine has seen something we cannot) and `false`
            // becomes `nil`, which lets the safety net stay armed.
            degraded: retrievalMode.degraded ? true : nil,
            health: try retrievalMode.health.mapped()
        )
    }

    /// The reader's disclosure for this payload.
    public func mappedFilter() throws -> ExclusionFilter {
        try filters.mapped()
    }

    /// A named corpus, or the fault state.
    ///
    /// `search_payload.scope` is null for a query that addressed an index by path. `EngineScope`
    /// has no failable initialiser on purpose — there is no correct render for an absent scope —
    /// and `.missing` is the one door to the fault state that does not trip its debug trap.
    static func mappedScope(_ raw: String?) -> EngineScope {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missing
        }
        return EngineScope(raw)
    }
}
