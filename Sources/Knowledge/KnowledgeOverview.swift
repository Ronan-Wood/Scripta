import SwiftUI
import ScriptaCore

// The hub's top-of-page strip: what this page is, the at-a-glance counts, the synthesized
// "what's important" blurb, and the nothing-recorded-yet card. Concrete structs rather than
// computed `some View` properties on KnowledgeView — each one is its own inference scope, which
// is what keeps `KnowledgeView.body`'s already-long modifier chain inside the type checker's
// budget (see KnowledgeSheets.swift for the failure this file's shape is guarding against).

/// Masthead: the page's name and how much it was compiled from.
struct KnowledgeHeader: View {
    let callCount: Int
    let workspaceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Knowledge center").font(CarbonFont.semibold(24)).foregroundStyle(Carbon.textPrimary)
            Text("Compiled on-device from \(callCount) call\(callCount == 1 ? "" : "s") in \(workspaceName)")
                .font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
        }
    }
}

/// At-a-glance counts (M22) — the shared `StatTile` `HomeView` already uses, with
/// Knowledge-specific numbers (not a duplicate of Home's calls/hours tiles), all from data
/// KnowledgeView already loads in `reload()` — no new queries for the tiles themselves.
struct KnowledgeStatRow: View {
    let commitmentCount: Int
    let peopleCount: Int
    let noteCount: Int
    let docCount: Int

    var body: some View {
        HStack(spacing: Space.x5) {
            StatTile(label: "Open commitments", value: "\(commitmentCount)")
            StatTile(label: "People tracked", value: "\(peopleCount)")
            StatTile(label: "Notes", value: "\(noteCount)")
            StatTile(label: "Documents", value: "\(docCount)")
        }
    }
}

/// "What's important" (M23) — hidden entirely when nil, same "don't show an awkward empty
/// state for a quiet workspace" rule the rail's needs-attention group already follows. Card
/// treatment (not a bare `Text`) matches `StatTile`'s own layer+border language just above it.
struct WhatsImportantCard: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(CarbonFont.body(13)).foregroundStyle(Carbon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
        }
    }
}

struct KnowledgeEmptyState: View {
    var body: some View {
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
}
