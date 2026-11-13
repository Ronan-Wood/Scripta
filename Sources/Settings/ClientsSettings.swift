import SwiftUI

/// Settings → Clients: which MCP clients (Claude Code, Claude desktop, Zed…) may write notes into
/// the vaults through the engine this app runs.
///
/// The engine decides every write (`--writes=granted`) and owns the grants. This pane lists them
/// with `substrate grants --json` and changes them with `substrate grant` and `substrate revoke`, the
/// same commands a terminal runs. A client that tried to write without a grant is refused by the
/// engine, which tells the model to send the user here, and appears under Requested.
@MainActor
final class ClientsModel: ObservableObject {
    enum State: Equatable {
        case unasked
        case listing
        case listed(EngineGrants)
        /// The engine's CLI did not answer with a listing; the sentence says why.
        case unavailable(String)
        /// There is no engine this app is using to ask. No sentence is stored: the view draws
        /// `noEngineSentence` from the live lifecycle, so it cannot go stale as the engine moves.
        case noEngine
    }

    @Published private(set) var state: State = .unasked
    @Published private(set) var working = false
    @Published var failure: String?

    /// Bumped by every `refresh`, so a reply that arrives after a newer refresh began is dropped
    /// rather than overwriting what that one found.
    private var generation = 0

    func refresh() async {
        generation += 1
        let mine = generation
        guard let cli = SubstrateEngine.shared.serving?.cli else {
            state = .noEngine
            return
        }
        if case .unasked = state { state = .listing }
        let run = await SubstrateCLI.run(cli, ["grants", "--json"])
        guard mine == generation else { return }
        if run.succeeded, let listing = EngineGrants.parse(run.stdout) {
            state = .listed(listing)
        } else {
            state = .unavailable("This engine did not list its clients (`\(run.line)`). An engine "
                                 + "older than v0.2.0 has none.")
        }
    }

    /// Why there is no engine to list clients from, in the engine's own terms. "Not running" is said
    /// only when none is: an engine on the socket that this app will not use is named, with the
    /// remedy for that kind (`Occupant.finding`/`remedy`), and one coming up is said to be.
    static func noEngineSentence(_ lifecycle: SubstrateEngine.Lifecycle) -> String {
        switch lifecycle {
        case .socketBusy(_, let occupant):
            return "\(occupant.finding) The engine's clients cannot be listed here until Scripta is "
                + "using an engine. \(occupant.remedy)."
        case .starting:
            return "The engine is starting. Its clients are listed once it answers."
        case .serving:
            // Serving, and still here: the source carries no CLI to run `grants` with.
            return "The engine is running, but Scripta found no `substrate` command beside it, so "
                + "its clients cannot be listed."
        case .idle, .notInstalled, .failed:
            return "The engine is not running, so its clients cannot be listed."
        }
    }

    /// The same path as Ask's "Start the engine": discovery and the socket check run again, so this
    /// also covers "I quit the engine that was in the way".
    func startEngine() async {
        SubstrateEngine.shared.restart()
        await refresh()
    }

    func allow(_ client: String) async { await change(["grant", client]) }

    /// Revoke and Deny are one command: the engine removes the grant and forgets that it asked.
    func revoke(_ client: String) async { await change(["revoke", client]) }

    private func change(_ arguments: [String]) async {
        guard let cli = SubstrateEngine.shared.serving?.cli else { return }
        working = true
        let run = await SubstrateCLI.run(cli, arguments)
        working = false
        if !run.succeeded {
            failure = run.transcript.isEmpty ? "`\(run.line)` failed." : run.transcript
        }
        await refresh()
    }
}

struct ClientsSettings: View {
    @StateObject private var model = ClientsModel()
    @ObservedObject private var engine = SubstrateEngine.shared
    @State private var newClient = ""

    var body: some View {
        Section {
            switch model.state {
            case .unasked, .listing:
                Text("Asking the engine…").font(.caption).foregroundStyle(.secondary)
            case .unavailable(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
            case .noEngine:
                Text(ClientsModel.noEngineSentence(engine.lifecycle))
                    .font(.caption).foregroundStyle(.secondary)
                // Not while one is starting, and not for an engine that serves without a CLI:
                // restarting a healthy engine cannot supply the missing command.
                switch engine.lifecycle {
                case .starting, .serving: EmptyView()
                default:
                    Button(engine.lifecycle.retryTitle) { Task { await model.startEngine() } }
                }
            case .listed(let listing):
                if listing.requested.isEmpty {
                    Text("No client is waiting.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(listing.requested) { request in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(request.client)
                            Text("asked \(request.at)"
                                 + (request.clientInfo?.version.map { " · version \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Deny") { Task { await model.revoke(request.client) } }
                        Button("Allow") { Task { await model.allow(request.client) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(model.working)
                }
            }
        } header: {
            Text("Requested")
        }

        Section {
            if case .listed(let listing) = model.state {
                if listing.granted.isEmpty {
                    Text("No client can write.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(listing.granted) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(grant.client)
                            Text((grant.scopes == ["*"] ? "every scope"
                                  : grant.scopes.joined(separator: ", "))
                                 + " · since \(grant.issuedAt)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { Task { await model.revoke(grant.client) } }
                    }
                    .disabled(model.working)
                }
            }
            HStack {
                TextField("Client name, e.g. claude-code", text: $newClient)
                Button("Allow") {
                    let name = newClient.trimmingCharacters(in: .whitespaces)
                    Task { await model.allow(name); newClient = "" }
                }
                .disabled(model.working || !EngineGrants.isClientName(
                    newClient.trimmingCharacters(in: .whitespaces)))
            }
        } header: {
            Text("Can write")
        } footer: {
            Text("A client here can add and change notes in your project vaults, never the shared core vault, and each note it writes names it (`written_by`). Every write is still shown to you as a plan first. A grant is consent, not a lock: any app running as you could read its token or claim its name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await model.refresh() }
        // Listed again when the engine comes up or goes. The no-engine sentence needs no refresh: it
        // is drawn from the live lifecycle.
        .onChange(of: engine.lifecycle.isServing) { _, _ in Task { await model.refresh() } }
        .alert("The engine refused", isPresented: .init(
            get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }
}
