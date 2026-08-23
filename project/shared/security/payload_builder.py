"""Build wire payloads with optional signed FederationEnvelope."""
import uuid
from typing import Any, Optional

from nacl.signing import SigningKey

from shared.security.federation_envelope import (
    build_buffer_federation_meta,
    build_signed_federation_meta,
    envelope_mode_signed,
)


def build_deliver_payload(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    envelope: dict,
    conversation_meta: dict,
    route: str = "direct",
    target_node_id: str = "",
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "origin_node_id": origin_node_id,
    }
    if envelope_mode_signed():
        payload["federation"] = build_signed_federation_meta(
            signing_key=signing_key,
            origin_node_id=origin_node_id,
            envelope=envelope,
            route=route,
            target_node_id=target_node_id,
            conversation_id=conversation_meta.get("conversation_id", ""),
            conversation_meta=conversation_meta,
        )
    return payload


def build_relay_forward_payload(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    envelope: dict,
    conversation_meta: dict,
    target_home_node_url: str,
    federation: Optional[dict] = None,
    hop_count: int = 1,
) -> dict[str, Any]:
    """Build a relay-forward packet.

    hop_count tracks how many relay hops have already been taken so relay-nodes
    can enforce MAX_HOPS (currently 2) and prevent loops:
      1 = first relay hop (home-node → L1 relay)
      2 = second relay hop (L1 relay → L2 hub)
    Relay-nodes MUST NOT forward further if hop_count >= MAX_HOPS.
    """
    payload: dict[str, Any] = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "target_home_node_url": target_home_node_url,
        "hop_count": hop_count,
    }
    if federation is not None:
        payload["federation"] = federation
    elif envelope_mode_signed():
        payload["federation"] = build_signed_federation_meta(
            signing_key=signing_key,
            origin_node_id=origin_node_id,
            envelope=envelope,
            route="relay",
            target_node_id=target_home_node_url,
            conversation_id=conversation_meta.get("conversation_id", ""),
            conversation_meta=conversation_meta,
        )
    return payload


def build_home_changed_payload(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    user_id: str,
    new_home_node_url: str,
    home_updated_at: Optional[str],
    target_node_id: str = "",
) -> dict[str, Any]:
    """Post-R5 CONTROL notify (docs/reality/R4-routing.md Gaps "Нет notify
    смены Home"): same signed-envelope machinery as build_deliver_payload,
    but the "envelope" is synthetic (empty ciphertext, no conversation) —
    it only exists so the existing federation signature/replay checks apply
    to this control ping too, without leaking any chat content."""
    envelope = {"packet_id": str(uuid.uuid4()), "ciphertext": ""}
    payload: dict[str, Any] = {
        "user_id": user_id,
        "home_node_url": new_home_node_url,
        "home_updated_at": home_updated_at,
        "origin_node_id": origin_node_id,
        "envelope": envelope,
    }
    if envelope_mode_signed():
        payload["federation"] = build_signed_federation_meta(
            signing_key=signing_key,
            origin_node_id=origin_node_id,
            envelope=envelope,
            route="control",
            target_node_id=target_node_id,
            recipient_user_id=user_id,
        )
    return payload


def build_delivery_ack_payload(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    packet_id: str,
    conversation_id: str,
    from_user_id: str,
    acked_at: str,
    target_node_id: str = "",
) -> dict[str, Any]:
    """Post-R5 e2e delivery ACK (spec/0202_DELIVERY.md): same synthetic-envelope
    pattern as build_home_changed_payload — the "envelope" carries the real
    Message.id being acked as packet_id (so the signature binds to it) but
    empty ciphertext, since no chat content crosses this control path."""
    envelope = {"packet_id": packet_id, "ciphertext": ""}
    payload: dict[str, Any] = {
        "packet_id": packet_id,
        "conversation_id": conversation_id,
        "from_user_id": from_user_id,
        "acked_at": acked_at,
        "origin_node_id": origin_node_id,
        "envelope": envelope,
    }
    if envelope_mode_signed():
        payload["federation"] = build_signed_federation_meta(
            signing_key=signing_key,
            origin_node_id=origin_node_id,
            envelope=envelope,
            route="control",
            target_node_id=target_node_id,
            recipient_user_id=from_user_id,
            conversation_id=conversation_id,
        )
    return payload


def build_buffer_payload(
    *,
    signing_key: SigningKey,
    origin_node_id: str,
    recipient_device_id: str,
    envelope: dict,
    ttl_seconds: int,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "recipient_device_id": recipient_device_id,
        "envelope": envelope,
        "ttl_seconds": ttl_seconds,
    }
    if envelope_mode_signed():
        payload["federation"] = build_buffer_federation_meta(
            signing_key=signing_key,
            origin_node_id=origin_node_id,
            recipient_device_id=recipient_device_id,
            envelope=envelope,
            ttl_seconds=ttl_seconds,
        )
    return payload
