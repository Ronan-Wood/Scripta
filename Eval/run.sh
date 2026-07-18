#!/bin/bash
# Retrieval eval harness. Compiles the real shared indexing/retrieval sources + the eval driver,
# builds a throwaway index from the transcript folder, and scores gold cases against written gates.
# Run from the repo root:  ./Eval/run.sh            (current ranking)
#                          ./Eval/run.sh --legacy   (pre-overhaul baseline)
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN="$(mktemp -d)/eval"

swiftc -Onone -o "$BIN" \
  Sources/Shared/OwnerMarker.swift \
  Sources/Shared/FTSQuery.swift \
  Sources/Shared/SharedLocations.swift \
  Sources/Viewer/TranscriptParser.swift \
  Sources/Shared/Frontmatter.swift \
  Sources/Index/IndexStore.swift \
  Sources/Index/Indexing.swift \
  Eval/main.swift \
  -lsqlite3

"$BIN" "$@"
