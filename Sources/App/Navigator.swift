import Foundation

/// The hub's sections — the sidebar's rows, and the top level of every `Destination`.
enum HubSection: String, CaseIterable {
    case home, calls, meetings, ask, knowledge, settings, docs

    static let primary: [HubSection] = [.home, .calls, .meetings, .ask, .knowledge]
    static let secondary: [HubSection] = [.settings, .docs]

    var title: String {
        switch self {
        case .home: return "Home"
        case .calls: return "Calls"
        case .meetings: return "Meetings"
        case .ask: return "Ask"
        case .knowledge: return "Knowledge"
        case .settings: return "Settings"
        case .docs: return "Docs"
        }
    }

    var sfIcon: String {
        switch self {
        case .home: return "house"
        case .calls: return "doc.text"
        case .meetings: return "calendar"
        case .ask: return "bubble.left.and.bubble.right"
        case .knowledge: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        case .docs: return "book"
        }
    }
}

/// What the Calls section arrives preselecting. One-shot by design — `Navigator.select` resets it
/// — so a manual sidebar tap never resurrects the selection a route left behind.
enum CallFocus: Equatable {
    case none
    /// A specific call, optionally scrolling the reader to a passage timestamp (ms).
    case call(URL, ms: Int?)
    case tag(String)

    var callURL: URL? { if case .call(let url, _) = self { return url }; return nil }
    var callMs: Int? { if case .call(_, let ms) = self { return ms }; return nil }
    var tagName: String? { if case .tag(let tag) = self { return tag }; return nil }

    /// What makes two arrivals the *same* context. Keyed on the file path rather than on `URL`
    /// equality because the same call reaches here as differently-built URLs — a search hit's
    /// `URL(fileURLWithPath:)` and a directory listing's URL are unequal values naming one file —
    /// and re-opening a call you are already reading should not throw away your place in it.
    /// Only `Navigator.go(to:)` consults this; it is not view identity.
    var contextKey: String {
        switch self {
        case .none: return "||"
        case .call(let url, let ms): return "\(url.path)|\(ms.map(String.init) ?? "")|"
        case .tag(let tag): return "||\(tag)"
        }
    }
}

/// A place in the hub, as a value: which section, plus what that section arrives showing. Every
/// destination the app can reach is one of the constants below. A newly parameterised section
/// gains a field here rather than another `@State` on HubView, which is what kept the previous
/// focus triple invisible to everything except the view that declared it.
struct Destination: Equatable {
    var section: HubSection
    var callFocus: CallFocus = .none

    static let home = Destination(section: .home)
    static func calls(_ focus: CallFocus = .none) -> Destination {
        Destination(section: .calls, callFocus: focus)
    }
    static let meetings = Destination(section: .meetings)
    static let ask = Destination(section: .ask)
    static let knowledge = Destination(section: .knowledge)
    static let settings = Destination(section: .settings)
    static let docs = Destination(section: .docs)
}

/// A navigation request posted from anywhere in the app through `AppModel.route`. This is the
/// caller's vocabulary; `Destination` is what it resolves to.
enum Route: Equatable {
    /// Jump to a call, optionally scrolling the reader to a passage timestamp (ms).
    case call(URL, ms: Int?)
    case tag(String)
    case section(HubSection)

    static func call(_ url: URL) -> Route { .call(url, ms: nil) }
}

/// The hub's routing API. Owns where the content area is and what it arrives showing, so a
/// destination is a value that can be read and set — not a side effect of which view SwiftUI
/// happens to be holding.
@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var destination: Destination = .home

    /// The identity Calls is mounted under. Bumped by `clearSearchScope()`, by nothing else.
    @Published private(set) var searchScopeGeneration = 0

    /// Sidebar navigation.
    func select(_ section: HubSection) {
        go(to: Destination(section: section))
    }

    /// Resolves a cross-view request. `.section` deliberately keeps the current focus: it means
    /// "show me that section", not "here is a new context" (HomeView's "View all calls").
    func follow(_ route: Route) {
        switch route {
        case .call(let url, let ms):
            go(to: .calls(.call(url, ms: ms)))
        case .tag(let tag):
            go(to: .calls(.tag(tag)))
        case .section(let section):
            go(to: Destination(section: section, callFocus: destination.callFocus))
        }
    }

    /// Discards the Calls surface's transient search state — the typed query, the person/tag/entity
    /// filters, and the one that makes this a privacy affordance rather than a rendering trick: the
    /// "search all workspaces" widening, which CallsView keeps deliberately non-sticky
    /// (Sources/Calls/CallsView.swift:15) so a one-off cross-workspace search can never become a
    /// lingering default. Following a citation into an unrelated call must not carry the previous
    /// context's scope with it.
    ///
    /// It lands by changing the identity CallsView is mounted under, which is also the only way a
    /// new focus reaches CallsView's init-seeded `@State` — see `HubContent`.
    func clearSearchScope() {
        searchScopeGeneration &+= 1
    }

    /// Entering a *different* context is what clears the scope. Re-requesting the call or tag
    /// already showing is not a new context and leaves the surface as the user left it — matching
    /// the behaviour of the identity string this replaced, which was derived from the focus itself.
    private func go(to destination: Destination) {
        let enteringNewContext = destination.callFocus.contextKey != self.destination.callFocus.contextKey
        self.destination = destination
        if enteringNewContext { clearSearchScope() }
    }
}
