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
| Updates | Sparkle 2, EdDSA-signed appcast attached to the Latest GitHub release |

**`Release` is a local build and must never ship.** It signs with whatever automatic signing
resolves — an *Apple Development* certificate — and Xcode gives the app bundle
`--timestamp=none`. Both are rejected at notarization. `Distribution` exists to state the identity
and add `OTHER_CODE_SIGN_FLAGS: --timestamp`; it is the only configuration that produces a
submittable artifact. This distinction is the whole reason the config exists, and this runbook
previously told you to build `Release` — which is how a decision that reached `project.yml` failed
to reach the document a human follows.

## The version lives in `project.yml`, not in Info.plist

`xcodegen generate` rewrites `Sources/App/Info.plist` from the `info.properties` block in
`project.yml`, and any key not declared there gets xcodegen's default — `1.0` and `1`. A bump made
in the plist file reverts on the next generate; that is how v0.1.0 shipped reporting 1.0 (1) and
how the first v0.2.0 build did too. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
`project.yml`, regenerate, and read the version back off the BUILT bundle before submitting:

```sh
defaults read "$(pwd)/build/Distribution/Scripta.app/Contents/Info.plist" CFBundleShortVersionString
```

`CFBundleVersion` must strictly increase every release — it is what Sparkle compares.

## Step 0 — one-time account setup (blocks everything below)

1. Enroll: developer.apple.com → Apple Developer Program, $99/yr, individual.
2. Xcode → Settings → Accounts → team `6CTH5M9UWZ`. One certificate is needed:
   **Developer ID Application**. (Apple Distribution is no longer required — no MAS channel.)
3. Credentials for `notarytool`:
   `xcrun notarytool store-credentials notary --apple-id <id> --team-id 6CTH5M9UWZ`
4. **The Sparkle signing key** — DONE 2026-09-14 on the release machine. `generate_keys` put an
   EdDSA private key in the login keychain (item "Private key for signing Sparkle updates") and
   its public half is `SUPublicEDKey` in `project.yml`. Every appcast is signed with it, and an
   installed app refuses an update signed with any other — `SUVerifyUpdateBeforeExtraction` is
   what makes that true, since without it Sparkle would fall back to trusting this team's
   Developer ID. Losing the key strands every installed copy on manual updates; the only recovery
   is a release users must drag-and-drop, carrying a new public key.

   **Back it up now if you have not — and never as a plain file.** `generate_keys -x` writes the
   raw key unencrypted, readable by every process running as you. Export it straight into an
   encrypted image and copy the image off this machine (a password manager works too):

   ```bash
   Distribution/backup-sparkle-key
   ```

   The first run creates `~/SparkleKey.dmg` and asks for a password for it. Every run mounts the
   image, exports the key into it, and ejects it, warning if the volume stays mounted.
   `generate_keys` raises a keychain prompt for the key, which is expected.

   Never in the repo, `dist/`, OneDrive, or the same backup as `dist/archive` — the archive plus
   the key is everything needed to push code to every install.

## Build, sign, notarize

Two scripts do the release, and each stops at its first failed check. They are scripts because
pasting blocks kept breaking: with zsh's default `interactivecomments` off, a trailing `# comment`
became arguments to the command before it, an `exit` in a guard closed the terminal, and the
wrapper that avoided both could not be read by the bash 3.2 macOS ships.

```bash
Distribution/build-and-notarize
```

It refuses a working tree with uncommitted changes, because the tag published with the release has
to be the source of exactly this binary, and it refuses if regenerating `Info.plist` changes the
committed file. It builds the `Distribution` configuration and asserts the signatures, including
Sparkle's helpers by name. It fails if FFmpeg or another GPL media library is in the bundle. It
notarizes and staples the app, builds the dmg from the stapled app, then notarizes and staples the
dmg. Only after Gatekeeper accepts the app does the dmg move into `dist/archive`, with its build
commit recorded in `dist/commits`. The script's comments say why each step is ordered as it is.

## The appcast, and the release that carries it

The in-app updater reads `https://github.com/Ronan-Wood/Scripta/releases/latest/download/appcast.xml`
— GitHub redirects that to the asset on whichever release is marked **Latest**. So the release
IS the feed: there is no branch to update and no site to host, and a release that forgets the
appcast is a release the updater never sees. The appcast describes one version — the newest —
with its full dmg and binary deltas from the releases before it, so every URL in it points at the
release being cut and one `--download-url-prefix` covers them all.

```bash
Distribution/publish-release
```

Write the release notes to `dist/release-notes-<version>.md` first. The script checks that this
checkout's Sparkle tools match the framework the app embeds, then generates and signs the appcast
and asserts it: signatures on the item and on the feed, exactly one item, and every URL under this
release's tag. `generate_appcast` reads the key through a keychain prompt, and if that prompt is
denied it still exits 0 with an unsigned feed, which the assertion catches. It then tags the commit
the dmg was built from, pushes the tag, and creates the release with `--verify-tag`, so GitHub cannot
put the tag on a different commit.

A pre-release is invisible to the updater by construction (`releases/latest` skips them), which is
the right default. Deltas are per version pair — the three most recent archives get one each; a
user further back than that downloads the full dmg. When the bundled engine changes (the Python
runtime or its dependencies) the delta is nearly the full size and there is nothing to be done
about it; the point of deltas is that most releases do not change the engine.

**Verifying the update path** before announcing: install the PREVIOUS release, launch it, Scripta
menu → Check for Updates…, and let it install. The installed copy should report the new version in
Settings → General. Deltas are the thing to watch: Sparkle falls back to the full download if one
fails to apply, silently from the user's side, so a delta that never works costs bandwidth, not
correctness — the log line in Console.app under subsystem `org.sparkle-project.Sparkle` says
which it used.

Sparkle's helpers are NOT signed for distribution when they arrive: the SwiftPM artifact is
ad-hoc signed, and Xcode's code-sign-on-copy re-signs only the framework's own binary. The "Sign
Sparkle's helpers" build phase deletes the XPC services (sandboxed apps only), re-signs
`Autoupdate`, `Updater.app` and the framework with Developer ID and a timestamp, and asserts it.
`codesign --verify --deep --strict` passes the ad-hoc originals, which is why
`Distribution/build-and-notarize` checks each binary by name.

Under `SURequireSignedFeed`, release notes shown by the updater must be embedded in the appcast
(`--embed-release-notes`, with a `Scripta-$VERSION.md` beside the dmg) — a linked notes file is
refused. The GitHub release notes are unaffected.

**Known rejections, both hit on 2026-08-17 and both fixed in `project.yml`:**

| symptom | cause |
|---|---|
| `The executable requests the com.apple.security.get-task-allow entitlement` | Xcode injects the debug entitlement at signing time. It is NOT in `Scripta.entitlements`, so it is invisible in the repo — only `codesign -d --entitlements` on the built app shows it. Fixed by `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` on the Distribution config |
| `stapler` **Error 65** | stapling a dmg that was rebuilt after its ticket was issued. Follow the order in `Distribution/build-and-notarize` |

**Notarization is proven.** Submission `c3eeb612` was **Accepted** on 2026-08-17 — 1.4 GB, 366
nested binaries, ~15 minutes end to end, dominated by the upload. Every nested binary passed; the
single rejection before it was the entitlement in the table above, not the size or the contents.
Budget ~15 minutes per submission and two submissions per release. The nested binaries are signed and timestamped by the
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
