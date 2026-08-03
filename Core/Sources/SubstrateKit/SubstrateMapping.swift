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

// MARK: - Passage

extension WirePassage {
    /// One wire passage as a `Passage`.
    ///
    /// `documentClass` IS A PARAMETER AND HAS NO DEFAULT, and that is the whole point of this
    /// signature. `index_store.Hit` carries a `document_class`; `render.passage` does not emit it.
    /// So the axis is simply not on the wire — and it is drawn, as a stated spine axis
    /// (`Sources/Theme/Components/Passage.swift`, `SpineAxis("document_class", documentClass)`).
    /// Defaulting it to `.referenceFrozen` would print an axis the engine never reported: right
    /// two-thirds of the time by luck, and on a conversation it is exactly the lie
    /// `PassageDocumentClass` was written to prevent.
    ///
    /// `filters.sources_excluded` does not rescue it either. `classes.EXCLUDED_CLASSES` is
    /// `{"conversation"}`, so excluding sources rules out ONE of the three values and leaves
    /// `reference-frozen` and `reference-versioned` indistinguishable.
    ///
    /// When `render.passage` starts emitting the key, `RenderContractTests` fails; the fix is to
    /// decode it and delete this parameter.
    public func mapped(documentClass: PassageDocumentClass) throws -> Passage {
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
            documentClass: documentClass,
            domains: domains,
            supersedes: supersedes
        )
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
    /// 1. `"fell_back"` on the wire is `EngineArmState.fellBack`, whose `rawValue` is `"fell back"`
    ///    — a SPACE, because that string is display text. `EngineArmState(rawValue:)` would return
    ///    nil on every fallen-back arm and quietly lose the one state that matters most.
    /// 2. An arm that was requested and could not start reports `off`, byte-identical to an arm
    ///    nobody asked for; `render.retrieval_mode` says so out loud and carries `unavailable` as a
    ///    separate field precisely because `Capability` cannot express the difference. So an `off`
    ///    arm named in `unavailable` is promoted to `.unavailable`. Matching is on the LEADING
    ///    TOKEN of each entry, which is how `stack.py` builds all three; `RenderContractTests` pins
    ///    that.
    ///
    /// KNOWN FIDELITY LOSS, stated rather than hidden: an embedder that fell back mid-run arrives
    /// as `embedder: null`, which is the same value an embedder that never ran sends, so its arm
    /// maps to `.off` rather than `.fellBack`. It does not read as healthy — `degraded` and
    /// `fallbacks` both carry the condition and the envelope raises its degraded line off them —
    /// but the arm row itself understates. Fixing it needs an arm-level state for the embedder on
    /// the wire, which `Capability.embedder` (a model key, not a state word) does not have.
    public func mappedArms() throws -> [EngineArm] {
        let embedState: EngineArmState = embedder != nil
            ? .ran
            : (isUnavailable("embedder") ? .unavailable : .off)
        return [
            EngineArm.embedder(embedder, embedState),
            EngineArm.hyde(nil, try armState(hyde, field: "hyde", arm: "hyde")),
            EngineArm.reranker(nil, try armState(reranker, field: "reranker", arm: "reranker")),
        ]
    }

    private func isUnavailable(_ arm: String) -> Bool {
        unavailable.contains { entry in
            entry.split(separator: " ", maxSplits: 1).first.map(String.init) == arm
        }
    }

    private func armState(_ word: String, field: String, arm: String) throws -> EngineArmState {
        let state: EngineArmState
        switch word {
        case "ran": state = .ran
        case "off": state = .off
        case "skipped": state = .skipped
        case "fell_back": state = .fellBack
        default:
            throw SubstrateMappingRefusal.unknownToken(
                field: field, value: word, known: ["ran", "off", "skipped", "fell_back"]
            )
        }
        return (state == .off && isUnavailable(arm)) ? .unavailable : state
    }
}

extension WireSearchResult {
    /// The capability half of this payload.
    ///
    /// Two fields on `EngineEnvelope` have no wire source and are left alone rather than invented:
    ///
    /// - `unmeasuredReason`. `EngineEnvelope` says the engine "always knows which of the five
    ///   reasons applies" — it does, and it does not send it: `render.retrieval_mode` emits
    ///   `expected_mrr` and no companion reason. Composing one from `unavailable` and `fallbacks`
    ///   would be a client-authored sentence attributed to the engine.
    /// - `health`. Nothing on the wire distinguishes "no local model server installed" (the
    ///   zero-install default, not a fault) from "installed and unreachable" (a fault). The
    ///   condition is not lost: an unreachable arm lands in `unavailable`, becomes `.unavailable`,
    ///   and `unavailableArms` drives its own higher-severity note.
    public func mappedEnvelope() throws -> EngineEnvelope {
        EngineEnvelope(
            scope: Self.mappedScope(scope),
            arms: try retrievalMode.mappedArms(),
            expectedMRR: retrievalMode.expectedMRR.wireValue,
            frozen: refresh.frozen.wireValue,
            cohort: retrievalMode.cohort,
            fallbacks: retrievalMode.fallbacks,
            // ONLY UPWARD. `EngineEnvelope` derives `degraded` from the arms as well as the
            // fallbacks, because a `.fellBack` arm with an empty `fallbacks` array used to render a
            // known-degraded run as clean. Passing the engine's `false` through explicitly would
            // switch that derivation off — the caller-outranks-inference door, walked through by
            // default. So `true` is forwarded (the engine has seen something we cannot) and `false`
            // becomes `nil`, which lets the safety net stay armed.
            degraded: retrievalMode.degraded ? true : nil
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
