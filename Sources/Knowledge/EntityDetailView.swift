import SwiftUI
import ScriptaCore

/// One person/topic's own page (M19): canonical name + aliases + gloss (`EntityRegistry` is
/// already the trust layer — merge verdicts, privacy walls, provenance), a mention timeline
/// across calls, and who/what else co-occurs with them. Read-only, no new mutation path —
/// brain ≠ editor holds here same as everywhere else; this only displays identity data other
/// features (the registry, extraction, the correction loop) already own and write.
struct EntityDetailView: View {
    /// `@State`, not `let` (M21) — co-occurring chips retarget this same sheet in place rather
    /// than closing and reopening a new one per hop, so exploring several connections in a row
    /// doesn't chain sheet-dismiss/present animations. `group`/`onClose`/the callbacks stay fixed
    /// for the sheet's lifetime; only the entity being shown changes.
    @State private var entityID: String
    let group: String
    /// Shown until (or instead of, if it never resolves) the real registry entity loads — needed
    /// because M17's commitment-owner fallback can pass an `entityID` that's a raw surface string
    /// rather than a real registry id when nothing confirmed matched, and this view shouldn't
    /// show a blank "…" header for a name the caller already had in hand. Also `@State` for the
    /// same reason as `entityID` — a jump seeds it from data already on screen (a co-occurring
    /// chip's own name) so the header doesn't flash blank while the fresh load resolves.
    @State private var fallbackName: String? = nil
    let onClose: () -> Void
    /// Invoked after a commitment here is marked done, so the presenting view (KnowledgeView's
    /// rail) can refresh — this sheet's own `commitments` state already updates itself, but the
    /// rail's separately-loaded copy of the same rows would otherwise go stale (crosscheck).
    var onCommitmentsChanged: () -> Void
    /// Opens a mentioned note/doc (M20) — routed through the presenter since this view has no
    /// direct access to any richer note/doc surface of its own, unlike calls, which go through
    /// the global `AppModel.route`. Passed the mention's raw path. Defaults to a no-op, not an
    /// "open it somehow" fallback (crosscheck) — the hit's SQL scope reads a cached
    /// transcripts.group column that can briefly lag a hand-edited frontmatter field, and a doc
    /// hit's path is an extracted-text sidecar, not the original file, so opening it correctly
    /// needs a live-group re-check plus (for docs) resolving the real file — every presenter has
    /// to do that itself via `NoteStore.verified`/`DocumentImporter.verifiedOriginalURL`, so a
    /// convenient-looking default that skips it would be a silent trap for whichever one forgets.
    var onOpenNote: (String) -> Void
    var onOpenDoc: (String) -> Void

    /// Where `jumpTo` came from, for the back button (M21). Not `[String]` — carries each stop's
    /// `fallbackName` too, so going back can seed the header instantly the same way jumping
    /// forward does, instead of only jumping forward getting the flash-free treatment.
    @State private var history: [(id: String, fallbackName: String?)] = []
    @State private var entity: EntityRegistry.Entity?
    @State private var mentions: [SearchHit] = []
    @State private var commitments: [IndexStore.CommitmentRow] = []
    @State private var coOccurring: [(id: String, name: String, kind: String, count: Int)] = []
    @State private var loaded = false

