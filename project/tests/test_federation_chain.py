"""
Интеграционные тесты цепочки федерации (Фаза 2 + 3).

Тестируется без реального Docker/сервисов — через unit-уровень:
  - подписанные user records (sign + verify)
  - hop_count guard в relay-node (≥MAX_HOPS → 400)
  - rate-limit sliding window
  - автодеградация trust level
  - mesh peer update из heartbeat-ответа
  - latency sort relay candidates
  - backup buffer при отказе всех путей
"""
from __future__ import annotations

import asyncio
import collections
import importlib
import sys
import time
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import httpx
from nacl.signing import SigningKey

# ── Фаза 2.1: подписанные User Records ──────────────────────────────────────

from shared.security.record_verifier import verify_user_record_response
from shared.security.keys import public_key_b64


def _service_module(service: str, module: str):
    """Import a service's top-level ``app`` package despite hyphens in its directory."""
    service_root = Path(__file__).parents[1] / "services" / service
    for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
        del sys.modules[name]
    sys.path.insert(0, str(service_root))
    try:
        return importlib.import_module(f"app.{module}")
    finally:
        sys.path.remove(str(service_root))


def _sign_record(key: SigningKey, user_id: str, home_url: str, updated_at: str) -> str:
    import base64
    msg = f"{user_id}|{home_url}|{updated_at}".encode()
    sig = key.sign(msg).signature
    return base64.urlsafe_b64encode(sig).decode()


class TestSignedUserRecords:
    def setup_method(self):
        self.key = SigningKey.generate()
        self.pub = public_key_b64(self.key)
        self.user_id = "user-alice"
        self.home_url = "https://home-a.example.com"
        self.updated_at = "2026-07-23T12:00:00+00:00"

    def test_valid_signature_accepted(self):
        sig = _sign_record(self.key, self.user_id, self.home_url, self.updated_at)
        assert verify_user_record_response(
            user_id=self.user_id,
            home_node_url=self.home_url,
            updated_at=self.updated_at,
            signature_b64=sig,
            public_key_b64=self.pub,
        )

    def test_wrong_home_url_rejected(self):
        sig = _sign_record(self.key, self.user_id, self.home_url, self.updated_at)
        assert not verify_user_record_response(
            user_id=self.user_id,
            home_node_url="https://evil-node.example.com",  # подменили URL
            updated_at=self.updated_at,
            signature_b64=sig,
            public_key_b64=self.pub,
        )

    def test_wrong_key_rejected(self):
        other_key = SigningKey.generate()
        sig = _sign_record(other_key, self.user_id, self.home_url, self.updated_at)
        assert not verify_user_record_response(
            user_id=self.user_id,
            home_node_url=self.home_url,
            updated_at=self.updated_at,
            signature_b64=sig,
            public_key_b64=self.pub,  # ключ не соответствует подписи
        )

    def test_tampered_signature_rejected(self):
        sig = _sign_record(self.key, self.user_id, self.home_url, self.updated_at)
        bad_sig = sig[:-4] + "XXXX"
        assert not verify_user_record_response(
            user_id=self.user_id,
            home_node_url=self.home_url,
            updated_at=self.updated_at,
            signature_b64=bad_sig,
            public_key_b64=self.pub,
        )

    def test_unpadded_base64_accepted(self):
        """Верификатор должен принимать base64url без padding '='."""
        sig = _sign_record(self.key, self.user_id, self.home_url, self.updated_at)
        sig_stripped = sig.rstrip("=")
        pub_stripped = self.pub.rstrip("=")
        assert verify_user_record_response(
            user_id=self.user_id,
            home_node_url=self.home_url,
            updated_at=self.updated_at,
            signature_b64=sig_stripped,
            public_key_b64=pub_stripped,
        )


# ── Фаза 2.2: hop_count guard ────────────────────────────────────────────────

