#!/usr/bin/env bash
# Retrieval eval. Mirrors the ergonomics of Scripta's ./Eval/run.sh: one command, written
# gates, non-zero exit for CI.
#
#   ./run.sh                     index (if needed) then evaluate
#   ./run.sh --update-baseline   accept the current results as the no-regression floor
#
# The gate asserts the RIGHT answer, not a well-formed one: a case passes only when a single
# chunk carries both the expected content AND the expected attribution.
set -euo pipefail
cd "$(dirname "$0")"

uv run python -m substrate.cli index >/dev/null
exec uv run python -m substrate.cli eval "$@"
