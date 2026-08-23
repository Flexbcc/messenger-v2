"""Signed privacy-minimized reliability observations for OUO Trust v1."""

import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-trust-observation/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/TRUST_OBSERVATION/v1\x00"
MAX_LIFETIME = timedelta(hours=24)
CLOCK_SKEW = timedelta(minutes=5)
CHALLENGE_TYPES = frozenset(
    {"relay_delivery", "storage_store_get", "discovery_lookup", "availability"}
)
RESULTS = frozenset({"success", "failure", "invalid"})
LATENCY_BUCKETS = frozenset(
    {"lt_20ms", "20_50ms", "50_100ms", "100_250ms", "250_1000ms", "gte_1000ms", "none"}
)
_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "observation_id",
    "observer_node_id",
    "subject_node_id",
    "epoch",
    "challenge_type",
    "challenge_commitment",
    "result",
    "latency_bucket",
    "observed_at",
    "expires_at",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class ObserverCredential:
    public_key: str
    valid_until: datetime
    revoked: bool = False


@dataclass(frozen=True)
class ObservationValidation:
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


def observation_signing_payload(observation: Mapping[str, Any]) -> bytes:
    unsigned = {field: observation[field] for field in _UNSIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(unsigned).encode("utf-8")


def trust_observation_hash(observation: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        canonical_json(dict(observation)).encode("utf-8")
    ).hexdigest()


def issue_reliability_observation(
    *,
    observer_node_id: str,
    subject_node_id: str,
    epoch: int,
    challenge_type: str,
    challenge_commitment: str,
    result: str,
    latency_bucket: str,
    observed_at: datetime,
    expires_at: datetime,
    observer_signing_key: SigningKey,
    observation_id: Optional[str] = None,
) -> dict[str, Any]:
    observation = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "observation_id": observation_id or str(uuid.uuid4()),
        "observer_node_id": observer_node_id,
        "subject_node_id": subject_node_id,
        "epoch": epoch,
        "challenge_type": challenge_type,
        "challenge_commitment": challenge_commitment,
        "result": result,
        "latency_bucket": latency_bucket,
        "observed_at": _utc_iso(observed_at),
        "expires_at": _utc_iso(expires_at),
    }
    observation["signature"] = sign_message(
        observer_signing_key, observation_signing_payload(observation)
    )
    return observation


def validate_reliability_observation(
    observation: Mapping[str, Any],
    *,
    now: datetime,
    observer_credentials: Mapping[str, ObserverCredential],
    minimum_epoch: int = 0,
    expected_subject_node_id: Optional[str] = None,
) -> ObservationValidation:
    if not isinstance(observation, Mapping) or set(observation) != _ALL_FIELDS:
        return ObservationValidation(False, "invalid observation fields")
    if observation.get("protocol_version") != PROTOCOL_VERSION:
        return ObservationValidation(False, "unsupported protocol_version")
    if observation.get("object_version") != OBJECT_VERSION:
        return ObservationValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(observation["observation_id"])) != observation["observation_id"]:
            return ObservationValidation(False, "invalid observation_id")
    except (AttributeError, TypeError, ValueError):
        return ObservationValidation(False, "invalid observation_id")
    observer = observation.get("observer_node_id")
    subject = observation.get("subject_node_id")
    if not isinstance(observer, str) or not observer.startswith(NODE_ID_PREFIX):
        return ObservationValidation(False, "invalid observer_node_id")
    if not isinstance(subject, str) or not subject.startswith(NODE_ID_PREFIX):
        return ObservationValidation(False, "invalid subject_node_id")
    if observer == subject:
        return ObservationValidation(False, "self-observation is not external evidence")
    if expected_subject_node_id and subject != expected_subject_node_id:
        return ObservationValidation(False, "unexpected observation subject")
    epoch = observation.get("epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < minimum_epoch:
        return ObservationValidation(False, "invalid or stale epoch")
    if observation.get("challenge_type") not in CHALLENGE_TYPES:
        return ObservationValidation(False, "invalid challenge_type")
    commitment = observation.get("challenge_commitment")
    if not isinstance(commitment, str) or re.fullmatch(r"[0-9a-f]{64}", commitment) is None:
        return ObservationValidation(False, "invalid challenge_commitment")
    if observation.get("result") not in RESULTS:
        return ObservationValidation(False, "invalid result")
    if observation.get("latency_bucket") not in LATENCY_BUCKETS:
        return ObservationValidation(False, "invalid latency_bucket")
    if not isinstance(observation.get("signature"), str):
        return ObservationValidation(False, "invalid signature encoding")
    if now.tzinfo is None or now.utcoffset() is None:
        return ObservationValidation(False, "validation time must be timezone-aware")
    try:
        observed_at = _parse_time(observation["observed_at"])
        expires_at = _parse_time(observation["expires_at"])
    except (TypeError, ValueError):
        return ObservationValidation(False, "malformed observation time")
    lifetime = expires_at - observed_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return ObservationValidation(False, "invalid observation lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < observed_at:
        return ObservationValidation(False, "observation is from the future")
    if now_utc - CLOCK_SKEW > expires_at:
        return ObservationValidation(False, "observation has expired")

    credential = observer_credentials.get(observer)
    if credential is None:
        return ObservationValidation(False, "unknown observer")
    if credential.revoked:
        return ObservationValidation(False, "observer is revoked")
    if credential.valid_until.tzinfo is None or credential.valid_until.utcoffset() is None:
        return ObservationValidation(False, "invalid observer credential time")
    if credential.valid_until.astimezone(timezone.utc) < now_utc:
        return ObservationValidation(False, "observer credential has expired")
    if not verify_message(
        credential.public_key,
        observation_signing_payload(observation),
        observation["signature"],
    ):
        return ObservationValidation(False, "invalid observer signature")
    return ObservationValidation(True)
