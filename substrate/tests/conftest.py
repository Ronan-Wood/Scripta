"""Every test gets its own blob store and engine config.

`substrate ingest` stores each original it accepts, and the store's location comes from
`~/.substrate/config.toml`. Without this, the hundreds of ingests the suite runs would write into
the developer's real store — and a developer's own `config.toml` would decide where the suite's
blobs went.
"""

from __future__ import annotations

import pytest

from substrate import blobs


@pytest.fixture(autouse=True)
def _private_blob_store(tmp_path_factory, monkeypatch):
    home = tmp_path_factory.mktemp("engine-home")
    monkeypatch.setattr(blobs, "config_path", lambda: home / blobs.CONFIG_NAME)
    monkeypatch.setattr(blobs, "default_root", lambda: home / "blobs")
    return home
