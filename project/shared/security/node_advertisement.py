"""Signed OUO NodeAdvertisement v1 primitives."""

import copy
import hashlib
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import urlsplit

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import public_key_b64, sign_message, verify_message
from shared.security.node_identity import validate_operational_certificate


PROTOCOL_VERSION = "ouo-node-advertisement/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/NODE_ADVERTISEMENT/v1\x00"
MAX_LIFETIME = timedelta(hours=24)
CLOCK_SKEW = timedelta(minutes=5)
ALLOWED_TRANSPORTS = frozenset({"https", "wss", "quic"})
ALLOWED_ENDPOINT_SCHEMES = frozenset({"http", "https", "ws", "wss"})
_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "advertisement_id",
    "node_id",
    "operational_certificate",
    "endpoints",
    "supported_transports",
    "supported_protocols",
    "epoch",
    "issued_at",
    "expires_at",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class AdvertisementValidation:
    valid: bool
    reason: Optional[str] = None


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def advertisement_signing_payload(advertisement: Mapping[str, Any]) -> bytes:
    unsigned = {field: advertisement[field] for field in _UNSIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(unsigned).encode("utf-8")


def node_advertisement_hash(advertisement: Mapping[str, Any]) -> str:
    """Return the content address of the complete signed advertisement."""
    return hashlib.sha256(canonical_json(dict(advertisement)).encode("utf-8")).hexdigest()


def issue_node_advertisement(
    *,
    operational_signing_key: SigningKey,
    operational_certificate: Mapping[str, Any],
    endpoints: Sequence[str],
    supported_transports: Sequence[str],
    supported_protocols: Sequence[str],
    epoch: int,
    issued_at: datetime,
    expires_at: datetime,
    advertisement_id: Optional[str] = None,
) -> dict[str, Any]:
    if public_key_b64(operational_signing_key) != operational_certificate.get(
        "operational_public_key"
    ):
        raise ValueError("operational key does not match certificate")
    advertisement = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "advertisement_id": advertisement_id or str(uuid.uuid4()),
        "node_id": operational_certificate.get("node_id"),
        "operational_certificate": copy.deepcopy(dict(operational_certificate)),
        "endpoints": sorted(endpoints),
        "supported_transports": sorted(supported_transports),
        "supported_protocols": sorted(supported_protocols),
        "epoch": epoch,
        "issued_at": _utc_iso(issued_at),
        "expires_at": _utc_iso(expires_at),
    }
    advertisement["signature"] = sign_message(
        operational_signing_key, advertisement_signing_payload(advertisement)
    )
    return advertisement


def _validate_endpoint(endpoint: Any) -> bool:
    if not isinstance(endpoint, str) or not endpoint or len(endpoint) > 2048:
        return False
    parsed = urlsplit(endpoint)
    return bool(
        parsed.scheme in ALLOWED_ENDPOINT_SCHEMES
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def validate_node_advertisement(
    advertisement: Mapping[str, Any],
    *,
    now: datetime,
    minimum_epoch: int = 0,
) -> AdvertisementValidation:
    if not isinstance(advertisement, Mapping) or set(advertisement) != _ALL_FIELDS:
        return AdvertisementValidation(False, "invalid advertisement fields")
    if advertisement.get("protocol_version") != PROTOCOL_VERSION:
        return AdvertisementValidation(False, "unsupported protocol_version")
    if advertisement.get("object_version") != OBJECT_VERSION:
        return AdvertisementValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(advertisement["advertisement_id"])) != advertisement["advertisement_id"]:
            return AdvertisementValidation(False, "invalid advertisement_id")
    except (AttributeError, TypeError, ValueError):
        return AdvertisementValidation(False, "invalid advertisement_id")
    endpoints = advertisement.get("endpoints")
    if (
        not isinstance(endpoints, list)
        or not endpoints
        or len(endpoints) > 16
        or any(not isinstance(endpoint, str) for endpoint in endpoints)
        or endpoints != sorted(set(endpoints))
        or any(not _validate_endpoint(endpoint) for endpoint in endpoints)
    ):
        return AdvertisementValidation(False, "invalid endpoints")
    transports = advertisement.get("supported_transports")
    if (
        not isinstance(transports, list)
        or not transports
        or any(not isinstance(value, str) for value in transports)
        or transports != sorted(set(transports))
        or not set(transports).issubset(ALLOWED_TRANSPORTS)
    ):
        return AdvertisementValidation(False, "invalid supported_transports")
    protocols = advertisement.get("supported_protocols")
    if (
        not isinstance(protocols, list)
        or not protocols
        or len(protocols) > 32
        or any(not isinstance(value, str) or not value or len(value) > 128 for value in protocols)
        or protocols != sorted(set(protocols))
    ):
        return AdvertisementValidation(False, "invalid supported_protocols")
    epoch = advertisement.get("epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < minimum_epoch:
        return AdvertisementValidation(False, "invalid or stale advertisement epoch")
    if now.tzinfo is None or now.utcoffset() is None:
        return AdvertisementValidation(False, "validation time must be timezone-aware")

    certificate = advertisement.get("operational_certificate")
    if not isinstance(certificate, Mapping):
        return AdvertisementValidation(False, "operational certificate is required")
    certificate_validation = validate_operational_certificate(certificate, now=now)
    if not certificate_validation.valid:
        return AdvertisementValidation(
            False, f"invalid operational certificate: {certificate_validation.reason}"
        )
    if advertisement.get("node_id") != certificate.get("node_id"):
        return AdvertisementValidation(False, "advertisement NodeID does not match certificate")
    try:
        issued_at = _parse_time(advertisement["issued_at"])
        expires_at = _parse_time(advertisement["expires_at"])
        certificate_expiry = _parse_time(certificate["valid_until"])
    except (TypeError, ValueError):
        return AdvertisementValidation(False, "malformed advertisement time")
    lifetime = expires_at - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AdvertisementValidation(False, "invalid advertisement lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return AdvertisementValidation(False, "advertisement is not yet valid")
    if now_utc - CLOCK_SKEW > expires_at:
        return AdvertisementValidation(False, "advertisement has expired")
    if expires_at > certificate_expiry:
        return AdvertisementValidation(False, "advertisement outlives operational certificate")
    if not isinstance(advertisement.get("signature"), str) or not verify_message(
        certificate["operational_public_key"],
        advertisement_signing_payload(advertisement),
        advertisement["signature"],
    ):
        return AdvertisementValidation(False, "invalid operational signature")
    return AdvertisementValidation(True)
