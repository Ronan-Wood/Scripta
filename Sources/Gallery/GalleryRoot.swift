import SwiftUI

/// The pages, in review order: the rules first, then the layers they are made of, then the two
/// composed components that are the hardest thing in the system to get right.
///
/// A case here is the ONLY way a pane is reachable, and the same omission has now happened twice.
/// `PassagePane` and `EnvelopeGallery` existed with no case and no arm in `GalleryPageBody`, which
/// made the two panes that review the passage and the capability envelope dead code inside the app
/// whose entire job is reviewing them. `ControlsPane` is the second: eleven control primitives had
/// no pane at all, so `forcedControlPhase` — an environment key whose doc comment says it is "set
/// by the gallery and nothing else" — was set by nothing, and every hover, pressed, focused and
/// disabled render in the system was unreviewable.
enum GalleryPage: String, CaseIterable, Identifiable {
    case rules = "Rules"
    case color = "Colour"
    case type = "Type"
    case contrast = "Contrast"
    case speakers = "Speakers"
    case surfaces = "Surfaces"
    case metrics = "Metrics"
    case controls = "Controls"
    case passage = "Passage"
    case envelope = "Envelope"

    var id: String { rawValue }
}

/// How the two appearances are shown. Side-by-side is the default because the interesting failures
/// are the ones where a token is fine in one theme and not the other, and a toggle hides exactly
/// those. The single-appearance modes exist to exercise `.preferredColorScheme` at the window root,
/// which is the only place on macOS its behaviour is well defined.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by side"
    case lightOnly = "Light only"
    case darkOnly = "Dark only"

    var id: String { rawValue }

    var single: GalleryAppearance? {
        switch self {
        case .sideBySide: return nil
        case .lightOnly: return .light
        case .darkOnly: return .dark
        }
    }
}

struct GalleryRoot: View {
    @State private var page: GalleryPage = .rules
    @State private var mode: AppearanceMode = .sideBySide

    var body: some View {
        VStack(spacing: 0) {
            GalleryToolbar(page: $page, mode: $mode)
            Divider()
            GalleryStage(page: page, mode: mode)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

private struct GalleryToolbar: View {
    @Binding var page: GalleryPage
    @Binding var mode: AppearanceMode

    var body: some View {
        HStack(spacing: Gap.s12) {
            Picker("", selection: $page) {
                ForEach(GalleryPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("", selection: $mode) {
                ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
        .labelsHidden()
        .padding(Gap.s12)
    }
}

private struct GalleryStage: View {
    let page: GalleryPage
    let mode: AppearanceMode

    private static let columnWidth: CGFloat = 620

    var body: some View {
        if let single = mode.single {
            SingleAppearanceStage(page: page, appearance: single)
        } else {
            SplitStage(page: page, width: Self.columnWidth)
        }
    }
}

/// Both appearances in one window, each inside its own forced `NSAppearance`. One shared
/// `ScrollView` on the outside keeps the two columns on the same row while scrolling, which is the
/// only reason side-by-side beats a toggle.
private struct SplitStage: View {
    let page: GalleryPage
    let width: CGFloat

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 0) {
                AppearanceHost(appearance: .light, width: width) {
                    GalleryColumn(page: page, appearance: .light)
                }
                Divider()
                AppearanceHost(appearance: .dark, width: width) {
                    GalleryColumn(page: page, appearance: .dark)
                }
            }
        }
    }
}

/// The honest use of `.preferredColorScheme`: applied once, at the root of the window's content,
/// where it sets the window appearance rather than fighting a sibling for it. The app pins
/// `NSApp.appearance` globally, which is why previews do not reflect theme in this codebase — the
/// gallery never does that, so this modifier is actually load-bearing here.
private struct SingleAppearanceStage: View {
    let page: GalleryPage
    let appearance: GalleryAppearance

    var body: some View {
        ScrollView {
            GalleryColumn(page: page, appearance: appearance)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.pageGutter)
        }
        .background(Ink.background)
        .preferredColorScheme(appearance.scheme)
    }
}

struct GalleryColumn: View {
    let page: GalleryPage
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            ColumnHeader(appearance: appearance)
            GalleryPageBody(page: page, appearance: appearance)
        }
        .padding(Metrics.pageGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.background)
    }
}

private struct ColumnHeader: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            Text(appearance.title).microLabel(Ink.textHelper)
            Text("Record & Register").typeface(Register.title1, Ink.textPrimary)
            Text("verba volant, scripta manent").typeface(Register.mono, Ink.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GalleryPageBody: View {
    let page: GalleryPage
    let appearance: GalleryAppearance

    var body: some View {
        switch page {
        case .rules: RulesPane(appearance: appearance)
        case .color: InkPane(appearance: appearance)
        case .type: RegisterPane()
        case .contrast: ContrastPane(appearance: appearance)
        case .speakers: SpeakerPane(appearance: appearance)
        case .surfaces: SurfacePane(appearance: appearance)
        case .metrics: MetricsPane()
        case .controls: ControlsPane()
        case .passage: PassagePane(appearance: appearance)
        case .envelope: EnvelopeGallery(appearance: appearance)
        }
    }
}
