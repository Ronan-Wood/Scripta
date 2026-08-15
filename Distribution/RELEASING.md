# Releasing — direct .dmg

**One channel.** `Scripta-MAS` was retired 2026-08-14 (Doc 5) and the App Store route with it. The
app has been UNSANDBOXED since Doc 3 §1 (2026-07-30) — it spawns the substrate engine as a
subprocess, which a sandboxed app cannot do — so it was unsubmittable long before the target went.

| | `Scripta` |
|---|---|
| Sandbox | **No** — and that is what closed the App Store |
| Configuration to ship | **`Distribution`** — NOT `Release` (see below) |
| Signing | Developer ID Application + notarization |
| Bundled engine | ~1.4 GB under `Contents/Resources/substrate-engine`, 366 nested Mach-O signed by the build phase |
| Build output | `build/Distribution/` (SYMROOT=build) |

**`Release` is a local build and must never ship.** It signs with whatever automatic signing
resolves — an *Apple Development* certificate — and Xcode gives the app bundle
`--timestamp=none`. Both are rejected at notarization. `Distribution` exists to state the identity
and add `OTHER_CODE_SIGN_FLAGS: --timestamp`; it is the only configuration that produces a
submittable artifact. This distinction is the whole reason the config exists, and this runbook
previously told you to build `Release` — which is how a decision that reached `project.yml` failed
to reach the document a human follows.

## Step 0 — one-time account setup (blocks everything below)

1. Enroll: developer.apple.com → Apple Developer Program, $99/yr, individual.
2. Xcode → Settings → Accounts → team `6CTH5M9UWZ`. One certificate is needed:
   **Developer ID Application**. (Apple Distribution is no longer required — no MAS channel.)
3. Credentials for `notarytool`:
   `xcrun notarytool store-credentials notary --apple-id <id> --team-id 6CTH5M9UWZ`

## Build, sign, notarize

```sh
xcodegen generate
rm -rf build/Distribution   # fail fast on a dropped SYMROOT rather than staging a stale binary
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Distribution build \
  SYMROOT="$(pwd)/build"

# The app's OWN signature: Developer ID, hardened runtime, and a secure timestamp — all three.
# CHECKED SEPARATELY AND ASSERTED, because one `grep -E` with alternations exits 0 on any single
# match: a build missing the timestamp (the exact defect `Distribution` exists to fix) printed two
# lines of three and passed. Each line below fails on its own.
sig=$(codesign -dv --verbose=2 build/Distribution/Scripta.app 2>&1)
grep -q 'Authority=Developer ID Application' <<<"$sig" || { echo "NOT Developer ID"; exit 1; }
grep -q 'flags=[^ ]*runtime'                 <<<"$sig" || { echo "NO hardened runtime"; exit 1; }
grep -q 'Timestamp='                         <<<"$sig" || { echo "NO secure timestamp"; exit 1; }

# The seal, and then the nested code the seal does NOT vouch for. `--verify --strict` validates the
# CodeResources hashes; it does not check that the 366 Mach-O under Resources are themselves signed
# with the hardened runtime, so a bundle of correctly-hashed UNSIGNED binaries passes it. The build
# phase already asserts that per binary and refuses to finish otherwise — this re-checks the
# shipped artifact, which is the thing being uploaded.
codesign --verify --strict --verbose=2 build/Distribution/Scripta.app
codesign --verify --deep --strict build/Distribution/Scripta.app

# stage dmg (app + /Applications symlink + README), then:
mkdir -p dist
hdiutil create -volname "Scripta" -srcfolder <stage> -ov -format UDZO dist/Scripta.dmg
xcrun notarytool submit dist/Scripta.dmg --keychain-profile notary --wait
xcrun stapler staple dist/Scripta.dmg
```

**Expect notarization to be the slow, uncertain step.** Nobody has run it against this bundle yet:
1.4 GB with 366 nested binaries is well outside the usual shape, and it is the one part of the
packaging plan with no evidence behind it. The nested binaries are signed and timestamped by the
build phase (`substrate/tools/build-bundled-engine`), which also verifies every one carries a valid
signature and the hardened-runtime flag before it will finish — so a failure here should be about
the submission, not the contents.

Existing users on the old personal-cert build: TCC re-grants once, because the signing identity
changes.

## The helper: retired 2026-08-07

There is no separate helper to ship. `scripta-mcp` answered call questions from the app's own index;
Doc 4 §7 moved calls into vaults the substrate engine composes, and Phase 3 deleted the second
server rather than keep two answering the same questions differently. What replaced it:

- **Reads** — the engine's own MCP server, over the same tools every other scope uses.
- **The privacy wall it enforced** — `substrate/guard.py`. A workspace vault declares `guard_state`
  and the engine withholds that vault's own notes unless the app is running and vouching for it.
  Narrower than the helper's, which refused the whole scope. **Currently inert:** no vault on this
  machine declares `guard_state`, so the wall is off in practice.
- **The four entity tools** (`people`, `tags`, `commitments`, `entity_detail`) — dropped by
  decision. The entity surfaces remain in the app; they are no longer reachable by a model client.

Still to do: the **Claude Code plugin** repo (skill + MCP registration pointing at the bundled
engine, `Contents/Resources/substrate-engine/bin/substrate-mcp`), and the Docs pane's download link.

`app-store-listing.md` beside this file is collateral for the retired channel. It is kept as a
record, not as a task.

## Rename — DONE 2026-07-16 (Call Transcriber → Scripta)

Executed across code, config, docs, skill, and MCP registrations. Bundle ID is
`com.ronanwood.Scripta`. Deliberately NOT renamed (they name on-disk data, not the brand): the
`app: call-transcriber` frontmatter marker, `.calltranscriber-registry.json`, the entity-mirror
markers, and the App Group ID `6CTH5M9UWZ.com.ronanwood.calltranscriber`. Repo folder is still
`~/CodeHome/CallTranscriber` (rename any time; nothing depends on it).

## Hosting the privacy policy

Any static host. Cheapest: a public GitHub repo → Settings → Pages → the markdown renders at
`https://<user>.github.io/<repo>/privacy-policy`.
