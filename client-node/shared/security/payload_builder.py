"""Build wire payloads with optional signed FederationEnvelope."""
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
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "target_home_node_url": target_home_node_url,
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
