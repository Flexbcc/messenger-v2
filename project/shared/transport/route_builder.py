"""Local, bounded and diversity-aware construction of onion hop routes."""

from __future__ import annotations

import base64
import ipaddress
import secrets
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping, Sequence
from urllib.parse import urlparse

from shared.security.canonical import canonical_json
from shared.security.transport_certificate import validate_transport_certificate
from shared.transport.onion_provider import OnionHop

MIN_RELAY_HOPS = 2
MAX_RELAY_HOPS = 4
MAX_HOPS = 5
TRANSPORT_CONSENSUS_FIELDS = {
    "node_id",
    "endpoint",
    "capabilities",
    "certified_quotas",
    "validated",
    "advertisement_epoch",
    "advertisement_expires_at",
    "observation_valid_until",
    "operational_certificate",
    "operational_valid_until",
    "capability_epoch",
    "capability_valid_until",
    "level",
    "transport_certificate",
}


@dataclass(frozen=True)
class TransportPeer:
    node_id: str
    endpoint: str
    transport_public_key: bytes
    network_group: str
    capabilities: tuple[str, ...]


def transport_candidate_commitment(candidate: Mapping[str, Any]) -> str:
    """Compare security state while allowing each Discovery's observer list."""
    if not isinstance(candidate, Mapping):
        raise ValueError("invalid transport candidate")
    if not TRANSPORT_CONSENSUS_FIELDS.issubset(candidate):
        raise ValueError("incomplete transport candidate")
    return canonical_json(
        {field: candidate[field] for field in TRANSPORT_CONSENSUS_FIELDS}
    )


def _network_group(endpoint: str) -> str:
    parsed = urlparse(endpoint)
    if parsed.scheme not in {"https", "wss"} or not parsed.hostname:
        raise ValueError("transport peer endpoint must use https or wss")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        labels = parsed.hostname.lower().rstrip(".").split(".")
        return ".".join(labels[-2:]) if len(labels) >= 2 else labels[0]
    prefix = 24 if address.version == 4 else 48
    return str(ipaddress.ip_network(f"{address}/{prefix}", strict=False))


def eligible_transport_peers(
    records: Sequence[Mapping[str, Any]],
    *,
    now: datetime,
    required_capability: str = "relay",
) -> tuple[TransportPeer, ...]:
    peers: list[TransportPeer] = []
    seen_nodes: set[str] = set()
    for record in records:
        node_id = record.get("identity_node_id")
        certificate = record.get("transport_certificate")
        capabilities = record.get("certified_capabilities", [])
        endpoints = record.get("advertised_endpoints", [])
        if (
            not isinstance(node_id, str)
            or node_id in seen_nodes
            or record.get("trust_status") != "trusted"
            or record.get("reachability") != "online"
            or record.get("transport_certificate_status") != "valid"
            or not isinstance(capabilities, list)
            or any(not isinstance(value, str) for value in capabilities)
            or capabilities != sorted(set(capabilities))
            or required_capability not in capabilities
            or not isinstance(endpoints, list)
            or not endpoints
            or not isinstance(certificate, Mapping)
        ):
            continue
        validation = validate_transport_certificate(
            certificate, now=now, expected_node_id=node_id
        )
        if not validation.valid:
            continue
        try:
            key = base64.b64decode(
                certificate["transport_public_key"], altchars=b"-_", validate=True
            )
            endpoint = endpoints[0]
            group = _network_group(endpoint)
        except (KeyError, TypeError, ValueError):
            continue
        if len(key) != 32:
            continue
        peers.append(
            TransportPeer(
                node_id,
                endpoint,
                key,
                group,
                tuple(sorted(set(capabilities))),
            )
        )
        seen_nodes.add(node_id)
    return tuple(peers)


def eligible_gossip_transport_peers(
    candidates: Sequence[Mapping[str, Any]],
    *,
    now: datetime,
    allowed_capabilities: Sequence[str] = ("relay",),
) -> tuple[TransportPeer, ...]:
    """Consume the independent-source peer-view shape from Discovery gossip."""
    allowed = set(allowed_capabilities)
    if not allowed or not allowed.issubset({"relay", "home"}):
        raise ValueError("invalid transport capability allowlist")
    peers: list[TransportPeer] = []
    seen: set[str] = set()
    for candidate in candidates:
        node_id = candidate.get("node_id")
        endpoint = candidate.get("endpoint")
        certificate = candidate.get("transport_certificate")
        candidate_capabilities = candidate.get("capabilities")
        if (
            candidate.get("validated") is not True
            or not isinstance(node_id, str)
            or node_id in seen
            or not isinstance(endpoint, str)
            or not isinstance(candidate_capabilities, list)
            or any(not isinstance(value, str) for value in candidate_capabilities)
            or candidate_capabilities != sorted(set(candidate_capabilities))
            or not allowed.intersection(candidate_capabilities)
            or not isinstance(certificate, Mapping)
        ):
            continue
        validation = validate_transport_certificate(
            certificate, now=now, expected_node_id=node_id
        )
        if not validation.valid:
            continue
        try:
            key = base64.b64decode(
                certificate["transport_public_key"], altchars=b"-_", validate=True
            )
            group = _network_group(endpoint)
        except (KeyError, TypeError, ValueError):
            continue
        if len(key) != 32:
            continue
        capabilities = tuple(candidate_capabilities)
        peers.append(TransportPeer(node_id, endpoint, key, group, capabilities))
        seen.add(node_id)
    return tuple(peers)


def choose_route(
    candidates: Sequence[TransportPeer],
    *,
    hop_count: int = 3,
    excluded_node_ids: Sequence[str] = (),
) -> tuple[TransportPeer, ...]:
    if not MIN_RELAY_HOPS <= hop_count <= MAX_RELAY_HOPS:
        raise ValueError(
            f"Relay hop_count must be between {MIN_RELAY_HOPS} and {MAX_RELAY_HOPS}"
        )
    excluded = set(excluded_node_ids)
    available = [peer for peer in candidates if peer.node_id not in excluded]
    if len(available) < hop_count:
        raise ValueError("insufficient eligible transport peers")
    selected: list[TransportPeer] = []
    used_groups: set[str] = set()
    while len(selected) < hop_count:
        diverse = [peer for peer in available if peer.network_group not in used_groups]
        pool = diverse or available
        peer = secrets.choice(pool)
        selected.append(peer)
        used_groups.add(peer.network_group)
        available = [item for item in available if item.node_id != peer.node_id]
    return tuple(selected)


def onion_hops(route: Sequence[TransportPeer]) -> tuple[OnionHop, ...]:
    if not 2 <= len(route) <= MAX_HOPS:
        raise ValueError("complete onion route must contain 2-5 hops")
    built: list[OnionHop] = []
    for index, peer in enumerate(route):
        expected = "home" if index == len(route) - 1 else "relay"
        if expected not in peer.capabilities:
            raise ValueError(f"onion hop lacks required {expected} capability")
        built.append(
            OnionHop(
                node_id=peer.node_id,
                public_key=peer.transport_public_key,
                capability=expected,
            )
        )
    hops = tuple(built)
    return hops
