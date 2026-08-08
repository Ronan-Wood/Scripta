# Releasing — dual-channel runbook

Two flavors from one codebase (see `project.yml` targets):

| | `Scripta` (direct .dmg) | `Scripta-MAS` (App Store) |
|---|---|---|
| Sandbox | Yes | Yes |
| Bundled MCP helper | Retired 2026-08-07 — the engine's own server replaced it (Doc 4 Phase 3) | — |
| Signing | Developer ID Application + notarization | Apple Distribution via ASC |
| Build output | `build/<config>/` (SYMROOT=build) | archive → `build/mas.xcarchive`; local builds `build-mas/<config>/` (SYMROOT=build-mas) |

The Docs pane registers the substrate ENGINE for Claude; the app ships no MCP server of its own.

## Step 0 — one-time account setup (blocks everything below)

1. Enroll: developer.apple.com → Apple Developer Program, $99/yr, individual
   (convertible to an organization later without losing the app).
2. Xcode → Settings → Accounts → team `6CTH5M9UWZ` now shows the paid membership.
   Certificates to create (Xcode does it on first archive, or ASC → Certificates):
   - **Apple Distribution** (MAS uploads)
   - **Developer ID Application** (direct .dmg)
3. App Store Connect: accept agreements, create the app record
   (see `app-store-listing.md`, including the bundle-ID-is-forever warning).
4. Generate an App Store Connect API key or app-specific password for `notarytool`:
   `xcrun notarytool store-credentials notary --apple-id <id> --team-id 6CTH5M9UWZ`

## Channel A — App Store

```sh
xcodegen generate
xcodebuild -project Scripta.xcodeproj -scheme Scripta-MAS archive \
  -archivePath build/mas.xcarchive
# then Xcode Organizer (or altool/Transporter): Distribute App → App Store Connect

# local flavor-check build only (the archive above doesn't need SYMROOT):
xcodebuild -project Scripta.xcodeproj -scheme Scripta-MAS -configuration Release build SYMROOT="$(pwd)/build-mas"
```

- TestFlight the build yourself before submitting (needs the sandbox — which we have).
- Submission collateral is all in `app-store-listing.md`; policy must be hosted first.
- First submission of a recording app may get a slower review — the review notes in the
  listing doc pre-answer the likely questions.

## Channel B — direct .dmg

```sh
rm -rf build/Release   # fail fast on a dropped SYMROOT instead of staging a stale binary
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Release build SYMROOT="$(pwd)/build"
# sign check: hardened runtime + sandbox + Developer ID identity
codesign -dv --verbose=2 build/Release/Scripta.app
# stage dmg (app + /Applications symlink + README), then:
hdiutil create -volname "Scripta" -srcfolder <stage> -ov -format UDZO dist/Scripta.dmg
xcrun notarytool submit dist/Scripta.dmg --keychain-profile notary --wait
xcrun stapler staple dist/Scripta.dmg
```

Existing users on the old personal-cert build: TCC re-grants once (signing identity
changes), and the first sandboxed launch shows the folder-choice notice — expected.

## The helper: retired 2026-08-07

There is no separate helper to ship. `scripta-mcp` answered call questions from the app's own
index; Doc 4 §7 moved calls into vaults the substrate engine composes, and Phase 3 deleted the
second server rather than keep two answering the same questions differently. What replaced it:

- **Reads** — the engine's own MCP server, over the same tools every other scope uses.
- **The privacy wall it enforced** — `substrate/guard.py`. A workspace vault declares
  `guard_state`, and the engine withholds that vault's own notes unless the app is running and
  vouching for that workspace. Narrower than the helper's, which refused the whole scope: the
  tiers a workspace inherits keep answering.
- **The four entity tools** (`people`, `tags`, `commitments`, `entity_detail`) — dropped, by
  decision. They were backed by `confirmed` and `groups`, which the engine's identity layer
  deliberately does not carry. The entity surfaces remain in the app; they are no longer reachable
  by a model client.

Packaging still to do (post-rename, since names are user-visible):
- **Claude Code plugin** — repo with the skill; MCP registration now points at the engine.
- Update the Docs pane's App Store branch with the real download link (placeholder today).

## Rename — DONE 2026-07-16 (Call Transcriber → Scripta)

Executed across code, config, docs, skill, and MCP registrations. Bundle ID is
`com.ronanwood.Scripta` (still only truly locked at first upload). Deliberately NOT renamed
(they name on-disk data, not the brand): the `app: call-transcriber` frontmatter marker,
`.calltranscriber-registry.json`, the entity-mirror markers, and the App Group ID
`6CTH5M9UWZ.com.ronanwood.calltranscriber`. Repo folder still `~/CodeHome/CallTranscriber`
(rename any time; nothing depends on it). Remaining name-bearing work: the plugin/`.mcpb`
repo names when packaging, and confirming the exact name in ASC at record creation.

## Hosting the privacy policy

Any static host. Cheapest: a public GitHub repo (can be just the policy, not the app
source) → Settings → Pages → the markdown renders at
`https://<user>.github.io/<repo>/privacy-policy`. Paste that URL into ASC.
