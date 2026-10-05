"""Bootstrap the one identity shared by all modules in a unified OUO node."""

import os
import json
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
    validate_capability_certificate,
)
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.node_identity_credentials import (
    load_or_update_operational_credential_state,
)


def _atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=f".{path.name}.", delete=False,
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


def _provision_local_capability(node_id: str) -> None:
    """Issue an aggregate certificate from a persistent local test authority."""
    authority_path = Path(os.environ["NODE_CAPABILITY_AUTHORITY_STATE_PATH"])
    certificate_path = Path(os.environ["NODE_CAPABILITY_CERTIFICATE_PATH"])
    authority_dir = authority_path.parent / "capability-authority"
    validators: dict[str, SigningKey] = {
        f"local-validator-{index}": load_or_create_signing_key(
            str(authority_dir / f"validator-{index}.key")
        )
        for index in range(1, 8)
    }
    committee = sorted(validators)
    valid_until = datetime.now(timezone.utc) + timedelta(days=365)
    authority = {
        "epoch": 1,
        "committee": committee,
        "threshold": 5,
        "validators": {
            validator_id: {
                "public_key": public_key_b64(key),
                "valid_until": valid_until.isoformat().replace("+00:00", "Z"),
                "revoked": False,
            }
            for validator_id, key in validators.items()
        },
    }
    if authority_path.exists():
        existing = json.loads(authority_path.read_text(encoding="utf-8"))
        if existing != authority:
            # Keep the original expiry and verify the persistent keys instead
            # of rewriting the authority state on every container restart.
            expected_keys = {
                key: public_key_b64(value) for key, value in validators.items()
            }
            actual_keys = {
                key: value["public_key"]
                for key, value in existing.get("validators", {}).items()
            }
            if (
                existing.get("committee") != committee
                or existing.get("threshold") != 5
                or actual_keys != expected_keys
            ):
                raise RuntimeError("local capability authority state does not match its keys")
            authority = existing
    else:
        _atomic_json(authority_path, authority)

    # Certificate construction canonicalises capabilities. Compare the same
    # canonical order here or every restart reissues a different certificate
    # with the same epoch, which Discovery correctly rejects as equivocation.
    capabilities = sorted({
        item.strip()
        for item in os.environ.get("NODE_CAPABILITIES", "home").split(",")
        if item.strip()
    })
    now = datetime.now(timezone.utc)
    if certificate_path.exists():
        existing_certificate = json.loads(certificate_path.read_text(encoding="utf-8"))
        expires = datetime.fromisoformat(existing_certificate["valid_until"].replace("Z", "+00:00"))
        if (
            existing_certificate.get("subject_node_id") == node_id
            and existing_certificate.get("capabilities") == capabilities
            and expires > now + timedelta(days=1)
        ):
            return

    certificate = build_capability_certificate(
        subject_node_id=node_id,
        level=4,
        capabilities=capabilities,
        quotas={"max_connections": 1000},
        epoch=1,
        authority_epoch=int(authority["epoch"]),
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=7),
        committee=committee,
        threshold=5,
    )
    for validator_id in committee[:5]:
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=validators[validator_id],
        )
    credentials = {
        validator_id: ValidatorCredential(
            public_key=value["public_key"],
            valid_until=datetime.fromisoformat(value["valid_until"].replace("Z", "+00:00")),
            revoked=bool(value["revoked"]),
        )
        for validator_id, value in authority["validators"].items()
    }
    result = validate_capability_certificate(
        certificate,
        now=now,
        expected_committee=committee,
        expected_threshold=5,
        validator_credentials=credentials,
        expected_authority_epoch=int(authority["epoch"]),
        expected_subject_node_id=node_id,
    )
    if not result.valid:
        raise RuntimeError(f"generated local capability certificate is invalid: {result.reason}")
    _atomic_json(certificate_path, certificate)


def main() -> None:
    root_key_path = os.environ["NODE_ROOT_KEY_PATH"]
    signing_key_path = os.environ["NODE_SIGNING_KEY_PATH"]
    certificate_path = os.environ["NODE_OPERATIONAL_CERTIFICATE_PATH"]
    chain_path = os.environ["NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"]

    # This exception is deliberately narrower than a general compatibility
    # switch: only an existing certificate with a missing chain is migrated.
    legacy_certificate_without_chain = (
        Path(certificate_path).is_file() and not Path(chain_path).exists()
    )
    state = load_or_update_operational_credential_state(
        root_key_path=root_key_path,
        operational_key_path=signing_key_path,
        certificate_path=certificate_path,
        credential_chain_path=chain_path,
        allow_existing_certificate_genesis=legacy_certificate_without_chain,
    )
    capability_mode = os.environ.get(
        "NODE_CAPABILITY_PROVISION_MODE", "local"
    ).strip().lower()
    if capability_mode == "local":
        _provision_local_capability(state["node_id"])
    elif capability_mode == "external":
        certificate_path = Path(os.environ["NODE_CAPABILITY_CERTIFICATE_PATH"])
        authority_path = os.environ["NODE_CAPABILITY_AUTHORITY_STATE_PATH"]
        authority = load_capability_authority_state(authority_path)
        if not certificate_path.is_file() or authority is None:
            raise RuntimeError(
                "external capability mode requires a certificate and authority state"
            )
        certificate = json.loads(certificate_path.read_text(encoding="utf-8"))
        result = validate_capability_certificate(
            certificate,
            now=datetime.now(timezone.utc),
            expected_committee=authority.committee,
            expected_threshold=authority.threshold,
            validator_credentials=authority.validators,
            expected_authority_epoch=authority.epoch,
            expected_subject_node_id=state["node_id"],
        )
        if not result.valid:
            raise RuntimeError(
                f"external capability certificate is invalid: {result.reason}"
            )
    else:
        raise RuntimeError(
            "NODE_CAPABILITY_PROVISION_MODE must be local or external"
        )
    action = "migrated" if legacy_certificate_without_chain else "ready"
    print(
        "[ouo-node] shared operational credential chain "
        f"{action} (epoch={state['credential_epoch']})",
        flush=True,
    )


if __name__ == "__main__":
    main()
