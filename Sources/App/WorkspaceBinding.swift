import Foundation

/// What a workspace binds to: one vault scope it READS, one transcript scope it WRITES.
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

    /// The vault scope this workspace reads, or `nil` when the operator has not bound one.
    ///
    /// OPTIONAL BECAUSE UNBOUND IS A REAL STATE, not a gap to fill with a default. Ask used to take
    /// "the first scope with an index", which made "which corpus am I asking" a question about
    /// roster order — so a workspace called Personal read whichever vault the engine happened to
    /// list first, and its silence about a topic read as a fact about that workspace.
    let readsScope: String?

    /// `scripta-<slug>` — `transcript_export.scope_name`, which is what the ENGINE writes into the
    /// manifest it composes. Derived rather than stored so it cannot drift from the vault path
    /// below; the two coming apart is the bug fixed in `SubstrateLibraryModel` (bc950f1).
    ///
    /// A PREDICTION UNTIL AN EXPORT HAS RUN. `scopes.record` refuses to repoint an existing name at
    /// a different vault, so the registered name is the engine's answer and not this app's to
    /// assert. Callers that need the REGISTERED name read it off the engine; this is what to show
    /// before one exists.
    var writesScope: String? {
        let slug = SubstrateLibrary.slug(workspace)
        return slug.isEmpty ? nil : "scripta-\(slug)"
    }

    /// Where this workspace's exported transcripts live. Local and non-synced by construction, and
    /// the engine's `assert_not_synced` refuses the destination before writing a byte if it ever
    /// stops being.
    var transcriptVault: URL { SubstrateLibrary.transcriptVault(workspace: workspace) }

    /// The vault directory of the bound scope, for the workspace vault's `inherits` (Doc 4 §8).
    ///
    /// THIS IS WHAT MAKES A WORKSPACE VAULT CONTAIN THE WORKSPACE. Without it the app writes a vault
    /// holding only calls, declaring `inherits = []` — and composing it would both omit the curated
    /// notes and collide with the registered scope of the same name, which `scopes.record` refuses.
    /// The collision is what surfaced this: a workspace vault takes the scope's NAME, so it must
    /// also take on what that scope was composing.
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
    /// The binding for one workspace, bound or not.
    static func binding(for workspace: String) -> WorkspaceBinding {
        WorkspaceBinding(workspace: workspace,
                         readsScope: AppSettings.workspaceReadScopes[workspace].flatMap {
                             $0.isEmpty ? nil : $0
                         })
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
    static func forget(_ workspace: String) { bind(workspace, reads: nil) }
}