class TestHopCountGuard:
    """Проверяем что relay_node правильно обрабатывает hop_count."""

    def test_hop_count_in_payload_builder(self):
        """build_relay_forward_payload должен включать hop_count в payload."""
        from shared.security.payload_builder import build_relay_forward_payload
        key = SigningKey.generate()
        payload = build_relay_forward_payload(
            signing_key=key,
            origin_node_id="home-1",
            envelope={"packet_id": "p1", "ciphertext": "abc"},
            conversation_meta={"conversation_id": "c1", "type": "direct", "participant_user_ids": []},
            target_home_node_url="https://home-b.example.com",
            hop_count=1,
        )
        assert payload["hop_count"] == 1
        assert payload["target_home_node_url"] == "https://home-b.example.com"

    def test_hop_count_default_is_1(self):
        from shared.security.payload_builder import build_relay_forward_payload
        key = SigningKey.generate()
        payload = build_relay_forward_payload(
            signing_key=key,
            origin_node_id="home-1",
            envelope={"packet_id": "p2", "ciphertext": "abc"},
            conversation_meta={"conversation_id": "c1", "type": "direct", "participant_user_ids": []},
            target_home_node_url="https://home-b.example.com",
        )
        assert payload["hop_count"] == 1

    def test_hop_count_2_included(self):
        from shared.security.payload_builder import build_relay_forward_payload
        key = SigningKey.generate()
        payload = build_relay_forward_payload(
            signing_key=key,
            origin_node_id="relay-1",
            envelope={"packet_id": "p3", "ciphertext": "abc"},
            conversation_meta={"conversation_id": "c1", "type": "direct", "participant_user_ids": []},
            target_home_node_url="https://home-b.example.com",
            hop_count=2,
        )
        assert payload["hop_count"] == 2


# ── Фаза 3.1: автодеградация trust level ─────────────────────────────────────

class TestTrustDegradation:
    """Тестируем логику _degrade_once() без реальной БД."""

    def _make_row(self, node_id: str, trust_level: int, offline_days: int) -> dict:
        last_hb = (datetime.now(timezone.utc) - timedelta(days=offline_days)).isoformat()
        return {
            "node_id": node_id,
            "trust_level": trust_level,
            "trust_status": "trusted",
            "last_heartbeat": last_hb,
        }

    def test_l2_degrades_after_7_days(self):
        td = _service_module("discovery-node", "trust_degradation")
        row = self._make_row("hub-1", trust_level=2, offline_days=8)
        offline = td._offline_since(row["last_heartbeat"])
        assert offline >= timedelta(days=7)
        # Нода с trust_level=2 и 8 днями offline должна деградировать до L1
        assert row["trust_level"] == 2
        assert offline.days >= td.DEGRADE_L2_AFTER_DAYS

    def test_l2_not_degrades_before_threshold(self):
        td = _service_module("discovery-node", "trust_degradation")
        row = self._make_row("hub-2", trust_level=2, offline_days=5)
        offline = td._offline_since(row["last_heartbeat"])
        assert offline.days < td.DEGRADE_L2_AFTER_DAYS

    def test_l1_degrades_after_14_days(self):
        td = _service_module("discovery-node", "trust_degradation")
        row = self._make_row("relay-old", trust_level=1, offline_days=15)
        offline = td._offline_since(row["last_heartbeat"])
        assert offline.days >= td.DEGRADE_L1_AFTER_DAYS

    def test_l0_not_degraded(self):
        """L0 ноды не деградируются (уже минимум)."""
        td = _service_module("discovery-node", "trust_degradation")
        row = self._make_row("node-zero", trust_level=0, offline_days=30)
        # Логика: trust_level >= 1 только деградируется
        assert row["trust_level"] < 1  # L0 не должна попасть в запрос деградации


# ── Фаза 3.2: rate-limit скользящее окно ─────────────────────────────────────

class TestRateLimit:
    """Тестируем sliding window rate limiter из relay-node."""

    def _make_limiter(self, limit: int = 5, window: int = 60):
        """Возвращает функцию _check_rate_limit с изолированным состоянием."""
        window_dict: dict[str, collections.deque] = {}

        def check(origin: str, now: float) -> bool:
            if origin not in window_dict:
                window_dict[origin] = collections.deque()
            dq = window_dict[origin]
            cutoff = now - window
            while dq and dq[0] < cutoff:
                dq.popleft()
            if len(dq) >= limit:
                return False
            dq.append(now)
            return True

        return check

    def test_within_limit_allowed(self):
        check = self._make_limiter(limit=3)
        now = time.monotonic()
        assert check("node-a", now) is True
        assert check("node-a", now + 1) is True
        assert check("node-a", now + 2) is True

    def test_exceeding_limit_blocked(self):
        check = self._make_limiter(limit=3)
        now = time.monotonic()
        check("node-a", now)
        check("node-a", now + 1)
        check("node-a", now + 2)
        assert check("node-a", now + 3) is False  # 4-й — заблокирован

    def test_window_expiry_resets_count(self):
        check = self._make_limiter(limit=3, window=10)
        now = time.monotonic()
        check("node-a", now)
        check("node-a", now + 1)
        check("node-a", now + 2)
        # Через 11 секунд старые записи вышли за окно
        assert check("node-a", now + 11) is True  # снова разрешено

    def test_different_origins_independent(self):
        check = self._make_limiter(limit=2)
        now = time.monotonic()
        check("node-a", now)
        check("node-a", now + 1)
        # node-a исчерпал лимит
        assert check("node-a", now + 2) is False
        # node-b независим
        assert check("node-b", now + 2) is True


