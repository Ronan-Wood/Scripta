"""Regression tests for the shared loopback egress guard (substrate.net.is_loopback).

Runnable with `python tests/test_loopback_guard.py` or under pytest.

Pins the parsing bug the audit's item 1 closed: the old `host.split("//")[-1].split(":")[0]`
guard read "127.0.0.1" out of `http://127.0.0.1:11434@evil.example:1337` (whose real host per
urlsplit is evil.example — the 127.0.0.1 is userinfo), and it mangled a legitimate
`http://[::1]:port` down to "[" and wrongly refused it. The replacement parses the authority with
urlsplit, refuses ANY userinfo outright (urllib.request doesn't strip it before the socket, and a
transport that does — requests/httpx — would connect off-machine, so the authority is ambiguous
whenever userinfo is present), fails CLOSED on anything it cannot parse, and does NOT widen the
allowed set beyond the loopback name + the two loopback literals.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.embed.engine import EmbeddingError, OllamaEmbedder  # noqa: E402
from substrate.net import is_loopback  # noqa: E402
from substrate.retrieve.expand import HyDE, LlamaServerHyDE, MultiQuery  # noqa: E402
from substrate.retrieve.rerank import LLMReranker  # noqa: E402
from substrate.retrieve.rerank_cross import CrossEncoderReranker  # noqa: E402


def test_userinfo_bypass_is_rejected() -> None:
    # The regression the fix closes: 127.0.0.1 is userinfo here, evil.example the real host, and
    # the old split-guard read "127.0.0.1" and ALLOWED it. This is the one case that flips.
    assert not is_loopback("http://127.0.0.1:11434@evil.example:1337")
    # The old split-guard already rejected these two (it mangled them to "127.0.0.1@evil.example"
    # and "[", neither in its set); kept to pin that the urlsplit guard refuses every userinfo form.
    assert not is_loopback("http://127.0.0.1@evil.example")
    assert not is_loopback("http://[::1]:11434@evil.example:80")


def test_ipv6_loopback_is_accepted() -> None:
    # The old guard mangled these to "[" and refused them.
    assert is_loopback("http://[::1]:8899")
    assert is_loopback("http://[::1]:11434")


def test_legit_loopback_forms_accepted() -> None:
    assert is_loopback("http://127.0.0.1:11434")
    assert is_loopback("http://localhost:11434")
    assert is_loopback("http://LOCALHOST:11434")                      # case-insensitive


def test_userinfo_on_loopback_host_is_rejected() -> None:
    # Even when the host IS loopback, userinfo makes the authority ambiguous and urllib.request
    # can't use it (it connects to the literal "user:pass@127.0.0.1" and DNS-fails), so refuse it.
    assert not is_loopback("http://user:pass@127.0.0.1:11434")
    assert not is_loopback("http://token@127.0.0.1:11434")
    assert not is_loopback("http://:pass@localhost:11434")            # password-only userinfo


def test_non_loopback_hosts_rejected() -> None:
    assert not is_loopback("http://attacker.example")
    assert not is_loopback("http://127.0.0.1.evil.example:80")        # loopback-as-subdomain
    assert not is_loopback("http://10.0.0.5:11434")


def test_fails_closed_on_unparseable_or_schemeless() -> None:
    # urlsplit raises ValueError on some malformed bracketed netlocs; a scheme-less string
    # yields no hostname. Both must read as non-loopback, not crash and not pass.
    assert not is_loopback("127.0.0.1:11434")                        # no scheme -> no hostname
    assert not is_loopback("")
    assert not is_loopback("://[bad")


def test_non_str_host_fails_closed() -> None:
    # A non-str host (a bare port int, a null from a missing config key) must read as non-loopback,
    # not escape as an uncaught AttributeError from urlsplit's internals.
    assert not is_loopback(123)          # type: ignore[arg-type]
    assert not is_loopback(None)         # type: ignore[arg-type]
    assert not is_loopback(b"http://127.0.0.1:11434")  # type: ignore[arg-type]  # bytes, not str


def test_schemeless_host_rejected_with_actionable_message() -> None:
    # A scheme-less loopback host (Ollama's bare OLLAMA_HOST convention) is not a URL the transport
    # can use; the refusal must not falsely brand it "non-loopback" and should hint the missing form.
    try:
        OllamaEmbedder(host="localhost:11434")
    except EmbeddingError as e:
        msg = str(e)
        assert "non-loopback" not in msg                             # don't assert a false claim
        assert "http://" in msg                                      # point at the missing scheme
    else:
        raise AssertionError("scheme-less host was accepted")


def test_allowed_set_not_widened() -> None:
    # 127.0.0.0/8 is loopback at the OS level, but the split-based guard only ever allowed the
    # single literal 127.0.0.1; parsing it correctly must not silently widen the surface.
    assert not is_loopback("http://127.0.0.2:11434")
    assert not is_loopback("http://127.1.2.3:11434")


def test_embedder_post_init_refuses_bypass_host() -> None:
    try:
        OllamaEmbedder(host="http://127.0.0.1:11434@evil.example:1337")
    except EmbeddingError:
        pass
    else:
        raise AssertionError("embedder accepted a userinfo-bypass host")
    # And still constructs for a genuine loopback host.
    OllamaEmbedder(host="http://127.0.0.1:11434")


def test_llama_server_hyde_post_init_refuses_bypass_host() -> None:
    try:
        LlamaServerHyDE(host="http://127.0.0.1:8899@evil.example:1337")
    except ValueError:
        pass
    else:
        raise AssertionError("LlamaServerHyDE accepted a userinfo-bypass host")
    LlamaServerHyDE(host="http://[::1]:8899")                         # IPv6 loopback now accepted


def test_ollama_expanders_carry_the_guard() -> None:
    # HyDE (the default expander) and MultiQuery ship the query too; they must refuse a
    # non-loopback host, not just the two arms the original fix touched.
    for cls in (HyDE, MultiQuery):
        try:
            cls(host="http://attacker.example")
        except ValueError:
            pass
        else:
            raise AssertionError(f"{cls.__name__} accepted a non-loopback host")
        try:
            cls(host="http://127.0.0.1:11434@evil.example:1337")     # userinfo bypass
        except ValueError:
            pass
        else:
            raise AssertionError(f"{cls.__name__} accepted a userinfo-bypass host")
        cls(host="http://127.0.0.1:11434")                           # genuine loopback constructs


def test_rerankers_carry_the_guard() -> None:
    # Both rerankers POST the query and retrieved passages to self.host; they must refuse a
    # non-loopback host too, not just the embedder and expanders.
    for cls in (LLMReranker, CrossEncoderReranker):
        try:
            cls(host="http://attacker.example")
        except ValueError:
            pass
        else:
            raise AssertionError(f"{cls.__name__} accepted a non-loopback host")
        try:
            cls(host="http://127.0.0.1:11434@evil.example:1337")     # userinfo bypass
        except ValueError:
            pass
        else:
            raise AssertionError(f"{cls.__name__} accepted a userinfo-bypass host")
        cls(host="http://127.0.0.1:11434")                           # genuine loopback constructs


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
