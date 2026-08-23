"""Validate signed FederationEnvelope on receiving nodes."""
from typing import Optional

from fastapi import HTTPException

from shared.security.audit_log import FederationAuditLog
from shared.security.config import ENVELOPE_NONCE_TTL_SECONDS, FEDERATION_ENVELOPE_MODE
from shared.security.federation_envelope import (
    envelope_mode_signed,
    validate_federation_fields,
    verify_federation_meta_signature,
)
from shared.security.metrics import metrics
from shared.security.nonce_store import NonceStore
from shared.security.trust_cache import TrustCache


def _mode_signed() -> bool:
    return FEDERATION_ENVELOPE_MODE == "signed"


async def verify_incoming_federation(
    *,
    federation: Optional[dict],
    envelope: dict,
    endpoint: str,
    trust_cache: TrustCache,
    nonce_store: NonceStore,
    audit: Optional[FederationAuditLog] = None,
    expected_origin_node_id: Optional[str] = None,
    conversation_meta: Optional[dict] = None,
    expected_target_node_id: Optional[str] = None,
    expected_recipient_user_id: Optional[str] = None,
    expected_ttl_seconds: Optional[int] = None,
    expected_routes: Optional[set[str]] = None,
    consume_nonce: bool = True,
) -> str:
    """
    Returns origin_node_id from federation block (or 'legacy').
    Raises HTTPException on failure.
    """
    if not _mode_signed():
        return expected_origin_node_id or federation.get("origin_node_id", "legacy") if federation else "legacy"

    if not federation:
        _audit_fail(audit, endpoint, "", "missing_federation", "Federation block required")
        metrics().capability_denied += 1
        raise HTTPException(status_code=400, detail="Federation envelope required")

    origin = federation.get("origin_node_id", "")
    packet_id = federation.get("packet_id", "")

    field_err = validate_federation_fields(
        federation,
        envelope=envelope,
        origin_node_id=expected_origin_node_id,
        conversation_meta=conversation_meta,
        expected_target_node_id=expected_target_node_id,
        expected_recipient_user_id=expected_recipient_user_id,
        expected_ttl_seconds=expected_ttl_seconds,
        expected_routes=expected_routes,
    )
    if field_err:
        _audit_fail(audit, endpoint, packet_id, origin, field_err)
        metrics().invalid_signature += 1
        raise HTTPException(status_code=400, detail=f"Invalid federation envelope: {field_err}")

    if not await trust_cache.is_trusted(origin):
        _audit_fail(audit, endpoint, packet_id, origin, "untrusted origin")
        metrics().untrusted_node += 1
        raise HTTPException(status_code=403, detail="Untrusted federation origin")

    pub = await trust_cache.signing_public_key(origin)
    if not pub or not verify_federation_meta_signature(pub, federation):
        _audit_fail(audit, endpoint, packet_id, origin, "invalid signature")
        metrics().invalid_signature += 1
        raise HTTPException(status_code=401, detail="Invalid federation envelope signature")

    nonce = federation.get("nonce", "")
    if consume_nonce:
        if not nonce_store.consume(f"env:{nonce}", origin, ENVELOPE_NONCE_TTL_SECONDS):
            _audit_fail(audit, endpoint, packet_id, origin, "replay")
            metrics().replay_rejected += 1
            raise HTTPException(status_code=403, detail="Federation envelope replay detected")

    if audit:
        audit.record(
            origin_node_id=origin,
            endpoint=endpoint,
            packet_id=packet_id,
            action="verify",
            result="ok",
        )
    return origin


def _audit_fail(
    audit: Optional[FederationAuditLog],
    endpoint: str,
    packet_id: str,
    origin: str,
    detail: str,
) -> None:
    if audit:
        audit.record(
            origin_node_id=origin or "unknown",
            endpoint=endpoint,
            packet_id=packet_id,
            action="verify",
            result="rejected",
            detail=detail,
        )
