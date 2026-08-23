import json
from datetime import datetime, timedelta, timezone

import pytest

from shared.security.node_identity import validate_operational_certificate
from shared.security.node_identity_credentials import (
    load_or_renew_operational_certificate,
    load_or_update_operational_credential_state,
    node_identity_registration_fields,
    rotate_operational_credential_bundle,
    rotate_operational_credentials,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _paths(tmp_path):
    return {
        "root_key_path": str(tmp_path / "root.key"),
        "operational_key_path": str(tmp_path / "operational.key"),
        "certificate_path": str(tmp_path / "operational-certificate.json"),
    }


def _bundle_paths(tmp_path):
    return {
        **_paths(tmp_path),
        "credential_chain_path": str(tmp_path / "operational-chain.json"),
    }


def test_credentials_are_persistent_and_private(tmp_path):
    paths = _paths(tmp_path)
    first = load_or_renew_operational_certificate(**paths, now=NOW)
    second = load_or_renew_operational_certificate(**paths, now=NOW + timedelta(hours=1))

    assert first == second
    assert validate_operational_certificate(first, now=NOW).valid
    for filename in ("root.key", "operational.key", "operational-certificate.json"):
        assert (tmp_path / filename).stat().st_mode & 0o777 == 0o600


def test_near_expiry_certificate_is_renewed_without_changing_identity(tmp_path):
    paths = _paths(tmp_path)
    first = load_or_renew_operational_certificate(**paths, now=NOW)
    renewed = load_or_renew_operational_certificate(
        **paths,
        now=NOW + timedelta(days=6, hours=1),
    )

    assert renewed["node_id"] == first["node_id"]
    assert renewed["operational_public_key"] == first["operational_public_key"]
    assert renewed["serial"] != first["serial"]


def test_registration_fields_use_certified_operational_key(tmp_path):
    fields = node_identity_registration_fields(**_paths(tmp_path))
    certificate = fields["operational_certificate"]
    assert fields["signing_public_key"] == certificate["operational_public_key"]
    assert json.loads((tmp_path / "operational-certificate.json").read_text()) == certificate


def test_operational_rotation_preserves_root_identity_and_changes_operational_key(tmp_path):
    paths = _paths(tmp_path)
    first = load_or_renew_operational_certificate(**paths, now=NOW)
    rotated = rotate_operational_credentials(**paths, now=NOW + timedelta(hours=1))

    assert rotated["node_id"] == first["node_id"]
    assert rotated["root_public_key"] == first["root_public_key"]
    assert rotated["operational_public_key"] != first["operational_public_key"]
    assert rotated["serial"] != first["serial"]
    assert validate_operational_certificate(rotated, now=NOW + timedelta(hours=1)).valid
    reloaded = load_or_renew_operational_certificate(
        **paths, now=NOW + timedelta(hours=2)
    )
    assert reloaded == rotated


def test_credential_state_chain_is_persistent_and_advances_on_renewal(tmp_path):
    paths = _bundle_paths(tmp_path)
    first = load_or_update_operational_credential_state(**paths, now=NOW)
    same = load_or_update_operational_credential_state(
        **paths,
        now=NOW + timedelta(hours=1),
    )
    renewed = load_or_update_operational_credential_state(
        **paths,
        now=NOW + timedelta(days=6, hours=1),
    )

    assert first == same
    assert first["credential_epoch"] == 0
    assert renewed["credential_epoch"] == 1
    assert renewed["node_id"] == first["node_id"]
    assert (
        renewed["operational_certificate"]["operational_public_key"]
        == first["operational_certificate"]["operational_public_key"]
    )
    document = json.loads((tmp_path / "operational-chain.json").read_text())
    assert [state["credential_epoch"] for state in document["states"]] == [0, 1]
    assert (tmp_path / "operational-chain.json").stat().st_mode & 0o777 == 0o600


def test_bundle_rotation_advances_epoch_and_changes_only_operational_key(tmp_path):
    paths = _bundle_paths(tmp_path)
    first = load_or_update_operational_credential_state(**paths, now=NOW)
    rotated = rotate_operational_credential_bundle(
        **paths,
        now=NOW + timedelta(hours=1),
    )

    assert rotated["credential_epoch"] == 1
    assert rotated["node_id"] == first["node_id"]
    assert (
        rotated["operational_certificate"]["operational_public_key"]
        != first["operational_certificate"]["operational_public_key"]
    )


def test_existing_certificate_cannot_silently_reset_missing_chain(tmp_path):
    paths = _bundle_paths(tmp_path)
    load_or_renew_operational_certificate(**_paths(tmp_path), now=NOW)

    with pytest.raises(ValueError, match="chain is missing"):
        load_or_update_operational_credential_state(**paths, now=NOW)
    migrated = load_or_update_operational_credential_state(
        **paths,
        now=NOW,
        allow_existing_certificate_genesis=True,
    )
    assert migrated["credential_epoch"] == 0


def test_corrupt_chain_fails_before_rotation(tmp_path):
    paths = _bundle_paths(tmp_path)
    first = load_or_update_operational_credential_state(**paths, now=NOW)
    document = json.loads((tmp_path / "operational-chain.json").read_text())
    document["states"][0]["previous_state_hash"] = "0" * 64
    (tmp_path / "operational-chain.json").write_text(json.dumps(document))

    with pytest.raises(ValueError, match="invalid Operational Credential chain"):
        rotate_operational_credential_bundle(
            **paths,
            now=NOW + timedelta(hours=1),
        )
    current = load_or_renew_operational_certificate(**_paths(tmp_path), now=NOW)
    assert current["operational_public_key"] == first["operational_certificate"][
        "operational_public_key"
    ]
