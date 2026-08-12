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
        /// Where a call begins, happens and finishes — see `available`. Idle it is the record card.
        case recording
        case list, calendar, digest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recording: return "Record"
            case .list: return "Transcripts"
            case .calendar: return "Calendar"
            case .digest: return "Digest"
            }
        }

        var sfIcon: String {
            switch self {
            case .recording: return "record.circle"
            case .list: return "doc.text"
            case .calendar: return "calendar"
            case .digest: return "list.bullet.rectangle"
            }
        }

        /// The three that hang UNDER Calls in the sidebar. `list` is what the Calls row itself
        /// shows, so listing it again as a child would be one destination with two rows.
        static let secondary: [Lens] = [.recording, .calendar, .digest]
    }

    @Published var lens: Lens = .list

    /// ALWAYS ALL FOUR, and `record` in particular is always offered.
    ///
    /// It used to be gated on the app being busy, on the reasoning that a recording screen with no
    /// recording on it is a chip pointing at nothing. That was wrong twice over. The screen's idle
    /// state is not empty — it is "Ready to record" and the START button, which is the app's PRIMARY
    /// ACTION and lived on Home until Doc 4 §2 retired that section. Gating the lens deleted the
    /// place you start a call from and left only the title-bar pill. And the gate also hid the
    /// `.processing` state, so "Transcribing…" — the longest phase — was unreachable in the other
    /// direction.
    ///
    /// A place, then, not a state: `Record` is where a call begins, happens, and finishes, and
    /// `follow` selects it when one starts rather than conjuring it.
    static var available: [Lens] { Lens.allCases }

    /// Follow the recording lifecycle. Starting a call selects the recording screen and it STAYS
    /// selected through transcription; only returning to idle hands the reader back to the list,
    /// where the transcript they just made is the top row.
    ///
    /// IT DOES NOT CHANGE SECTION. `HomeView` used to take itself over when a recording began,
    /// which only reached a reader who was already on Home; yanking someone out of Ask mid-question
    /// because a call started would be a larger claim than the one being replaced.
    func follow(busy: Bool) {
        if busy {
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
