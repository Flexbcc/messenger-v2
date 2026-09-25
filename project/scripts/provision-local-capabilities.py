#!/usr/bin/env python3
"""Provision real threshold-signed Capability Certificates for local Docker.

The generated validator seeds and certificates live under ignored ``data/``.
This script is intentionally limited to the local Compose service layout; it
is not a production authority or a substitute for offline release procedures.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from shared.security.capability_certificate import (  # noqa: E402
    add_validator_signature,
    build_capability_certificate,
    capability_certificate_hash,
    validate_capability_certificate,
    ValidatorCredential,
)
from shared.security.keys import (  # noqa: E402
    load_or_create_signing_key,
    public_key_b64,
)
from shared.security.node_identity_credentials import (  # noqa: E402
    load_or_update_operational_credential_state,
)


AUTHORITY_DIR = PROJECT_ROOT / "data" / "capability-authority"
AUTHORITY_STATE_PATH = AUTHORITY_DIR / "state.json"
VALIDATOR_COUNT = 7
THRESHOLD = 5
SERVICES = {
    "discovery": ("discovery", 4, "discovery_node_operational_certificate.json"),
    "discovery-2": ("discovery", 4, "discovery_node_operational_certificate.json"),
    "discovery-3": ("discovery", 4, "discovery_node_operational_certificate.json"),
    "home": ("home", 0, "node_operational_certificate.json"),
    "relay": ("relay", 2, "node_operational_certificate.json"),
    "storage": ("storage", 4, "node_operational_certificate.json"),
    "media-meta": ("media", 4, "node_operational_certificate.json"),
    "turn": ("turn", 4, "node_operational_certificate.json"),
    "gateway": ("gateway", 4, "node_operational_certificate.json"),
}


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load_validators() -> tuple[dict[str, SigningKey], dict]:
    AUTHORITY_DIR.mkdir(parents=True, exist_ok=True)
    validators = {
        f"local-validator-{index}": load_or_create_signing_key(
            str(AUTHORITY_DIR / f"validator-{index}.key")
        )
        for index in range(1, VALIDATOR_COUNT + 1)
    }
    committee = sorted(validators)
    if AUTHORITY_STATE_PATH.is_file():
        state = json.loads(AUTHORITY_STATE_PATH.read_text(encoding="utf-8"))
        expected = {
            validator_id: public_key_b64(key)
            for validator_id, key in validators.items()
        }
        actual = {
            validator_id: value["public_key"]
            for validator_id, value in state.get("validators", {}).items()
        }
        if state.get("committee") != committee or actual != expected:
            raise RuntimeError("local capability authority keys do not match state.json")
        return validators, state

    valid_until = datetime.now(timezone.utc) + timedelta(days=365)
    state = {
        "epoch": 1,
        "committee": committee,
        "threshold": THRESHOLD,
        "validators": {
            validator_id: {
                "public_key": public_key_b64(key),
                "valid_until": valid_until.isoformat().replace("+00:00", "Z"),
                "revoked": False,
            }
            for validator_id, key in validators.items()
        },
    }
    atomic_json(AUTHORITY_STATE_PATH, state)
    return validators, state


def operational_node_id(data_dir: Path, certificate_name: str) -> str:
    certificate = json.loads(
        (data_dir / certificate_name).read_text(encoding="utf-8")
    )
    node_id = certificate.get("node_id")
    if not isinstance(node_id, str) or not node_id:
        raise RuntimeError(f"invalid operational certificate in {data_dir}")
    return node_id


def provision_service(
    directory: str,
    capability: str,
    level: int,
    certificate_name: str,
    validators: dict[str, SigningKey],
    authority: dict,
) -> str:
    data_dir = PROJECT_ROOT / "data" / directory
    node_id = operational_node_id(data_dir, certificate_name)
    target = data_dir / "capability-certificate.json"
    previous = None
    if target.is_file():
        previous = json.loads(target.read_text(encoding="utf-8"))
        if (
            previous.get("subject_node_id") == node_id
            and previous.get("capabilities") == [capability]
            and previous.get("authority_epoch") == authority["epoch"]
        ):
            valid_until = datetime.fromisoformat(
                previous["valid_until"].replace("Z", "+00:00")
            )
            if valid_until > datetime.now(timezone.utc) + timedelta(days=1):
                return "unchanged"

    now = datetime.now(timezone.utc)
    certificate = build_capability_certificate(
        subject_node_id=node_id,
        level=level,
        capabilities=[capability],
        quotas={"max_connections": 1000},
        epoch=(int(previous["epoch"]) + 1 if previous else 1),
        authority_epoch=int(authority["epoch"]),
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=7),
        committee=authority["committee"],
        threshold=int(authority["threshold"]),
        previous_hash=capability_certificate_hash(previous) if previous else None,
    )
    for validator_id in authority["committee"][: authority["threshold"]]:
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=validators[validator_id],
        )

    credentials = {
        validator_id: ValidatorCredential(
            public_key=value["public_key"],
            valid_until=datetime.fromisoformat(value["valid_until"].replace("Z", "+00:00")),
            revoked=value["revoked"],
        )
        for validator_id, value in authority["validators"].items()
    }
    result = validate_capability_certificate(
        certificate,
        now=now,
        expected_committee=authority["committee"],
        expected_threshold=authority["threshold"],
        validator_credentials=credentials,
        expected_authority_epoch=authority["epoch"],
        expected_subject_node_id=node_id,
    )
    if not result.valid:
        raise RuntimeError(f"generated certificate is invalid: {result.reason}")
    atomic_json(target, certificate)
    return "issued"


def provision_discovery_credential_chain(directory: str) -> str:
    """One-time local migration for Discovery identities predating chains."""
    data_dir = PROJECT_ROOT / "data" / directory
    target = data_dir / "node_operational_credential_chain.json"
    existed = target.is_file()
    load_or_update_operational_credential_state(
        root_key_path=str(data_dir / "discovery_node_root.key"),
        operational_key_path=str(data_dir / "discovery_node_operational.key"),
        certificate_path=str(
            data_dir / "discovery_node_operational_certificate.json"
        ),
        credential_chain_path=str(target),
        allow_existing_certificate_genesis=True,
    )
    return "unchanged" if existed else "issued"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate presence without creating or rotating certificates",
    )
    args = parser.parse_args()
    if args.check:
        missing = [
            directory
            for directory in SERVICES
            if not (PROJECT_ROOT / "data" / directory / "capability-certificate.json").is_file()
        ]
        if missing or not AUTHORITY_STATE_PATH.is_file():
            print("missing local capability state: " + ", ".join(missing or ["authority"]))
            return 1
        print("local capability files are present")
        return 0

    validators, authority = load_validators()
    for directory, (capability, level, certificate_name) in SERVICES.items():
        if directory.startswith("discovery"):
            chain_result = provision_discovery_credential_chain(directory)
            print(f"{directory}: operational credential chain {chain_result}")
        result = provision_service(
            directory, capability, level, certificate_name, validators, authority
        )
        print(f"{directory}: {capability} certificate {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
