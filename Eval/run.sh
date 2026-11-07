#!/bin/bash
# Retrieval eval harness. Builds the scripta-eval executable from the Core package (the SAME
# ScriptaCore indexing/retrieval code the app and tests use), builds a throwaway index from the
# transcript folder, and scores gold cases against written gates. By default it scores the synthetic
# corpus in Eval/corpus against Eval/gold.json; pass --folder <dir> --gold <file> for another corpus,
# whose gold set stays outside this repo.
# Run from the repo root:  ./Eval/run.sh            (current ranking)
#                          ./Eval/run.sh --legacy   (pre-overhaul baseline)
set -e
cd "$(dirname "$0")/.."

swift build --package-path Core --product scripta-eval -c release
"$(swift build --package-path Core -c release --show-bin-path)/scripta-eval" "$@"
