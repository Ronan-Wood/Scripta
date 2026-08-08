import SubstrateKit
import SwiftUI

/// Which notes in the workspace's VAULT mention this person — the half of an entity page the local
/// registry has never been able to show.
///
/// THE LOCAL RAILS KNOW ABOUT CALLS AND UPLOADS; THIS KNOWS ABOUT THE CORPUS. `EntityRegistry` and
/// `entity_mentions` are built from what this app indexed — its own calls and the documents dropped
/// into it. The composed scope is that plus every curated note the workspace inherits, and a person
/// who appears in six project notes and one call was, until now, a person with one appearance.
///
/// IT IS ADDITIVE, NOT A REPLACEMENT, and that is a decision rather than a staging step. The
/// registry stays the system of record: it holds the merge verdicts, the confirmed flag and the
/// per-workspace scoping, and it has to keep working with the engine down — `recognitionVocab` runs
/// at the moment a recording starts, and a call that could not be recorded because a subprocess was
/// not up would be the worst trade this project could make.
struct EntityVaultNotes: View {
    let entityID: String

    @State private var lookup: Lookup = .idle

    /// Named `Lookup`, not `State`: an enum called `State` inside a `View` shadows the `@State`
    /// attribute and the compiler reports it as a wrong-attribute error rather than a collision.
    enum Lookup {
        case idle
        case loading
        /// The scope declares no roster, so it cannot resolve anyone. NOT "nobody was mentioned".
        case noRoster
        case listed([VaultDocument])
        case refused(VaultRefusal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            SectionHeader(title: "In your vault")
            content
        }
        .task(id: entityID) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch lookup {
        case .idle, .loading:
            Text("Asking the vault…")
                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
        case .noRoster:
            // NAMED, not blank. A workspace whose vault declares no identity roster cannot resolve
            // anyone, and an empty list here would read as "this person appears in nothing".
            Text("This workspace's vault does not resolve people yet, so it cannot say which notes "
                 + "mention them. The calls above are what the app indexed itself.")
                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
                .fixedSize(horizontal: false, vertical: true)
        case .refused(let refusal):
            VaultRefusalCard(refusal: refusal, retryTitle: nil, retry: nil)
        case .listed(let documents):
            if documents.isEmpty {
                Text("No notes in the vault mention them.")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
            } else {
                ForEach(documents) { document in
                    HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                        Text(document.title ?? document.id)
                            .font(CarbonFont.label(12)).foregroundStyle(Carbon.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: Space.x2)
                        // WHICH TIER it came from. "my note" and "a note I share with every
                        // project" are different answers to "where does this person appear", and
                        // the vault name is the only thing that distinguishes them.
                        if !document.vault.isEmpty {
                            Text(document.vault)
                                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let scope = WorkspaceBindings.active.readsScope else { lookup = .noRoster; return }
        lookup = .loading
        // `includeSources: true` — a person's calls are conversation-class, and this list would
        // otherwise omit exactly the documents this app produced.
        let request = SubstrateDocumentsRequest(scope: scope, entity: entityID,
                                                includeSources: true, limit: 50)
        switch await SubstrateClient().documents(request) {
        case .ok(let payload):
            do { lookup = .listed(try payload.mappedDocuments()) }
            catch { lookup = .refused(.vocabulary("\(error)")) }
        case .toolFault(let text):
            lookup = .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            lookup = .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            guard !failure.isCancellation else { return }
            lookup = .refused(.of(failure))
        }
    }
}