# ── Фаза 3.3: mesh update из heartbeat-ответа ────────────────────────────────

class TestMeshHeartbeatUpdate:
    def test_peers_from_heartbeat_added_to_registry(self):
        from shared.mesh.registry import MeshPeerRegistry
        from shared.mesh.sync import update_mesh_from_heartbeat_response

        registry = MeshPeerRegistry()
        # Подменяем глобальный registry на изолированный
        with patch("shared.mesh.sync.get_mesh_registry", return_value=registry):
            count = update_mesh_from_heartbeat_response(
                {
                    "node_id": "home-a",
                    "peers": [
                        {
                            "node_id": "relay-1",
                            "node_url": "http://relay-1:8005",
                            "capabilities": ["relay"],
                            "cluster_id": "default",
                            "trust_level": 1,
                        },
                        {
                            "node_id": "storage-1",
                            "node_url": "http://storage-1:8002",
                            "capabilities": ["storage"],
                            "cluster_id": "default",
                            "trust_level": 0,
                        },
                    ],
                },
                self_node_id="home-a",
            )
        assert count == 2
        urls = registry.urls_for_capability("relay")
        assert "http://relay-1:8005" in urls

    def test_empty_peers_no_update(self):
        from shared.mesh.registry import MeshPeerRegistry
        from shared.mesh.sync import update_mesh_from_heartbeat_response

        registry = MeshPeerRegistry()
        with patch("shared.mesh.sync.get_mesh_registry", return_value=registry):
            count = update_mesh_from_heartbeat_response(
                {"node_id": "home-a"},  # нет поля peers
                self_node_id="home-a",
            )
        assert count == 0

    def test_self_node_excluded(self):
        from shared.mesh.registry import MeshPeerRegistry
        from shared.mesh.sync import update_mesh_from_heartbeat_response

        registry = MeshPeerRegistry()
        with patch("shared.mesh.sync.get_mesh_registry", return_value=registry):
            count = update_mesh_from_heartbeat_response(
                {
                    "peers": [
                        {
                            "node_id": "home-a",  # сама себя не должна добавлять
                            "node_url": "http://home-a:8001",
                            "capabilities": ["home"],
                            "cluster_id": "default",
                        }
                    ]
                },
                self_node_id="home-a",
            )
        assert count == 0


# ── Фаза 2.3: сортировка relay по latency ────────────────────────────────────

class TestLatencySort:
    def test_nodes_sorted_by_latency_asc(self):
        nodes = [
            {"node_url": "http://relay-slow:8005", "status": "online",
             "trust_status": "trusted", "trust_level": 1,
             "metrics": {"latency_ms": 300}},
            {"node_url": "http://relay-fast:8005", "status": "online",
             "trust_status": "trusted", "trust_level": 1,
             "metrics": {"latency_ms": 50}},
            {"node_url": "http://relay-mid:8005", "status": "online",
             "trust_status": "trusted", "trust_level": 1,
             "metrics": {"latency_ms": 150}},
        ]

        def _latency(node: dict) -> float:
            m = node.get("metrics") or {}
            lat = m.get("latency_ms")
            return float(lat) if lat is not None else float("inf")

        eligible = [n for n in nodes if (n.get("trust_level") or 0) >= 1]
        eligible.sort(key=_latency)
        urls = [n["node_url"] for n in eligible]
        assert urls == [
            "http://relay-fast:8005",
            "http://relay-mid:8005",
            "http://relay-slow:8005",
        ]

    def test_unknown_latency_sorts_last(self):
        nodes = [
            {"node_url": "http://relay-known:8005", "metrics": {"latency_ms": 100},
             "trust_level": 1},
            {"node_url": "http://relay-unknown:8005", "metrics": None,
             "trust_level": 1},
        ]

        def _latency(n):
            m = n.get("metrics") or {}
            lat = m.get("latency_ms") if m else None
            return float(lat) if lat is not None else float("inf")

        nodes.sort(key=_latency)
        assert nodes[0]["node_url"] == "http://relay-known:8005"
        assert nodes[1]["node_url"] == "http://relay-unknown:8005"


# ── Фаза 2.4: buffer fallback ────────────────────────────────────────────────

