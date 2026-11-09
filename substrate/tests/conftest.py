"""Every test gets its own blob store, engine config and vaults lock.

`substrate ingest` stores each original it accepts, and the store's location comes from
`~/.substrate/config.toml`. Without this, the hundreds of ingests the suite runs would write into
the developer's real store — and a developer's own `config.toml` would decide where the suite's
blobs went. The default index folder, `~/.substrate/index`, likewise. And `~/.substrate/serve.toml`:
a `substrate serve` a test starts in-process reads the suite's, never the developer's models or a
malformed file of theirs.
"""

from __future__ import annotations

import os

import pytest

from substrate import blobs, refresh, scopes, serve_config


@pytest.fixture(autouse=True)
def _private_blob_store(tmp_path_factory, monkeypatch):
    home = tmp_path_factory.mktemp("engine-home")
    monkeypatch.setattr(blobs, "config_path", lambda: home / blobs.CONFIG_NAME)
    monkeypatch.setattr(blobs, "default_root", lambda: home / "blobs")
    monkeypatch.setattr(serve_config, "path", lambda: home / serve_config.FILE)
    # A compose given no --db or --index-root builds in the engine's own folder: the suite's.
    monkeypatch.setattr(scopes, "index_home", lambda: home / scopes.INDEX_DIR)
    return home


@pytest.fixture(autouse=True)
def _private_vaults_lock(tmp_path_factory, monkeypatch):
    """`compose` and `embed` take the vaults lock beside the registry. A test that names no
    registry would otherwise take the developer's real one, and wait out a running Scripta or
    `substrate serve`, then fail as if flaky."""
    home = tmp_path_factory.mktemp("vaults-lock")
    real = refresh.lock_path

    def isolated(registry=None):
        if registry is None and not os.environ.get(scopes.ENV_VAR):
            return home / refresh.LOCK_NAME
        return real(registry)

    monkeypatch.setattr(refresh, "lock_path", isolated)
