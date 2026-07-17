# Releasing — dual-channel runbook

Two flavors from one codebase (see `project.yml` targets):

| | `CallTranscriber` (direct .dmg) | `CallTranscriber-MAS` (App Store) |
|---|---|---|
| Sandbox | Yes | Yes |
| Bundled MCP helper | Yes (`Contents/MacOS/calltranscriber-mcp`) | **No** — separate download |
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
xcodebuild -project CallTranscriber.xcodeproj -scheme CallTranscriber-MAS archive \
  -archivePath build/mas.xcarchive
# then Xcode Organizer (or altool/Transporter): Distribute App → App Store Connect
```

- TestFlight the build yourself before submitting (needs the sandbox — which we have).
- Submission collateral is all in `app-store-listing.md`; policy must be hosted first.
- First submission of a recording app may get a slower review — the review notes in the
  listing doc pre-answer the likely questions.

## Channel B — direct .dmg

```sh
xcodebuild -project CallTranscriber.xcodeproj -target CallTranscriber -configuration Release build
# sign check: hardened runtime + sandbox + Developer ID identity
codesign -dv --verbose=2 build/Release/CallTranscriber.app
# stage dmg (app + /Applications symlink + README), then:
hdiutil create -volname "Call Transcriber" -srcfolder <stage> -ov -format UDZO dist/CallTranscriber.dmg
xcrun notarytool submit dist/CallTranscriber.dmg --keychain-profile notary --wait
xcrun stapler staple dist/CallTranscriber.dmg
```

Existing users on the old personal-cert build: TCC re-grants once (signing identity
changes), and the first sandboxed launch shows the folder-choice notice — expected.

## The helper (App Store users' separate download)

```sh
xcodebuild -project CallTranscriber.xcodeproj -target calltranscriber-mcp -configuration Release build
codesign --force --options runtime --entitlements SourcesMCP/calltranscriber-mcp.entitlements \
  -s "Developer ID Application" build/Release/calltranscriber-mcp
ditto -c -k build/Release/calltranscriber-mcp calltranscriber-mcp.zip
xcrun notarytool submit calltranscriber-mcp.zip --keychain-profile notary --wait
# bare binaries can't be stapled — Gatekeeper verifies the notarization online
```

Publish via GitHub Release. Packaging (post-rename, since names are user-visible):
- **Claude Code plugin** — repo with the skill + MCP registration; one `/plugin` install.
- **`.mcpb` bundle** — binary embedded, double-click installs into Claude Desktop.
- Update the Docs pane's App Store branch with the real download link (placeholder today).

## Rename checklist (do BEFORE first store upload)

- [ ] Decide the final **bundle ID** — permanent after first upload. If it changes from
      `com.ronanwood.CallTranscriber`: users' TCC grants + container reset once; the App
      Group ID stays `6CTH5M9UWZ.com.ronanwood.calltranscriber` (deliberately brand-neutral,
      do NOT rename it).
- [ ] `project.yml`: `CFBundleDisplayName`, usage-description strings, `PRODUCT_NAME`s
- [ ] First-run dialog + Docs pane copy (`AppDelegate.swift`, `HelpView.swift`)
- [ ] `Distribution/privacy-policy.md` + `app-store-listing.md` (find/replace)
- [ ] MCP server name in `SourcesMCP/main.swift` (`serverName`) + registration commands
- [ ] Skill folder/name (`Skill/call-transcriber/`) + plugin/mcpb/repo names
- [ ] README/SPEC titles

## Hosting the privacy policy

Any static host. Cheapest: a public GitHub repo (can be just the policy, not the app
source) → Settings → Pages → the markdown renders at
`https://<user>.github.io/<repo>/privacy-policy`. Paste that URL into ASC.
