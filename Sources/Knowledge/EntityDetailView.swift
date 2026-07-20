import SwiftUI
import ScriptaCore

/// One person/topic's own page (M19): canonical name + aliases + gloss (`EntityRegistry` is
/// already the trust layer — merge verdicts, privacy walls, provenance), a mention timeline
/// across calls, and who/what else co-occurs with them. Read-only, no new mutation path —
/// brain ≠ editor holds here same as everywhere else; this only displays identity data other
/// features (the registry, extraction, the correction loop) already own and write.
struct EntityDetailView: View {
    let entityID: String
    let group: String
    /// Shown until (or instead of, if it never resolves) the real registry entity loads — needed
    /// because M17's commitment-owner fallback can pass an `entityID` that's a raw surface string
    /// rather than a real registry id when nothing confirmed matched, and this view shouldn't
    /// show a blank "…" header for a name the caller already had in hand.
    var fallbackName: String? = nil
    let onClose: () -> Void

    @State private var entity: EntityRegistry.Entity?
    @State private var mentions: [SearchHit] = []
    @State private var coOccurring: [(id: String, name: String, kind: String, count: Int)] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Carbon.borderSubtle)
            if !loaded {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        if let entity {
                            // Filtered once, gated on the filtered result — not on raw
                            // entity.aliases, which every freshly-resolved entity already
                            // contains (its own normalized name) even with zero real alternate
                            // spellings, which rendered an empty "Also known as" heading for the
                            // common case (crosscheck).
                            let extraAliases = entity.aliases.filter { $0 != EntityRegistry.normalize(entity.name) }
                            if !extraAliases.isEmpty { aliasesSection(extraAliases) }
                            if let gloss = entity.gloss, !gloss.isEmpty { glossSection(gloss) }
                        }
                        mentionsSection
                        if !coOccurring.isEmpty { coOccurringSection }
                    }
                    .padding(Space.x6)
                }
            }
        }
        .frame(width: 420, height: 520)
        .background(Carbon.background)
        .task { await load() }
    }

    private var displayName: String { entity?.name ?? fallbackName ?? "…" }

    private var header: some View {
        HStack(spacing: Space.x3) {
            InitialsBadge(name: displayName)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).font(CarbonFont.medium(16)).foregroundStyle(Carbon.textPrimary)
                if let entity {
                    Text(entity.kind == "term" ? "Term" : entity.confirmed ? "Confirmed" : "Unconfirmed")
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
            }
            Spacer()
            Button(action: onClose) {
                CarbonIcon(name: "close", size: 14, color: Carbon.iconSecondary)
            }.buttonStyle(.plain)
        }
        .padding(Space.x5)
    }

    private func aliasesSection(_ aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Also known as")
            FlexWrap(spacing: Space.x2) {
                ForEach(aliases, id: \.self) { alias in
                    CarbonChip(text: alias)
                }
            }
        }
    }

    private func glossSection(_ gloss: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            SectionHeader(title: "Meaning")
            Text(gloss).font(CarbonFont.body(13)).foregroundStyle(Carbon.textPrimary)
        }
    }

    @ViewBuilder private var mentionsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Mentioned in")
            if mentions.isEmpty {
                // "No calls yet" would be a flat false claim for the M17 commitment-owner
                // fallback path: the person WAS just mentioned, in the call the user opened this
                // page from — there's simply no tracked identity for them yet, a different and
                // more honest thing to say (crosscheck).
                Text(entity == nil && fallbackName != nil
                     ? "\(fallbackName!) isn't a tracked contact yet — not yet confirmed as a call participant."
                     : "No calls yet.")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 1) {
                    ForEach(mentions) { hit in
                        Button {
                            onClose()
                            AppModel.shared.route = .call(URL(fileURLWithPath: hit.path), ms: hit.startMs)
                        } label: {
                            HStack {
                                Text(hit.title.isEmpty ? hit.date : hit.title)
                                    .font(CarbonFont.medium(13)).foregroundStyle(Carbon.interactive).lineLimit(1)
                                Spacer()
                                Text(hit.date).font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                            }
                            .padding(Space.x3)
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

    private var coOccurringSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Appears alongside")
            FlexWrap(spacing: Space.x2) {
                ForEach(coOccurring, id: \.id) { co in
                    CarbonChip(text: "\(co.name) · \(co.count)")
                }
            }
        }
    }

    private func load() async {
        let id = entityID, g = group
        let (foundEntity, foundMentions, foundCoOccurring) = await Task.detached(priority: .userInitiated) {
            // Group-scoped (crosscheck, security lens): one identity can legitimately span
            // workspaces by design, but this is the first UI surface that DISPLAYS an entity's
            // aliases — an unscoped lookup would show surface forms only ever spoken in a
            // DIFFERENT workspace's private calls. Mentions/co-occurrence below are already
            // correctly SQL-scoped; this closes the one unscoped read.
            let entity = EntityRegistry.shared.entity(id: id, group: g)
            let mentions = IndexStore.shared?.callsMentioning(entityID: id, group: g) ?? []
            let co = IndexStore.shared?.coOccurring(entityID: id, group: g) ?? []
            return (entity, mentions, co)
        }.value
        entity = foundEntity
        mentions = foundMentions
        coOccurring = foundCoOccurring
        loaded = true
    }
}
