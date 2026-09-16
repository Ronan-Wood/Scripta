# Security

Scripta records calls and reads documents on your own Mac. A vulnerability here is a vulnerability
in software holding microphone access, calendar access and the text of your conversations, so it is
taken seriously and answered.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **[open a draft advisory](https://github.com/Ronan-Wood/Scripta/security/advisories/new)**.
It is private to you and the maintainer until a fix ships.

Please do not open a public issue for a vulnerability. Public issues are the right place for bugs,
crashes and everything else.

This is a one-person project. Expect a first reply within a week, and a fix timed to severity rather
than to a policy. You will be credited in the advisory unless you ask not to be.

## What is in scope

- The app: recording, transcription, the vault it writes, the Library, Ask, and the settings that
  govern them.
- The bundled engine (`substrate/`): ingestion, the index, retrieval, and the MCP server it exposes
  to Claude.
- The update mechanism: the appcast, its signing key, and the installer path.
- The build and release scripts in `Distribution/`, including what ends up inside a signed bundle.

Out of scope: vulnerabilities in third-party dependencies with no Scripta-specific exposure, which
belong upstream; and findings that require an attacker who already has code execution as your user,
since the app is unsandboxed by design and that boundary is not one it claims to hold.

## What the app already does

Stated so a report can be aimed at what matters:

- **Signed and notarized.** Releases are Developer ID signed with a secure timestamp, notarized by
  Apple, and stapled. The engine's binaries are signed individually under the hardened runtime.
- **Updates are signed twice over.** The appcast is served over HTTPS, every item carries an EdDSA
  signature, and the feed itself is signed. The app verifies before extracting and refuses an
  unsigned feed. The private key lives on an encrypted volume and is never exported in the clear.
- **No network except two places.** A model server you chose, restricted to loopback or a private
  address, and the update check, which you allow before it first runs.
- **No account, no telemetry.** There is no server belonging to this project to talk to.
- **Nothing is fetched at runtime.** The Python engine, its dependencies and its interpreter are
  built into the bundle, and every binary in it is verified at build time to link only macOS
  frameworks or the bundle itself.

## Supported versions

The latest release. Fixes go into the next release rather than to older versions.
