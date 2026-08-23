"""Signed Discovery observation of an independently signed NodeAdvertisement."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-node-advertisement-observation/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/NODE_ADVERTISEMENT_OBSERVATION/v1\x00"
MAX_LIFETIME = timedelta(minutes=10)
CLOCK_SKEW = timedelta(minutes=2)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "observation_id",
    "source_node_id",
    "subject_node_id",
    "advertisement_epoch",
    "advertisement_hash",
    "observed_at",
    "expires_at",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class AdvertisementObservationValidation:
    valid: bool
    reason: str | None = None


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


def observation_signing_payload(observation: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: observation[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def issue_advertisement_observation(
    *,
    source_node_id: str,
    subject_node_id: str,
    advertisement_epoch: int,
    advertisement_hash: str,
    observed_at: datetime,
    expires_at: datetime,
    source_signing_key: SigningKey,
    observation_id: str | None = None,
) -> dict[str, Any]:
    if expires_at.astimezone(timezone.utc) - observed_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("advertisement observation lifetime exceeds ten minutes")
    observation = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "observation_id": observation_id or str(uuid.uuid4()),
        "source_node_id": source_node_id,
        "subject_node_id": subject_node_id,
        "advertisement_epoch": advertisement_epoch,
        "advertisement_hash": advertisement_hash,
        "observed_at": _utc_iso(observed_at),
        "expires_at": _utc_iso(expires_at),
    }
    observation["signature"] = sign_message(
        source_signing_key, observation_signing_payload(observation)
    )
    return observation


def validate_advertisement_observation(
    observation: Mapping[str, Any],
    *,
    now: datetime,
    expected_subject_node_id: str,
    expected_advertisement_epoch: int,
    expected_advertisement_hash: str,
    source_credential: ValidatorCredential,
) -> AdvertisementObservationValidation:
    if not isinstance(observation, Mapping) or set(observation) != _ALL_FIELDS:
        return AdvertisementObservationValidation(False, "invalid observation fields")
    if observation.get("protocol_version") != PROTOCOL_VERSION:
        return AdvertisementObservationValidation(False, "unsupported protocol_version")
    if observation.get("object_version") != OBJECT_VERSION:
        return AdvertisementObservationValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(observation["observation_id"])) != observation["observation_id"]:
            return AdvertisementObservationValidation(False, "invalid observation_id")
    except (AttributeError, TypeError, ValueError):
        return AdvertisementObservationValidation(False, "invalid observation_id")
    source_node_id = observation.get("source_node_id")
    if not isinstance(source_node_id, str) or not source_node_id.startswith(NODE_ID_PREFIX):
        return AdvertisementObservationValidation(False, "invalid source_node_id")
    if observation.get("subject_node_id") != expected_subject_node_id:
        return AdvertisementObservationValidation(False, "observation subject mismatch")
    epoch = observation.get("advertisement_epoch")
    if (
        not isinstance(epoch, int)
        or isinstance(epoch, bool)
        or epoch != expected_advertisement_epoch
    ):
        return AdvertisementObservationValidation(False, "observation advertisement_epoch mismatch")
    digest = observation.get("advertisement_hash")
    if (
        not isinstance(digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        or digest != expected_advertisement_hash
    ):
        return AdvertisementObservationValidation(False, "observation advertisement_hash mismatch")
    if not isinstance(observation.get("signature"), str):
        return AdvertisementObservationValidation(False, "invalid observation signature encoding")
    if now.tzinfo is None or now.utcoffset() is None:
        return AdvertisementObservationValidation(False, "validation time must be timezone-aware")
    try:
        observed_at = _parse_time(observation["observed_at"])
        expires_at = _parse_time(observation["expires_at"])
    except (TypeError, ValueError):
        return AdvertisementObservationValidation(False, "malformed observation time")
    lifetime = expires_at - observed_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AdvertisementObservationValidation(False, "invalid observation lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < observed_at:
        return AdvertisementObservationValidation(False, "observation is from the future")
    if now_utc - CLOCK_SKEW > expires_at:
        return AdvertisementObservationValidation(False, "observation has expired")
    if source_credential.revoked:
        return AdvertisementObservationValidation(False, "source credential is revoked")
    if (
        source_credential.valid_until.tzinfo is None
        or source_credential.valid_until.utcoffset() is None
        or source_credential.valid_until.astimezone(timezone.utc) < now_utc
    ):
        return AdvertisementObservationValidation(False, "source credential has expired")
    if not verify_message(
        source_credential.public_key,
        observation_signing_payload(observation),
        observation["signature"],
    ):
        return AdvertisementObservationValidation(False, "invalid source observation signature")
    return AdvertisementObservationValidation(True)
