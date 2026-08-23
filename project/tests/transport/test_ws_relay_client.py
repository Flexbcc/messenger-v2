import json

import pytest
from nacl.signing import SigningKey

from shared.security.config import HDR_NODE_ID
from shared.transport.binary_batch import decode_batch, encode_batch
from shared.transport.ws_relay_client import (
    RelayTransportError,
    RelayWebSocketClient,
    relay_websocket_url,
)


class FakeWebSocket:
    def __init__(self, *, reject=False, fail_first_send=False):
        self.reject = reject
        self.fail_first_send = fail_first_send
        self.sent = []
        self.closed = False

    async def send(self, data):
        if self.fail_first_send:
            self.fail_first_send = False
            raise OSError("link dropped")
        self.sent.append(data)

    async def recv(self):
        batch = decode_batch(self.sent[-1])
        if self.reject:
            result = {"ok": False, "status": 403, "detail": "denied"}
        else:
            result = {"ok": True, "result": {"status": "forwarded"}}
        return encode_batch(
            sequence=batch.sequence,
            cells=[json.dumps(result, separators=(",", ":")).encode()],
        )

    async def close(self):
        self.closed = True


def test_relay_websocket_url_is_strict():
    assert relay_websocket_url("http://node.example:8006") == "ws://node.example:8006/relay/ws"
    assert relay_websocket_url("https://node.example/base/") == "wss://node.example/base/relay/ws"
    with pytest.raises(ValueError):
        relay_websocket_url("ftp://node.example")
    with pytest.raises(ValueError):
        relay_websocket_url("https://user:pass@node.example")


@pytest.mark.asyncio
async def test_client_reuses_link_and_increments_sequence(monkeypatch):
    websocket = FakeWebSocket()
    connect_calls = []

    async def fake_connect(url, **kwargs):
        connect_calls.append((url, kwargs))
        return websocket

    monkeypatch.setattr("shared.transport.ws_relay_client.websocket_connect", fake_connect)
    client = RelayWebSocketClient(signing_key=SigningKey.generate(), node_id="home-a")
    assert await client.forward("https://relay.example", {"cell": 1}) == {"status": "forwarded"}
    assert await client.forward("https://relay.example", {"cell": 2}) == {"status": "forwarded"}
    assert len(connect_calls) == 1
    assert [decode_batch(item).sequence for item in websocket.sent] == [1, 2]
    headers = connect_calls[0][1]["additional_headers"]
    assert headers[HDR_NODE_ID] == "home-a"
    await client.close()
    assert websocket.closed


@pytest.mark.asyncio
async def test_client_reconnects_once_after_link_failure(monkeypatch):
    sockets = [FakeWebSocket(fail_first_send=True), FakeWebSocket()]

    async def fake_connect(_url, **_kwargs):
        return sockets.pop(0)

    monkeypatch.setattr("shared.transport.ws_relay_client.websocket_connect", fake_connect)
    client = RelayWebSocketClient(signing_key=SigningKey.generate(), node_id="home-a")
    result = await client.forward("http://relay.example", {"cell": 1})
    assert result["status"] == "forwarded"
    assert not sockets


@pytest.mark.asyncio
async def test_rejected_cell_fails_without_retry(monkeypatch):
    websocket = FakeWebSocket(reject=True)

    async def fake_connect(_url, **_kwargs):
        return websocket

    monkeypatch.setattr("shared.transport.ws_relay_client.websocket_connect", fake_connect)
    client = RelayWebSocketClient(signing_key=SigningKey.generate(), node_id="home-a")
    with pytest.raises(RelayTransportError, match="403.*denied"):
        await client.forward("http://relay.example", {"cell": 1})
    assert websocket.closed
