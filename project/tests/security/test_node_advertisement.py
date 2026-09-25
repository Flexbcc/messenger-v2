from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.node_advertisement import (
    issue_node_advertisement,
    node_advertisement_hash,
    validate_node_advertisement,
)
from shared.security.node_identity import issue_operational_certificate


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _advertisement():
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(hours=1),
        valid_until=NOW + timedelta(days=2),
    )
    advertisement = issue_node_advertisement(
        operational_signing_key=operational,
        operational_certificate=certificate,
        endpoints=["wss://node.example/ws", "https://node.example"],
        supported_transports=["https", "wss"],
        supported_protocols=["ouo-federation/1"],
        epoch=12,
        issued_at=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(hours=1),
    )
    return advertisement


def test_valid_node_advertisement_is_accepted():
    advertisement = _advertisement()
    assert validate_node_advertisement(advertisement, now=NOW, minimum_epoch=12).valid
    assert len(node_advertisement_hash(advertisement)) == 64
    assert node_advertisement_hash(advertisement) == node_advertisement_hash(dict(advertisement))


def test_endpoint_tampering_breaks_operational_signature():
    advertisement = _advertisement()
    advertisement["endpoints"] = ["https://evil.example"]
    result = validate_node_advertisement(advertisement, now=NOW)
    assert not result.valid
    assert result.reason == "invalid operational signature"


def test_credentialed_or_non_network_endpoint_is_rejected():
    advertisement = _advertisement()
    advertisement["endpoints"] = ["http://user:password@internal"]
    result = validate_node_advertisement(advertisement, now=NOW)
    assert not result.valid
    assert result.reason == "invalid endpoints"


def test_advertisement_cannot_outlive_operational_certificate():
    advertisement = _advertisement()
    advertisement["expires_at"] = "2026-08-25T12:00:00Z"
    result = validate_node_advertisement(advertisement, now=NOW)
    assert not result.valid
    assert result.reason in {
        "invalid advertisement lifetime",
        "advertisement outlives operational certificate",
    }


def test_old_advertisement_epoch_is_rejected():
    result = validate_node_advertisement(_advertisement(), now=NOW, minimum_epoch=13)
    assert not result.valid
    assert result.reason == "invalid or stale advertisement epoch"


def test_advertisement_does_not_self_assert_capabilities():
    advertisement = _advertisement()
    advertisement["capabilities"] = ["discovery", "validator"]
    result = validate_node_advertisement(advertisement, now=NOW)
    assert not result.valid
    assert result.reason == "invalid advertisement fields"
