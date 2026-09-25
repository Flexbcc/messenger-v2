"""Bounded schemas for traffic received from other Home nodes.

The signed federation hash authenticates bytes, but it does not make an
oversized or internally inconsistent payload safe to persist.  These models
keep the original dictionaries intact for signature verification while
rejecting malformed input at the HTTP boundary.
"""

import json
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from shared.security.media_id import validate_media_id


MAX_MESSAGE_CIPHERTEXT_CHARS = 192 * 1024
MAX_ENVELOPE_JSON_BYTES = 256 * 1024
MAX_FEDERATION_JSON_BYTES = 64 * 1024
MAX_DEVICE_ENVELOPES = 512
MAX_MEDIA_IDS = 256

_DELIVER_ENVELOPE_FIELDS = frozenset(
    {
        "packet_id",
        "type",
        "conversation_id",
        "sender_user_id",
        "sender_device_id",
        "sealed_sender_box",
        "crypto_version",
        "ciphertext",
        "content_type",
        "created_at",
        "device_envelopes",
        "media_node_url",
        "media_ids",
    }
)
_CONVERSATION_META_FIELDS = frozenset(
    {"conversation_id", "type", "name", "participant_user_ids"}
)


def _bounded_string(
    value: Any,
    field_name: str,
    *,
    minimum: int = 1,
    maximum: int = 128,
) -> str:
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        raise ValueError(
            f"{field_name} must contain between {minimum} and {maximum} characters"
        )
    return value


def _json_size(value: Any, field_name: str, maximum: int) -> None:
    try:
        size = len(
            json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            )
        )
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be JSON serializable") from exc
    if size > maximum:
        raise ValueError(f"{field_name} exceeds the maximum encoded size")


def _validate_federation(value: Optional[dict]) -> Optional[dict]:
    if value is not None:
        _json_size(value, "federation", MAX_FEDERATION_JSON_BYTES)
    return value


def _validate_envelope(value: dict) -> dict:
    if not isinstance(value, dict):
        raise ValueError("envelope must be an object")
    unknown = set(value) - _DELIVER_ENVELOPE_FIELDS
    if unknown:
        raise ValueError("envelope contains unsupported fields")
    required = {"packet_id", "type", "conversation_id", "ciphertext"}
    if not required.issubset(value):
        raise ValueError("envelope is missing required fields")

    _bounded_string(value["packet_id"], "packet_id")
    if value["type"] != "MESSAGE":
        raise ValueError("unsupported envelope type")
    _bounded_string(value["conversation_id"], "conversation_id")
    ciphertext = _bounded_string(
        value["ciphertext"],
        "ciphertext",
        maximum=MAX_MESSAGE_CIPHERTEXT_CHARS,
    )

    sender = value.get("sender_user_id")
    sealed_sender = value.get("sealed_sender_box")
    if bool(sender) == bool(sealed_sender):
        raise ValueError(
            "envelope must contain exactly one sender identity representation"
        )
    if sender is not None:
        _bounded_string(sender, "sender_user_id")
    if sealed_sender is not None:
        _bounded_string(sealed_sender, "sealed_sender_box", maximum=2048)

    for key, maximum in (
        ("sender_device_id", 128),
        ("crypto_version", 64),
        ("content_type", 32),
        ("created_at", 64),
        ("media_node_url", 255),
    ):
        if value.get(key) is not None:
            _bounded_string(value[key], key, maximum=maximum)

    device_envelopes = value.get("device_envelopes")
    if device_envelopes is not None:
        if not isinstance(device_envelopes, list) or len(device_envelopes) > MAX_DEVICE_ENVELOPES:
            raise ValueError("device_envelopes must be a bounded list")
        seen_devices: set[str] = set()
        total_ciphertext = len(ciphertext)
        for item in device_envelopes:
            if not isinstance(item, dict) or set(item) != {"device_id", "ciphertext"}:
                raise ValueError("invalid device envelope")
            device_id = _bounded_string(item["device_id"], "device_id")
            if device_id in seen_devices:
                raise ValueError("device envelope ids must be unique")
            seen_devices.add(device_id)
            per_device = _bounded_string(
                item["ciphertext"],
                "device ciphertext",
                maximum=MAX_MESSAGE_CIPHERTEXT_CHARS,
            )
            total_ciphertext += len(per_device)
        if total_ciphertext > MAX_MESSAGE_CIPHERTEXT_CHARS:
            raise ValueError("combined ciphertext is too large")

    media_ids = value.get("media_ids")
    if media_ids is not None:
        if not isinstance(media_ids, list) or len(media_ids) > MAX_MEDIA_IDS:
            raise ValueError("media_ids must be a bounded list")
        if len(media_ids) != len(set(media_ids)):
            raise ValueError("media_ids must be unique")
        for media_id in media_ids:
            validate_media_id(media_id)

    _json_size(value, "envelope", MAX_ENVELOPE_JSON_BYTES)
    return value


