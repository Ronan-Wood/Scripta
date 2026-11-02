"""Every Ollama generator must ask a thinking model NOT to think.

qwen3.5 (the generator family installed after qwen2.5 was removed on 2026-10-30) routes its whole
token budget into Ollama's separate `thinking` field unless the request says `think: false`, and
`response` comes back empty. Each generator fails OPEN on an empty response — HyDE to the bare
query, multi-query to no variants, the listwise reranker to fused order — so the omission does not
error: it silently turns the arm into a no-op that still reports itself as wired.

The fake server below behaves the way qwen3.5 measurably does: empty `response` unless the
request carries `think: false`. Each test fails on code that does not send it.

Runnable with `python tests/test_thinking_generators.py` or under pytest.
"""

from __future__ import annotations

import contextlib
import http.server
import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.retrieve.expand import HyDE, MultiQuery  # noqa: E402
from substrate.retrieve.rerank import LLMReranker  # noqa: E402
from substrate.store.index_store import Hit  # noqa: E402


@contextlib.contextmanager
def _thinking_model(prose: str):
    """A loopback `/api/generate` that answers like a thinking model, recording each payload."""
    seen: list[dict] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seen.append(payload)
            thinks = payload.get("think") is not False
            body = json.dumps({"response": "" if thinks else prose,
                               "thinking": "Let me consider the question..." if thinks else "",
                               "done": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args) -> None:
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{httpd.server_address[1]}", seen
    finally:
        httpd.shutdown()
        httpd.server_close()


def _hit(i: int, text: str) -> Hit:
    return Hit(chunk_id=f"c{i}", doc_id="d", kind="passage", text=text, path_str="",
               path_depth=0, page_start=None, page_label_start=None, n_chars=len(text),
               score=0.0, document_class="reference-frozen", version=None, title="T",
               prev_id=None, next_id=None)


def test_hyde_gets_prose_from_a_thinking_model() -> None:
    with _thinking_model("Failover promotes a follower to leader.") as (host, seen):
        out = HyDE(model="qwen3.5:9b-mlx", host=host).expand("who takes over")
    assert seen[0]["think"] is False, seen[0]
    assert out == "who takes over\n\nFailover promotes a follower to leader.", out


def test_multiquery_gets_variants_from_a_thinking_model() -> None:
    with _thinking_model("1. how does leader failover work\n2. what replaces a dead primary") as (
            host, seen):
        out = MultiQuery(model="qwen3.5:9b-mlx", host=host, n=2).variants("who takes over")
    assert seen[0]["think"] is False, seen[0]
    assert out == ["how does leader failover work", "what replaces a dead primary"], out


def test_listwise_rerank_gets_an_ordering_from_a_thinking_model() -> None:
    hits = [_hit(0, "unrelated text about storage"), _hit(1, "failover promotes a follower")]
    with _thinking_model("2, 1") as (host, seen):
        rr = LLMReranker(model="qwen3.5:9b-mlx", host=host)
        ranked, changed = rr.rerank("who takes over when the leader dies", hits)
    assert seen[0]["think"] is False, seen[0]
    assert changed and [h.chunk_id for h in ranked] == ["c1", "c0"], ranked
    assert rr.fallback_queries == 0


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok  {name}")
