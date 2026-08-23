import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "validate-secure-env.py"
SPEC = importlib.util.spec_from_file_location("validate_secure_env", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _valid_values():
    values = dict(MODULE.REQUIRED_MODES)
    values["CAPABILITY_AUTHORITY_STATE_PATH"] = "/data/capability_authority.json"
    for index, key in enumerate(MODULE.REQUIRED_SECRETS):
        values[key] = f"{index:02d}-" + (chr(65 + index) * 40)
    for index, key in enumerate(MODULE.NODE_ID_FIELDS):
        values[key] = f"node-{index}"
    return values


def test_valid_secure_environment_is_accepted():
    assert MODULE.validate_secure_environment(_valid_values()) == []


def test_default_or_short_secrets_are_rejected():
    values = _valid_values()
    values["JWT_SECRET"] = "change-me"
    errors = MODULE.validate_secure_environment(values)
    assert any("JWT_SECRET must contain" in error for error in errors)
    assert any("JWT_SECRET still contains" in error for error in errors)


def test_reused_secrets_are_rejected():
    values = _valid_values()
    values["JWT_SECRET"] = values["TURN_SHARED_SECRET"]
    errors = MODULE.validate_secure_environment(values)
    assert any("secrets must be independent" in error for error in errors)


def test_legacy_modes_are_rejected():
    values = _valid_values()
    values["ENROLLMENT_MODE"] = "legacy"
    values["INTERNAL_SECURITY_MODE"] = "legacy"
    values["FEDERATION_CAPABILITY_MODE"] = "report"
    values["CAPABILITY_CERTIFICATE_MODE"] = "report"
    errors = MODULE.validate_secure_environment(values)
    assert "ENROLLMENT_MODE must be 'strict'" in errors
    assert "INTERNAL_SECURITY_MODE must be 'signed'" in errors
    assert "FEDERATION_CAPABILITY_MODE must be 'enforce'" in errors
    assert "CAPABILITY_CERTIFICATE_MODE must be 'enforce'" in errors


def test_duplicate_logical_node_ids_are_rejected():
    values = _valid_values()
    values["HOME_NODE_ID"] = values["RELAY_NODE_ID"]
    assert "logical node IDs must be unique" in MODULE.validate_secure_environment(values)


def test_enforced_signed_peer_selection_requires_two_origins_and_bootstrap_files():
    values = _valid_values()
    values["SIGNED_PEER_SELECTION_MODE"] = "enforce"
    values["PEER_DISCOVERY_URLS"] = "https://d1.example"
    errors = MODULE.validate_secure_environment(values)
    assert "enforced signed peer selection requires at least two Discovery origins" in errors
    assert any("PEER_AUTHORITY_STATE_PATH is required" in error for error in errors)
    assert any("PEER_DISCOVERY_SOURCE_SET_PATH is required" in error for error in errors)

    values["PEER_DISCOVERY_URLS"] = "https://d1.example,https://d2.example"
    values["PEER_AUTHORITY_STATE_PATH"] = "/run/ouo/authority.json"
    values["PEER_DISCOVERY_SOURCE_SET_PATH"] = "/run/ouo/discovery-sources.json"
    assert MODULE.validate_secure_environment(values) == []


def test_advertisement_gossip_rejects_invalid_or_single_peer_configuration():
    values = _valid_values()
    values["NODE_ADVERTISEMENT_GOSSIP_ENABLED"] = "true"
    values["NODE_ADVERTISEMENT_GOSSIP_PEERS"] = "https://user:secret@d1.example/path"
    errors = MODULE.validate_secure_environment(values)
    assert any("invalid origin" in error for error in errors)
    assert any("requires at least two peers" in error for error in errors)


def test_trust_record_gossip_requires_two_valid_peer_origins():
    values = _valid_values()
    values["TRUST_RECORD_GOSSIP_ENABLED"] = "true"
    values["TRUST_RECORD_GOSSIP_PEERS"] = "https://d2.example"
    errors = MODULE.validate_secure_environment(values)
    assert "TRUST_RECORD_GOSSIP_ENABLED requires at least two peers" in errors

    values["TRUST_RECORD_GOSSIP_PEERS"] = "https://d2.example,https://d3.example"
    assert MODULE.validate_secure_environment(values) == []


def test_authority_gossip_requires_two_valid_peer_origins():
    values = _valid_values()
    values["AUTHORITY_GOSSIP_ENABLED"] = "true"
    values["AUTHORITY_GOSSIP_PEERS"] = "https://d2.example"
    errors = MODULE.validate_secure_environment(values)
    assert "AUTHORITY_GOSSIP_ENABLED requires at least two peers" in errors

    values["AUTHORITY_GOSSIP_PEERS"] = "https://d2.example,https://d3.example"
    assert MODULE.validate_secure_environment(values) == []


def test_capability_enforce_requires_authority_state():
    values = _valid_values()
    values["CAPABILITY_AUTHORITY_STATE_PATH"] = ""
    errors = MODULE.validate_secure_environment(values)
    assert any("CAPABILITY_AUTHORITY_STATE_PATH" in error for error in errors)

    values["CAPABILITY_AUTHORITY_STATE_PATH"] = "/run/ouo/capability-authority.json"
    assert MODULE.validate_secure_environment(values) == []


def test_trust_ledger_enforce_requires_authority_and_replica_gossip():
    values = _valid_values()
    values["TRUST_LEDGER_MODE"] = "enforce"
    errors = MODULE.validate_secure_environment(values)
    assert any("TRUST_AUTHORITY_STATE_PATH" in error for error in errors)
    assert any("TRUST_RECORD_GOSSIP_ENABLED" in error for error in errors)
    assert any("AUTHORITY_GOSSIP_ENABLED" in error for error in errors)

    values.update(
        {
            "TRUST_AUTHORITY_STATE_PATH": "/run/ouo/trust-authority.json",
            "TRUST_RECORD_GOSSIP_ENABLED": "true",
            "TRUST_RECORD_GOSSIP_PEERS": "https://d2.example,https://d3.example",
            "AUTHORITY_GOSSIP_ENABLED": "true",
            "AUTHORITY_GOSSIP_PEERS": "https://d2.example,https://d3.example",
        }
    )
    assert MODULE.validate_secure_environment(values) == []


def test_federation_body_limit_is_bounded():
    values = _valid_values()
    values["FEDERATION_MAX_BODY_BYTES"] = "999999999"
    assert any(
        "FEDERATION_MAX_BODY_BYTES" in error
        for error in MODULE.validate_secure_environment(values)
    )


def test_storage_replication_quorum_is_bounded_and_fail_closed():
    values = _valid_values()
    values["STORAGE_NODE_URLS"] = "https://storage-a.example,https://storage-b.example"
    values["STORAGE_REPLICATION_FACTOR"] = "2"
    values["STORAGE_WRITE_QUORUM"] = "3"
    errors = MODULE.validate_secure_environment(values)
    assert "STORAGE_WRITE_QUORUM cannot exceed STORAGE_REPLICATION_FACTOR" in errors

    values["STORAGE_WRITE_QUORUM"] = "2"
    assert MODULE.validate_secure_environment(values) == []

    values["STORAGE_NODE_URLS"] = "https://user:secret@storage-a.example/path"
    assert any(
        "STORAGE_NODE_URLS contains an invalid origin" in error
        for error in MODULE.validate_secure_environment(values)
    )


def test_challenge_assignment_gossip_requires_two_peer_origins():
    values = _valid_values()
    values["CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED"] = "true"
    values["CHALLENGE_ASSIGNMENT_GOSSIP_PEERS"] = "https://d2.example"
    errors = MODULE.validate_secure_environment(values)
    assert "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED requires at least two peers" in errors

    values["CHALLENGE_ASSIGNMENT_GOSSIP_PEERS"] = (
        "https://d2.example,https://d3.example"
    )
    assert MODULE.validate_secure_environment(values) == []


def test_randomness_enforce_requires_assignment_lifecycle_gossip():
    values = _valid_values()
    values["RANDOMNESS_CHECKPOINT_MODE"] = "enforce"
    errors = MODULE.validate_secure_environment(values)
    assert (
        "RANDOMNESS_CHECKPOINT_MODE=enforce requires "
        "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED"
    ) in errors

    values["CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED"] = "true"
    values["CHALLENGE_ASSIGNMENT_GOSSIP_PEERS"] = (
        "https://d2.example,https://d3.example"
    )
    assert MODULE.validate_secure_environment(values) == []


def test_operational_credential_enforce_requires_replica_gossip():
    values = _valid_values()
    values["OPERATIONAL_CREDENTIAL_STATE_MODE"] = "enforce"
    errors = MODULE.validate_secure_environment(values)
    assert (
        "OPERATIONAL_CREDENTIAL_STATE_MODE=enforce requires "
        "NodeAdvertisement or ChallengeAssignment gossip"
    ) in errors
    assert (
        "OPERATIONAL_CREDENTIAL_STATE_MODE=enforce requires "
        "NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"
    ) in errors

    values["NODE_ADVERTISEMENT_GOSSIP_ENABLED"] = "true"
    values["NODE_ADVERTISEMENT_GOSSIP_PEERS"] = (
        "https://d2.example,https://d3.example"
    )
    values["NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"] = (
        "/data/node_operational_credential_chain.json"
    )
    assert MODULE.validate_secure_environment(values) == []

    values = _valid_values()
    values["OPERATIONAL_CREDENTIAL_STATE_MODE"] = "enforce"
    values["CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED"] = "true"
    values["CHALLENGE_ASSIGNMENT_GOSSIP_PEERS"] = (
        "https://d2.example,https://d3.example"
    )
    values["NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"] = (
        "/data/node_operational_credential_chain.json"
    )
    assert MODULE.validate_secure_environment(values) == []


def test_operational_credential_revocation_enforce_requires_chain_and_authority():
    values = _valid_values()
    values["OPERATIONAL_CREDENTIAL_REVOCATION_MODE"] = "enforce"
    errors = MODULE.validate_secure_environment(values)
    assert any("STATE_MODE=enforce" in error for error in errors)
    assert any("TRUST_AUTHORITY_STATE_PATH" in error for error in errors)

    values["OPERATIONAL_CREDENTIAL_STATE_MODE"] = "enforce"
    values["NODE_ADVERTISEMENT_GOSSIP_ENABLED"] = "true"
    values["NODE_ADVERTISEMENT_GOSSIP_PEERS"] = (
        "https://d2.example,https://d3.example"
    )
    values["NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"] = (
        "/data/node_operational_credential_chain.json"
    )
    values["TRUST_AUTHORITY_STATE_PATH"] = "/run/ouo/authority.json"
    assert MODULE.validate_secure_environment(values) == []
