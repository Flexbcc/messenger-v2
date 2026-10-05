#!/usr/bin/env python3
"""Issue a capability certificate from a unified node's local authority.

Run this inside the authority node container.  Validator private keys never
leave that node; only the resulting public certificate is written to output.
"""

from __future__ import annotations

import argparse
import base64
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
    validate_capability_certificate,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node-id", required=True)
    parser.add_argument("--capabilities", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--epoch", type=int, default=1)
    parser.add_argument("--previous-hash", default=None)
    parser.add_argument(
        "--authority-state",
        default="/data/identity/capability_authority_state.json",
    )
    parser.add_argument(
        "--validator-dir",
        default="/data/identity/capability-authority",
    )
    args = parser.parse_args()

    authority = json.loads(Path(args.authority_state).read_text(encoding="utf-8"))
    committee = authority["committee"]
    threshold = int(authority["threshold"])
    validator_dir = Path(args.validator_dir)
    keys: dict[str, SigningKey] = {}
    for validator_id in committee[:threshold]:
        index = validator_id.rsplit("-", 1)[-1]
        key_path = validator_dir / f"validator-{index}.key"
        seed = base64.urlsafe_b64decode(key_path.read_text(encoding="utf-8").strip())
        if len(seed) != 32:
            raise RuntimeError(f"invalid validator seed: {key_path}")
        keys[validator_id] = SigningKey(seed)

    now = datetime.now(timezone.utc)
    capabilities = sorted({item.strip() for item in args.capabilities.split(",") if item.strip()})
    certificate = build_capability_certificate(
        subject_node_id=args.node_id,
        level=4,
        capabilities=capabilities,
        quotas={"max_connections": 1000},
        epoch=args.epoch,
        authority_epoch=int(authority["epoch"]),
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=29),
        committee=committee,
        threshold=threshold,
        previous_hash=args.previous_hash,
    )
    for validator_id, signing_key in keys.items():
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=signing_key,
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
        expected_threshold=threshold,
        validator_credentials=credentials,
        expected_authority_epoch=int(authority["epoch"]),
        expected_subject_node_id=args.node_id,
    )
    if not result.valid:
        raise RuntimeError(f"issued certificate did not validate: {result.reason}")
    target = Path(args.output)
    target.write_text(json.dumps(certificate, sort_keys=True, separators=(",", ":")) + "\n")
    target.chmod(0o600)
    print(f"issued {target} for {args.node_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
