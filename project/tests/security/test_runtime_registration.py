import json

import pytest

from shared.security.runtime import FederationSecurity, federation_registration_fields
from shared.security.node_identity import NODE_ID_PREFIX


def test_registration_rejects_unverifiable_capability_certificate(tmp_path):
    capability = {"protocol_version": "ouo-capability/1", "opaque": "test-only"}
    capability_path = tmp_path / "capability.json"
    capability_path.write_text(json.dumps(capability), encoding="utf-8")

    with pytest.raises(ValueError, match="requires a local authority state"):
        federation_registration_fields(
            str(tmp_path / "operational.key"),
            str(tmp_path / "root.key"),
            str(tmp_path / "operational-certificate.json"),
            "https://node.example",
            str(capability_path),
        )


def test_registration_can_publish_atomic_operational_credential_state(tmp_path):
    fields = federation_registration_fields(
        str(tmp_path / "operational.key"),
        str(tmp_path / "root.key"),
        str(tmp_path / "operational-certificate.json"),
        "https://node.example",
        operational_credential_chain_path=str(tmp_path / "operational-chain.json"),
    )

    assert fields["operational_credential_state"]["credential_epoch"] == 0
    assert (
        fields["operational_credential_state"]["operational_certificate"]
        == fields["operational_certificate"]
    )
    assert fields["node_advertisement"]["operational_certificate"] == fields[
        "operational_certificate"
    ]


def test_oversized_capability_file_fails_closed(tmp_path):
    capability_path = tmp_path / "capability.json"
    capability_path.write_bytes(b"x" * 65537)
    with pytest.raises(ValueError, match="exceeds size limit"):
        federation_registration_fields(
            str(tmp_path / "operational.key"),
            str(tmp_path / "root.key"),
            str(tmp_path / "operational-certificate.json"),
            "https://node.example",
            str(capability_path),
        )


def test_enforced_federation_identity_uses_self_certifying_node_id(tmp_path):
    security = FederationSecurity(
        discovery_url="https://discovery.example",
        node_id="legacy-alias",
        signing_key_path=str(tmp_path / "operational.key"),
        root_key_path=str(tmp_path / "root.key"),
        operational_certificate_path=str(tmp_path / "operational-certificate.json"),
        node_id_mode="enforce",
    )
    first = security.node_id
    second = security.node_id
    assert first == second
    assert first.startswith(NODE_ID_PREFIX)
    assert first != security.node_alias
    assert security.signing_public_key


def test_report_mode_preserves_alias_during_migration(tmp_path):
    security = FederationSecurity(
        discovery_url="https://discovery.example",
        node_id="legacy-alias",
        signing_key_path=str(tmp_path / "operational.key"),
        node_id_mode="report",
    )
    assert security.node_id == "legacy-alias"
    assert security.identity_node_id is None


def test_enforced_federation_identity_fails_without_identity_paths(tmp_path):
    security = FederationSecurity(
        discovery_url="https://discovery.example",
        node_id="legacy-alias",
        signing_key_path=str(tmp_path / "operational.key"),
        node_id_mode="enforce",
    )
    with pytest.raises(RuntimeError, match="requires identity paths"):
        _ = security.node_id
