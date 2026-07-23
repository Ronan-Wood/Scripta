#!/usr/bin/env bash
# Lint (bug-catchers only, see [tool.ruff.lint] in pyproject.toml). Deterministic,
# non-zero exit for CI. Formatting is out of scope by design.
#
#   ./lint.sh          report problems
#   ./lint.sh --fix    apply the safe fixes (unused imports, etc.)
set -euo pipefail
cd "$(dirname "$0")"

exec uv run ruff check . "$@"
