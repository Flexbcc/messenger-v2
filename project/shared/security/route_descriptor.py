"""Endpoint-signed RouteDescriptor v1 primitives."""

import hashlib
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import urlsplit

from nacl.signing import SigningKey

from shared.security.bootstrap_record import user_id_from_identity_public_key
from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message


PROTOCOL_VERSION = "ouo-route-descriptor/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/ROUTE_DESCRIPTOR/v1\x00"
COMMITMENT_DOMAIN = b"OUO/ROUTE_COMMITMENT/v1\x00"
MAX_LIFETIME = timedelta(days=3)
CLOCK_SKEW = timedelta(minutes=5)
_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "descriptor_id",
    "user_id",
    "identity_version",
    "route_epoch",
    "ingress_set",
    "valid_from",
    "valid_until",
    "previous_hash",
    "next_descriptor_commitment",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}
_COMMITMENT_FIELDS = {
    "user_id",
    "identity_version",
    "route_epoch",
    "ingress_set",
    "valid_from",
    "valid_until",
}


@dataclass(frozen=True)
class RouteDescriptorValidation:
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


def route_descriptor_signing_payload(descriptor: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: descriptor[field] for field in _UNSIGNED_FIELDS}
    ).encode("utf-8")


def route_descriptor_hash(descriptor: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(descriptor)).encode("utf-8")).hexdigest()


def route_descriptor_commitment(descriptor: Mapping[str, Any]) -> str:
    payload = {field: descriptor[field] for field in _COMMITMENT_FIELDS}
    return hashlib.sha256(
        COMMITMENT_DOMAIN + canonical_json(payload).encode("utf-8")
    ).hexdigest()


def issue_route_descriptor(
    *,
    identity_signing_key: SigningKey,
    identity_version: int,
    route_epoch: int,
    ingress_set: Sequence[Mapping[str, str]],
    valid_from: datetime,
    valid_until: datetime,
    previous_hash: Optional[str] = None,
    next_descriptor_commitment: Optional[str] = None,
    descriptor_id: Optional[str] = None,
) -> dict[str, Any]:
    normalized_ingress = sorted(
        (dict(item) for item in ingress_set), key=lambda item: (item.get("node_id", ""), item.get("endpoint", ""))
    )
    descriptor = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "descriptor_id": descriptor_id or str(uuid.uuid4()),
        "user_id": user_id_from_identity_public_key(bytes(identity_signing_key.verify_key)),
        "identity_version": identity_version,
        "route_epoch": route_epoch,
        "ingress_set": normalized_ingress,
        "valid_from": _utc_iso(valid_from),
        "valid_until": _utc_iso(valid_until),
        "previous_hash": previous_hash,
        "next_descriptor_commitment": next_descriptor_commitment,
    }
    descriptor["signature"] = sign_message(
        identity_signing_key, route_descriptor_signing_payload(descriptor)
    )
    return descriptor


def _valid_hash(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, str) or len(value) != 64:
        return False
    try:
        int(value, 16)
        return value == value.lower()
    except ValueError:
        return False


