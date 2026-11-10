# Contributing to Scripta

Thank you for looking. Scripta is a one-person project, and a bug report with exact steps helps as
much as a patch does.

**Is it the app or the engine?** Scripta records, transcribes and writes Markdown, and it runs the
search engine. The engine itself is [Ronan-Wood/substrate](https://github.com/Ronan-Wood/substrate):
ingestion, the index, retrieval, and the MCP server Claude talks to. Engine bugs and changes belong
in that repository, which has its own [contributing guide](https://github.com/Ronan-Wood/substrate/blob/main/CONTRIBUTING.md).
If you can't tell which side a problem is on, open the issue here.

**Security problems** don't go in a public issue. [SECURITY.md](SECURITY.md) says how to report
them privately.

## Setup

You need a Mac with Apple silicon, **macOS 26 or later**, and Xcode with the macOS 26 SDK. Then:

```sh
brew install xcodegen uv
```
```sh
Distribution/fetch-engine
```
```sh
xcodegen generate
```

`fetch-engine` downloads the engine release that `engine.lock` pins, checks it against the lock and
unpacks it into `vendor/`. It needs the network once; after that the tarball is kept in `vendor/`.
`xcodegen generate` writes `Scripta.xcodeproj` from `project.yml`. The project file isn't tracked, so
edit `project.yml` and regenerate.

## Build and run

```sh
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Debug build
```

Debug builds sign automatically with the maintainer's team, and the entitlements name its app
group. To build under your own team, set your team in Xcode (or pass `DEVELOPMENT_TEAM` to
`xcodebuild`) and change the app group in `Sources/App/Scripta.entitlements` to one under your team.
Keep both changes local; don't commit them. Building under another team isn't tested yet, so say in
an issue if it fails.

The first build is slow. It vendors a Python runtime and the engine's dependencies into the app
bundle, and compiles OpenCV from source with FFmpeg switched off, because every prebuilt macOS
OpenCV bundles a GPL-licensed FFmpeg. uv caches that, so it happens once per machine, and later
builds skip the engine in seconds unless it changed.

**Working on the engine at the same time?** A Debug build can bundle another engine checkout instead
of the pinned release. Set `SUBSTRATE_ENGINE_SRC` to the absolute path of an engine checkout's root.
Release and Distribution builds refuse the variable.

**Open the app** before you call a UI change done. A green build says nothing about layout, about
whether a control can be reached, or whether it does anything.

## Tests

The tests that run without the app are in the `Core` package:

```sh
cd Core && swift test
```

They run as **two test bundles**, `SubstrateKitTests` and `ScriptaCoreTests`, and `swift test`
prints an `Executed …` line for each. The last line you see is only the second bundle, so check
the exit status and both lines.

- **`SubstrateKitTests`** decodes the engine's wire format. It reads the golden frames in
  `Core/Tests/EngineContract/`, a copy of the pinned release's `contract/`.
- **`ScriptaCoreTests`** covers vault layout, parsing, the note writer, the release scripts run
  against stubs, and `PublicDocsTests`, which fails if a public document names a home folder.

The retrieval eval is `./Eval/run.sh`. It scores the synthetic corpus in `Eval/corpus/` against
`Eval/gold.json`.

## What CI checks

| check | what it runs |
|---|---|
| `engine pin` | `Distribution/fetch-engine --check`: the lock matches the release, GitHub's tag is signed and on the lock's commit, every file in the tarball is that commit's, and `Core/Tests/EngineContract/` is byte for byte the release's contract |
| `app core` | `swift test` in `Core`, on a macOS runner |
| `codeql swift` | CodeQL code scanning of the `Core` package, on every PR and weekly. Not required to merge |

CI doesn't build the app, because the bundled engine takes about an hour to build. A change to
`Sources/` needs a build and a run on your own Mac.

## How a change lands

- **One branch per change**, named for what it does: `fix/…`, `feat/…`, `docs/…`, `ci/…`, `chore/…`.
- **Pull requests into `main` only.** `main` takes squash merges only, keeps a linear history, and
  requires signed commits. `engine pin` and `app core` must pass on a branch that is up to date
  with `main`.
- **Write the PR title as a Conventional Commit** that says what is true afterwards:
  `fix(capture): a second display no longer drops system audio`. The squash commit takes the PR's
  title, except that a one-commit PR takes its commit's title, so name that commit the same way.
- **A fix comes with a regression test** that fails on the old code the way the bug did. Say in the
  PR that you watched it fail.
- **Synthetic data only.** Fixtures, screenshots, examples and issue text use made-up calls, like
  `Eval/corpus/`, never real recordings, notes, names or paths from your machine. This repository is
  public.

## Changing what the engine and the app share

The app and the engine agree on a wire format and a note format, written down in the engine's
`contract/` and its [client contract](https://github.com/Ronan-Wood/substrate/blob/main/docs/client-contract.md).
A change to either lands in the engine first, as a release. Then a PR here moves the pin:

```sh
Distribution/fetch-engine --bump vX.Y.Z
```

It needs the [GitHub CLI](https://cli.github.com), installed and signed in (`gh auth login`), as
`--check` does. It rewrites `engine.lock` from the release, unpacks it, and re-vendors
`Core/Tests/EngineContract/`. Commit those with whatever `SubstrateKit` change the new contract
needs. `engine pin` then holds the PR to the release.

## Releases

Releases are cut by the maintainer, as [`Distribution/RELEASING.md`](Distribution/RELEASING.md)
describes. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) when your change is
something a user would notice.

## Licence

Scripta is GPL-3.0-or-later. By contributing you agree that your contribution is licensed the same
way.
