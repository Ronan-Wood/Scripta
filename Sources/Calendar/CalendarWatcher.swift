import EventKit
import Foundation

/// An upcoming calendar event that contains a video-call link.
struct UpcomingCall: Identifiable {
    let id: String
    let title: String
    let start: Date
    let service: String       // "Zoom", "Teams", or "Meet"
    let calendarID: String
}

/// Title + participant names + group tag lifted from the calendar event a recording overlapped,
/// used to pre-fill the post-record details prompt and auto-tag by calendar group.
struct CallContext {
    let title: String
    let participants: [String]
    let groupTag: String?
}

/// Reads upcoming video-call events from macOS's system Calendar via EventKit. Purely
/// informational — it never starts a recording. Only sees calendars already synced into
/// the system Calendar app (System Settings › Internet Accounts).
final class CalendarWatcher {
    static let shared = CalendarWatcher()

    private let store = EKEventStore()

    // Synchronous EventKit fetches are not cheap and the dashboard asks repeatedly per pass —
    // cache the 12h window briefly and drop it whenever the event store reports a change.
    private var cached: (stamp: Date, calls: [UpcomingCall])?
    private let cacheWindow: TimeInterval = 30

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.cached = nil
        }
    }

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Requests full calendar access, returning whether it was granted.
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// All event calendars, grouped by account (source) then name, for the Settings picker.
    func calendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).sorted {
            if $0.source.title != $1.source.title { return $0.source.title < $1.source.title }
            return $0.title < $1.title
        }
    }

    /// Upcoming events that carry a Zoom/Teams/Meet link, from the watched calendars (all, if none
    /// are explicitly chosen). Served from the cached fetch when fresh; a narrower window filters
    /// the cache rather than re-reading the store.
    ///
    /// THE HORIZON IS A SETTING NOW, and it was twelve hours hard-coded twice — once in the fetch
    /// and again as `min(hours, 12)` here, which silently clamped every caller. A meeting tomorrow
    /// morning was invisible to the app whose job is to record it, and asking for more got you
    /// twelve hours without saying so.
    ///
    /// - Parameter hours: narrow the window for a caller that wants only what is imminent (the menu
    ///   bar's "next call" asks for one hour). `nil` means the whole configured horizon. A value
    ///   LONGER than the horizon is clamped to it, because the cache behind this only holds that
    ///   much — returning fewer events than asked for is correct; pretending otherwise is not.
    func upcomingCalls(within hours: Int? = nil) -> [UpcomingCall] {
        guard isAuthorized else { return [] }

        let now = Date()
        let calls: [UpcomingCall]
        if let cached, now.timeIntervalSince(cached.stamp) < cacheWindow {
            calls = cached.calls
        } else {
            calls = fetchUpcomingCalls(from: now)
            cached = (now, calls)
        }

        let horizon = Self.horizon
        let span = hours.map { min(TimeInterval($0) * 3600, horizon) } ?? horizon
        let end = now.addingTimeInterval(span)
        return calls.filter { $0.start >= now && $0.start <= end }
    }

    /// How far ahead the store is read. One place, so the fetch and the filter cannot disagree —
    /// which is exactly how the old `min(hours, 12)` outlived the window it was clamping to.
    /// Drop the cached fetch so the next read goes to the store.
    ///
    /// NEEDED BECAUSE THE CACHE OUTLIVES THE SETTING. The cached list was fetched over whatever
    /// horizon was configured at the time, so widening the window would show nothing new until the
    /// cache expired, and narrowing it would keep serving events now out of range.
    func invalidateCache() { cached = nil }

    private static var horizon: TimeInterval {
        TimeInterval(AppSettings.calendarLookaheadDays) * 86_400
    }

    private func fetchUpcomingCalls(from now: Date) -> [UpcomingCall] {
        let end = now.addingTimeInterval(Self.horizon)

        let watched = Set(AppSettings.watchedCalendarIDs)
        let all = store.calendars(for: .event)
        let calendars = watched.isEmpty ? all : all.filter { watched.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        return store.events(matching: predicate)
            .compactMap { event -> UpcomingCall? in
                guard event.startDate >= now, let service = videoService(for: event) else { return nil }
                return UpcomingCall(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    service: service,
                    calendarID: event.calendar?.calendarIdentifier ?? ""
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Finds the calendar event that best overlaps the recording window `[start, end]` and returns
    /// its title + participant names (organizer first, the current user excluded). Prefers an event
    /// carrying a video-call link, then the largest time overlap. Returns nil if calendar access is
    /// off or nothing overlaps. The window is widened ±30 min so a recording started a few minutes
    /// into (or before) the meeting still matches.
    func callContext(from start: Date, to end: Date) -> CallContext? {
        guard isAuthorized else { return nil }

        let watched = Set(AppSettings.watchedCalendarIDs)
        let all = store.calendars(for: .event)
        let calendars = watched.isEmpty ? all : all.filter { watched.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return nil }

        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1800), end: end.addingTimeInterval(1800), calendars: calendars)

        let candidate = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { (event: $0, overlap: overlap($0, start, end)) }
            .filter { $0.overlap > 0 }
            .sorted { a, b in
                let aVideo = videoService(for: a.event) != nil
                let bVideo = videoService(for: b.event) != nil
                if aVideo != bVideo { return aVideo }   // video-call events win
                return a.overlap > b.overlap            // then the larger overlap
            }
            .first?.event

        guard let event = candidate else { return nil }
        let group = (event.calendar?.calendarIdentifier).flatMap { AppSettings.calendarGroups[$0] }
        return CallContext(title: event.title ?? "", participants: attendeeNames(of: event),
                           groupTag: group?.isEmpty == true ? nil : group)
    }

    /// Duration that event `e` overlaps the window `[start, end]` (0 if disjoint).
    private func overlap(_ e: EKEvent, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(e.endDate, end).timeIntervalSince(max(e.startDate, start)))
    }

    /// Attendee display names for an event — organizer first, current user excluded, de-duplicated.
    private func attendeeNames(of event: EKEvent) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func add(_ participant: EKParticipant?) {
            guard let participant, !participant.isCurrentUser, let name = displayName(participant) else { return }
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        add(event.organizer)
        (event.attendees ?? []).forEach(add)
        return names
    }

    /// A participant's real name, falling back to their email address when the provider only
    /// carries an address (common on personal calendars).
    private func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty, name.lowercased() != "unknown" {
            return name
        }
        let email = participant.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return email.isEmpty ? nil : email
    }

    private func videoService(for event: EKEvent) -> String? {
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("zoom.us") { return "Zoom" }
        if haystack.contains("teams.microsoft.com") || haystack.contains("teams.live.com") { return "Teams" }
        if haystack.contains("meet.google.com") { return "Meet" }
        return nil
    }
}
