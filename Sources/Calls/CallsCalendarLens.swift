import SwiftUI
import ScriptaCore

/// Calls against time: an always-visible "Upcoming" strip of the next video meetings, over a
/// Month/Week/Day calendar of recorded calls (past) and meetings (future). Recording is always a
/// manual click.
///
/// WAS THE `Meetings` SECTION, folded in per Doc 4 §2. It is the same corpus `CallsView` lists,
/// read against the calendar instead of as a ranked list, which is why it is a lens rather than a
/// place of its own.
///
/// SCOPED TO THE ACTIVE WORKSPACE, which it was NOT as a section. It listed every transcript on the
/// machine — defensible while it was its own top-level place, and wrong the moment it sits inside a
/// surface whose scope indicator claims otherwise. `CallsView` keeps cross-workspace search
/// deliberately transient "so it can never become a lingering default"; a calendar quietly showing
/// every workspace would be exactly that default, arriving through the back door. The partition is
/// `meta.group`, which since Doc 4 §7 is derived from the vault the file sits in rather than from a
/// label that can disagree with its own location.
struct CallsCalendarLens: View {
    @ObservedObject private var app = AppModel.shared
    @State private var calls: [TranscriptMeta] = []
    @State private var meetings: [UpcomingCall] = []

    var body: some View {
        VStack(spacing: 0) {
            if !meetings.isEmpty {
                upcomingStrip
                Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
            }
            CalendarView(
                calls: calls,
                meetings: meetings,
                onOpenCall: { app.route = .call($0) },
                onRecordMeeting: { app.recordMeeting?($0) }
            )
        }
        .background(Carbon.background)
        .onAppear(perform: reload)
        .onChange(of: app.activeGroup) { _, _ in reload() }
        .onChange(of: app.recordingState) { _, state in if state == .idle { reload() } }
    }

    private var upcomingStrip: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            SectionHeader(title: "Upcoming")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.x3) {
                    ForEach(meetings.prefix(6)) { meeting in upcomingCard(meeting) }
                }
            }
        }
        .padding(.horizontal, Space.x5).padding(.vertical, Space.x4)
    }

    private func upcomingCard(_ meeting: UpcomingCall) -> some View {
        HStack(spacing: Space.x3) {
            Image(systemName: "calendar").foregroundStyle(Carbon.interactive)
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(meeting.title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Text("\(relative(meeting.start)) · \(meeting.service)")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
            }
            if app.recordingState == .idle {
                Button { app.recordMeeting?(meeting) } label: {
                    CarbonIcon(name: "recording", size: 15, color: Carbon.danger)
                }.buttonStyle(.plain).help("Record this")
            }
        }
        .padding(.horizontal, Space.x4).padding(.vertical, Space.x3)
        .frame(minWidth: 240, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
    }

    private func relative(_ date: Date) -> String {
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEE h:mm a"
        return fmt.string(from: date)
    }

    private func reload() {
        let group = app.activeGroup
        calls = TranscriptStore.list().filter { $0.group == group }
        // BOTH HALVES, or the claim above is only half true. The Upcoming strip and the future side
        // of the grid render calendar events, and `AppSettings.calendarGroups` already routes each
        // calendar to a workspace — it is what decides where a recording of that meeting lands. So
        // an unfiltered strip shows meetings this lens would refuse to file here: sitting in
        // Personal, the titles of every upcoming CBRE client call. Same mapping as the record path,
        // so what is shown is what would be recorded into this workspace.
        meetings = app.upcomingMeetings.filter {
            AppSettings.recordingGroup(forCalendarID: $0.calendarID) == group
        }
    }
}
