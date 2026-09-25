"""Strict verification of Discovery user-to-Home routing records."""

import base64
from typing import Any, Collection, Mapping, Optional
from urllib.parse import urlsplit

from shared.security.record_verifier import verify_user_record_response


def parse_discovery_signing_public_keys(raw: str) -> frozenset[str]:
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) > 16:
        raise RuntimeError("DISCOVERY_SIGNING_PUBLIC_KEYS accepts at most 16 keys")
    for value in values:
        try:
            decoded = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        except (ValueError, TypeError) as exc:
            raise RuntimeError("invalid Discovery signing public key") from exc
        if len(decoded) != 32:
            raise RuntimeError("Discovery signing public keys must encode 32 bytes")
    return frozenset(values)


def validate_user_home_record(
    record: Any,
    *,
    expected_user_id: str,
    require_signature: bool,
    trusted_public_keys: Collection[str],
) -> tuple[Optional[str], Optional[str]]:
    if not isinstance(record, Mapping):
        return None, "Discovery user record is not an object"
    if record.get("user_id") != expected_user_id:
        return None, "Discovery user record has a mismatched user_id"
    home_node_url = record.get("home_node_url")
    updated_at = record.get("updated_at")
    if not isinstance(home_node_url, str) or not home_node_url or len(home_node_url) > 2048:
        return None, "Discovery user record has an invalid home_node_url"
    if not isinstance(updated_at, str) or not updated_at:
        return None, "Discovery user record has an invalid updated_at"

    parsed = urlsplit(home_node_url)
    try:
        parsed.port
    except ValueError:
        return None, "Discovery user record contains an invalid Home URL port"
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        return None, "Discovery user record contains an unsafe Home URL"

    signature = record.get("record_signature")
    public_key = record.get("discovery_public_key")
    if bool(signature) != bool(public_key):
        return None, "Discovery user record has incomplete signature fields"
    if signature and public_key:
        if not isinstance(signature, str) or not isinstance(public_key, str):
            return None, "Discovery user record has invalid signature fields"
        if public_key not in trusted_public_keys:
            return None, "Discovery user record uses an untrusted signing key"
        if not verify_user_record_response(
            user_id=expected_user_id,
            home_node_url=home_node_url,
            updated_at=updated_at,
            signature_b64=signature,
            public_key_b64=public_key,
        ):
            return None, "Discovery user record signature is invalid"
    elif require_signature:
        return None, "Discovery user record is unsigned"

    return home_node_url.rstrip("/"), None
