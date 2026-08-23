"""Signed FederationEnvelope wrapper around client envelope (Phase B / P2)."""
import hashlib
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.config import ENVELOPE_DEFAULT_TTL_SECONDS, FEDERATION_ENVELOPE_MODE
from shared.security.keys import public_key_b64, sign_message, verify_message


PROTOCOL_VERSION = "ouo-federation-envelope/1"
MAX_TTL_SECONDS = 60 * 60 * 24 * 30
ROUTES = frozenset({"direct", "relay", "buffer", "control"})
FEDERATION_META_FIELDS = {
    "protocol_version",
    "packet_id",
    "origin_node_id",
    "target_node_id",
    "sender_user_id",
    "recipient_user_id",
    "conversation_id",
    "ciphertext_hash",
    "envelope_hash",
    "conversation_meta_hash",
    "created_at",
    "expires_at",
    "ttl_seconds",
    "route",
    "nonce",
    "signature",
}


def envelope_mode_signed() -> bool:
    return FEDERATION_ENVELOPE_MODE == "signed"


def ciphertext_hash(envelope: dict) -> str:
    ciphertext = envelope.get("ciphertext", "")
    raw = ciphertext.encode("utf-8") if isinstance(ciphertext, str) else bytes(ciphertext)
    return hashlib.sha256(raw).hexdigest()


def envelope_hash(envelope: dict) -> str:
    return hashlib.sha256(canonical_json(envelope).encode("utf-8")).hexdigest()


def conversation_meta_hash(conversation_meta: Optional[dict]) -> str:
    if conversation_meta is None:
        return ""
    return hashlib.sha256(canonical_json(conversation_meta).encode("utf-8")).hexdigest()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_federation_meta(
    *,
    origin_node_id: str,
    envelope: dict,
    route: str = "direct",
    target_node_id: str = "",
    recipient_user_id: str = "",
    conversation_id: str = "",
    conversation_meta: Optional[dict] = None,
    ttl_seconds: int = ENVELOPE_DEFAULT_TTL_SECONDS,
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    expires = now + timedelta(seconds=ttl_seconds)
    conv_id = conversation_id or envelope.get("conversation_id") or ""
    return {
        "protocol_version": PROTOCOL_VERSION,
        "packet_id": envelope["packet_id"],
        "origin_node_id": origin_node_id,
        "target_node_id": target_node_id,
        "sender_user_id": envelope.get("sender_user_id", ""),
        "recipient_user_id": recipient_user_id,
        "conversation_id": conv_id,
        "ciphertext_hash": ciphertext_hash(envelope),
        "envelope_hash": envelope_hash(envelope),
        "conversation_meta_hash": conversation_meta_hash(conversation_meta),
        "created_at": now.isoformat().replace("+00:00", "Z"),
        "expires_at": expires.isoformat().replace("+00:00", "Z"),
        "ttl_seconds": ttl_seconds,
        "route": route,
        "nonce": str(uuid.uuid4()),
    }


def sign_federation_meta(signing_key: SigningKey, meta: dict[str, Any]) -> dict[str, Any]:
    signed = dict(meta)
    message = canonical_json({k: v for k, v in signed.items() if k != "signature"}).encode()
    signed["signature"] = sign_message(signing_key, message)
    return signed


def build_signed_federation_meta(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    envelope: dict,
    route: str = "direct",
    target_node_id: str = "",
    recipient_user_id: str = "",
    conversation_id: str = "",
    conversation_meta: Optional[dict] = None,
    ttl_seconds: int = ENVELOPE_DEFAULT_TTL_SECONDS,
) -> dict[str, Any]:
    meta = build_federation_meta(
        origin_node_id=origin_node_id,
        envelope=envelope,
        route=route,
        target_node_id=target_node_id,
        recipient_user_id=recipient_user_id,
        conversation_id=conversation_id,
        conversation_meta=conversation_meta,
        ttl_seconds=ttl_seconds,
    )
    return sign_federation_meta(signing_key, meta)


def build_buffer_federation_meta(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    recipient_device_id: str,
    envelope: dict,
    ttl_seconds: int,
) -> dict[str, Any]:
    meta = build_federation_meta(
        origin_node_id=origin_node_id,
        envelope=envelope,
        route="buffer",
        recipient_user_id=recipient_device_id,
        ttl_seconds=ttl_seconds,
    )
    return sign_federation_meta(signing_key, meta)


def verify_federation_meta_signature(public_key_b64: str, federation: dict[str, Any]) -> bool:
    if not federation.get("signature"):
        return False
    unsigned = {k: v for k, v in federation.items() if k != "signature"}
    message = canonical_json(unsigned).encode()
    return verify_message(public_key_b64, message, federation["signature"])


def _parse_iso(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def validate_federation_fields(
    federation: dict[str, Any],
    *,
    envelope: dict,
    origin_node_id: Optional[str] = None,
    conversation_meta: Optional[dict] = None,
    expected_target_node_id: Optional[str] = None,
    expected_recipient_user_id: Optional[str] = None,
    expected_ttl_seconds: Optional[int] = None,
    expected_routes: Optional[set[str]] = None,
) -> Optional[str]:
    """Returns error detail string, or None if valid."""
    if set(federation) != FEDERATION_META_FIELDS:
        return "invalid federation metadata fields"
    if federation.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported federation protocol_version"
    if federation.get("packet_id") != envelope.get("packet_id"):
        return "packet_id mismatch"

    if origin_node_id and federation.get("origin_node_id") != origin_node_id:
        return "origin_node_id mismatch"

    if federation.get("ciphertext_hash") != ciphertext_hash(envelope):
        return "ciphertext_hash mismatch"

    if federation.get("envelope_hash") != envelope_hash(envelope):
        return "envelope_hash mismatch"

    if federation.get("conversation_meta_hash") != conversation_meta_hash(conversation_meta):
        return "conversation_meta_hash mismatch"

    if expected_target_node_id is not None:
        actual_target = str(federation.get("target_node_id", "")).rstrip("/")
        if actual_target != expected_target_node_id.rstrip("/"):
            return "target_node_id mismatch"

    if (
        expected_recipient_user_id is not None
        and federation.get("recipient_user_id") != expected_recipient_user_id
    ):
        return "recipient_user_id mismatch"

    ttl_seconds = federation.get("ttl_seconds")
    if (
        not isinstance(ttl_seconds, int)
        or isinstance(ttl_seconds, bool)
        or not 1 <= ttl_seconds <= MAX_TTL_SECONDS
    ):
        return "invalid ttl_seconds"
    if expected_ttl_seconds is not None and ttl_seconds != expected_ttl_seconds:
        return "ttl_seconds mismatch"

    route = federation.get("route")
    if route not in ROUTES:
        return "invalid route"
    if expected_routes is not None and route not in expected_routes:
        return "unexpected route"

    nonce = federation.get("nonce")
    try:
        uuid.UUID(nonce)
    except (AttributeError, TypeError, ValueError):
        return "invalid nonce"

    created_at = federation.get("created_at")
    expires_at = federation.get("expires_at")
    try:
        created = _parse_iso(created_at)
        expires = _parse_iso(expires_at)
        if created.tzinfo is None or expires.tzinfo is None:
            return "federation timestamps must include timezone"
        if abs((expires - created).total_seconds() - ttl_seconds) > 1:
            return "expiry does not match ttl_seconds"
        if datetime.now(timezone.utc) > expires:
            return "envelope expired"
    except (TypeError, ValueError):
        return "invalid federation timestamps"

    return None
