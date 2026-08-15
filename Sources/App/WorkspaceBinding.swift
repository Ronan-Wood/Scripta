import Foundation
import ScriptaCore

/// What a workspace binds to.
///
/// ONE CONCRETE VAULT IS THE HOME; THE REST ARE CONTEXT. Calls are written into this workspace's own
/// vault and nowhere else — that directory is the source. Everything else the scope answers from is
/// pulled in through the manifest's `inherits`, read-only, for context. Operator, 2026-08-07: "when
/// a call gets recorded there should be a concrete vault it goes to and that is the source, the
/// others are just to pull context from."
///
/// That was already the shape on disk after §7 and the app did not say so: the destination shown in
/// the Library was the retired local export path, `writesScope` described a split that no longer
/// exists, and nothing populated `inherits`, so no context was ever pulled.
///
/// Doc 3 §7: "a workspace declares one vault scope it reads, one transcript scope it writes, and
/// the calendars that route into it. It stops being a container that holds calls."
///
/// ```
/// workspace "CBRE"
///   reads    scope cbre           vault notes, OneDrive, read-only
///   writes   scope scripta-cbre   calls and ingested documents, local, non-synced
///   routes   calendars [...]  ->  tag group: CBRE at record time
/// ```
///
/// THE ENGINE IS THE AUTHORITY ON WHAT SCOPES EXIST, and this type never asserts otherwise. It
/// stores a NAME the operator chose; whether that name still resolves is `SubstrateScopes`' answer,
/// re-asked every time the roster is listed. A binding whose scope the engine no longer lists is a
/// stale binding to be REPORTED, never one to repair by quietly picking another — which is exactly
/// the auto-adoption §7 removes.
///
/// THE READ/WRITE ASYMMETRY IS LOAD-BEARING AND MUST NOT BE COLLAPSED. Reads point at a vault scope
/// in OneDrive; writes point at a transcript scope that is local and non-synced. Doc 3 §7 names the
/// failure of tidying this into "a workspace is just a scope": it pushes call transcripts, the most
/// sensitive content the app holds, into cloud sync. That is why `readsScope` is stored and
/// `writesScope` is derived — they are not two of the same kind of thing.
struct WorkspaceBinding: Equatable {
    /// The app's own partition: the `group:` written into transcript frontmatter at record time.
    let workspace: String

    /// The scope this workspace reads.
    ///
    /// ITS OWN VAULT, BY DEFAULT — which is what §7 changed. A workspace IS a vault now: capture
    /// writes every call into `<output>/<slug>/`, that directory carries a manifest naming the
    /// scope, and composing it yields this workspace's calls plus whatever it inherits. So "which
    /// scope does this workspace read" has an obvious answer the app was making the operator supply
    /// by hand — and until they did, every vault surface reported itself unbound while the calls
    /// sat composable on disk.
    ///
    /// It stays OPTIONAL for the one case with no answer: a workspace whose name slugifies to
    /// nothing cannot name a vault. Ask used to take "the first scope with an index", which made
    /// "which corpus am I asking" a question about roster order — that is what this must never do,
    /// and defaulting to the workspace's OWN vault is the opposite of it.
    ///
    /// An explicit binding still wins: pointing a workspace at a different scope is a real thing to
    /// want, and the stored value is what expresses it.
    let readsScope: String?

