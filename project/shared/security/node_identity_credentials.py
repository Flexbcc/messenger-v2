"""Persistent Node Root and Operational Certificate lifecycle helpers."""

import base64
import json
import os
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from nacl.signing import SigningKey

from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.node_identity import (
    MAX_CERTIFICATE_LIFETIME,
    issue_operational_certificate,
    node_id_from_root_public_key,
    validate_operational_certificate,
)
from shared.security.canonical import canonical_json
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
    operational_credential_state_hash,
    validate_operational_credential_state,
)


DEFAULT_RENEW_BEFORE = timedelta(days=1)
OPERATIONAL_CHAIN_FILE_VERSION = "ouo-operational-credential-chain-file/1"
MAX_OPERATIONAL_CHAIN_STATES = 4096
MAX_OPERATIONAL_CHAIN_FILE_BYTES = 64 * 1024 * 1024


def _read_certificate(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return data if isinstance(data, dict) else None


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            json.dump(value, temporary, sort_keys=True, separators=(",", ":"))
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def _read_operational_state_chain(path: Path) -> list[dict[str, Any]] | None:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ValueError("cannot read Operational Credential chain") from exc
    if len(raw) > MAX_OPERATIONAL_CHAIN_FILE_BYTES:
        raise ValueError("Operational Credential chain file exceeds size limit")
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("Operational Credential chain file is invalid JSON") from exc
    if (
        not isinstance(document, dict)
        or set(document) != {"protocol_version", "states"}
        or document.get("protocol_version") != OPERATIONAL_CHAIN_FILE_VERSION
        or not isinstance(document.get("states"), list)
        or not 1 <= len(document["states"]) <= MAX_OPERATIONAL_CHAIN_STATES
        or any(not isinstance(state, dict) for state in document["states"])
    ):
        raise ValueError("invalid Operational Credential chain file")
    return document["states"]


def _write_operational_state_chain(
    path: Path,
    states: list[dict[str, Any]],
) -> None:
    if not 1 <= len(states) <= MAX_OPERATIONAL_CHAIN_STATES:
        raise ValueError("invalid Operational Credential chain length")
    _write_json_atomic(
        path,
        {
            "protocol_version": OPERATIONAL_CHAIN_FILE_VERSION,
            "states": states,
        },
    )


def _validate_operational_state_chain(
    states: list[dict[str, Any]],
    *,
    expected_node_id: str,
    now: datetime,
) -> None:
    previous_hash: str | None = None
    for epoch, state in enumerate(states):
        validation = validate_operational_credential_state(
            state,
            now=now,
            expected_node_id=expected_node_id,
            expected_epoch=epoch,
            expected_previous_hash=previous_hash,
            require_current_certificate=False,
        )
        if not validation.valid:
            raise ValueError(
                "invalid Operational Credential chain: "
                f"epoch {epoch}: {validation.reason}"
            )
        previous_hash = operational_credential_state_hash(state)


def _write_signing_key_atomic(path: Path, signing_key: SigningKey) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="ascii",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(base64.urlsafe_b64encode(bytes(signing_key)).decode("ascii"))
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def _valid_until(certificate: dict[str, Any]) -> datetime:
    raw = certificate["valid_until"]
    return datetime.fromisoformat(raw[:-1] + "+00:00" if raw.endswith("Z") else raw).astimezone(
        timezone.utc
    )


def load_or_renew_operational_certificate(
    *,
    root_key_path: str,
    operational_key_path: str,
    certificate_path: str,
    now: datetime | None = None,
    renew_before: timedelta = DEFAULT_RENEW_BEFORE,
) -> dict[str, Any]:
    """Return a valid certificate, renewing it atomically when needed.

    Certificate renewal reuses the current operational key.  Explicit key
    rotation is a separate operation so a certificate refresh cannot silently
    invalidate active federation sessions.
    """
    if not root_key_path or not operational_key_path or not certificate_path:
        raise ValueError("node identity paths must be non-empty")
    if Path(root_key_path).resolve() == Path(operational_key_path).resolve():
        raise ValueError("Node Root and operational key paths must be different")
    if renew_before < timedelta(0) or renew_before >= MAX_CERTIFICATE_LIFETIME:
        raise ValueError("renew_before must be within the certificate lifetime")

    current_time = now or datetime.now(timezone.utc)
    if current_time.tzinfo is None or current_time.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    current_time = current_time.astimezone(timezone.utc)

    root_key = load_or_create_signing_key(root_key_path)
    operational_key = load_or_create_signing_key(operational_key_path)
    expected_node_id = node_id_from_root_public_key(bytes(root_key.verify_key))
    expected_operational_key = public_key_b64(operational_key)
    certificate_file = Path(certificate_path)
    existing = _read_certificate(certificate_file)
    if existing:
        validation = validate_operational_certificate(existing, now=current_time)
        if (
            validation.valid
            and existing.get("node_id") == expected_node_id
            and existing.get("operational_public_key") == expected_operational_key
            and _valid_until(existing) - current_time > renew_before
        ):
            return existing

    issued_at = current_time - timedelta(minutes=1)
    certificate = issue_operational_certificate(
        root_signing_key=root_key,
        operational_verify_key=operational_key.verify_key,
        issued_at=issued_at,
        valid_until=issued_at + MAX_CERTIFICATE_LIFETIME,
    )
    _write_json_atomic(certificate_file, certificate)
    return certificate


def node_identity_registration_fields(
    *,
    root_key_path: str,
    operational_key_path: str,
    certificate_path: str,
) -> dict[str, Any]:
    certificate = load_or_renew_operational_certificate(
        root_key_path=root_key_path,
        operational_key_path=operational_key_path,
        certificate_path=certificate_path,
    )
    return {
        "signing_public_key": certificate["operational_public_key"],
        "operational_certificate": certificate,
    }


def load_or_update_operational_credential_state(
    *,
    root_key_path: str,
    operational_key_path: str,
    certificate_path: str,
    credential_chain_path: str,
    now: datetime | None = None,
    renew_before: timedelta = DEFAULT_RENEW_BEFORE,
    allow_existing_certificate_genesis: bool = False,
) -> dict[str, Any]:
    """Return the current root-signed monotonic credential state.

    A brand-new identity may create epoch zero. If a certificate already
    exists but its chain file is missing, reset is denied unless an operator
    explicitly authorizes the one-time legacy migration flag.
    """
    if not credential_chain_path:
        raise ValueError("credential_chain_path must be non-empty")
    chain_path = Path(credential_chain_path)
    certificate_existed = Path(certificate_path).exists()
    states = _read_operational_state_chain(chain_path)
    if states is None and certificate_existed and not allow_existing_certificate_genesis:
        raise ValueError(
            "Operational Credential chain is missing for existing certificate; "
            "restore it or explicitly authorize legacy genesis"
        )
    certificate = load_or_renew_operational_certificate(
        root_key_path=root_key_path,
        operational_key_path=operational_key_path,
        certificate_path=certificate_path,
        now=now,
        renew_before=renew_before,
    )
    current_time = now or datetime.now(timezone.utc)
    if current_time.tzinfo is None or current_time.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    current_time = current_time.astimezone(timezone.utc)
    root_key = load_or_create_signing_key(root_key_path)

    if states is None:
        state = issue_operational_credential_state(
            root_signing_key=root_key,
            operational_certificate=certificate,
            credential_epoch=0,
        )
        _write_operational_state_chain(chain_path, [state])
        return state

    _validate_operational_state_chain(
        states,
        expected_node_id=certificate["node_id"],
        now=current_time,
    )
    current_state = states[-1]
    if canonical_json(current_state["operational_certificate"]) == canonical_json(
        certificate
    ):
        validation = validate_operational_credential_state(
            current_state,
            now=current_time,
            require_current_certificate=True,
        )
        if not validation.valid:
            raise ValueError(
                f"current Operational Credential state is invalid: {validation.reason}"
            )
        return current_state
    if len(states) >= MAX_OPERATIONAL_CHAIN_STATES:
        raise ValueError("Operational Credential chain limit exceeded")
    next_state = issue_operational_credential_state(
        root_signing_key=root_key,
        operational_certificate=certificate,
        credential_epoch=len(states),
        previous_state_hash=operational_credential_state_hash(current_state),
    )
    _write_operational_state_chain(chain_path, [*states, next_state])
    return next_state


def rotate_operational_credential_bundle(
    *,
    root_key_path: str,
    operational_key_path: str,
    certificate_path: str,
    credential_chain_path: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Rotate the operational key and advance its persistent state chain."""
    current_time = now or datetime.now(timezone.utc)
    # Fail before key mutation if an existing identity has lost/corrupted its
    # credential chain.
    load_or_update_operational_credential_state(
        root_key_path=root_key_path,
        operational_key_path=operational_key_path,
        certificate_path=certificate_path,
        credential_chain_path=credential_chain_path,
        now=current_time,
    )
    rotate_operational_credentials(
        root_key_path=root_key_path,
        operational_key_path=operational_key_path,
        certificate_path=certificate_path,
        now=current_time,
    )
    return load_or_update_operational_credential_state(
        root_key_path=root_key_path,
        operational_key_path=operational_key_path,
        certificate_path=certificate_path,
        credential_chain_path=credential_chain_path,
        now=current_time,
    )


def rotate_operational_credentials(
    *,
    root_key_path: str,
    operational_key_path: str,
    certificate_path: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Replace only the short-lived operational key and certificate.

    Node Root and therefore NodeID stay unchanged. The caller must restart or
    explicitly refresh any in-memory signing-key cache after this filesystem
    operation; no running process is mutated implicitly.
    """
    if Path(root_key_path).resolve() == Path(operational_key_path).resolve():
        raise ValueError("Node Root and operational key paths must be different")
    current_time = now or datetime.now(timezone.utc)
    if current_time.tzinfo is None or current_time.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    current_time = current_time.astimezone(timezone.utc)
    root_key = load_or_create_signing_key(root_key_path)
    operational_key = SigningKey.generate()
    issued_at = current_time - timedelta(minutes=1)
    certificate = issue_operational_certificate(
        root_signing_key=root_key,
        operational_verify_key=operational_key.verify_key,
        issued_at=issued_at,
        valid_until=issued_at + MAX_CERTIFICATE_LIFETIME,
    )
    _write_signing_key_atomic(Path(operational_key_path), operational_key)
    _write_json_atomic(Path(certificate_path), certificate)
    return certificate
