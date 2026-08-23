"""Persistent lifecycle for the node's dedicated X25519 transport key."""

from __future__ import annotations

import base64
import json
import os
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from nacl.public import PrivateKey

from shared.security.keys import load_or_create_signing_key
from shared.security.transport_certificate import (
    MAX_LIFETIME,
    issue_transport_certificate,
    validate_transport_certificate,
)


DEFAULT_RENEW_BEFORE = timedelta(days=1)


def _write_bytes_atomic(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(value)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    encoded = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    _write_bytes_atomic(path, encoded)


def load_or_create_transport_key(path: str) -> PrivateKey:
    if not path:
        raise ValueError("transport key path must be non-empty")
    destination = Path(path)
    try:
        encoded = destination.read_bytes()
    except FileNotFoundError:
        key = PrivateKey.generate()
        _write_bytes_atomic(
            destination, base64.urlsafe_b64encode(bytes(key)) + b"\n"
        )
        return key
    try:
        raw = base64.b64decode(encoded.strip(), altchars=b"-_", validate=True)
        if len(raw) != PrivateKey.SIZE:
            raise ValueError("invalid transport private key length")
        return PrivateKey(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid transport private key file") from exc


def _read_certificate(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None
    if len(raw) > 64 * 1024:
        raise ValueError("transport certificate file exceeds size limit")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid transport certificate file") from exc
    if not isinstance(value, dict):
        raise ValueError("transport certificate must be an object")
    return value


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    ).astimezone(timezone.utc)


def load_or_renew_transport_certificate(
    *,
    root_key_path: str,
    transport_key_path: str,
    certificate_path: str,
    now: datetime | None = None,
    renew_before: timedelta = DEFAULT_RENEW_BEFORE,
) -> dict[str, Any]:
    if not root_key_path or not transport_key_path or not certificate_path:
        raise ValueError("transport credential paths must be non-empty")
    resolved = {
        Path(root_key_path).resolve(),
        Path(transport_key_path).resolve(),
        Path(certificate_path).resolve(),
    }
    if len(resolved) != 3:
        raise ValueError("root, transport key and certificate paths must differ")
    if renew_before < timedelta(0) or renew_before >= MAX_LIFETIME:
        raise ValueError("renew_before must be within certificate lifetime")
    supplied_time = now or datetime.now(timezone.utc)
    if supplied_time.tzinfo is None or supplied_time.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    current = supplied_time.astimezone(timezone.utc)
    root_key = load_or_create_signing_key(root_key_path)
    transport_key = load_or_create_transport_key(transport_key_path)
    certificate_file = Path(certificate_path)
    existing = _read_certificate(certificate_file)
    if existing:
        validation = validate_transport_certificate(existing, now=current)
        expected_public = base64.urlsafe_b64encode(
            bytes(transport_key.public_key)
        ).decode("ascii")
        if (
            validation.valid
            and existing.get("transport_public_key") == expected_public
            and _parse_time(existing["valid_until"]) - current > renew_before
        ):
            return existing
    issued_at = current - timedelta(minutes=1)
    certificate = issue_transport_certificate(
        root_signing_key=root_key,
        transport_private_key=transport_key,
        issued_at=issued_at,
        valid_until=issued_at + MAX_LIFETIME,
    )
    _write_json_atomic(certificate_file, certificate)
    return certificate