    /// Where this workspace's calls are written — the ONE concrete vault that is their home.
    ///
    /// It used to point at a local, non-synced tree that an export step filled. Capture writes here
    /// directly now (§7), and the two had come apart: the Library screen advertised the old path
    /// while every call went to the new one, which is a surface naming the wrong place to look for
    /// the most important file the app produces.
    ///
    /// `nil` for a workspace that cannot name a vault, which is the same case `readsScope` has no
    /// default for.
    var transcriptVault: URL? {
        try? ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder).transcripts
    }

    /// The vault directory of the bound scope, for the workspace vault's `inherits` (Doc 4 §8).
    ///
    /// THIS IS WHAT MAKES A WORKSPACE VAULT CONTAIN THE WORKSPACE. Without it the app writes a vault
    /// holding only calls, declaring `inherits = []` — and composing it would both omit the curated
    /// notes and collide with the registered scope of the same name, which `scopes.record` refuses.
    /// The collision is what surfaced this: a workspace vault takes the scope's NAME, so it must
    /// also take on what that scope was composing.
    /// Every vault this workspace pulls context from, for the manifest's `inherits`.
    ///
    /// THE OPERATOR'S CHOICE FIRST, the bound scope's vault as the fallback. Before Settings could
    /// express this, the only way a workspace inherited anything was as a side effect of picking a
    /// scope in Ask — which bound exactly one, and left the operator hand-editing TOML to add a
    /// second.
    var contextVaults: [URL] {
        let chosen = AppSettings.workspaceContextVaults[workspace] ?? []
        if !chosen.isEmpty {
            return chosen.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return inheritsVault.map { [$0] } ?? []
    }

    var inheritsVault: URL? {
        AppSettings.workspaceReadVaults[workspace]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var isBound: Bool { readsScope != nil }
}

/// The bindings, stored. A thin namespace rather than a type with state: the values live in
/// `AppSettings` beside `calendarGroups`, which is already the sole authority on which workspace an
/// artefact belongs to.
enum WorkspaceBindings {
    /// The binding for one workspace.
    ///
    /// STORED FIRST, OWN VAULT SECOND. An explicit binding is the operator pointing this workspace
    /// somewhere deliberate; the default is the vault its own calls are written into, which is the
    /// answer whenever they have not said otherwise.
    static func binding(for workspace: String) -> WorkspaceBinding {
        let stored = AppSettings.workspaceReadScopes[workspace].flatMap { $0.isEmpty ? nil : $0 }
        let own = ScriptaVault.slug(workspace)
        return WorkspaceBinding(workspace: workspace,
                                readsScope: stored ?? (own.isEmpty ? nil : own))
    }

    /// The active workspace's binding — what Ask is asking.
    static var active: WorkspaceBinding { binding(for: AppSettings.activeGroup) }

    /// Bind a workspace to a vault scope, or pass `nil` to unbind it.
    ///
    /// The scope is not validated here. `SubstrateScopes` holds the roster and is re-asked on every
    /// listing, so validating at write time would only move the check to the one moment it cannot
    /// be kept true — a scope can stop resolving after it is bound, and that has to surface as a
    /// stale binding rather than have been prevented at a moment that has passed.
    /// `vault` is the bound scope's vault directory, from `WireScopeRow.vault`. Stored beside the
    /// name because capture needs it off the main actor — see `AppSettings.workspaceReadVaults`.
    /// Passing `nil` for it binds the name without the path, which leaves the workspace vault
    /// inheriting nothing: correct only when the caller genuinely does not know the path.
    static func bind(_ workspace: String, reads scope: String?, vault: String? = nil) {
        var scopes = AppSettings.workspaceReadScopes
        var vaults = AppSettings.workspaceReadVaults
        if let scope, !scope.isEmpty {
            scopes[workspace] = scope
            if let vault, !vault.isEmpty { vaults[workspace] = vault } else { vaults.removeValue(forKey: workspace) }
        } else {
            scopes.removeValue(forKey: workspace)
            vaults.removeValue(forKey: workspace)
        }
        AppSettings.workspaceReadScopes = scopes
        AppSettings.workspaceReadVaults = vaults
    }

    /// Drop a workspace's binding entirely — for `WorkspaceDeleter`, which wipes a workspace.
    ///
    /// ALL THREE STORES, and it used to clear two. `bind(reads: nil)` covers `workspaceReadScopes`
    /// and `workspaceReadVaults`; `workspaceContextVaults` is the operator's explicit choice and is
    /// the one `contextVaults` consults FIRST, so leaving it behind left a wiped workspace's list of
    /// private vault paths sitting in plaintext defaults — exactly the residue the wipe exists to
    /// remove.
    ///
    /// It became reachable rather than merely untidy when "New workspace…" started writing the vault
    /// (Doc 5): retyping a wiped workspace's name found the surviving paths, wrote them into the new
    /// `.substrate.toml` as `inherits`, and the engine composed the wiped workspace's private context
    /// into the new scope — before a single call had been recorded into it.
    static func forget(_ workspace: String) {
        bind(workspace, reads: nil)
        var chosen = AppSettings.workspaceContextVaults
        chosen.removeValue(forKey: workspace)
        AppSettings.workspaceContextVaults = chosen
    }
}
