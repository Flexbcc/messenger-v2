"""Root-signed, monotonic Operational Credential state for OUO nodes.

OperationalCertificate v1 intentionally has a random serial and timestamps,
not a protocol sequence number.  This wrapper adds an explicit per-NodeID
credential epoch and hash chain so Discovery replicas can enforce the same
high-watermark without treating their local arrival order as authority.
"""

from __future__ import annotations

import copy
import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import public_key_b64, sign_message, verify_message
from shared.security.node_identity import validate_operational_certificate


PROTOCOL_VERSION = "ouo-operational-credential-state/1"
OBJECT_VERSION = 1
SIGNATURE_ALGORITHM = "Ed25519"
SIGNING_DOMAIN = b"OUO/OPERATIONAL_CREDENTIAL_STATE/v1\x00"
GENESIS_DOMAIN = b"OUO/OPERATIONAL_CREDENTIAL_GENESIS/v1\x00"
DEFAULT_CLOCK_SKEW = timedelta(minutes=5)
MAX_STATE_BYTES = 32 * 1024

_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "node_id",
    "credential_epoch",
    "previous_state_hash",
    "operational_certificate",
    "signature_algorithm",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class OperationalCredentialStateValidation:
    valid: bool
    reason: Optional[str] = None


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def operational_credential_genesis_hash(node_id: str) -> str:
    if not isinstance(node_id, str) or not node_id:
        raise ValueError("node_id must be a non-empty string")
    return hashlib.sha256(GENESIS_DOMAIN + node_id.encode("utf-8")).hexdigest()


def operational_credential_state_signing_payload(
    state: Mapping[str, Any],
) -> bytes:
    unsigned = {field: state[field] for field in _UNSIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(unsigned).encode("utf-8")


def operational_credential_state_hash(state: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(state)).encode("utf-8")).hexdigest()


def issue_operational_credential_state(
    *,
    root_signing_key: SigningKey,
    operational_certificate: Mapping[str, Any],
    credential_epoch: int,
    previous_state_hash: Optional[str] = None,
) -> dict[str, Any]:
    if not isinstance(credential_epoch, int) or isinstance(credential_epoch, bool):
        raise ValueError("credential_epoch must be an integer")
    if credential_epoch < 0:
        raise ValueError("credential_epoch cannot be negative")
    node_id = operational_certificate.get("node_id")
    if public_key_b64(root_signing_key) != operational_certificate.get(
        "root_public_key"
    ):
        raise ValueError("Node Root key does not match Operational Certificate")
    if previous_state_hash is None:
        if credential_epoch != 0:
            raise ValueError("non-genesis state requires previous_state_hash")
        previous_state_hash = operational_credential_genesis_hash(str(node_id))
    if re.fullmatch(r"[0-9a-f]{64}", previous_state_hash) is None:
        raise ValueError("previous_state_hash must be lowercase SHA-256 hex")

    state: dict[str, Any] = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "node_id": node_id,
        "credential_epoch": credential_epoch,
        "previous_state_hash": previous_state_hash,
        "operational_certificate": copy.deepcopy(dict(operational_certificate)),
        "signature_algorithm": SIGNATURE_ALGORITHM,
    }
    state["signature"] = sign_message(
        root_signing_key,
        operational_credential_state_signing_payload(state),
    )
    return state


def validate_operational_credential_state(
    state: Mapping[str, Any],
    *,
    now: datetime,
    expected_node_id: Optional[str] = None,
    expected_epoch: Optional[int] = None,
    expected_previous_hash: Optional[str] = None,
    require_current_certificate: bool = True,
    clock_skew: timedelta = DEFAULT_CLOCK_SKEW,
) -> OperationalCredentialStateValidation:
    if not isinstance(state, Mapping) or set(state) != _ALL_FIELDS:
        return OperationalCredentialStateValidation(False, "invalid credential state fields")
    try:
        if len(canonical_json(dict(state)).encode("utf-8")) > MAX_STATE_BYTES:
            return OperationalCredentialStateValidation(False, "credential state exceeds size limit")
    except (TypeError, ValueError):
        return OperationalCredentialStateValidation(False, "credential state is not canonical JSON")
    if state.get("protocol_version") != PROTOCOL_VERSION:
        return OperationalCredentialStateValidation(False, "unsupported protocol_version")
    if state.get("object_version") != OBJECT_VERSION:
        return OperationalCredentialStateValidation(False, "unsupported object_version")
    if state.get("signature_algorithm") != SIGNATURE_ALGORITHM:
        return OperationalCredentialStateValidation(False, "unsupported signature_algorithm")
    epoch = state.get("credential_epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        return OperationalCredentialStateValidation(False, "invalid credential_epoch")
    if expected_epoch is not None and epoch != expected_epoch:
        return OperationalCredentialStateValidation(False, "unexpected credential_epoch")
    previous_hash = state.get("previous_state_hash")
    if not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None:
        return OperationalCredentialStateValidation(False, "invalid previous_state_hash")
    if expected_previous_hash is not None and previous_hash != expected_previous_hash:
        return OperationalCredentialStateValidation(False, "credential state chain mismatch")
    certificate = state.get("operational_certificate")
    if not isinstance(certificate, Mapping):
        return OperationalCredentialStateValidation(False, "operational certificate is required")
    node_id = state.get("node_id")
    if not isinstance(node_id, str) or certificate.get("node_id") != node_id:
        return OperationalCredentialStateValidation(False, "credential state NodeID mismatch")
    if expected_node_id is not None and node_id != expected_node_id:
        return OperationalCredentialStateValidation(False, "unexpected credential state NodeID")
    if epoch == 0 and previous_hash != operational_credential_genesis_hash(node_id):
        return OperationalCredentialStateValidation(False, "invalid credential genesis anchor")
    if now.tzinfo is None or now.utcoffset() is None:
        return OperationalCredentialStateValidation(False, "validation time must be timezone-aware")
    if clock_skew < timedelta(0):
        return OperationalCredentialStateValidation(False, "clock_skew cannot be negative")
    try:
        issued_at = _parse_time(certificate.get("issued_at"))
    except (TypeError, ValueError):
        return OperationalCredentialStateValidation(False, "malformed certificate issued_at")

    # Historical chain entries may be replicated after certificate expiry.
    # Validate their intrinsic certificate at issuance, while live admission
    # additionally requires validity at the receiver's current time.
    certificate_validation = validate_operational_certificate(
        certificate,
        now=issued_at,
        clock_skew=timedelta(0),
    )
    if not certificate_validation.valid:
        return OperationalCredentialStateValidation(
            False,
            f"invalid operational certificate: {certificate_validation.reason}",
        )
    if require_current_certificate:
        current_validation = validate_operational_certificate(
            certificate,
            now=now.astimezone(timezone.utc),
            clock_skew=clock_skew,
        )
        if not current_validation.valid:
            return OperationalCredentialStateValidation(
                False,
                f"operational certificate is not current: {current_validation.reason}",
            )
    if not isinstance(state.get("signature"), str) or not verify_message(
        certificate["root_public_key"],
        operational_credential_state_signing_payload(state),
        state["signature"],
    ):
        return OperationalCredentialStateValidation(False, "invalid Node Root signature")
    return OperationalCredentialStateValidation(True)
