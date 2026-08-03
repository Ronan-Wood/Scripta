@_exported import SubstrateKit
import SwiftUI

// MARK: - Record & Register: how the passage spine is drawn
//
// THE SPINE ITSELF IS NOT HERE. `RetrievalClass`, `PassageStatus`, `PassageDocType`,
// `PassageConfidence`, `PassageDocumentClass` and `Passage` are values the ENGINE sends, so they
// live in `SubstrateKit` (Core/Sources/SubstrateKit/Passage.swift) where nothing can teach them a
// colour. This file is the other half: how we choose to draw one. The two ended up in one directory
// because nobody had to choose — `PassageConfidence` is schema, `SpineBadge.Prominence` is
// presentation, and that is the line.
//
// It is re-exported rather than imported per file so a view can name `Passage` without knowing which
// module it came from — the schema is part of this layer's vocabulary, it is just not this layer's
// to define.
//
// A passage carries four independent axes — kind, lifecycle, document class, and provenance
// strength — without any of them shouting. Rule 3 is what makes that possible: a default-corpus,
// ACTIVE, VERIFIED passage is ENTIRELY MONOCHROME, so the only coloured pixels on a screenful of
// results are the ones the reader needs to stop at.
//
// Two rules govern how the axes below spend that budget:
//
//   ONE TONE PER AXIS, NOT PER VALUE. `Ink.danger` says "a reader could mistake this for settled
//   fact"; `Ink.stale` says "this is outside the default corpus". Which value triggered it is
//   carried by the WORD, which is always rendered. Colour is redundant reinforcement, never the
//   sole signal — that is what keeps the spine legible to a dichromat and keeps the palette at two.
//
//   ABSENCE IS NOT A LOW VALUE. `unstated` / `unjudged` mean nobody has judged the note yet. Most
//   of the migrated corpus is in that state. It is rendered by REMOVING chrome, not by fading ink
//   toward "weak" — see `SpineBadge.Prominence.absent`.

/// One of the spine's axes: a word, and how loudly the badge says it.
///
/// The protocol is what lets `Passage.spineAxes` be a LIST. A spine assembled from a list cannot
/// omit an axis the passage declares, which is the failure this file already had once — an axis
/// modelled in one component and missing from the one that renders the answer.
///
/// It is declared HERE and not beside the enums because `prominence` is the whole of it: `label` is
/// the engine's own token and already lives on each type, and a protocol requiring a `Prominence`
/// cannot exist in a module that has no such vocabulary.
protocol PassageAxis {
    /// Always rendered. The word is the signal; colour only says "stop here".
    var label: String { get }
    var prominence: SpineBadge.Prominence { get }
}

/// MONO. Rule 1's name/value split (see `Register.swift`): a retrieval class is a VALUE the engine
/// put in a field and the exact token you would type to ask for it back, not the name of the field.
/// Declared on the type — as an extension, since the type is schema and a typeface is not — so a
/// second renderer of this vocabulary cannot pick a different face.
extension RetrievalClass {
    static let register = Register.mono
}

extension PassageStatus: PassageAxis {
    /// `complete` is silent alongside `active`: a finished note is a healthy note, and spending
    /// colour on it would leave nothing left to mark the results that are genuinely unusual.
    var prominence: SpineBadge.Prominence { isExcluded ? .excluded : .record }
}

extension PassageDocumentClass: PassageAxis {
    /// Marked with `stale` and not `danger`, matching the status axis and `ExclusionBar`: "outside
    /// the default corpus" is one reason and gets one tone, whichever axis carried it there.
    ///
    /// `unreported` takes the ABSENT tier, the same one `unstated` confidence takes, and for the
    /// same reason: the field was never filled in. It is emphatically not `.record` — a settled
    /// badge on an axis the engine could not answer is the lie this whole spine exists to prevent,
    /// and it is what a defaulted `reference-frozen` drew here before the class reached the wire.
    /// Written as a switch and not off `withheldAs` because those are different questions: the
    /// class is unknown, which is not the same as known-and-not-withheld.
    var prominence: SpineBadge.Prominence {
        switch self {
        case .unreported: return .absent
        case .conversation: return .excluded
        case .referenceFrozen, .referenceVersioned: return .record
        }
    }
}

extension PassageConfidence: PassageAxis {
    /// The judged/unjudged split first, settled/unsettled only inside the judged half. Both
    /// questions are answered by the schema; this only picks the tier each answer draws in.
    var prominence: SpineBadge.Prominence {
        guard isJudged else { return .absent }
        return isUnsettled ? .unsettled : .record
    }
}

extension PassageDocType: PassageAxis {
    /// Never a deviation — every note declares one, and none of the five is unusual enough to be
    /// worth a colour under rule 3.
    var prominence: SpineBadge.Prominence { .record }
}

/// An axis flattened to what the badge needs. A struct rather than an existential so the spine
/// stays a plain `ForEach` and the four enums keep their own types and their own reasons.
struct SpineAxis: Identifiable {
    /// The envelope field, which is also the `ForEach` identity — two axes can share a word
    /// (`reference` is a doc_type and half of two document classes) and must not share a row.
    let field: String
    let label: String
    let prominence: SpineBadge.Prominence

    var id: String { field }

    init(_ field: String, _ value: some PassageAxis) {
        self.field = field
        self.label = value.label
        self.prominence = value.prominence
    }
}

extension Passage {
    /// Every axis the spine draws, in reading order: what kind of note, where it sits, what corpus
    /// it came out of, how well it is backed. `PassageSpine` renders THIS and nothing else, so an
    /// axis added to the model reaches every card without anyone remembering to add a badge.
    ///
    /// The field names are the engine's own keys, which is what makes a spine badge and a CLI
    /// `--json` line checkable against each other by eye.
    var spineAxes: [SpineAxis] {
        [SpineAxis("doc_type", docType),
         SpineAxis("status", status),
         SpineAxis("document_class", documentClass),
         SpineAxis("confidence", confidence)]
    }
}
