import SwiftUI
import ScriptaCore

/// A calendar of recorded calls (past) and upcoming video meetings (future) — Month / Week / Day.
/// Month is a grid; Week and Day are time-of-day grids with events sized to their duration. Past
/// calls open in the reader; upcoming meetings can be recorded. Carbon-styled.
struct CalendarView: View {
    let calls: [TranscriptMeta]
    let meetings: [UpcomingCall]
    let onOpenCall: (URL) -> Void
    let onRecordMeeting: (UpcomingCall) -> Void

    enum Mode: String, CaseIterable, Identifiable { case month = "Month", week = "Week", day = "Day"; var id: String { rawValue } }
    @State private var mode: Mode = .month
    @State private var anchor = Date()

    private let cal = Calendar.current
    private let hourHeight: CGFloat = 44
    private let gutter: CGFloat = 54
    // Bucketed once per input change — the grids ask "calls on this day?" per cell per render,
    // which used to parse every call's date with a fresh DateFormatter each time.
    private let callsByDay: [Date: [TranscriptMeta]]

    private static let dayFormatter: DateFormatter = {
        // POSIX to match the frontmatter dates TranscriptWriter emits.
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    init(calls: [TranscriptMeta], meetings: [UpcomingCall],
         onOpenCall: @escaping (URL) -> Void, onRecordMeeting: @escaping (UpcomingCall) -> Void) {
        self.calls = calls
        self.meetings = meetings
        self.onOpenCall = onOpenCall
        self.onRecordMeeting = onRecordMeeting
        let cal = Calendar.current
        var buckets: [Date: [TranscriptMeta]] = [:]
        for meta in calls {
            guard let parsed = Self.dayFormatter.date(from: meta.date) else { continue }
            buckets[cal.startOfDay(for: parsed), default: []].append(meta)
        }
        for key in buckets.keys { buckets[key]?.sort { $0.time < $1.time } }
        callsByDay = buckets
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
            switch mode {
            case .month: monthView
            case .week: timeGrid(weekDays())
            case .day: timeGrid([cal.startOfDay(for: anchor)])
            }
        }
        .background(Carbon.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.x3) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Button("Today") { anchor = Date() }.buttonStyle(.plain).font(CarbonFont.body(13))
            Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Text(periodLabel).font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary)
            Spacer()
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
        }
        .foregroundStyle(Carbon.iconSecondary)
        .padding(.horizontal, Space.x5).padding(.vertical, Space.x4)
    }

    private func step(_ dir: Int) {
        let comp: Calendar.Component = mode == .month ? .month : (mode == .week ? .weekOfYear : .day)
        anchor = cal.date(byAdding: comp, value: dir, to: anchor) ?? anchor
    }

    private var periodLabel: String {
        let f = DateFormatter()
        switch mode {
        case .month: f.dateFormat = "MMMM yyyy"; return f.string(from: anchor)
        case .week:
            let days = weekDays(); f.dateFormat = "MMM d"
            let end = DateFormatter(); end.dateFormat = "d"
            return "\(f.string(from: days.first!)) – \(end.string(from: days.last!))"
        case .day: f.dateFormat = "EEEE, MMM d"; return f.string(from: anchor)
        }
    }

    // MARK: - Month

    private var monthView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(shortWeekdaySymbols(), id: \.self) { s in
                    Text(s.uppercased()).font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Space.x2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(monthGridDays(), id: \.self) { day in monthCell(day) }
            }
            .padding(1).background(Carbon.borderSubtle)
        }
    }

    private func monthCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: anchor, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: day))")
                .font(CarbonFont.label(12))
                .frame(width: 20, height: 20)
                .background(cal.isDateInToday(day) ? Carbon.interactive : Color.clear, in: Circle())
                .foregroundStyle(cal.isDateInToday(day) ? Carbon.textOnColor : (inMonth ? Carbon.textPrimary : Carbon.textPlaceholder))
            ForEach(meetingsOn(day)) { m in
                Button { mode = .day; anchor = m.start } label: {
                    chipLabel(m.title, color: Carbon.warning, filled: false)
                }.buttonStyle(.plain)
            }
            ForEach(callsOn(day).prefix(3)) { meta in
                Button { onOpenCall(meta.url) } label: {
                    chipLabel(meta.displayTitle, color: Carbon.interactive, filled: true)
                }.buttonStyle(.plain)
            }
            let overflow = callsOn(day).count - 3
            if overflow > 0 { Text("+\(overflow)").font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary) }
            Spacer(minLength: 0)
        }
        .padding(Space.x2)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .background(Carbon.background)
    }

    private func chipLabel(_ text: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 3) {
            if !filled { Circle().fill(color).frame(width: 5, height: 5) }
            Text(text).font(CarbonFont.label(11)).foregroundStyle(filled ? color : Carbon.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, Space.x2).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(filled ? color.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay { if !filled { RoundedRectangle(cornerRadius: 4).strokeBorder(Carbon.borderStrong, lineWidth: 1) } }
    }

    // MARK: - Time grid (Week / Day)

    private func timeGrid(_ days: [Date]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 44)
                ForEach(days, id: \.self) { day in dayHeader(day).frame(maxWidth: .infinity) }
            }
            .frame(height: 44)
            .padding(.vertical, Space.x2)
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(days, id: \.self) { day in
                            dayColumn(day)
                            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
                        }
                    }
                    .frame(height: 24 * hourHeight)
                }
                .onAppear { proxy.scrollTo("hour-8", anchor: .top) }
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        VStack(spacing: 1) {
            Text(weekdayShort(day)).font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
            Text("\(cal.component(.day, from: day))")
                .font(CarbonFont.medium(14))
                .foregroundStyle(cal.isDateInToday(day) ? Carbon.textOnColor : Carbon.textPrimary)
                .frame(width: 24, height: 24)
                .background(cal.isDateInToday(day) ? Carbon.interactive : Color.clear, in: Circle())
        }
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(hourLabel(h)).font(CarbonFont.label(10)).foregroundStyle(Carbon.textSecondary)
                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    .id("hour-\(h)")
            }
        }
        .frame(width: gutter)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let laid = laidOut(eventsOn(day))
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                hourLines
                ForEach(laid, id: \.ev.id) { item in
                    positioned(item.ev, columnWidth: geo.size.width, lane: item.lane, lanes: item.lanes)
                }
            }
            .frame(width: geo.size.width, height: 24 * hourHeight, alignment: .topLeading)
            .background(cal.isDateInToday(day) ? Carbon.interactive.opacity(0.04) : Color.clear)
        }
        .frame(height: 24 * hourHeight)
    }

    /// Positions an event block at its start time, sized to its duration, in its overlap lane.
    private func positioned(_ ev: GridEvent, columnWidth: CGFloat, lane: Int, lanes: Int) -> some View {
        let laneWidth: CGFloat = columnWidth / CGFloat(max(1, lanes))
        let width: CGFloat = max(0, laneWidth - 4)
        let height: CGFloat = max(20, CGFloat(ev.durationMin) / 60.0 * hourHeight)
        let x: CGFloat = CGFloat(lane) * laneWidth + 2
        let y: CGFloat = CGFloat(ev.startMin) / 60.0 * hourHeight
        return eventBlock(ev)
            .frame(width: width, height: height, alignment: .topLeading)
            .offset(x: x, y: y)
    }

    /// Assigns each event to a lane so overlapping events sit side by side.
    private func laidOut(_ events: [GridEvent]) -> [(ev: GridEvent, lane: Int, lanes: Int)] {
        let sorted = events.sorted { $0.startMin < $1.startMin }
        var laneEnd: [Int] = []
        var placed: [(GridEvent, Int)] = []
        for ev in sorted {
            let end = ev.startMin + max(15, Int(ev.durationMin.rounded()))
            if let lane = laneEnd.firstIndex(where: { $0 <= ev.startMin }) {
                laneEnd[lane] = end
                placed.append((ev, lane))
            } else {
                laneEnd.append(end)
                placed.append((ev, laneEnd.count - 1))
            }
        }
        let lanes = max(1, laneEnd.count)
        return placed.map { (ev: $0.0, lane: $0.1, lanes: lanes) }
    }

    private func eventBlock(_ ev: GridEvent) -> some View {
        let accent: Color = ev.isMeeting ? Carbon.warning : Carbon.interactive
        return Button {
            if let url = ev.url { onOpenCall(url) } else if let m = ev.meeting { onRecordMeeting(m) }
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ev.title).font(CarbonFont.medium(11)).foregroundStyle(Carbon.textPrimary).lineLimit(2)
                    Text(minutesLabel(ev.startMin)).font(CarbonFont.label(10)).foregroundStyle(Carbon.textSecondary)
                }
                .padding(.horizontal, Space.x2)
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(accent.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Events

    struct GridEvent: Identifiable {
        let id: String   // stable across renders, or the grid rebuilds every block every pass
        let title: String
        let startMin: Int
        let durationMin: Double
        let url: URL?
        let meeting: UpcomingCall?
        var isMeeting: Bool { meeting != nil }
    }

    private func eventsOn(_ day: Date) -> [GridEvent] {
        var events: [GridEvent] = meetingsOn(day).map { m in
            let c = cal.dateComponents([.hour, .minute], from: m.start)
            return GridEvent(id: "meeting-\(m.id)", title: m.title,
                             startMin: (c.hour ?? 9) * 60 + (c.minute ?? 0),
                             durationMin: 30, url: nil, meeting: m)
        }
        events += callsOn(day).map { meta in
            GridEvent(id: "call-\(meta.url.path)", title: meta.displayTitle,
                      startMin: startMinutes(meta.time),
                      durationMin: durationMinutes(meta.duration), url: meta.url, meeting: nil)
        }
        return events
    }

    // MARK: - Data + parsing

    private func callsOn(_ day: Date) -> [TranscriptMeta] {
        callsByDay[cal.startOfDay(for: day)] ?? []
    }
    private func meetingsOn(_ day: Date) -> [UpcomingCall] {
        meetings.filter { cal.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
    }
    private func startMinutes(_ time: String) -> Int {
        let p = time.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 9 * 60
    }
    /// "M:SS" or "H:MM:SS" → minutes.
    private func durationMinutes(_ s: String) -> Double {
        let p = s.split(separator: ":").compactMap { Int($0) }
        if p.count == 2 { return Double(p[0]) + Double(p[1]) / 60.0 }
        if p.count == 3 { return Double(p[0]) * 60 + Double(p[1]) + Double(p[2]) / 60.0 }
        return 15
    }
    private func minutesLabel(_ min: Int) -> String {
        let h = min / 60, m = min % 60
        let period = h < 12 ? "AM" : "PM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, period)
    }
    private func hourLabel(_ h: Int) -> String {
        if h == 0 { return "12 AM" }; if h == 12 { return "12 PM" }
        return h < 12 ? "\(h) AM" : "\(h - 12) PM"
    }

    private func monthGridDays() -> [Date] {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor)),
              let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let leading = ((cal.component(.weekday, from: monthStart) - cal.firstWeekday) + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -leading, to: monthStart) else { return [] }
        let total = Int(ceil(Double(leading + range.count) / 7.0)) * 7
        return (0..<total).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }
    private func weekDays() -> [Date] {
        let leading = ((cal.component(.weekday, from: anchor) - cal.firstWeekday) + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -leading, to: cal.startOfDay(for: anchor)) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
    private func shortWeekdaySymbols() -> [String] {
        let symbols = cal.shortStandaloneWeekdaySymbols; let start = cal.firstWeekday - 1
        return (0..<7).map { symbols[($0 + start) % 7] }
    }
    private func weekdayShort(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: day)
    }
}
