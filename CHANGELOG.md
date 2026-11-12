# Changelog

What changed in each release of Scripta, newest first. The engine has
[its own changelog](https://github.com/Ronan-Wood/substrate/blob/main/CHANGELOG.md).

## Unreleased

### Changed

- **Workspaces no longer limit what Claude reads.** Claude and other MCP clients read every
  workspace, whichever one Scripta is showing. Scripta stops writing `guard_state` into its
  workspace vaults and removes it from them at launch; a guard you added by hand stays. This
  needs engine v0.2.1 or later: an older one you run yourself withholds a workspace that still has
  the line, and its agent-mode snapshots can carry the calls of one that does not.

## 0.3.5

The first public release. It is built from a pinned release of the engine, substrate v0.1.0.

### Added

- **The engine is open source.** It now has its own repository,
  [Ronan-Wood/substrate](https://github.com/Ronan-Wood/substrate). `engine.lock` pins the release
  the app bundles. Every Scripta release attaches its own source and the engine's.
- **The engine keeps itself current.** Scripta runs it as a server that refreshes every vault on
  its own timer, so new and edited notes reach search without a manual rebuild.
- **An engine that is already running is reused.** If one is already serving on this Mac, Scripta
  uses it instead of starting a second one, writes notes only, and leaves the indexing to it.

### Changed

- **Every search index lives in the engine's folder.** Indexes in Scripta's old folder are rebuilt
  there on the first launch where Scripta runs its own engine and its embedder is reachable. The
  old files are left in place. Delete them only once the Library shows each scope in the engine's
  folder.
- **Semantic search is faster.** The engine keeps its vectors in memory between questions.
- **The connection to the engine is private.** The engine listens on a socket in a folder only
  your account can reach, and both sides check they speak the same wire version before trading
  answers. Clients set up with the old socket path keep working.

### Fixed

- **Search stays inside your filters.** When search rephrases your question, the extra searches
  stay within the vaults and people you filtered to.
- **A withheld vault stays withheld.** A passage from a vault that is withheld from you can no
  longer be opened by its link.
- **Edits to converted documents are noticed.** Editing a note made from a PDF or another document
  now updates search. Before, the change could go unseen.

## 0.1.0 to 0.3.4

These versions were built before this repository was public. Their tags are kept, but their
release pages are no longer on GitHub. Their history is in the git log.
