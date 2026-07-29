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

DB=out/substrate.db
ENGINE_SCHEMA=$(uv run python -c 'from substrate.store.schema import SCHEMA_VERSION; print(SCHEMA_VERSION)')

# PREFLIGHT, not a bare abort. `index` below carries NO `--migrate`, deliberately: migration is
# drop-and-rebuild, so crossing a schema version here would destroy the very artifact the eval
# measures and then report a number computed on a corpus this script rebuilt seconds earlier.
#
# But refusing is only half an answer. Without this check `index` exits 2, `set -e` kills the
# script, and the operator sees a schema message about a file they did not know was the thing
# standing between them and a number. Read with `?immutable=1` — never through engine code, and
# `mode=ro` no longer opens this file at all, since SQLite cannot create the `-shm` a WAL database
# needs under a read-only open.
if [ -f "$DB" ]; then
  ON_DISK=$(sqlite3 "file:$DB?immutable=1" "PRAGMA user_version;" 2>/dev/null || echo "?")
  if [ "$ON_DISK" != "$ENGINE_SCHEMA" ]; then
    cat >&2 <<EOF
REFUSING TO RUN: $DB is schema v$ON_DISK, this engine is v$ENGINE_SCHEMA.

  Migration is drop-and-rebuild, so simply running the eval would DESTROY the fixture and then
  measure whatever it had just rebuilt. That is a decision, not a step, so this script will not
  make it for you.

  The fixture is recoverable — the ingest dirs under out/ are the source of truth and
  out/vector-cache.db is content-addressed — but rebuilding resets its "untouched since"
  property, which is most of what makes it a fixture. To do it deliberately:

      uv run python -m substrate.cli index --migrate
      uv run python -m substrate.cli embed          # the drop takes the vectors with it
      ./run.sh

EOF
    exit 1
  fi
fi

uv run python -m substrate.cli index >/dev/null
exec uv run python -m substrate.cli eval "$@"
