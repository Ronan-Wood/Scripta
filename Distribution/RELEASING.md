# Releasing — dual-channel runbook

Two flavors from one codebase (see `project.yml` targets):

| | `Scripta` (direct .dmg) | `Scripta-MAS` (App Store) |
|---|---|---|
| Sandbox | Yes | Yes |
| Bundled MCP helper | Yes (`Contents/MacOS/scripta-mcp`) | **No** — separate download |
| Signing | Developer ID Application + notarization | Apple Distribution via ASC |
| Build output | `build/<config>/` | `build/<config>-mas/` |

Docs pane auto-detects the flavor (`helperIsBundled`) and shows the right Claude setup.

## Step 0 — one-time account setup (blocks everything below)

1. Enroll: developer.apple.com → Apple Developer Program, $99/yr, individual
   (convertible to an organization later without losing the app).
2. Xcode → Settings → Accounts → team `6CTH5M9UWZ` now shows the paid membership.
   Certificates to create (Xcode does it on first archive, or ASC → Certificates):
   - **Apple Distribution** (MAS uploads)
   - **Developer ID Application** (direct .dmg + the helper)
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
```

- TestFlight the build yourself before submitting (needs the sandbox — which we have).
- Submission collateral is all in `app-store-listing.md`; policy must be hosted first.
- First submission of a recording app may get a slower review — the review notes in the
  listing doc pre-answer the likely questions.

## Channel B — direct .dmg

```sh
xcodebuild -project Scripta.xcodeproj -target Scripta -configuration Release build
# sign check: hardened runtime + sandbox + Developer ID identity
codesign -dv --verbose=2 build/Release/Scripta.app
# stage dmg (app + /Applications symlink + README), then:
hdiutil create -volname "Scripta" -srcfolder <stage> -ov -format UDZO dist/Scripta.dmg
xcrun notarytool submit dist/Scripta.dmg --keychain-profile notary --wait
xcrun stapler staple dist/Scripta.dmg
```

Existing users on the old personal-cert build: TCC re-grants once (signing identity
changes), and the first sandboxed launch shows the folder-choice notice — expected.

## The helper (App Store users' separate download)

```sh
xcodebuild -project Scripta.xcodeproj -target scripta-mcp -configuration Release build
codesign --force --options runtime --entitlements SourcesMCP/scripta-mcp.entitlements \
  -s "Developer ID Application" build/Release/scripta-mcp
ditto -c -k build/Release/scripta-mcp scripta-mcp.zip
xcrun notarytool submit scripta-mcp.zip --keychain-profile notary --wait
# bare binaries can't be stapled — Gatekeeper verifies the notarization online
```

Publish via GitHub Release. Packaging (post-rename, since names are user-visible):
- **Claude Code plugin** — repo with the skill + MCP registration; one `/plugin` install.
- **`.mcpb` bundle** — binary embedded, double-click installs into Claude Desktop.
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