def _validate_conversation_meta(value: dict) -> dict:
    if not isinstance(value, dict) or set(value) != _CONVERSATION_META_FIELDS:
        raise ValueError("invalid conversation_meta fields")
    _bounded_string(value.get("conversation_id"), "conversation_id")
    if value.get("type") not in {"direct", "group"}:
        raise ValueError("unsupported conversation type")
    name = value.get("name")
    if name is not None:
        _bounded_string(name, "conversation name", maximum=256)
    participants = value.get("participant_user_ids")
    if not isinstance(participants, list) or not 2 <= len(participants) <= 256:
        raise ValueError("participant_user_ids must contain 2 to 256 users")
    if len(participants) != len(set(participants)):
        raise ValueError("participant_user_ids must be unique")
    for user_id in participants:
        _bounded_string(user_id, "participant_user_id")
    if value["type"] == "direct" and len(participants) != 2:
        raise ValueError("direct conversations must contain exactly two users")
    return value


class InternalDeliverRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    envelope: dict
    conversation_meta: dict
    origin_node_id: str = Field(min_length=1, max_length=128)
    forwarded_by_node_id: Optional[str] = Field(default=None, min_length=1, max_length=128)
    federation: Optional[dict] = None

    _envelope_validator = field_validator("envelope")(_validate_envelope)
    _conversation_validator = field_validator("conversation_meta")(
        _validate_conversation_meta
    )
    _federation_validator = field_validator("federation")(_validate_federation)

    @model_validator(mode="after")
    def validate_cross_field_consistency(self) -> "InternalDeliverRequest":
        if self.envelope["conversation_id"] != self.conversation_meta["conversation_id"]:
            raise ValueError("envelope and conversation metadata disagree")
        return self


class InternalDeliveryAckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    packet_id: str = Field(min_length=1, max_length=128)
    conversation_id: str = Field(min_length=1, max_length=128)
    from_user_id: str = Field(min_length=1, max_length=128)
    from_device_id: str = Field(default="", max_length=128)
    acked_at: str = Field(min_length=1, max_length=64)
    origin_node_id: str = Field(min_length=1, max_length=128)
    envelope: dict
    federation: Optional[dict] = None

    _federation_validator = field_validator("federation")(_validate_federation)

    @field_validator("envelope")
    @classmethod
    def validate_control_envelope(cls, value: dict) -> dict:
        _json_size(value, "envelope", MAX_FEDERATION_JSON_BYTES)
        return value


class HomeChangedRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    user_id: str = Field(min_length=1, max_length=128)
    home_node_url: str = Field(min_length=1, max_length=2048)
    home_updated_at: Optional[str] = Field(default=None, min_length=1, max_length=64)
    origin_node_id: str = Field(min_length=1, max_length=128)
    envelope: dict
    federation: Optional[dict] = None

    _federation_validator = field_validator("federation")(_validate_federation)

    @field_validator("envelope")
    @classmethod
    def validate_control_envelope(cls, value: dict) -> dict:
        _json_size(value, "envelope", MAX_FEDERATION_JSON_BYTES)
        return value
