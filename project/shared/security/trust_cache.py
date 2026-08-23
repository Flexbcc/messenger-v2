import asyncio
import os
import time
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlparse

import httpx

from shared.security.config import TRUST_CACHE_TTL_SECONDS
from shared.security.config import FEDERATION_CAPABILITY_MODE
from shared.security.node_identity import validate_operational_certificate
from shared.transport.route_builder import transport_candidate_commitment


INFRASTRUCTURE_CAPABILITIES = frozenset(
    {"relay", "storage", "discovery", "gateway", "turn", "media", "validator"}
)


class TrustCache:
    def __init__(self, discovery_url: str):
        self._discovery_url = discovery_url.rstrip("/")
        configured = os.environ.get("FEDERATION_DISCOVERY_URLS", "").strip()
        self._discovery_urls = tuple(
            dict.fromkeys(
                self._origin(value.strip())
                for value in configured.split(",")
                if value.strip()
            )
        )
        try:
            self._minimum_sources = int(
                os.environ.get("FEDERATION_MINIMUM_DISCOVERY_SOURCES", "2")
            )
        except ValueError as exc:
            raise RuntimeError(
                "FEDERATION_MINIMUM_DISCOVERY_SOURCES must be an integer"
            ) from exc
        if not 2 <= self._minimum_sources <= 16:
            raise RuntimeError(
                "FEDERATION_MINIMUM_DISCOVERY_SOURCES must be between 2 and 16"
            )
        if self._discovery_urls and len(self._discovery_urls) < self._minimum_sources:
            raise RuntimeError(
                "Federation quorum mode requires enough independent Discovery URLs"
            )
        self._entries: dict[str, dict] = {}
        self._fetched_at = 0.0
        self._refresh_lock = asyncio.Lock()

    @staticmethod
    def _origin(value: str) -> str:
        parsed = urlparse(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("Federation Discovery URL must be an http(s) origin")
        return value.rstrip("/")

    async def _fetch_peer_view(
        self, client: httpx.AsyncClient, origin: str
    ) -> tuple[str, list[dict]]:
        response = await client.get(
            f"{origin}/registry/node-advertisements/peer-view",
            params={"minimum_sources": 2},
        )
        response.raise_for_status()
        candidates = response.json().get("candidates")
        if not isinstance(candidates, list) or len(candidates) > 1000:
            raise ValueError("invalid Federation peer view")
        return origin, [item for item in candidates if isinstance(item, dict)]

    async def _refresh_quorum(self) -> dict[str, dict]:
        async with httpx.AsyncClient(
            timeout=5.0, follow_redirects=False, trust_env=False
        ) as client:
            results = await asyncio.gather(
                *(self._fetch_peer_view(client, origin) for origin in self._discovery_urls),
                return_exceptions=True,
            )
        variants: dict[str, dict[str, list[tuple[str, dict]]]] = {}
        for result in results:
            if isinstance(result, Exception):
                continue
            origin, candidates = result
            for candidate in candidates:
                node_id = candidate.get("node_id")
                if not isinstance(node_id, str):
                    continue
                try:
                    commitment = transport_candidate_commitment(candidate)
                except (TypeError, ValueError):
                    continue
                variants.setdefault(node_id, {}).setdefault(commitment, []).append(
                    (origin, candidate)
                )
        entries: dict[str, dict] = {}
        current = datetime.now(timezone.utc)
        for node_id, commitments in variants.items():
            agreed = [
                observations[0][1]
                for observations in commitments.values()
                if len({origin for origin, _item in observations})
                >= self._minimum_sources
            ]
            if len(agreed) != 1:
                continue
            candidate = agreed[0]
            certificate = candidate.get("operational_certificate")
            if not isinstance(certificate, dict):
                continue
            validation = validate_operational_certificate(certificate, now=current)
            if (
                not validation.valid
                or certificate.get("node_id") != node_id
                or candidate.get("validated") is not True
            ):
                continue
            try:
                deadlines = [
                    self._deadline(candidate["advertisement_expires_at"]),
                    self._deadline(candidate["observation_valid_until"]),
                    self._deadline(candidate["operational_valid_until"]),
                    self._deadline(candidate["capability_valid_until"]),
                    self._deadline(
                        candidate["transport_certificate"]["valid_until"]
                    ),
                ]
            except (KeyError, TypeError, ValueError):
                continue
            valid_until_unix = min(value.timestamp() for value in deadlines)
            if valid_until_unix <= current.timestamp():
                continue
            entries[node_id] = {
                "node_id": node_id,
                "node_url": candidate.get("endpoint"),
                "identity_node_id": node_id,
                "trust_status": "trusted",
                "node_identity_status": "valid",
                "signing_public_key": certificate.get("operational_public_key"),
                "capability_certificate_status": "valid",
                "certified_capabilities": candidate.get("capabilities", []),
                "certified_quotas": candidate.get("certified_quotas", {}),
                "capability_epoch": candidate.get("capability_epoch"),
                "certified_level": candidate.get("level"),
                "_valid_until_unix": valid_until_unix,
            }
        return entries

    @staticmethod
    def _deadline(value: object) -> datetime:
        if not isinstance(value, str):
            raise ValueError("signed peer deadline must be a string")
        parsed = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError("signed peer deadline must include timezone")
        return parsed.astimezone(timezone.utc)

    async def _refresh(self) -> None:
        now = time.time()
        if now - self._fetched_at < TRUST_CACHE_TTL_SECONDS:
            return
        async with self._refresh_lock:
            now = time.time()
            if now - self._fetched_at < TRUST_CACHE_TTL_SECONDS:
                return
            if self._discovery_urls:
                self._entries = await self._refresh_quorum()
                self._fetched_at = now
                return
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{self._discovery_url}/registry/nodes")
                resp.raise_for_status()
                nodes = resp.json().get("nodes", [])
            entries: dict[str, dict] = {}
            identity_conflicts: set[str] = set()
            for node in nodes:
                alias = node.get("node_id")
                if isinstance(alias, str) and alias:
                    entries[alias] = node
                identity = node.get("identity_node_id")
                if not isinstance(identity, str) or not identity:
                    continue
                existing = entries.get(identity)
                if existing is not None and existing is not node:
                    identity_conflicts.add(identity)
                    continue
                entries[identity] = node
            for identity in identity_conflicts:
                entries.pop(identity, None)
            self._entries = entries
            # Empty catalogs are valid negative cache entries and must not
            # cause one Discovery request per unknown NodeID.
            self._fetched_at = now

    async def get_node(self, node_id: str) -> Optional[dict]:
        await self._refresh()
        node = self._entries.get(node_id)
        if node is None:
            return None
        deadline = node.get("_valid_until_unix")
        if isinstance(deadline, (int, float)) and deadline <= time.time():
            self._entries.pop(node_id, None)
            return None
        return node

    async def is_trusted(self, node_id: str) -> bool:
        node = await self.get_node(node_id)
        if not node:
            return False
        return node.get("trust_status", "trusted") == "trusted"

    async def signing_public_key(self, node_id: str) -> Optional[str]:
        node = await self.get_node(node_id)
        if not node:
            return None
        return node.get("signing_public_key")

    async def has_capability(self, node_id: str, capability: str) -> bool:
        node = await self.get_node(node_id)
        if not node:
            return False
        if FEDERATION_CAPABILITY_MODE != "legacy":
            certified = node.get("certified_capabilities") or []
            if (
                node.get("capability_certificate_status") == "valid"
                and capability in certified
            ):
                return True
            if FEDERATION_CAPABILITY_MODE == "enforce" and capability in INFRASTRUCTURE_CAPABILITIES:
                return False
        caps = node.get("capabilities") or []
        return capability in caps

    async def capability_quotas(self, node_id: str) -> dict[str, int]:
        node = await self.get_node(node_id)
        if not node or node.get("capability_certificate_status") != "valid":
            return {}
        quotas = node.get("certified_quotas")
        if not isinstance(quotas, dict):
            return {}
        return {
            key: value
            for key, value in quotas.items()
            if isinstance(key, str)
            and isinstance(value, int)
            and not isinstance(value, bool)
            and value >= 0
        }
