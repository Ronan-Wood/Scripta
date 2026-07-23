"""Regression tests for AppleEmbedder vector hygiene (embed/engine.py).

Runnable with `python tests/test_apple_embedder.py` or under pytest.

Pins the medium: the Apple arm returned the shim's floats verbatim while the Ollama arm L2-
normalizes every vector. The shim normalizes today, but nothing on the Python side verified it —
so at that trust boundary a non-unit vector would silently stop a dot product being cosine, and a
vector whose length disagreed with the handshake `dim` would be stored anyway. `_one` now
L2-normalizes and rejects a wrong-dim vector. The shim is a Swift subprocess, so a fake stdout
stands in for it — the logic under test is pure decode/normalize/check.
"""

from __future__ import annotations

import base64
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.embed.engine import AppleEmbedder, EmbeddingError  # noqa: E402


def _encode(vec: list[float]) -> str:
    return base64.b64encode(struct.pack(f"{len(vec)}f", *vec)).decode()


class _FakeStdin:
    def write(self, s: str) -> None: ...
    def flush(self) -> None: ...


class _FakeStdout:
    def __init__(self, line: str) -> None:
        self._line = line

    def readline(self) -> str:
        return self._line + "\n"


class _FakeProc:
    """Alive (poll() is None) so _ensure() reuses it without restarting or resetting dim."""

    def __init__(self, line: str) -> None:
        self.stdin = _FakeStdin()
        self.stdout = _FakeStdout(line)

    def poll(self) -> None:
        return None


def _emb(vec: list[float], dim: int) -> AppleEmbedder:
    e = AppleEmbedder()
    e.dim = dim
    e._proc = _FakeProc(_encode(vec))
    return e


def test_one_l2_normalizes() -> None:
    # 3-4-0 has magnitude 5; a correct L2 gives 0.6/0.8/0.0 and unit norm.
    v = _emb([3.0, 0.0, 4.0], dim=3)._one("hi")
    assert abs(sum(x * x for x in v) - 1.0) < 1e-9
    assert abs(v[0] - 0.6) < 1e-9 and abs(v[2] - 0.8) < 1e-9


def test_one_normalizes_a_non_unit_vector() -> None:
    # A shim that fails to normalize (all-ones, norm=2) must not leak a non-unit vector through.
    v = _emb([1.0, 1.0, 1.0, 1.0], dim=4)._one("hi")
    assert abs(sum(x * x for x in v) - 1.0) < 1e-9
    assert all(abs(x - 0.5) < 1e-9 for x in v)


def test_one_rejects_wrong_dim() -> None:
    # Handshake said 4 dims; shim returned 3 — must raise, not silently store a short vector.
    try:
        _emb([1.0, 0.0, 0.0], dim=4)._one("hi")
    except EmbeddingError:
        pass
    else:
        raise AssertionError("wrong-dim vector was not rejected")


def test_one_rejects_trailing_garbage_bytes() -> None:
    # A payload one byte longer than dim*4 (transport corruption) must raise a clean
    # EmbeddingError, not a struct.error and not a silently-reshaped vector.
    line = base64.b64encode(struct.pack("4f", 1.0, 2.0, 3.0, 4.0) + b"\x00").decode()
    e = AppleEmbedder()
    e.dim = 4
    e._proc = _FakeProc(line)
    try:
        e._one("hi")
    except EmbeddingError:
        pass
    else:
        raise AssertionError("trailing-byte payload was not rejected")


def test_one_accepts_matching_dim() -> None:
    # Non-unit fixture on purpose ([0,2] has norm 2): this fails if _l2 is dropped from _one.
    v = _emb([0.0, 2.0], dim=2)._one("hi")
    assert len(v) == 2
    assert abs(sum(x * x for x in v) - 1.0) < 1e-9
    assert abs(v[1] - 1.0) < 1e-9


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