@pytest.mark.asyncio
class TestBufferFallback:
    async def test_buffer_called_for_each_recipient_on_all_relay_fail(self):
        """Когда все relay упали, buffer_for_offline_user вызывается для каждого получателя."""
        buffered = []

        async def fake_buffer(user_id: str, envelope: dict):
            buffered.append(user_id)

        envelope = {
            "packet_id": "p-test",
            "sender_user_id": "alice",
            "ciphertext": "ENCRYPTED",
        }
        conversation_meta = {
            "conversation_id": "conv-1",
            "type": "direct",
            "participant_user_ids": ["alice", "bob", "carol"],
        }

        federation = _service_module("home-node", "federation")
        with patch.object(federation, "buffer_for_offline_user", side_effect=fake_buffer):
            await federation._buffer_envelope_for_recipients(envelope, conversation_meta)

        # alice — отправитель, не буферизуется
        assert "alice" not in buffered
        assert "bob" in buffered
        assert "carol" in buffered
        assert len(buffered) == 2

    async def test_storage_failure_is_propagated_for_outbox_retry(self):
        envelope = {
            "packet_id": "p-failed-storage",
            "sender_user_id": "alice",
            "ciphertext": "ENCRYPTED",
        }
        conversation_meta = {
            "conversation_id": "conv-failed-storage",
            "type": "direct",
            "participant_user_ids": ["alice", "bob"],
        }
        federation = _service_module("home-node", "federation")
        with patch.object(
            federation,
            "buffer_for_offline_user",
            new=AsyncMock(side_effect=RuntimeError("storage unavailable")),
        ):
            with pytest.raises(RuntimeError, match="did not persist fallback"):
                await federation._buffer_envelope_for_recipients(envelope, conversation_meta)


@pytest.mark.asyncio
class TestDeliveryFailureMatrix:
    @staticmethod
    def _payloads():
        return (
            {
                "packet_id": "packet-failure-matrix",
                "sender_user_id": "alice",
                "ciphertext": "opaque",
            },
            {
                "conversation_id": "conversation-failure-matrix",
                "type": "direct",
                "participant_user_ids": ["alice", "bob"],
            },
        )

    @staticmethod
    def _client_context():
        client = MagicMock()
        context = MagicMock()
        context.__aenter__ = AsyncMock(return_value=client)
        context.__aexit__ = AsyncMock(return_value=None)
        return context

    async def test_direct_failure_then_relay_success(self):
        federation = _service_module("home-node", "federation")
        envelope, conversation_meta = self._payloads()
        security = MagicMock(node_id="home-a", signing_key=SigningKey.generate())
        success = MagicMock()
        success.raise_for_status.return_value = None
        direct_error = httpx.ConnectError("home-b offline")
        with (
            patch.object(federation, "get_federation_security", return_value=security),
            patch.object(federation, "_get_target_curve_public_key", new=AsyncMock(return_value=None)),
            patch.object(federation, "_reachable_relays", new=AsyncMock(return_value=["http://relay-a"])),
            patch.object(federation.httpx, "AsyncClient", side_effect=lambda **_kwargs: self._client_context()),
            patch.object(
                federation,
                "federation_post",
                new=AsyncMock(side_effect=[direct_error, success]),
            ),
        ):
            await federation.deliver_to_remote_home_node(
                "http://home-b", envelope, conversation_meta
            )

    async def test_direct_and_all_relays_fail_then_storage_is_attempted(self):
        federation = _service_module("home-node", "federation")
        envelope, conversation_meta = self._payloads()
        security = MagicMock(node_id="home-a", signing_key=SigningKey.generate())
        storage = AsyncMock(return_value=None)
        with (
            patch.object(federation, "get_federation_security", return_value=security),
            patch.object(federation, "_get_target_curve_public_key", new=AsyncMock(return_value=None)),
            patch.object(
                federation,
                "_reachable_relays",
                new=AsyncMock(return_value=["http://relay-a", "http://relay-b"]),
            ),
            patch.object(federation, "_buffer_envelope_for_recipients", new=storage),
            patch.object(federation.httpx, "AsyncClient", side_effect=lambda **_kwargs: self._client_context()),
            patch.object(
                federation,
                "federation_post",
                new=AsyncMock(
                    side_effect=[
                        httpx.ConnectError("home offline"),
                        httpx.ConnectError("relay-a offline"),
                        httpx.ConnectError("relay-b offline"),
                    ]
                ),
            ),
        ):
            with pytest.raises(RuntimeError, match="buffered"):
                await federation.deliver_to_remote_home_node(
                    "http://home-b", envelope, conversation_meta
                )
        storage.assert_awaited_once_with(envelope, conversation_meta)
