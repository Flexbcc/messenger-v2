"""Reachability checks must preserve the configured private TLS trust root."""

import pytest

from app import capability_directory


class _Response:
    def raise_for_status(self):
        return None


class _Client:
    def __init__(self, captured, **kwargs):
        captured.update(kwargs)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def get(self, _url):
        return _Response()


@pytest.mark.asyncio
async def test_reachability_probe_uses_configured_tls_verifier(monkeypatch):
    captured = {}
    monkeypatch.setattr(capability_directory, "outbound_tls_verify", lambda: "/data/ca.crt")
    monkeypatch.setattr(
        capability_directory.httpx,
        "AsyncClient",
        lambda **kwargs: _Client(captured, **kwargs),
    )

    assert await capability_directory.rank_reachable(["https://storage-a:8002"]) == [
        "https://storage-a:8002"
    ]
    assert captured["verify"] == "/data/ca.crt"
