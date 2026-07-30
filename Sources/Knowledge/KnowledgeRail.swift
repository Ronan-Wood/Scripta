import SwiftUI
import ScriptaCore

/// The hub's right-hand rail: two purpose-grouped zones (M22), not a flat stack of unrelated
/// sections: things only you can resolve, then facets you browse by. Order matters — actionable
/// before reference.
struct KnowledgeRail: View {
    let commitments: [CommitmentDisplay]
    let collisions: [(a: EntityRegistry.Entity, b: EntityRegistry.Entity)]
    let people: [(name: String, count: Int)]
    let topics: [(name: String, count: Int)]
    let vocabTerms: [EntityRegistry.Entity]
    let suggestions: [String]
    @Binding var entitySheetTarget: EntitySheetTarget?
    @Binding var addingTerm: Bool
    @Binding var termCanonical: String
    @Binding var termAliases: String
    @Binding var termGloss: String
    let onMarkCommitmentDone: (CommitmentDisplay) -> Void
    let onVerdict: ((a: EntityRegistry.Entity, b: EntityRegistry.Entity), Bool) -> Void
    let onAddTerm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x7) {
            NeedsAttentionGroup(commitments: commitments,
                                collisions: collisions,
                                entitySheetTarget: $entitySheetTarget,
                                onMarkDone: onMarkCommitmentDone,
                                onVerdict: onVerdict)
            BrowseGroup(people: people,
                        topics: topics,
                        vocabTerms: vocabTerms,
                        suggestions: suggestions,
                        entitySheetTarget: $entitySheetTarget,
                        addingTerm: $addingTerm,
                        termCanonical: $termCanonical,
                        termAliases: $termAliases,
                        termGloss: $termGloss,
                        onAddTerm: onAddTerm)
        }
    }
}

/// Visually distinct from `SectionHeader` (bigger, sentence case, full-strength color) —
/// used only for the two rail groups below, so "Needs attention"/"Browse" read as a tier
/// above the individual section titles inside them, not a peer of "Commitments"/"People".
private struct RailGroupHeader: View {
    let title: String

    var body: some View {
        Text(title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary)
    }
}

/// Commitments + identity collisions — both "only you can resolve this," previously
/// scattered (commitments mid-rail, collisions buried at the bottom under Vocabulary with
/// nothing suggesting they were related). Hidden entirely, not shown empty, when there's
/// genuinely nothing pending — an empty "Needs attention" header with nothing under it would
/// read as broken, not reassuring.
private struct NeedsAttentionGroup: View {
    let commitments: [CommitmentDisplay]
    let collisions: [(a: EntityRegistry.Entity, b: EntityRegistry.Entity)]
    @Binding var entitySheetTarget: EntitySheetTarget?
    let onMarkDone: (CommitmentDisplay) -> Void
    let onVerdict: ((a: EntityRegistry.Entity, b: EntityRegistry.Entity), Bool) -> Void

    var body: some View {
        if !commitments.isEmpty || !collisions.isEmpty {
            VStack(alignment: .leading, spacing: Space.x5) {
                RailGroupHeader(title: "Needs attention")
                CommitmentsSection(commitments: commitments,
                                   entitySheetTarget: $entitySheetTarget,
                                   onMarkDone: onMarkDone)
                IdentityCheckSection(collisions: collisions, onVerdict: onVerdict)
            }
        }
    }
}

/// People + Topics + Vocabulary — three "look something up by facet" surfaces that used to be
/// split across the rail (People, Topics) and a separate section below the fold (Vocabulary).
/// Always shown (unlike `NeedsAttentionGroup`): Vocabulary already renders a placeholder
/// prompt when empty rather than disappearing, so this group is never genuinely empty.
private struct BrowseGroup: View {
    let people: [(name: String, count: Int)]
    let topics: [(name: String, count: Int)]
    let vocabTerms: [EntityRegistry.Entity]
    let suggestions: [String]
    @Binding var entitySheetTarget: EntitySheetTarget?
    @Binding var addingTerm: Bool
    @Binding var termCanonical: String
    @Binding var termAliases: String
    @Binding var termGloss: String
    let onAddTerm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            RailGroupHeader(title: "Browse")
            PeopleSection(people: people, entitySheetTarget: $entitySheetTarget)
            TopicsSection(topics: topics)
            VocabularySection(vocabTerms: vocabTerms,
                              suggestions: suggestions,
                              entitySheetTarget: $entitySheetTarget,
                              addingTerm: $addingTerm,
                              termCanonical: $termCanonical,
                              termAliases: $termAliases,
                              termGloss: $termGloss,
                              onAddTerm: onAddTerm)
        }
    }
}

