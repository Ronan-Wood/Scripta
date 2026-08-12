import ScriptaCore
import SwiftUI

/// Where the app opens: what is happening, what just happened, and the one button that starts a call.
///
/// NOT THE DASHBOARD DOC 4 DELETED, and the distinction is the reason this exists again. That Home
/// was "Swift aggregates over the local index" — stat tiles counting things, a synthesized blurb,
/// a second call list beside the real one — and §2 was right to retire it: every card duplicated a
/// surface that owned the same content better. What went with it was not a dashboard, it was the
/// LANDING: the four sections are four places to work, and the app opened into whichever one you
/// happened to leave it on with no view of the whole.
///
/// So this answers three questions and refuses the fourth. **Can I start?** — the record card, the
/// primary action, at the top. **What is next?** — the meetings this workspace will record.
/// **What just happened?** — the last few calls, as links into Calls rather than as a rival list.
/// It does NOT restate the corpus: Library browses it, Ask queries it, and a count of it here would
/// be the aggregate-for-its-own-sake that got the old one deleted.
struct HomeView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                greeting
                HomeRecordCard()
                HomeUpcoming()
                HomeRecent()
                Spacer(minLength: 0)
            }
            .padding(Space.x7)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Carbon.background)
    }

    /// Names the workspace, because everything below it is scoped to one and the operator can have
    /// several. The privacy partition is never a hidden default anywhere else in this app.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(model.activeGroup.isEmpty ? "Ungrouped" : model.activeGroup)
                .font(CarbonFont.semibold(22)).foregroundStyle(Carbon.textPrimary)
            Text("Everything below is this workspace's.")
                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
        }
    }
}

/// Start a call, or see the one in progress. The SAME transport the Record lens draws, deliberately
/// — a second way to start recording that looked different would be a second thing to keep true.
private struct HomeRecordCard: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Button {
            if model.recordingState == .idle { model.toggleRecording?() }
            else { model.route = .section(.calls) }
        } label: {
            HStack(spacing: Space.x4) {
                ZStack {
                    Circle().fill(Carbon.danger.opacity(model.recordingState == .idle ? 0.14 : 1))
                        .frame(width: 34, height: 34)
                    if model.recordingState == .idle {
                        CarbonIcon(name: "recording-filled", size: 16, color: Carbon.danger)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary)
                    Text(subtitle).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                }
                Spacer()
                if model.recordingState == .recording {
                    Text(model.elapsedLabel)
                        .font(CarbonFont.monospace(15)).foregroundStyle(Carbon.danger)
                }
            }
            .padding(Space.x5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carbon.interactive.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Carbon.interactive.opacity(0.25), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch model.recordingState {
        case .idle: return "Start recording"
        case .recording: return model.isPaused ? "Paused" : "Recording…"
        case .processing: return "Transcribing…"
        }
    }

    private var subtitle: String {
        switch model.recordingState {
        case .idle: return "⌥⌘R from anywhere, or the Record pill above."
        case .recording, .processing: return "Open the call in Calls › Record."
        }
    }
}

/// The meetings this workspace will record. SCOPED, like the Calendar lens it shares its rule with:
/// `AppSettings.calendarGroups` routes each calendar to a workspace, so showing another workspace's
/// client calls here would be the partition leaking onto the landing screen.
private struct HomeUpcoming: View {
    @ObservedObject private var model = AppModel.shared

    private var meetings: [UpcomingCall] {
        let group = model.activeGroup
        return model.upcomingMeetings
            .filter { AppSettings.recordingGroup(forCalendarID: $0.calendarID) == group }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        if !meetings.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Next up")
                ForEach(meetings) { meeting in
                    HStack(spacing: Space.x3) {
                        Image(systemName: "calendar").foregroundStyle(Carbon.interactive)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title).font(CarbonFont.medium(13))
                                .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                            Text("\(relative(meeting.start)) · \(meeting.service)")
                                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                        }
                        Spacer()
                        if model.recordingState == .idle {
                            CarbonButton(title: "Record", icon: "recording-filled", kind: .secondary) {
                                model.recordMeeting?(meeting)
                            }
                        }
                    }
                    .padding(Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                    }
                }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEE h:mm a"
        return fmt.string(from: date)
    }
}

/// The last few calls, as a way IN rather than as a second call list. Tapping one opens it in Calls,
/// which is the surface that owns reading a transcript — the old Home's mistake was rebuilding that
/// surface here rather than pointing at it.
private struct HomeRecent: View {
    @ObservedObject private var model = AppModel.shared

    private var recent: [TranscriptMeta] { Array(model.calls.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Recent calls")
                Spacer()
                if !model.calls.isEmpty {
                    Button("View all") { model.route = .section(.calls) }
                        .buttonStyle(.plain)
                        .font(CarbonFont.label(12)).foregroundStyle(Carbon.interactive)
                }
            }
            if recent.isEmpty {
                Text("No calls in this workspace yet. Record one and it lands in its vault.")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
            } else {
                ForEach(recent, id: \.url) { call in
                    Button { model.route = .call(call.url) } label: {
                        HStack(spacing: Space.x3) {
                            CarbonIcon(name: "document", size: 13, color: Carbon.iconSecondary)
                            Text(call.displayTitle).font(CarbonFont.medium(13))
                                .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                            Spacer()
                            Text(call.date).font(CarbonFont.label(11))
                                .foregroundStyle(Carbon.textHelper)
                        }
                        .padding(Space.x4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
