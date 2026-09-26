from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.home_migration import (
    device_manifest_hash,
    issue_home_migration_ticket,
    validate_and_consume_home_migration_ticket,
    validate_home_migration_ticket,
)
from shared.security.nonce_store import NonceStore
from shared.security.keys import public_key_b64


NOW = datetime(2026, 9, 26, 12, 0, tzinfo=timezone.utc)


def _manifest():
    return {
        "devices": [
            {
                "device_id": "device-a",
                "auth_public_key": "public-only",
                "trusted": True,
            }
        ],
        "profile": {"display_name": "Alice"},
    }


def _ticket(key: SigningKey):
    return issue_home_migration_ticket(
        identity_signing_key=key,
        identity_version=3,
        route_epoch=12,
        from_home="https://old.example/home",
        to_home="https://new.example/home",
        manifest_hash=device_manifest_hash(_manifest()),
        issued_at=NOW,
        expires_at=NOW + timedelta(minutes=10),
        nonce=b"n" * 32,
    )


def test_valid_ticket_binds_identity_homes_and_manifest():
    ticket = _ticket(SigningKey.generate())
    result = validate_home_migration_ticket(
        ticket,
        now=NOW + timedelta(minutes=1),
        expected_user_id=ticket["user_id"],
        expected_from_home="https://old.example/home",
        expected_to_home="https://new.example/home",
        expected_manifest_hash=device_manifest_hash(_manifest()),
        minimum_identity_version=3,
        minimum_route_epoch=12,
    )
    assert result.valid, result.reason


def test_tampering_destination_invalidates_signature():
    ticket = _ticket(SigningKey.generate())
    ticket["to_home"] = "https://attacker.example/home"
    result = validate_home_migration_ticket(ticket, now=NOW)
    assert not result.valid
    assert result.reason == "invalid identity signature"


def test_manifest_substitution_is_rejected_before_import():
    ticket = _ticket(SigningKey.generate())
    replacement = {"devices": [], "profile": {"display_name": "Mallory"}}
    result = validate_home_migration_ticket(
        ticket,
        now=NOW,
        expected_manifest_hash=device_manifest_hash(replacement),
    )
    assert not result.valid
    assert result.reason == "device manifest hash mismatch"


def test_expired_ticket_is_rejected():
    ticket = _ticket(SigningKey.generate())
    result = validate_home_migration_ticket(
        ticket,
        now=NOW + timedelta(minutes=13),
    )
    assert not result.valid
    assert result.reason == "ticket has expired"


def test_insecure_or_equal_home_urls_are_rejected():
    key = SigningKey.generate()
    ticket = _ticket(key)
    ticket["to_home"] = ticket["from_home"]
    result = validate_home_migration_ticket(ticket, now=NOW)
    assert not result.valid
    assert result.reason == "source and destination Home are equal"


def test_route_and_identity_rollback_are_rejected():
    ticket = _ticket(SigningKey.generate())
    assert not validate_home_migration_ticket(
        ticket, now=NOW, minimum_identity_version=4
    ).valid
    assert not validate_home_migration_ticket(
        ticket, now=NOW, minimum_route_epoch=13
    ).valid


def test_ticket_can_be_consumed_only_once():
    ticket = _ticket(SigningKey.generate())
    store = NonceStore()
    first = validate_and_consume_home_migration_ticket(
        ticket,
        nonce_store=store,
        now=NOW,
        expected_manifest_hash=device_manifest_hash(_manifest()),
    )
    replay = validate_and_consume_home_migration_ticket(
        ticket,
        nonce_store=store,
        now=NOW,
        expected_manifest_hash=device_manifest_hash(_manifest()),
    )
    assert first.valid
    assert not replay.valid
    assert replay.reason == "migration ticket already consumed"


def test_dual_bound_legacy_uuid_can_authorize_migration():
    key = SigningKey.generate()
    manifest_hash = device_manifest_hash(_manifest())
    ticket = issue_home_migration_ticket(
        identity_signing_key=key,
        user_id="legacy-account-uuid",
        identity_version=1,
        route_epoch=4,
        from_home="https://old.example/home",
        to_home="https://new.example/home",
        manifest_hash=manifest_hash,
        issued_at=NOW,
        expires_at=NOW + timedelta(minutes=10),
    )
    result = validate_home_migration_ticket(
        ticket,
        now=NOW,
        expected_user_id="legacy-account-uuid",
        expected_identity_public_key=public_key_b64(key),
        expected_manifest_hash=manifest_hash,
    )
    assert result.valid, result.reason


def test_legacy_uuid_rejects_a_different_identity_root():
    key = SigningKey.generate()
    ticket = issue_home_migration_ticket(
        identity_signing_key=key,
        user_id="legacy-account-uuid",
        identity_version=1,
        route_epoch=4,
        from_home="https://old.example/home",
        to_home="https://new.example/home",
        manifest_hash=device_manifest_hash(_manifest()),
        issued_at=NOW,
        expires_at=NOW + timedelta(minutes=10),
    )
    result = validate_home_migration_ticket(
        ticket,
        now=NOW,
        expected_user_id="legacy-account-uuid",
        expected_identity_public_key=public_key_b64(SigningKey.generate()),
    )
    assert not result.valid
    assert result.reason == "Identity Root mismatch"
