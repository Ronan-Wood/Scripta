## What this changes

<!-- What is true after this PR that wasn't before, and why. Link the issue it closes. -->

## Engine

<!-- Delete the lines that don't apply. -->
- No change to the engine pin or to what the app expects from the engine.
- **Moves the pin** to substrate `vX.Y.Z` with `Distribution/fetch-engine --bump`, and changes `SubstrateKit` as the new contract needs.

## Tests

- [ ] `cd Core && swift test` exits 0. Counts: <!-- SubstrateKitTests: N, ScriptaCoreTests: N -->
- [ ] A fix has a regression test, and I watched it fail with the fix reverted.
- [ ] A change under `Sources/` was built and run in the app. <!-- What you checked, by hand. -->
- [ ] Fixtures, screenshots, examples and docs use only made-up data.
- [ ] A change a user would notice has a line under **Unreleased** in `CHANGELOG.md`.

## Known follow-ups

<!-- Anything this PR deliberately leaves for later. -->
