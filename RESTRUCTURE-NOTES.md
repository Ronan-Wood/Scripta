# Restructure notes — running log

Working notes kept during the `restructure-2026-07-18` branch. Observations only — nothing here
is applied without being picked deliberately. Fold the survivors into SPEC.md / issues at the end
and delete this file.

## Test gaps (add later, not during the structural phases)

- **`Indexing` has no test suite at all** — the chunking budgets (500 char / 45 s), speaker-change
  flush, `parseStamp` edge cases ("[1:23:45]", malformed stamps), and `screenChunks` section
  parsing are all uncovered. This is correctness-critical pure logic — ideal host-less tests.
- **`IndexStore.search` fusion is only eval-covered** — topic-fusion ordering (passage hits before
  topic-only calls), group scoping (the privacy wall!), and `people`/`tags` aggregates have no
  unit tests. The eval gates catch regressions coarsely; unit tests would localize them.
- **NUL-stripping (audit L2) has no unit test** — the control-char strip before FTS bind is only
  protected by the v12 schema-bump rebuild; a regression would reintroduce silent truncation.
- **`Frontmatter` has no dedicated suite** — exercised only indirectly via TranscriptParser tests.
  `rawValue`/`field`/`list` quoting and bracket edge cases deserve direct cases (audit L4 touched
  exactly this).
- **Schema migration path untested** — the version-bump drop-and-rebuild (v13 today) has no test
  proving an old-version DB is detected and recreated rather than half-used.
- **Phase 2 arrivals to cover when they move:** `EntityRegistry` (merge/verdict union-find-lite,
  purge cascade, collision candidates), `IndexBuilder.reconcile` (mtime add/update/remove),
  `IndexWatcher` debounce. Registry lock semantics get replaced in Phase 3 — test the behavior,
  not the lock.
- **SourcesMCP has zero tests** — tool routing, path guarding (symlink resolution), heartbeat
  refusal. Bigger lift (needs a stdio harness); worth its own line in the plan.

## Decisions parked

- **Package floor vs Phase 3 `Mutex`:** `Mutex` (Synchronization) needs macOS 15+; package floor
  is 14 (inherited from scripta-mcp). Either bump helper+package floor (26 is defensible — the
  helper refuses without the app running, and the app needs 26) or use `OSAllocatedUnfairLock`.
  Decide at Phase 3 start.
- **MCP reading via `IndexStore`:** SourcesMCP still hand-rolls read-only SQLite. Once it depends
  on ScriptaCore (not just ScriptaShared) it could reuse `IndexStore` reads — kills ~a few hundred
  duplicated lines. Phase 2 candidate; needs the read-only open mode preserved.

## Over-exposure to revisit (from the bulk `public` pass)

- The mechanical public pass (commit b4e2b2d) made every non-private func/static on the moved
  types public. After the app is rewired and compiles, run a pass to demote anything with no
  external consumer back to internal — the compiler finds the true surface. Cheap in Phase 5.