private struct PeopleSection: View {
    let people: [(name: String, count: Int)]
    @Binding var entitySheetTarget: EntitySheetTarget?
    @ObservedObject var model = AppModel.shared

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "People")
                VStack(spacing: 1) {
                    ForEach(people.prefix(8), id: \.name) { person in
                        Button {
                            let id = EntityRegistry.shared.resolveConfirmed(surface: person.name, kind: "person", group: model.activeGroup)
                            entitySheetTarget = EntitySheetTarget(id: id ?? person.name, fallbackName: person.name)
                        } label: {
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
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            }
        }
    }

    /// "Wertz, Lalita @ Harrisburg" → "Wertz, Lalita" for the rail; full name in the tooltip.
    private func shortName(_ name: String) -> String {
        name.components(separatedBy: " @ ").first ?? name
    }
}

private struct TopicsSection: View {
    let topics: [(name: String, count: Int)]
    @ObservedObject var model = AppModel.shared

    var body: some View {
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Topics")
                FlexWrap(spacing: Space.x2) {
                    ForEach(topics.prefix(14), id: \.name) { topic in
                        CarbonChip(text: topic.name) { model.route = .tag(topic.name) }
                    }
                }
            }
        }
    }
}

/// Per-person commitment rollup (M17): what you owe, and what's owed to you, grouped by
/// person — workspace-wide (via IndexStore.commitments), not scoped to what's currently
/// rendered in the digest, matching how the Vocabulary section is workspace-wide too.
private struct CommitmentsSection: View {
    let commitments: [CommitmentDisplay]
    @Binding var entitySheetTarget: EntitySheetTarget?
    let onMarkDone: (CommitmentDisplay) -> Void

    var body: some View {
        let owedByYou = commitments.filter(\.isYou)
        // Keyed by ownerID, not the display name — two different people can share a name, and
        // grouping by string would silently merge their commitments (crosscheck finding).
        let owedToYou = Dictionary(grouping: commitments.filter { !$0.isYou }, by: \.ownerID)
        if !owedByYou.isEmpty || !owedToYou.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Commitments")
                if !owedByYou.isEmpty {
                    Text("You owe").font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                    ForEach(owedByYou) { CommitmentRowView(item: $0, onMarkDone: onMarkDone) }
                }
                ForEach(owedToYou.keys.sorted(), id: \.self) { ownerID in
                    let items = owedToYou[ownerID] ?? []
                    if let name = items.first?.ownerName {
                        Button { entitySheetTarget = EntitySheetTarget(id: ownerID, fallbackName: name) } label: {
                            Text("\(name) owes you").font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                        }.buttonStyle(.plain)
                        ForEach(items) { CommitmentRowView(item: $0, onMarkDone: onMarkDone) }
                    }
                }
            }
        }
    }
}

private struct CommitmentRowView: View {
    let item: CommitmentDisplay
    let onMarkDone: (CommitmentDisplay) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.x2) {
            Button { onMarkDone(item) } label: {
                CarbonIcon(name: "checkmark", size: 10, color: Carbon.textHelper)
            }.buttonStyle(.plain).help("Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text).font(CarbonFont.body(12)).foregroundStyle(Carbon.textPrimary)
                Text(item.callTitle).font(CarbonFont.label(10)).foregroundStyle(Carbon.textHelper)
            }
        }
        .padding(.leading, Space.x1)
    }
}

/// Deterministic identity clarifiers: pairs the registry itself flags as possibly the same
/// person/org. Your verdict persists as a rule, so each pair is asked exactly once.
private struct IdentityCheckSection: View {
    let collisions: [(a: EntityRegistry.Entity, b: EntityRegistry.Entity)]
    let onVerdict: ((a: EntityRegistry.Entity, b: EntityRegistry.Entity), Bool) -> Void

    var body: some View {
        if !collisions.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Identity check")
                ForEach(Array(collisions.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text("Same \(pair.a.kind == "org" ? "company" : "person")?")
                            .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                        Text("\(pair.a.name)  ·  \(pair.b.name)")
                            .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: Space.x3) {
                            Button("Same") { onVerdict(pair, true) }
                                .buttonStyle(.plain)
                                .font(CarbonFont.medium(12)).foregroundStyle(Carbon.interactive)
                            Button("Different") { onVerdict(pair, false) }
                                .buttonStyle(.plain)
                                .font(CarbonFont.medium(12)).foregroundStyle(Carbon.textSecondary)
                        }
                    }
                    .padding(Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                    }
                }
            }
        }
    }
}
