import SwiftUI

/// The routing table: the one place a `Destination` becomes a screen. A concrete struct rather
/// than a `@ViewBuilder` property on HubView, so the type checker gets a boundary here instead of
/// solving the whole hub as one expression.
struct HubContent: View {
    let destination: Destination
    let searchScopeGeneration: Int

    var body: some View {
        switch destination.section {
        case .home:
            HomeView()
        case .calls:
            CallsView(focusCall: destination.callFocus.callURL,
                      focusMs: destination.callFocus.callMs,
                      focusTag: destination.callFocus.tagName)
                // The only `.id()` left in the hub's routing. CallsView seeds its selection and tag
                // filter from `init` (Sources/Calls/CallsView.swift:20-24), and SwiftUI ignores init
                // values for @State that already exists — so a focus change reaches it only on a
                // fresh identity. Keyed on the generation, not on the focus itself, so the discard
                // is something Navigator.clearSearchScope() decides rather than something view
                // identity does incidentally. Retiring it needs CallsView to accept the focus as a
                // binding, which is that file's change to make.
                .id(searchScopeGeneration)
        case .ask:
            // `shared`, like the Library's model: the pane is rebuilt every time the sidebar
            // reselects the section, and a `@State` model would drop the thread and any answer
            // still streaming into it.
            AskView(model: AskModel.shared)
        case .library:
            // `shared`, like Ask's model, and for the same reason: the pane is rebuilt every time
            // the sidebar reselects the section, and a `@State` model would drop a running ingest
            // — a minutes-long subprocess — the moment someone looked at another tab.
            SubstrateLibraryView(model: SubstrateLibraryModel.shared)
        case .settings:
            SettingsView()
        }
    }
}
