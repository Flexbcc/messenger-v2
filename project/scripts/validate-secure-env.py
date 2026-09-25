#!/usr/bin/env python3
"""Fail-closed validation for the local node cluster secret/config file."""

import argparse
import stat
import sys
from pathlib import Path
from typing import Mapping
from urllib.parse import urlsplit


REQUIRED_SECRETS = (
    "DISCOVERY_ADMIN_SECRET",
    "JWT_SECRET",
    "MEDIA_ACCESS_SECRET",
    "TURN_SHARED_SECRET",
    "PUSH_PROXY_SECRET",
    "GATEWAY_INVITE_SECRET",
    "ADMIN_PANEL_SECRET",
    "MESH_NOTIFY_SECRET",
)
NODE_ID_FIELDS = (
    "HOME_NODE_ID",
    "STORAGE_NODE_ID",
    "MEDIA_NODE_ID",
    "RELAY_NODE_ID",
    "TURN_NODE_ID",
    "GATEWAY_NODE_ID",
)
REQUIRED_MODES = {
    "ENROLLMENT_MODE": "strict",
    "INTERNAL_SECURITY_MODE": "signed",
    "FEDERATION_NODE_ID_MODE": "enforce",
    "FEDERATION_ENVELOPE_MODE": "signed",
    "FEDERATION_CAPABILITY_MODE": "enforce",
    "CAPABILITY_CERTIFICATE_MODE": "enforce",
    "TRUST_DEGRADATION_MODE": "observe",
    "TRUST_LEDGER_MODE": "enforce",
    "RANDOMNESS_CHECKPOINT_MODE": "enforce",
    "OPERATIONAL_CREDENTIAL_STATE_MODE": "enforce",
    "OPERATIONAL_CREDENTIAL_REVOCATION_MODE": "enforce",
    "SIGNED_PEER_SELECTION_MODE": "enforce",
    "ROUTE_RESOLUTION_MODE": "enforce",
}
FORBIDDEN_MARKERS = (
    "change-me",
    "changeme",
    "replace_",
    "replace-with",
    "dev-secret",
    "insecure",
)


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            raise ValueError(f"line {number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or key in values:
            raise ValueError(f"line {number}: empty or duplicate key")
        values[key] = value
    return values


def validate_secure_environment(values: Mapping[str, str]) -> list[str]:
    errors: list[str] = []
    for key, expected in REQUIRED_MODES.items():
        if values.get(key) != expected:
            errors.append(f"{key} must be {expected!r}")

    try:
        max_body_bytes = int(values.get("FEDERATION_MAX_BODY_BYTES", "1048576"))
        if not 1024 <= max_body_bytes <= 16 * 1024 * 1024:
            raise ValueError
    except ValueError:
        errors.append("FEDERATION_MAX_BODY_BYTES must be an integer between 1024 and 16777216")

    secret_values: dict[str, str] = {}
    for key in REQUIRED_SECRETS:
        value = values.get(key, "")
        lowered = value.lower()
        if len(value.encode("utf-8")) < 32:
            errors.append(f"{key} must contain at least 32 bytes")
        if any(marker in lowered for marker in FORBIDDEN_MARKERS):
            errors.append(f"{key} still contains a placeholder/insecure marker")
        if value:
            secret_values[key] = value
    duplicates: dict[str, list[str]] = {}
    for key, value in secret_values.items():
        duplicates.setdefault(value, []).append(key)
    for keys in duplicates.values():
        if len(keys) > 1:
            errors.append("secrets must be independent: " + ", ".join(sorted(keys)))

    node_ids = [values.get(key, "").strip() for key in NODE_ID_FIELDS]
    for key, node_id in zip(NODE_ID_FIELDS, node_ids):
        if not node_id:
            errors.append(f"{key} is required")
    if len([node_id for node_id in node_ids if node_id]) != len(set(filter(None, node_ids))):
        errors.append("logical node IDs must be unique")

    def origins(key: str) -> list[str]:
        result = []
        for value in values.get(key, "").split(","):
            value = value.strip()
            if not value:
                continue
            parsed = urlsplit(value)
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.username
                or parsed.password
                or parsed.query
                or parsed.fragment
                or parsed.path not in {"", "/"}
            ):
                errors.append(f"{key} contains an invalid origin: {value}")
            result.append(value.rstrip("/"))
        if len(result) != len(set(result)):
            errors.append(f"{key} must not contain duplicate origins")
        return result

    gossip_enabled = values.get("NODE_ADVERTISEMENT_GOSSIP_ENABLED", "false").lower() in {
        "1", "true", "yes", "on"
    }
    gossip_origins = origins("NODE_ADVERTISEMENT_GOSSIP_PEERS")
    if gossip_enabled and len(gossip_origins) < 2:
        errors.append("NODE_ADVERTISEMENT_GOSSIP_ENABLED requires at least two peers")

    authority_gossip_enabled = values.get(
        "AUTHORITY_GOSSIP_ENABLED", "false"
    ).lower() in {"1", "true", "yes", "on"}
    authority_gossip_origins = origins("AUTHORITY_GOSSIP_PEERS")
    if authority_gossip_enabled and len(authority_gossip_origins) < 2:
        errors.append("AUTHORITY_GOSSIP_ENABLED requires at least two peers")

    trust_gossip_enabled = values.get("TRUST_RECORD_GOSSIP_ENABLED", "false").lower() in {
        "1", "true", "yes", "on"
    }
    trust_gossip_origins = origins("TRUST_RECORD_GOSSIP_PEERS")
    if trust_gossip_enabled and len(trust_gossip_origins) < 2:
        errors.append("TRUST_RECORD_GOSSIP_ENABLED requires at least two peers")

    capability_mode = values.get(
        "CAPABILITY_CERTIFICATE_MODE", "report"
    ).lower()
    if capability_mode not in {"off", "report", "enforce"}:
        errors.append("CAPABILITY_CERTIFICATE_MODE must be off, report, or enforce")
    if capability_mode == "enforce" and not values.get(
        "CAPABILITY_AUTHORITY_STATE_PATH", ""
    ).strip():
        errors.append(
            "CAPABILITY_CERTIFICATE_MODE=enforce requires "
            "CAPABILITY_AUTHORITY_STATE_PATH"
        )

    trust_ledger_mode = values.get("TRUST_LEDGER_MODE", "report").lower()
    if trust_ledger_mode not in {"off", "report", "enforce"}:
        errors.append("TRUST_LEDGER_MODE must be off, report, or enforce")
    if trust_ledger_mode == "enforce":
        if not values.get("TRUST_AUTHORITY_STATE_PATH", "").strip():
            errors.append(
                "TRUST_LEDGER_MODE=enforce requires TRUST_AUTHORITY_STATE_PATH"
            )
        if not trust_gossip_enabled:
            errors.append(
                "TRUST_LEDGER_MODE=enforce requires TRUST_RECORD_GOSSIP_ENABLED"
            )
        if not authority_gossip_enabled:
            errors.append(
                "TRUST_LEDGER_MODE=enforce requires AUTHORITY_GOSSIP_ENABLED"
            )
    trust_proposal_mode = values.get("TRUST_PROPOSAL_MODE", "off").lower()
    if trust_proposal_mode not in {"off", "report"}:
        errors.append("TRUST_PROPOSAL_MODE must be off or report")
    if trust_ledger_mode == "enforce" and trust_proposal_mode == "off":
        errors.append(
            "TRUST_LEDGER_MODE=enforce requires TRUST_PROPOSAL_MODE=report"
        )

    assignment_gossip_enabled = values.get(
        "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED", "false"
    ).lower() in {"1", "true", "yes", "on"}
    assignment_gossip_origins = origins("CHALLENGE_ASSIGNMENT_GOSSIP_PEERS")
    if assignment_gossip_enabled and len(assignment_gossip_origins) < 2:
        errors.append("CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED requires at least two peers")

    randomness_mode = values.get("RANDOMNESS_CHECKPOINT_MODE", "report").lower()
    if randomness_mode not in {"off", "report", "enforce"}:
        errors.append("RANDOMNESS_CHECKPOINT_MODE must be off, report, or enforce")
    if randomness_mode == "enforce" and not assignment_gossip_enabled:
        errors.append(
            "RANDOMNESS_CHECKPOINT_MODE=enforce requires CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED"
        )
    proposal_mode = values.get("CHALLENGE_PROPOSAL_SCHEDULER_MODE", "off").lower()
    if proposal_mode not in {"off", "report", "enforce"}:
        errors.append(
            "CHALLENGE_PROPOSAL_SCHEDULER_MODE must be off, report, or enforce"
        )
    if randomness_mode == "enforce" and proposal_mode != "enforce":
        errors.append(
            "RANDOMNESS_CHECKPOINT_MODE=enforce requires "
            "CHALLENGE_PROPOSAL_SCHEDULER_MODE=enforce"
        )
    observer_enabled = values.get(
        "NODE_CHALLENGE_OBSERVER_ENABLED", "false"
    ).lower() in {"1", "true", "yes", "on"}
    if proposal_mode == "enforce" and not observer_enabled:
        errors.append(
            "CHALLENGE_PROPOSAL_SCHEDULER_MODE=enforce requires "
            "NODE_CHALLENGE_OBSERVER_ENABLED=true"
        )

    credential_state_mode = values.get(
        "OPERATIONAL_CREDENTIAL_STATE_MODE", "report"
    ).lower()
    if credential_state_mode not in {"off", "report", "enforce"}:
        errors.append(
            "OPERATIONAL_CREDENTIAL_STATE_MODE must be off, report, or enforce"
        )
    if credential_state_mode == "enforce" and not (
        gossip_enabled or assignment_gossip_enabled
    ):
        errors.append(
            "OPERATIONAL_CREDENTIAL_STATE_MODE=enforce requires "
            "NodeAdvertisement or ChallengeAssignment gossip"
        )
    if credential_state_mode == "enforce" and not values.get(
        "NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH", ""
    ).strip():
        errors.append(
            "OPERATIONAL_CREDENTIAL_STATE_MODE=enforce requires "
            "NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"
        )

    credential_revocation_mode = values.get(
        "OPERATIONAL_CREDENTIAL_REVOCATION_MODE", "report"
    ).lower()
    if credential_revocation_mode not in {"off", "report", "enforce"}:
        errors.append(
            "OPERATIONAL_CREDENTIAL_REVOCATION_MODE must be off, report, or enforce"
        )
    if credential_revocation_mode == "enforce" and credential_state_mode != "enforce":
        errors.append(
            "OPERATIONAL_CREDENTIAL_REVOCATION_MODE=enforce requires "
            "OPERATIONAL_CREDENTIAL_STATE_MODE=enforce"
        )
    if credential_revocation_mode == "enforce" and not values.get(
        "TRUST_AUTHORITY_STATE_PATH", ""
    ).strip():
        errors.append(
            "OPERATIONAL_CREDENTIAL_REVOCATION_MODE=enforce requires "
            "TRUST_AUTHORITY_STATE_PATH"
        )

    peer_mode = values.get("SIGNED_PEER_SELECTION_MODE", "off").lower()
    if peer_mode not in {"off", "report", "enforce"}:
        errors.append("SIGNED_PEER_SELECTION_MODE must be off, report, or enforce")
    peer_origins = origins("PEER_DISCOVERY_URLS")
    if peer_mode == "enforce":
        if len(peer_origins) < 2:
            errors.append("enforced signed peer selection requires at least two Discovery origins")
        for key in ("PEER_AUTHORITY_STATE_PATH", "PEER_DISCOVERY_SOURCE_SET_PATH"):
            if not values.get(key, "").strip():
                errors.append(f"{key} is required for enforced signed peer selection")

    route_mode = values.get("ROUTE_RESOLUTION_MODE", "off").lower()
    if route_mode not in {"off", "report", "enforce"}:
        errors.append("ROUTE_RESOLUTION_MODE must be off, report, or enforce")
    route_origins = origins("ROUTE_DISCOVERY_URLS")
    try:
        route_minimum = int(values.get("ROUTE_MINIMUM_DISCOVERY_SOURCES", "2"))
        if not 1 <= route_minimum <= 16:
            raise ValueError
    except ValueError:
        route_minimum = 2
        errors.append("ROUTE_MINIMUM_DISCOVERY_SOURCES must be between 1 and 16")
    if route_mode == "enforce" and len(route_origins) < route_minimum:
        errors.append("enforced route resolution requires a Discovery quorum")

    federation_origins = origins("FEDERATION_DISCOVERY_URLS")
    try:
        federation_minimum = int(
            values.get("FEDERATION_MINIMUM_DISCOVERY_SOURCES", "2")
        )
        if not 2 <= federation_minimum <= 16:
            raise ValueError
    except ValueError:
        federation_minimum = 2
        errors.append(
            "FEDERATION_MINIMUM_DISCOVERY_SOURCES must be between 2 and 16"
        )
    if len(federation_origins) < federation_minimum:
        errors.append("secure Federation authentication requires a Discovery quorum")

    rendezvous_enabled = values.get("RENDEZVOUS_GOSSIP_ENABLED", "false").lower() in {
        "1", "true", "yes", "on"
    }
    rendezvous_origins = origins("RENDEZVOUS_GOSSIP_PEERS")
    if rendezvous_enabled and len(rendezvous_origins) < 2:
        errors.append("RENDEZVOUS_GOSSIP_ENABLED requires at least two peers")

    origins("STORAGE_NODE_URLS")
    try:
        storage_replication = int(values.get("STORAGE_REPLICATION_FACTOR", "1"))
        if not 1 <= storage_replication <= 5:
            raise ValueError
    except ValueError:
        storage_replication = 1
        errors.append("STORAGE_REPLICATION_FACTOR must be an integer between 1 and 5")
    try:
        storage_quorum = int(values.get("STORAGE_WRITE_QUORUM", "1"))
        if not 1 <= storage_quorum <= 5:
            raise ValueError
    except ValueError:
        storage_quorum = 1
        errors.append("STORAGE_WRITE_QUORUM must be an integer between 1 and 5")
    if storage_quorum > storage_replication:
        errors.append("STORAGE_WRITE_QUORUM cannot exceed STORAGE_REPLICATION_FACTOR")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("env_file", type=Path)
    parser.add_argument(
        "--allow-insecure-permissions",
        action="store_true",
        help="skip owner-only file mode check (tests only)",
    )
    args = parser.parse_args()
    if not args.env_file.is_file():
        print(f"secure env file not found: {args.env_file}", file=sys.stderr)
        return 2
    if not args.allow_insecure_permissions:
        mode = stat.S_IMODE(args.env_file.stat().st_mode)
        if mode & 0o077:
            print(
                f"secure env must be owner-only (chmod 600); current mode is {mode:o}",
                file=sys.stderr,
            )
            return 2
    try:
        values = parse_env_file(args.env_file)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"cannot parse secure env: {exc}", file=sys.stderr)
        return 2
    errors = validate_secure_environment(values)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("secure environment validation: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
