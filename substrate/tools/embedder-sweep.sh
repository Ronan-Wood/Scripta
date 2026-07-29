#!/usr/bin/env bash
# A/B sweep across embedding models.
#
# Each model occupies its own (content_sha, model) space in the durable cache, so a model
# already measured is re-measured for free and switching back costs nothing. That is what
# makes an honest sweep affordable rather than a one-shot guess.
#
# HyDE is held constant at the measured best (qwen2.5:7b) and its expansions are cached, so
# the only variable between rows is the embedder.
set -uo pipefail
cd "$(dirname "$0")/.."

MODELS=${*:-"nomic-embed-text mxbai-embed-large bge-m3 snowflake-arctic-embed2"}

printf '%-28s %-8s %-10s %s\n' MODEL DIM SEM_MRR LEXICAL
printf '%.0s─' {1..64}; printf '\n'

for m in $MODELS; do
    if ! curl -s http://127.0.0.1:11434/api/tags | grep -q "\"${m}"; then
        printf '%-28s %s\n' "$m" "(not pulled)"
        continue
    fi

    embed_out=$(uv run python -m substrate.cli embed --model "$m" 2>&1 | tail -2)
    # migrate=False. This reads ONE integer, and with the default it dropped and rebuilt
    # `out/substrate.db` — the eval fixture — on the first mismatched version, one line after the
    # `embed` above had correctly refused to. `2>/dev/null` meant it did so in silence, and `dim`
    # just came back `?`. The sixth call site of the five this guard was written for.
    dim=$(uv run python -c "
from substrate.store.index_store import IndexStore
with IndexStore('out/substrate.db', migrate=False) as s:
    r=s.db.execute('SELECT dim FROM chunk_vectors WHERE embed_model=? LIMIT 1',('$m',)).fetchone()
    print(r['dim'] if r else '?')
" 2>/dev/null)
    # A refused read now yields an EMPTY string, where the pre-guard version printed `?`.
    # `mrr` and `lex` carry `${...:-?}` on the printf line; this one did not, so the column
    # silently blanked rather than saying "not known".
    dim=${dim:-?}

    line=$(uv run python -m substrate.cli eval --embed-model "$m" 2>&1 \
           | grep -E "SEMANTIC COHORT|LEXICAL ")
    mrr=$(echo "$line" | grep -o 'mrr [0-9.]*' | awk '{print $2}')
    lex=$(echo "$line" | grep -o '[0-9]*/[0-9]* pass' | head -1)
    printf '%-28s %-8s %-10s %s\n' "$m" "$dim" "${mrr:-?}" "${lex:-?}"
done
