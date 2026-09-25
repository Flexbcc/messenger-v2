"""Persistent one-time pairing, device revocation and replay state.

The state contains public certificates and hashes of short-lived pairing
secrets only.  Device private keys and the node root seed are never persisted
by this component.
"""

import base64
import hashlib
import json
import os
import secrets
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

from nacl.signing import SigningKey, VerifyKey

from shared.security.keys import public_key_b64
from shared.security.owner_management import (
    ALLOWED_ROLES,
    OwnerValidation,
    issue_owner_device_certificate,
    validate_owner_device_certificate,
    validate_owner_request,
)


PAIRING_PROTOCOL = "ouo-owner-pair/1"
MAX_PAIRING_LIFETIME = timedelta(minutes=10)
MAX_ACTIVE_PAIRINGS = 5
MAX_NONCES_PER_DEVICE = 256

ROLE_PERMISSIONS = {
    "viewer": frozenset({"health.read", "devices.read"}),
    "operator": frozenset(
        {"health.read", "devices.read", "diagnostics.read", "service.restart"}
    ),
    "owner": frozenset(
        {
            "health.read",
            "devices.read",
            "diagnostics.read",
            "service.restart",
            "devices.pair",
            "devices.revoke",
            "settings.write",
            "update.approve",
        }
    ),
}


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _pairing_hash(pairing_id: str, secret: str) -> str:
    return hashlib.sha256(
        b"OUO/OWNER_PAIR_SECRET/v1\x00"
        + pairing_id.encode("ascii")
        + b"\x00"
        + secret.encode("ascii")
    ).hexdigest()


