"""Signed destination receipt for a synthetic Relay delivery challenge."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message


_DOMAIN = b"OUO/RELAY_CHALLENGE_RECEIPT/v1\x00"
_FIELDS = frozenset(
    {
        "protocol_version",
        "challenge_id",
        "receiver_node_id",
        "cell_hash",
        "received_at",
        "expires_at",
        "signature",
    }
)


def _time(value: object) -> datetime:
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError("invalid Relay receipt time")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("Relay receipt time must include timezone")
    return parsed.astimezone(timezone.utc)


def _payload(receipt: Mapping[str, Any]) -> bytes:
    unsigned = {key: value for key, value in receipt.items() if key != "signature"}
    return _DOMAIN + canonical_json(unsigned).encode("utf-8")


def issue_relay_challenge_receipt(
    *,
    challenge_id: str,
    receiver_node_id: str,
    cell_hash: str,
    signing_key: SigningKey,
    received_at: datetime,
    expires_at: datetime,
) -> dict[str, Any]:
    if received_at.tzinfo is None or expires_at.tzinfo is None:
        raise ValueError("Relay receipt times must be timezone-aware")
    if not received_at < expires_at <= received_at + timedelta(minutes=5):
        raise ValueError("invalid Relay receipt lifetime")
    receipt = {
        "protocol_version": "ouo-relay-challenge-receipt/1",
        "challenge_id": challenge_id,
        "receiver_node_id": receiver_node_id,
        "cell_hash": cell_hash,
        "received_at": received_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "expires_at": expires_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    receipt["signature"] = sign_message(signing_key, _payload(receipt))
    return receipt


def validate_relay_challenge_receipt(
    receipt: object,
    *,
    expected_challenge_id: str,
    expected_receiver_node_id: str,
    expected_cell_hash: str,
    receiver_public_key: str,
    now: datetime,
) -> bool:
    if not isinstance(receipt, dict) or set(receipt) != _FIELDS:
        return False
    if (
        receipt.get("protocol_version") != "ouo-relay-challenge-receipt/1"
        or receipt.get("challenge_id") != expected_challenge_id
        or receipt.get("receiver_node_id") != expected_receiver_node_id
        or receipt.get("cell_hash") != expected_cell_hash
    ):
        return False
    try:
        received_at = _time(receipt.get("received_at"))
        expires_at = _time(receipt.get("expires_at"))
    except ValueError:
        return False
    current = now.astimezone(timezone.utc)
    if not received_at <= current <= expires_at or expires_at > received_at + timedelta(minutes=5):
        return False
    signature = receipt.get("signature")
    return isinstance(signature, str) and verify_message(
        receiver_public_key, _payload(receipt), signature
    )