    // Explicit init: the synthesized memberwise one would be `private` (Swift derives an init's
    // access level from its least-visible stored property, and `@State private var` storage is
    // private) — breaking the one existing call site, which is in a different file.
    init(entityID: String, group: String, fallbackName: String? = nil, onClose: @escaping () -> Void,
         onCommitmentsChanged: @escaping () -> Void = {}, onOpenNote: @escaping (String) -> Void = { _ in },
         onOpenDoc: @escaping (String) -> Void = { _ in }) {
        self._entityID = State(initialValue: entityID)
        self.group = group
        self._fallbackName = State(initialValue: fallbackName)
        self.onClose = onClose
        self.onCommitmentsChanged = onCommitmentsChanged
        self.onOpenNote = onOpenNote
        self.onOpenDoc = onOpenDoc
    }

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
                        if !commitments.isEmpty { commitmentsSection }
                        if !coOccurring.isEmpty { coOccurringSection }
                    }
                    .padding(Space.x6)
                }
            }
        }
        .frame(width: 420, height: 520)
        .background(Carbon.background)
        // Keyed on entityID (crosscheck): a plain `.task { }` runs once for the sheet's whole
        // lifetime and never re-fires on a jump/back, and `jumpTo`/`goBack` calling `load()`
        // themselves raced two in-flight loads with nothing to cancel the older one. `.task(id:)`
        // owns re-running on every entityID change so those functions don't have to.
        .task(id: entityID) { await load() }
    }

    private var displayName: String { entity?.name ?? fallbackName ?? "…" }

    private var header: some View {
        HStack(spacing: Space.x3) {
            if !history.isEmpty {
                Button(action: goBack) {
                    // No dedicated left-chevron asset — chevron-right, mirrored, matches this
                    // app's existing icon set instead of introducing a new one for one button.
                    CarbonIcon(name: "chevron-right", size: 14, color: Carbon.iconSecondary)
                        .rotationEffect(.degrees(180))
                }.buttonStyle(.plain)
            }
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
                // more honest thing to say (crosscheck). "No mentions" (not "no calls") since M20:
                // this section can now also be empty of notes/docs that mention them.
                Text(entity == nil && fallbackName != nil
                     ? "\(fallbackName!) isn't a tracked contact yet — not yet confirmed as a call participant."
                     : "No mentions yet.")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 1) {
                    ForEach(mentions) { hit in
                        Button {
                            onClose()
                            // M20: entity_mentions now spans calls/notes/docs, so the click target
                            // has to match — routing every hit to .call(...) would try to open a
                            // note/doc's path as if it were a call transcript.
                            switch hit.kind {
                            case "note": onOpenNote(hit.path)
                            case "doc": onOpenDoc(hit.path)
                            default: AppModel.shared.route = .call(URL(fileURLWithPath: hit.path), ms: hit.startMs)
                            }
                        } label: {
                            HStack {
                                Text(hit.title.isEmpty ? hit.date : hit.title)
                                    .font(CarbonFont.medium(13)).foregroundStyle(Carbon.interactive).lineLimit(1)
                                Spacer()
                                Text(hit.kind == "call" ? hit.date : "\(hit.date) · \(hit.kind)")
                                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
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

    /// What this person owes you (M17 data, filtered to this entity's own commitments — the
    /// obvious connection between M17 and M19 that wasn't made when either shipped: the rollup
    /// already exists, this page already loads by entityID+group, they just weren't wired
    /// together). Same mark-done affordance as the Commitments rail, since it's the same
    /// underlying frontmatter-backed action.
    private var commitmentsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Owes you")
            VStack(spacing: 1) {
                ForEach(commitments) { item in
                    HStack(alignment: .top, spacing: Space.x2) {
                        Button { markDone(item) } label: {
                            CarbonIcon(name: "checkmark", size: 10, color: Carbon.textHelper)
                        }.buttonStyle(.plain).help("Mark done")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text).font(CarbonFont.body(12)).foregroundStyle(Carbon.textPrimary)
                            Text(item.callTitle).font(CarbonFont.label(10)).foregroundStyle(Carbon.textHelper)
                        }
                    }
                    .padding(Space.x3)
                    .background(Carbon.layer)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
        }
    }

    /// Same frontmatter-is-source-of-truth path as KnowledgeView's markCommitmentDone — see that
    /// one's doc comment for why this can't be a DB-only status flip. `ownerID` prevents
    /// cross-resolving two people's identically-worded commitments (crosscheck); the callback
    /// lets the presenting rail refresh its own separately-loaded copy of these rows.
    private func markDone(_ item: IndexStore.CommitmentRow) {
        guard let store = IndexStore.shared else { return }
        commitments.removeAll { $0.id == item.id }
        let url = URL(fileURLWithPath: item.path)
        let text = item.text
        let g = group
        let ownerID = item.ownerID
        Task.detached(priority: .utility) {
            try? TranscriptMetadataEditor.markCommitmentDone(url: url, group: g, ownerID: ownerID, commitmentText: text)
            IndexBuilder.index(url, into: store)
            await MainActor.run { onCommitmentsChanged() }
        }
    }

    private var coOccurringSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Appears alongside")
            FlexWrap(spacing: Space.x2) {
                ForEach(coOccurring, id: \.id) { co in
                    CarbonChip(text: "\(co.name) · \(co.count)") { jumpTo(co.id, fallbackName: co.name) }
                }
            }
        }
    }

    /// Retargets this same sheet to a different entity (M21) instead of closing and reopening —
    /// see `entityID`'s doc comment for why. `fallbackName` is already on hand from the chip that
    /// was tapped, so the header shows the right name immediately instead of "…" until `load()`
    /// resolves the real entity a beat later — which only works if `entity` is ALSO cleared here
    /// (crosscheck): `displayName` reads `entity?.name ?? fallbackName`, so leaving the outgoing
    /// entity in place made the header silently keep showing the person just navigated away from,
    /// defeating the whole point of seeding `fallbackName` in the first place.
    private func jumpTo(_ id: String, fallbackName: String?) {
        history.append((entityID, self.fallbackName))
        entityID = id
        self.fallbackName = fallbackName
        resetForReload()
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        entityID = previous.id
        fallbackName = previous.fallbackName
        resetForReload()
    }

    private func resetForReload() {
        loaded = false
        entity = nil
        mentions = []
        commitments = []
        coOccurring = []
    }

    private func load() async {
        let id = entityID, g = group
        let (foundEntity, foundMentions, foundCommitments, foundCoOccurring) = await Task.detached(priority: .userInitiated) {
            // Group-scoped (crosscheck, security lens): one identity can legitimately span
            // workspaces by design, but this is the first UI surface that DISPLAYS an entity's
            // aliases — an unscoped lookup would show surface forms only ever spoken in a
            // DIFFERENT workspace's private calls. Mentions/co-occurrence below are already
            // correctly SQL-scoped; this closes the one unscoped read.
            let entity = EntityRegistry.shared.entity(id: id, group: g)
            let mentions = IndexStore.shared?.callsMentioning(entityID: id, group: g) ?? []
            // SQL-level owner filter (crosscheck): filtering client-side after commitments(group:)'s
            // workspace-wide 200-row cap already applied could silently drop this person's older
            // commitments once the workspace had enough total volume.
            let commitments = IndexStore.shared?.commitments(group: g, ownerID: id) ?? []
            let co = IndexStore.shared?.coOccurring(entityID: id, group: g) ?? []
            return (entity, mentions, commitments, co)
        }.value
        // A jump/back that landed while this call was still in flight already started its OWN
        // load for the entity now current — let that one win instead of overwriting it with
        // this now-stale result (crosscheck: race between overlapping in-flight loads).
        guard id == entityID else { return }
        entity = foundEntity
        mentions = foundMentions
        commitments = foundCommitments
        coOccurring = foundCoOccurring
        loaded = true
    }
}