class OwnerManagementStore:
    def __init__(self, path: str | Path, *, node_root_signing_key: SigningKey):
        self.path = Path(path)
        self.node_root_signing_key = node_root_signing_key
        self.node_root_public_key = public_key_b64(node_root_signing_key)

    def _empty(self) -> dict[str, Any]:
        return {
            "version": 1,
            "pairings": {},
            "devices": {},
            "revoked_serials": [],
            "replay": {},
        }

    def _read(self) -> dict[str, Any]:
        if not self.path.exists():
            return self._empty()
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict) or raw.get("version") != 1:
            raise ValueError("unsupported owner management state")
        for key, expected in (
            ("pairings", dict),
            ("devices", dict),
            ("revoked_serials", list),
            ("replay", dict),
        ):
            if not isinstance(raw.get(key), expected):
                raise ValueError(f"invalid owner management state field: {key}")
        return raw

    def _write(self, state: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary_path = tempfile.mkstemp(
            dir=self.path.parent, prefix=f".{self.path.name}.", text=True
        )
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                fd = -1
                json.dump(state, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_path, self.path)
            os.chmod(self.path, 0o600)
        finally:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass

    def create_pairing(
        self,
        *,
        role: str,
        now: datetime,
        expires_in: timedelta = timedelta(minutes=5),
    ) -> dict[str, Any]:
        if role not in ALLOWED_ROLES:
            raise ValueError("unsupported owner role")
        if expires_in <= timedelta(0) or expires_in > MAX_PAIRING_LIFETIME:
            raise ValueError("invalid pairing lifetime")
        state = self._read()
        now_utc = now.astimezone(timezone.utc)
        state["pairings"] = {
            pairing_id: pairing
            for pairing_id, pairing in state["pairings"].items()
            if _parse_utc(pairing["expires_at"]) >= now_utc
        }
        if len(state["pairings"]) >= MAX_ACTIVE_PAIRINGS:
            raise ValueError("too many active pairing capabilities")

        pairing_id = str(uuid.uuid4())
        pairing_secret = secrets.token_urlsafe(32)
        expires_at = now_utc + expires_in
        state["pairings"][pairing_id] = {
            "secret_hash": _pairing_hash(pairing_id, pairing_secret),
            "role": role,
            "created_at": _utc_iso(now_utc),
            "expires_at": _utc_iso(expires_at),
        }
        self._write(state)
        return {
            "protocol_version": PAIRING_PROTOCOL,
            "pairing_id": pairing_id,
            "pairing_secret": pairing_secret,
            "node_id": self.node_id,
            "node_root_public_key": self.node_root_public_key,
            "role": role,
            "expires_at": _utc_iso(expires_at),
        }

    @property
    def node_id(self) -> str:
        from shared.security.node_identity import node_id_from_root_public_key

        return node_id_from_root_public_key(bytes(self.node_root_signing_key.verify_key))

    def consume_pairing(
        self,
        *,
        pairing_id: str,
        pairing_secret: str,
        device_public_key: str,
        now: datetime,
        certificate_lifetime: timedelta = timedelta(days=30),
    ) -> dict[str, Any]:
        state = self._read()
        pairing = state["pairings"].get(pairing_id)
        if pairing is None:
            raise ValueError("unknown or consumed pairing capability")
        now_utc = now.astimezone(timezone.utc)
        if now_utc > _parse_utc(pairing["expires_at"]):
            del state["pairings"][pairing_id]
            self._write(state)
            raise ValueError("pairing capability expired")
        if not secrets.compare_digest(
            pairing["secret_hash"], _pairing_hash(pairing_id, pairing_secret)
        ):
            raise ValueError("invalid pairing secret")
        try:
            key_bytes = base64.b64decode(device_public_key, altchars=b"-_", validate=True)
            device_verify_key = VerifyKey(key_bytes)
        except (TypeError, ValueError) as exc:
            raise ValueError("invalid device public key") from exc

        certificate = issue_owner_device_certificate(
            node_root_signing_key=self.node_root_signing_key,
            device_verify_key=device_verify_key,
            role=pairing["role"],
            issued_at=now_utc,
            valid_until=now_utc + certificate_lifetime,
        )
        # Consume only after every validation and certificate construction has
        # succeeded.  A malformed phone request cannot burn a valid QR code.
        del state["pairings"][pairing_id]
        state["devices"][certificate["serial"]] = certificate
        state["replay"][certificate["serial"]] = {"next_sequence": 0, "nonces": []}
        self._write(state)
        return certificate

    def list_devices(self, *, now: datetime) -> list[dict[str, Any]]:
        state = self._read()
        revoked = frozenset(state["revoked_serials"])
        result = []
        for certificate in state["devices"].values():
            validation = validate_owner_device_certificate(
                certificate,
                node_root_public_key=self.node_root_public_key,
                now=now,
                revoked_serials=revoked,
            )
            result.append(
                {
                    "device_id": certificate["device_id"],
                    "serial": certificate["serial"],
                    "role": certificate["role"],
                    "valid_until": certificate["valid_until"],
                    "active": validation.valid,
                    "status": validation.reason or "active",
                }
            )
        return sorted(result, key=lambda item: item["device_id"])

    def revoke_device(self, serial: str) -> bool:
        state = self._read()
        if serial not in state["devices"]:
            return False
        if serial not in state["revoked_serials"]:
            state["revoked_serials"].append(serial)
        state["replay"].pop(serial, None)
        self._write(state)
        return True

    def authorize_request(
        self,
        request: dict[str, Any],
        *,
        permission: str,
        now: datetime,
        method: str,
        path: str,
        body: bytes,
    ) -> OwnerValidation:
        state = self._read()
        serial = request.get("certificate_serial")
        certificate = state["devices"].get(serial)
        if certificate is None:
            return OwnerValidation(False, "unknown owner device")
        certificate_result = validate_owner_device_certificate(
            certificate,
            node_root_public_key=self.node_root_public_key,
            now=now,
            revoked_serials=frozenset(state["revoked_serials"]),
        )
        if not certificate_result.valid:
            return certificate_result
        if permission not in ROLE_PERMISSIONS[certificate["role"]]:
            return OwnerValidation(False, "owner role lacks permission")
        replay = state["replay"].setdefault(serial, {"next_sequence": 0, "nonces": []})
        result = validate_owner_request(
            request,
            certificate=certificate,
            now=now,
            method=method,
            path=path,
            body=body,
            minimum_sequence=replay["next_sequence"],
            seen_nonces=frozenset(replay["nonces"]),
        )
        if not result.valid:
            return result
        replay["next_sequence"] = request["sequence"] + 1
        replay["nonces"].append(request["nonce"])
        replay["nonces"] = replay["nonces"][-MAX_NONCES_PER_DEVICE:]
        self._write(state)
        return result