def _valid_ingress(item: Any) -> bool:
    if not isinstance(item, Mapping) or set(item) != {"node_id", "endpoint", "transport"}:
        return False
    node_id = item.get("node_id")
    endpoint = item.get("endpoint")
    transport = item.get("transport")
    if not isinstance(node_id, str) or not node_id or len(node_id) > 128:
        return False
    if transport not in {"https", "wss"} or not isinstance(endpoint, str):
        return False
    parsed = urlsplit(endpoint)
    return bool(
        parsed.scheme == transport
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def validate_route_descriptor(
    descriptor: Mapping[str, Any],
    *,
    identity_public_key: str,
    expected_user_id: str,
    now: datetime,
    minimum_identity_version: int = 1,
    minimum_route_epoch: int = 0,
    allow_future: bool = False,
) -> RouteDescriptorValidation:
    if not isinstance(descriptor, Mapping) or set(descriptor) != _ALL_FIELDS:
        return RouteDescriptorValidation(False, "invalid descriptor fields")
    if descriptor.get("protocol_version") != PROTOCOL_VERSION:
        return RouteDescriptorValidation(False, "unsupported protocol_version")
    if descriptor.get("object_version") != OBJECT_VERSION:
        return RouteDescriptorValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(descriptor["descriptor_id"])) != descriptor["descriptor_id"]:
            return RouteDescriptorValidation(False, "invalid descriptor_id")
    except (AttributeError, TypeError, ValueError):
        return RouteDescriptorValidation(False, "invalid descriptor_id")
    try:
        import base64

        public_key = base64.b64decode(
            identity_public_key.encode("ascii"), altchars=b"-_", validate=True
        )
        derived_user_id = user_id_from_identity_public_key(public_key)
    except (TypeError, ValueError):
        return RouteDescriptorValidation(False, "invalid identity public key")
    if expected_user_id != derived_user_id or descriptor.get("user_id") != expected_user_id:
        return RouteDescriptorValidation(False, "descriptor identity mismatch")
    identity_version = descriptor.get("identity_version")
    route_epoch = descriptor.get("route_epoch")
    if (
        not isinstance(identity_version, int)
        or isinstance(identity_version, bool)
        or identity_version < minimum_identity_version
    ):
        return RouteDescriptorValidation(False, "invalid or stale identity_version")
    if (
        not isinstance(route_epoch, int)
        or isinstance(route_epoch, bool)
        or route_epoch < minimum_route_epoch
    ):
        return RouteDescriptorValidation(False, "invalid or stale route_epoch")
    ingress_set = descriptor.get("ingress_set")
    if (
        not isinstance(ingress_set, list)
        or not ingress_set
        or len(ingress_set) > 8
        or any(not _valid_ingress(item) for item in ingress_set)
        or ingress_set
        != sorted(ingress_set, key=lambda item: (item["node_id"], item["endpoint"]))
    ):
        return RouteDescriptorValidation(False, "invalid ingress_set")
    if not _valid_hash(descriptor.get("previous_hash")) or not _valid_hash(
        descriptor.get("next_descriptor_commitment")
    ):
        return RouteDescriptorValidation(False, "invalid chain commitment")
    if now.tzinfo is None or now.utcoffset() is None:
        return RouteDescriptorValidation(False, "validation time must be timezone-aware")
    try:
        valid_from = _parse_time(descriptor["valid_from"])
        valid_until = _parse_time(descriptor["valid_until"])
    except (KeyError, TypeError, ValueError):
        return RouteDescriptorValidation(False, "malformed descriptor time")
    lifetime = valid_until - valid_from
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return RouteDescriptorValidation(False, "invalid descriptor lifetime")
    now_utc = now.astimezone(timezone.utc)
    if not allow_future and now_utc + CLOCK_SKEW < valid_from:
        return RouteDescriptorValidation(False, "descriptor is not yet valid")
    if now_utc - CLOCK_SKEW > valid_until:
        return RouteDescriptorValidation(False, "descriptor has expired")
    if not isinstance(descriptor.get("signature"), str) or not verify_message(
        identity_public_key,
        route_descriptor_signing_payload(descriptor),
        descriptor["signature"],
    ):
        return RouteDescriptorValidation(False, "invalid identity signature")
    return RouteDescriptorValidation(True)


def validate_route_transition(
    current: Mapping[str, Any], next_descriptor: Mapping[str, Any]
) -> RouteDescriptorValidation:
    if next_descriptor.get("user_id") != current.get("user_id"):
        return RouteDescriptorValidation(False, "route user changed")
    if next_descriptor.get("identity_version") != current.get("identity_version"):
        return RouteDescriptorValidation(False, "route identity version changed")
    if next_descriptor.get("route_epoch") != current.get("route_epoch", -1) + 1:
        return RouteDescriptorValidation(False, "route epoch is not consecutive")
    if next_descriptor.get("previous_hash") != route_descriptor_hash(current):
        return RouteDescriptorValidation(False, "previous_hash mismatch")
    commitment = current.get("next_descriptor_commitment")
    if commitment and commitment != route_descriptor_commitment(next_descriptor):
        return RouteDescriptorValidation(False, "next descriptor commitment mismatch")
    return RouteDescriptorValidation(True)
