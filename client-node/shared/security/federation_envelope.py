"""Signed FederationEnvelope wrapper around client envelope (Phase B / P2)."""
import hashlib
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.config import ENVELOPE_DEFAULT_TTL_SECONDS, FEDERATION_ENVELOPE_MODE
from shared.security.keys import public_key_b64, sign_message, verify_message


def envelope_mode_signed() -> bool:
    return FEDERATION_ENVELOPE_MODE == "signed"


def ciphertext_hash(envelope: dict) -> str:
    ciphertext = envelope.get("ciphertext", "")
    raw = ciphertext.encode("utf-8") if isinstance(ciphertext, str) else bytes(ciphertext)
    return hashlib.sha256(raw).hexdigest()


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
    ttl_seconds: int = ENVELOPE_DEFAULT_TTL_SECONDS,
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    expires = now + timedelta(seconds=ttl_seconds)
    conv_id = conversation_id or envelope.get("conversation_id") or ""
    return {
        "packet_id": envelope["packet_id"],
        "origin_node_id": origin_node_id,
        "target_node_id": target_node_id,
        "sender_user_id": envelope.get("sender_user_id", ""),
        "recipient_user_id": recipient_user_id,
        "conversation_id": conv_id,
        "ciphertext_hash": ciphertext_hash(envelope),
        "created_at": _now_iso(),
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
    ttl_seconds: int = ENVELOPE_DEFAULT_TTL_SECONDS,
) -> dict[str, Any]:
    meta = build_federation_meta(
        origin_node_id=origin_node_id,
        envelope=envelope,
        route=route,
        target_node_id=target_node_id,
        recipient_user_id=recipient_user_id,
        conversation_id=conversation_id,
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
) -> Optional[str]:
    """Returns error detail string, or None if valid."""
    if federation.get("packet_id") != envelope.get("packet_id"):
        return "packet_id mismatch"

    if origin_node_id and federation.get("origin_node_id") != origin_node_id:
        return "origin_node_id mismatch"

    if federation.get("ciphertext_hash") != ciphertext_hash(envelope):
        return "ciphertext_hash mismatch"

    expires_at = federation.get("expires_at")
    if expires_at:
        try:
            if datetime.now(timezone.utc) > _parse_iso(expires_at):
                return "envelope expired"
        except ValueError:
            return "invalid expires_at"

    return None
