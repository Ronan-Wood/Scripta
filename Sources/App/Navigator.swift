import Foundation

/// The hub's sections — the sidebar's rows, and the top level of every `Destination`.
///
/// The seven-row sidebar predated the engine and had one row per thing that had been built, not per
/// thing a reader goes looking for. Doc 4 §2 cut it to **Ask · Calls · Library · Settings**:
///
/// | went | into |
/// |---|---|
/// | `meetings` | Calls, as the Calendar lens — the same calls, read against time |
/// | `knowledge` | Library (vault lens) + Calls (Digest lens) — two unrelated surfaces sharing a picker |
/// | `docs` | the Help menu — it is documentation, and macOS has a place for that |
///
/// `home` CAME BACK, and the doc's reason for cutting it is still right about what it cut. §2
/// retired "a dashboard of Swift aggregates over the local index" — stat tiles and a second call
/// list, every card duplicating a surface that owned its content better. What went with it was the
/// LANDING: four places to work and no view of the whole, so the app opened into whichever you left
/// it on. `HomeView` is that landing and deliberately not that dashboard — it starts a call, shows
/// what is next, and links into Calls rather than rebuilding it.
///
/// `library` sits beside `ask` because they are the two directions of one relationship — Ask reads
/// a composed scope, the Library writes one and now also browses it.
/// `docs` IS BACK IN THE SIDEBAR, and the reason it left still holds — which is why it is in
/// `secondary` rather than beside the four. Doc 4 §2 moved it to the Help menu because a
/// documentation row competed with the surfaces a reader actually works in, and `NSApp.helpMenu` is
/// where macOS has taught people to look.
///
/// What that argument missed is that this is an `LSUIElement` app. The menu bar carries Scripta's
/// menus only while one of its windows has focus, so "look in the Help menu" is advice you can only
/// follow if you already know to look there. Measured the hard way: the operator who built the app
/// could not find its documentation. ⌘? still works and the Help menu keeps its entry; this is the
/// visible affordance beside Settings, which is the other place people hunt.
enum HubSection: String, CaseIterable {
    case home, ask, calls, library, docs, settings

    static let primary: [HubSection] = [.home, .ask, .calls, .library]
    static let secondary: [HubSection] = [.docs, .settings]

    var title: String {
        switch self {
        case .home: return "Home"
        case .ask: return "Ask"
        case .calls: return "Calls"
        case .library: return "Library"
        case .docs: return "Docs"
        case .settings: return "Settings"
        }
    }

    var sfIcon: String {
        switch self {
        case .home: return "house"
        case .ask: return "bubble.left.and.bubble.right"
        case .calls: return "doc.text"
        case .library: return "books.vertical"
        case .docs: return "questionmark.circle"
        case .settings: return "gearshape"
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

    static func calls(_ focus: CallFocus = .none) -> Destination {
        Destination(section: .calls, callFocus: focus)
    }
    static let home = Destination(section: .home)
    static let ask = Destination(section: .ask)
    static let library = Destination(section: .library)
    static let settings = Destination(section: .settings)
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
    /// HOME, and it is a landing rather than the dashboard Doc 4 §2 retired — see `HomeView`. It
    /// also needs no engine, which Ask (the previous default) did: opening a cold launch onto a
    /// surface that must say "starting the substrate engine" before it can say anything is a poor
    /// first frame even when that state is honest.
    @Published private(set) var destination: Destination = .home

    /// The identity Calls is mounted under. Bumped by `clearSearchScope()`, by nothing else.
    @Published private(set) var searchScopeGeneration = 0

    /// Sidebar navigation.
    func select(_ section: HubSection) {
        go(to: Destination(section: section))
    }

    /// Resolves a cross-view request. `.section` deliberately keeps the current focus: it means
    /// "show me that section", not "here is a new context".
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
        // A specific call or tag can only be shown by the list lens. Arriving at Calls with a focus
        // while the reader had left it on Calendar or Digest would select the call underneath a
        // surface that cannot draw it — navigation reporting success and showing nothing. Decided
        // here because this type already owns what a section arrives showing.
        //
        // ONLY ON A NEW CONTEXT, and never over a live call. `follow(.section(.calls))` deliberately
        // CARRIES the previous focus (see above), so keying on `callFocus != .none` alone fired on a
        // plain "show me Calls" that happened to have a stale focus attached — and it fired while
        // recording, dropping the reader off the live screen with nothing to put them back on it.
        // `enteringNewContext` is the question actually being asked: did the reader ask for a
        // different call than the one already showing.
        if destination.section == .calls, destination.callFocus != .none, enteringNewContext {
            CallsLensModel.shared.focusList()
        }
    }
}
