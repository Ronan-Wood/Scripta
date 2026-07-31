import SwiftUI

/// The control primitives, in states a pointer cannot produce.
///
/// Every component on this page had no page at all — the same defect `GalleryRoot` records for
/// `PassagePane` and `EnvelopeGallery`, one level up: eleven components compiling into a target
/// whose stated job is that "a component that is not in the gallery is a component nobody
/// reviewed". `ControlPhase.resolve(forced:)` and the `forcedControlPhase` environment key exist,
/// in their own words, "so the gallery can FORCE each one" — and nothing in the gallery set it, so
/// the hover, pressed, focused and disabled render of every control was unreviewable by
/// construction. That is how a progress bar kept a blue default nobody looked at.
struct ControlsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            PhaseMatrixCard()
            IconButtonCard()
            PillCard()
            RowCard()
            FieldCard()
            ProgressCard()
            EmptyStateCard()
            GlyphCard()
        }
    }
}

// MARK: - Buttons

private struct PhaseMatrixCard: View {
    var body: some View {
        GalleryCard(title: "Buttons — every rank in every phase",
                    note: "Forced through ControlPhase, not produced with a cursor. Priority is disabled > pressed > focused > hover: a pointer resting on a focused control must not take the ring away, because it is a keyboard user's only position signal.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                ForEach(ButtonRank.allCases) { PhaseRow(rank: $0) }
            }
        }
    }
}

private struct PhaseRow: View {
    let rank: ButtonRank

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(rank.rawValue).microLabel(Ink.textHelper)
            HStack(alignment: .top, spacing: Gap.s8) {
                ForEach(ControlPhase.allCases) { PhaseSample(rank: rank, phase: $0) }
                Spacer(minLength: Gap.s8)
            }
        }
    }
}

private struct PhaseSample: View {
    let rank: ButtonRank
    let phase: ControlPhase

    /// `.disabled(true)` alongside the forced phase, per `forcedControlPhase`'s own instruction:
    /// a control painted disabled and still clickable is a worse lie than one painted wrong.
    var body: some View {
        VStack(spacing: Gap.s4) {
            ActionButton(title: rank.rawValue, rank: rank) {}
                .forcedControlPhase(phase)
                .disabled(phase == .disabled)
            Text(phase.rawValue).typeface(Register.monoMicro, Ink.textHelper)
        }
    }
}

private struct IconButtonCard: View {
    var body: some View {
        GalleryCard(title: "Icon buttons",
                    note: "Density.pill square, and `label` is required — an icon button without one is a control VoiceOver announces as \"button\".") {
            HStack(spacing: Gap.s8) {
                ForEach(ControlPhase.allCases) { IconButtonSample(phase: $0) }
                Spacer(minLength: Gap.s8)
            }
        }
    }
}

private struct IconButtonSample: View {
    let phase: ControlPhase

    var body: some View {
        VStack(spacing: Gap.s4) {
            IconButton(glyph: .refresh, label: "Rebuild index") {}
                .forcedControlPhase(phase)
                .disabled(phase == .disabled)
            Text(phase.rawValue).typeface(Register.monoMicro, Ink.textHelper)
        }
    }
}

// MARK: - Pills

/// The state presets keep their hue in the WASH and their ink in `textPrimary`; the speaker preset
/// is the one that keeps hue in the ink, because for a speaker the hue IS the identity. Seeing them
/// side by side is the only way to check that the two shapes still read as one family.
private struct PillCard: View {
    private static let presets: [(String, PillStyle)] = [
        ("neutral", .neutral), ("selected", .selected), ("danger", .danger),
        ("warning", .warning), ("success", .success), ("stale", .stale), ("me", .me),
    ]

    var body: some View {
        GalleryCard(title: "Pills",
                    note: "Rule 2 permits exactly one blue pill: `selected`, because a selected filter IS interaction state. Every other hue here is a wash under textPrimary.") {
            VStack(alignment: .leading, spacing: Gap.s8) {
                PillRow(pills: Self.presets)
                SpeakerPillRow()
                RemovablePillRow()
            }
        }
    }
}

private struct PillRow: View {
    let pills: [(String, PillStyle)]

    var body: some View {
        HStack(spacing: Gap.s6) {
            ForEach(pills, id: \.0) { Pill(text: $0.0, style: $0.1) }
            Spacer(minLength: Gap.s8)
        }
    }
}

private struct SpeakerPillRow: View {
    var body: some View {
        HStack(spacing: Gap.s6) {
            ForEach(0..<4, id: \.self) { index in
                Pill(text: "Speaker \(index + 2)", style: .speaker(index))
            }
            Spacer(minLength: Gap.s8)
        }
    }
}

private struct RemovablePillRow: View {
    var body: some View {
        HStack(spacing: Gap.s6) {
            Pill(text: "design-system", glyph: .tag, style: .neutral, onRemove: {})
            Pill(text: "retrieval", glyph: .tag, style: .neutral, onRemove: {})
            Spacer(minLength: Gap.s8)
        }
    }
}

