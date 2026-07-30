import SwiftUI
import ScriptaCore

/// The call log — the hub's primary content: every call's generated note, bucketed by the day it
/// happened, newest day first.
struct KnowledgeDigestColumn: View {
    let rows: [IndexStore.DigestRow]
    let notes: [KnowledgeNote]
    let addToNote: (KnowledgeNote?, URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: day.day)
                    VStack(spacing: Space.x3) {
                        ForEach(day.rows, id: \.path) { row in
                            DigestCard(row: row, notes: notes) { note in
                                addToNote(note, URL(fileURLWithPath: row.path))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Rows bucketed by their frontmatter date, newest day first.
    private var days: [(day: String, rows: [IndexStore.DigestRow])] {
        var buckets: [String: [IndexStore.DigestRow]] = [:]
        for row in rows { buckets[row.date, default: []].append(row) }
        return buckets.keys.sorted(by: >).map { (dayLabel($0), buckets[$0]!) }
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
}

/// One call's generated note in the digest, with the "add on" hook into your standing notes.
private struct DigestCard: View {
    let row: IndexStore.DigestRow
    let notes: [KnowledgeNote]
    let addToNote: (KnowledgeNote?) -> Void
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Spacer()
                Menu {
                    ForEach(notes) { note in
                        Button(note.title) { addToNote(note) }
                    }
                    if !notes.isEmpty { Divider() }
                    Button("New note…") { addToNote(nil) }
                } label: {
                    HStack(spacing: Space.x2) {
                        Image(systemName: "text.append").font(.system(size: 10, weight: .semibold))
                        Text("Add to note").font(CarbonFont.label(12))
                    }
                    .foregroundStyle(Carbon.textSecondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Append what this call taught you to a standing note")
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
                    ForEach(row.tags.prefix(6), id: \.self) { tag in
                        // M21: matches the People rail's own tag chips, which already navigate —
                        // this was the one tag surface in the hub that didn't.
                        CarbonChip(text: tag) { model.route = .tag(tag) }
                    }
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
