import SwiftUI

/// The Knowledge center: review what happened across your calls. A day-grouped digest of every
/// call's generated note (title, summary, topics, people), with the workspace's people and
/// topics alongside — all served from the index, so it opens instantly and never re-reads
/// transcript files. Comments (the "add on" layer) attach per call via NoteStore.
struct KnowledgeView: View {
    @ObservedObject var model = AppModel.shared
    @State private var rows: [IndexStore.DigestRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                header
                if rows.isEmpty {
                    emptyState
                } else {
                    HStack(alignment: .top, spacing: Space.x6) {
                        digestColumn.frame(maxWidth: .infinity, alignment: .leading)
                        rail.frame(width: 300)
                    }
                }
            }
            .padding(Space.x7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Carbon.background)
        .onAppear(perform: reload)
        .onChange(of: model.activeGroup) { _, _ in reload() }
        .onChange(of: model.calls) { _, _ in reload() }
    }

    private func reload() {
        rows = model.index?.digest(group: model.activeGroup) ?? []
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Knowledge center").font(CarbonFont.semibold(24)).foregroundStyle(Carbon.textPrimary)
            Text("Compiled on-device from \(rows.count) call\(rows.count == 1 ? "" : "s") in \(workspaceName)")
                .font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var workspaceName: String {
        model.activeGroup.isEmpty ? "your workspace" : "“\(model.activeGroup)”"
    }

    private var emptyState: some View {
        CarbonCard {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text("Nothing here yet").font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary)
                Text("As you record calls, their notes collect here — a running record of what happened, who said it, and what you added.")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: - Digest (day-grouped call notes)

    /// Rows bucketed by their frontmatter date, newest day first.
    private var days: [(day: String, rows: [IndexStore.DigestRow])] {
        var buckets: [String: [IndexStore.DigestRow]] = [:]
        for row in rows { buckets[row.date, default: []].append(row) }
        return buckets.keys.sorted(by: >).map { (dayLabel($0), buckets[$0]!) }
    }

    private var digestColumn: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: day.day)
                    VStack(spacing: Space.x3) {
                        ForEach(day.rows, id: \.path) { NoteCard(row: $0) }
                    }
                }
            }
        }
    }

    /// "Today" / "Yesterday" / "Monday, July 14" from a yyyy-MM-dd frontmatter date.
    private func dayLabel(_ date: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let parsed = parser.date(from: date) else { return date }
        if Calendar.current.isDateInToday(parsed) { return "Today" }
        if Calendar.current.isDateInYesterday(parsed) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: parsed)
    }

    // MARK: - Rail (people + topics, scoped to what's on screen — the wall holds)

    private var scopedPeople: [(name: String, count: Int)] {
        aggregate(rows.map(\.participants))
    }
    private var scopedTopics: [(name: String, count: Int)] {
        aggregate(rows.map(\.tags))
    }

    private func aggregate(_ lists: [[String]]) -> [(name: String, count: Int)] {
        var counts: [String: (display: String, count: Int)] = [:]
        for list in lists {
            for value in Set(list) {   // one count per call, not per mention
                let key = value.lowercased()
                counts[key] = (counts[key]?.display ?? value, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.map { (name: $0.display, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            if !scopedPeople.isEmpty {
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: "People")
                    VStack(spacing: 1) {
                        ForEach(scopedPeople.prefix(8), id: \.name) { person in
                            HStack(spacing: Space.x3) {
                                InitialsBadge(name: person.name)
                                Text(shortName(person.name)).font(CarbonFont.medium(13))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Spacer()
                                Text("\(person.count) call\(person.count == 1 ? "" : "s")")
                                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                            }
                            .padding(Space.x4)
                            .background(Carbon.layer)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                }
            }
            if !scopedTopics.isEmpty {
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: "Topics")
                    FlexWrap(spacing: Space.x2) {
                        ForEach(scopedTopics.prefix(14), id: \.name) { topic in
                            CarbonChip(text: topic.name) { model.route = .tag(topic.name) }
                        }
                    }
                }
            }
        }
    }

    /// "Wertz, Lalita @ Harrisburg" → "Wertz, Lalita" for the rail; full name in the tooltip.
    private func shortName(_ name: String) -> String {
        name.components(separatedBy: " @ ").first ?? name
    }
}

/// One call's generated note in the digest.
private struct NoteCard: View {
    let row: IndexStore.DigestRow
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Spacer()
                Button {
                    model.route = .call(URL(fileURLWithPath: row.path))
                } label: {
                    HStack(spacing: Space.x2) {
                        Text("Open").font(CarbonFont.label(12))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Carbon.interactive)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(meta).font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
            if !row.summary.isEmpty {
                Text(row.summary).font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if !row.tags.isEmpty {
                FlexWrap(spacing: Space.x2) {
                    ForEach(row.tags.prefix(6), id: \.self) { CarbonChip(text: $0) }
                }
            }
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    private var title: String {
        row.title.isEmpty ? "\(row.date) \(row.time)" : row.title
    }
    private var meta: String {
        var parts: [String] = []
        if !row.time.isEmpty { parts.append(row.time) }
        if !row.duration.isEmpty { parts.append(row.duration) }
        if !row.participants.isEmpty {
            parts.append(row.participants.prefix(3).map { $0.components(separatedBy: " @ ").first ?? $0 }
                .joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// Colored initials disc, Carbon-blue family.
struct InitialsBadge: View {
    let name: String
    var body: some View {
        Text(initials)
            .font(CarbonFont.medium(10))
            .foregroundStyle(Carbon.interactive)
            .frame(width: 24, height: 24)
            .background(Carbon.interactive.opacity(0.14), in: Circle())
    }
    private var initials: String {
        let words = name.components(separatedBy: " @ ").first?
            .components(separatedBy: CharacterSet(charactersIn: " ,")).filter { !$0.isEmpty } ?? []
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
