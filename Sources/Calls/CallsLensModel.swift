import Foundation

/// Which reading of this workspace's calls is on screen (Doc 4 §2 — "Meetings folds into Calls;
/// Knowledge splits").
///
/// THREE READINGS OF ONE CORPUS, not three sections. The list is the calls themselves, the calendar
/// is those same calls against the ones still to come, and the digest is what was said across them.
/// They were three sidebar rows because they were built at three different times, not because a
/// reader thinks of them as separate places.
///
/// ON A SHARED MODEL, NOT `@State`, and this is the third surface to record the same defect:
/// `HubContent` resolves the section through a `switch`, so leaving Calls and coming back destroys
/// the branch and any `@State` in it. `AskModel` records it for its thread and its bound scope, and
/// `VaultBrowseModel` recorded it for the lens that has since moved into the Library. A lens that
/// silently snaps back to the list is a reader concluding the calendar lost their meetings.
@MainActor
final class CallsLensModel: ObservableObject {
    static let shared = CallsLensModel()

    enum Lens: String, CaseIterable, Identifiable {
        /// The call happening right now. OFFERED ONLY WHILE ONE IS — see `available(recording:)`.
        case recording
        case list, calendar, digest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recording: return "Recording"
            case .list: return "Calls"
            case .calendar: return "Calendar"
            case .digest: return "Digest"
            }
        }
    }

    @Published var lens: Lens = .list

    /// The lenses the picker offers. `recording` is a STATE, not a choice — a chip for it while
    /// nothing is being recorded would select a screen with no call on it.
    static func available(recording: Bool) -> [Lens] {
        recording ? Lens.allCases : Lens.allCases.filter { $0 != .recording }
    }

    /// Follow the recording lifecycle. Starting a call selects the recording screen; finishing one
    /// hands the reader back to the list rather than leaving them on a lens that no longer has a
    /// subject — and the transcript they just made is the top row of it.
    ///
    /// IT DOES NOT CHANGE SECTION. `HomeView` used to take itself over when a recording began,
    /// which only reached a reader who was already on Home; yanking someone out of Ask mid-question
    /// because a call started would be a larger claim than the one being replaced.
    func follow(recording: Bool) {
        if recording {
            lens = .recording
        } else if lens == .recording {
            lens = .list
        }
    }

    /// Arriving at a specific call or tag forces the list, because that is the only lens that can
    /// show one. Following a citation from Ask into the digest would leave the reader on a summary
    /// of everything with no sign the call they asked for had been selected underneath it —
    /// navigation that reports success and shows nothing.
    ///
    /// Called by `Navigator`, which already owns "what the section arrives showing"; a `CallsView`
    /// init doing it would fire on every rebuild rather than on every arrival.
    func focusList() { lens = .list }
}
