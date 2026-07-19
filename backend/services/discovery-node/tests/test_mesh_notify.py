"""Tests for Discovery mesh notify heuristics."""
import json

from app.mesh_notify import should_notify_on_register


class _Row:
    def __init__(self, **kwargs):
        self._data = kwargs

    def __getitem__(self, key):
        return self._data[key]


class _Payload:
    def __init__(self, node_url, capabilities):
        self.node_url = node_url
        self.capabilities = capabilities


def test_notify_on_first_trusted_register():
    payload = _Payload("http://new:8001", ["home"])
    assert should_notify_on_register(None, payload, "trusted") is True


def test_skip_pending_register():
    payload = _Payload("http://new:8001", ["home"])
    assert should_notify_on_register(None, payload, "pending") is False


def test_notify_when_url_changes():
    existing = _Row(trust_status="trusted", node_url="http://old:8001", capabilities=json.dumps(["home"]))
    payload = _Payload("http://new:8001", ["home"])
    assert should_notify_on_register(existing, payload, "trusted") is True


def test_skip_unchanged_reregister():
    existing = _Row(trust_status="trusted", node_url="http://same:8001", capabilities=json.dumps(["home"]))
    payload = _Payload("http://same:8001", ["home"])
    assert should_notify_on_register(existing, payload, "trusted") is False