// MARK: - Rows

private struct RowCard: View {
    var body: some View {
        GalleryCard(title: "List rows",
                    note: "Density.row as a MINIMUM. The long title is the specimen that matters: a fixed height is invisible until something needs to grow.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ListRow(title: "Weekly review", subtitle: "prism · 14 passages", glyph: .document)
                ListRow(title: "Vendor call — pricing", glyph: .chat, selected: true)
                ListRow(title: "A title long enough that a fixed height would clip it the moment the window narrows",
                        subtitle: "and a subtitle beneath it", glyph: .book)
            }
        }
    }
}

// MARK: - Fields

private struct FieldCard: View {
    @State private var query = ""
    @State private var filled = "scope=prism status=active"

    var body: some View {
        GalleryCard(title: "Text fields",
                    note: "The prompt is DECORATIVE — textPlaceholder measures 2.16:1 on `field` in light, a recorded finding, so a field's meaning lives in a label outside it.") {
            VStack(alignment: .leading, spacing: Gap.s8) {
                InputField(prompt: "Search this scope", text: $query, glyph: .search)
                InputField(prompt: "Search this scope", text: $filled, glyph: .search)
                InputField(prompt: "Disabled", text: $query).disabled(true)
            }
        }
    }
}

// MARK: - Progress

private struct ProgressCard: View {
    var body: some View {
        GalleryCard(title: "Progress",
                    note: "Monochrome, and not configurably so. A determinate bar reports machine-measured work state — content meaning, and you cannot click a progress bar. It reads the same tokens EngineTierMeter draws its measured fraction with.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                ProgressTrack(value: 0.64, label: "Ingesting", detail: "412 / 640 pages")
                ProgressTrack(value: nil, label: "Composing", detail: "extent unknown")
                SpinnerRow()
            }
        }
    }
}

private struct SpinnerRow: View {
    var body: some View {
        HStack(spacing: Gap.s8) {
            Spinner()
            Text("Spinner — for work that finishes in a beat")
                .typeface(Register.caption, Ink.textHelper)
            Spacer(minLength: Gap.s8)
        }
    }
}

// MARK: - Surfaces

private struct EmptyStateCard: View {
    var body: some View {
        GalleryCard(title: "Cards and the empty state",
                    note: "The empty state's title is UI and its message is PROSE — a heading labels a region, the sentence beneath it is something a person wrote. In chrome type it reads as an error dialog.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                StatCard(label: "Passages indexed", value: "1 284", unit: "in 6 scopes")
                Card(title: "A card", note: "Layer fill, hairline border, Corner.card.") {
                    Text("Hairline over shadow is the house style.")
                        .proseText(Register.proseSm, Ink.textSecondary)
                }
                EmptyState(glyph: .search, title: "No passages match",
                           message: "Nothing in this scope answers that. Archived notes, superseded notes and call transcripts were not searched.",
                           actionTitle: "Include everything") {}
            }
        }
    }
}

// MARK: - Icons

/// `Glyph.audit()` traps in debug on an unresolvable symbol and this page is where the whole set is
/// looked at — the failure it replaced was `CarbonIcon` drawing `Color.clear` for a missing asset,
/// which is a control that is simply not there and says nothing.
private struct GlyphCard: View {
    private static let columns = 8

    /// Chunked rows rather than a `LazyVGrid`. Every column here lives inside an `NSHostingView`
    /// sized from its intrinsic content, and a lazy container asked for an intrinsic height before
    /// it has laid anything out is exactly the shape that reports zero — a page that silently
    /// renders nothing is the failure this whole target exists to catch, not to demonstrate.
    private static let rows: [[Glyph]] = stride(from: 0, to: Glyph.allCases.count, by: columns)
        .map { Array(Glyph.allCases[$0..<min($0 + columns, Glyph.allCases.count)]) }

    var body: some View {
        GalleryCard(title: "Glyphs — \(Glyph.allCases.count) cases, \(Glyph.unresolved.count) unresolved",
                    note: "Named for the JOB, not the picture — `stale`, not `clockArrow` — so swapping the symbol later is one line and not a rename across the app. Anything unresolvable draws as a danger-tinted box, never as nothing.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                ForEach(Self.rows, id: \.first) { GlyphRow(glyphs: $0, columns: Self.columns) }
            }
        }
    }
}

private struct GlyphRow: View {
    let glyphs: [Glyph]
    let columns: Int

    var body: some View {
        HStack(alignment: .top, spacing: Gap.s8) {
            ForEach(glyphs) { GlyphSample(glyph: $0) }
            // Holds a short final row on the same columns as the full ones above it.
            ForEach(0..<(columns - glyphs.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }
}

private struct GlyphSample: View {
    let glyph: Glyph

    var body: some View {
        VStack(spacing: Gap.s4) {
            Icon(glyph, Register.title3, Ink.iconPrimary)
            Text(glyph.title).typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: Density.action)
    }
}
