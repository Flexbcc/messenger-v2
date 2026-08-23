import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey
import pytest
from fastapi import HTTPException

from shared.security.node_identity import NODE_ID_PREFIX, issue_operational_certificate
from shared.security.node_advertisement import issue_node_advertisement
from shared.security.capability_certificate import (
    add_validator_signature,
    build_capability_certificate,
    capability_certificate_hash,
)
from shared.security.capability_enrollment import parse_capability_authority_state
from shared.security.keys import public_key_b64
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
    operational_credential_state_hash,
)
from shared.security.operational_credential_revocation import (
    operational_certificate_hash,
)


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"


@contextmanager
def _discovery_modules():
    previous_app_modules = {
        name: module
        for name, module in sys.modules.items()
        if name == "app" or name.startswith("app.")
    }
    for name in previous_app_modules:
        del sys.modules[name]
    sys.path.insert(0, str(DISCOVERY_ROOT))
    try:
        db = importlib.import_module("app.db")
        schemas = importlib.import_module("app.schemas")
        registry = importlib.import_module("app.routers.registry")
        yield db, schemas, registry
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous_app_modules)


def _certificate():
    now = datetime.now(timezone.utc)
    root = SigningKey.generate()
    operational = SigningKey.generate()
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )


def test_discovery_persists_valid_identity_report_and_certified_key(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "report"
        db.init_db()
        certificate = _certificate()

        response = registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="home-a",
                node_url="http://home-a:8001",
                capabilities=["home"],
                operational_certificate=certificate,
            )
        )

        assert response.node_id == "home-a"
        assert response.identity_node_id == certificate["node_id"]
        assert response.node_identity_status == "valid"
        assert response.signing_public_key == certificate["operational_public_key"]
        with db.get_conn() as conn:
            row = conn.execute(
                "SELECT identity_node_id, operational_certificate FROM node_capabilities "
                "WHERE node_id = ?",
                ("home-a",),
            ).fetchone()
        assert row["identity_node_id"] == certificate["node_id"]
        assert row["operational_certificate"]


def test_discovery_reports_root_conflict_without_rebinding_alias(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "report"
        db.init_db()
        first = _certificate()
        second = _certificate()

        for certificate in (first, second):
            response = registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="relay-a",
                    node_url="http://relay-a:8005",
                    capabilities=["relay"],
                    operational_certificate=certificate,
                )
            )

        assert response.node_identity_status == "conflict"
        assert response.identity_node_id == first["node_id"]
        with db.get_conn() as conn:
            bound = conn.execute(
                "SELECT identity_node_id FROM node_capabilities WHERE node_id = ?",
                ("relay-a",),
            ).fetchone()["identity_node_id"]
        assert bound == first["node_id"]


def test_discovery_enforce_rejects_operational_certificate_rollback(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        older = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=SigningKey.generate().verify_key,
            issued_at=now - timedelta(minutes=2),
            valid_until=now + timedelta(hours=12),
        )
        newer = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=SigningKey.generate().verify_key,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(hours=12),
        )
        for certificate in (older, newer):
            response = registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="rotating-home",
                    node_url="https://home.example",
                    capabilities=["home"],
                    operational_certificate=certificate,
                )
            )
            assert response.signing_public_key == certificate["operational_public_key"]

        with pytest.raises(HTTPException) as error:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="rotating-home",
                    node_url="https://home.example",
                    capabilities=["home"],
                    operational_certificate=older,
                )
            )
        assert error.value.status_code == 403
        with db.get_conn() as conn:
            row = conn.execute(
                """SELECT signing_public_key, operational_certificate
                   FROM node_capabilities WHERE node_id = ?""",
                ("rotating-home",),
            ).fetchone()
        assert row["signing_public_key"] == newer["operational_public_key"]
        assert newer["serial"] in row["operational_certificate"]


def test_registration_enforces_and_atomically_advances_credential_chain(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.OPERATIONAL_CREDENTIAL_STATE_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        first_certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=SigningKey.generate().verify_key,
            issued_at=now - timedelta(minutes=2),
            valid_until=now + timedelta(hours=12),
        )
        first_state = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=first_certificate,
            credential_epoch=0,
        )
        without_state = schemas.RegisterNodeCapability(
            node_id="stateful-home",
            node_url="https://home.example",
            capabilities=["home"],
            operational_certificate=first_certificate,
        )
        with pytest.raises(HTTPException, match="state is required") as missing:
            registry.register_node_capability(without_state)
        assert missing.value.status_code == 403

        first_response = registry.register_node_capability(
            without_state.model_copy(
                update={"operational_credential_state": first_state}
            )
        )
        assert first_response.identity_node_id == first_state["node_id"]

        second_certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=SigningKey.generate().verify_key,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(hours=12),
        )
        second_state = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=second_certificate,
            credential_epoch=1,
            previous_state_hash=operational_credential_state_hash(first_state),
        )
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="stateful-home",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=second_certificate,
                operational_credential_state=second_state,
            )
        )
        third_certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=SigningKey.generate().verify_key,
            issued_at=now,
            valid_until=now + timedelta(hours=12),
        )
        third_state = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=third_certificate,
            credential_epoch=2,
            previous_state_hash=operational_credential_state_hash(second_state),
        )
        heartbeat_response = registry.heartbeat(
            "stateful-home",
            schemas.HeartbeatRequest(
                signing_public_key=third_certificate["operational_public_key"],
                operational_certificate=third_certificate,
                operational_credential_state=third_state,
            ),
        )
        assert heartbeat_response.signing_public_key == third_certificate[
            "operational_public_key"
        ]
        with pytest.raises(HTTPException) as rollback:
            registry.heartbeat(
                "stateful-home",
                schemas.HeartbeatRequest(
                    signing_public_key=second_certificate["operational_public_key"],
                    operational_certificate=second_certificate,
                    operational_credential_state=second_state,
                ),
            )
        assert rollback.value.status_code == 403
        with db.get_conn() as conn:
            rows = conn.execute(
                """SELECT credential_epoch FROM operational_credential_states
                   WHERE node_id = ? ORDER BY credential_epoch""",
                (first_state["node_id"],),
            ).fetchall()
        assert [row["credential_epoch"] for row in rows] == [0, 1, 2]


def test_revoked_operational_serial_cannot_register_or_heartbeat(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.OPERATIONAL_CREDENTIAL_STATE_MODE = "report"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        certificate = _certificate()
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="revoked-home",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=certificate,
            )
        )
        revocation_store = importlib.import_module(
            "app.operational_credential_revocation_store"
        )
        revocation_store.OPERATIONAL_CREDENTIAL_REVOCATION_MODE = "enforce"
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with db.get_conn() as conn:
            conn.execute(
                """INSERT INTO operational_credential_revocations (
                       node_id, revocation_epoch, revocation_hash, previous_hash,
                       credential_epoch, certificate_serial, certificate_hash,
                       operational_public_key, authority_epoch, effective_at,
                       revocation_json, stored_at
                   ) VALUES (?, 0, ?, ?, 0, ?, ?, ?, 0, ?, '{}', ?)""",
                (
                    certificate["node_id"],
                    "1" * 64,
                    "2" * 64,
                    certificate["serial"],
                    operational_certificate_hash(certificate),
                    certificate["operational_public_key"],
                    now,
                    now,
                ),
            )
            conn.commit()

        request = schemas.RegisterNodeCapability(
            node_id="revoked-home",
            node_url="https://home.example",
            capabilities=["home"],
            operational_certificate=certificate,
        )
        with pytest.raises(HTTPException, match="revoked") as registration:
            registry.register_node_capability(request)
        assert registration.value.status_code == 403
        with pytest.raises(HTTPException, match="revoked") as heartbeat:
            registry.heartbeat(
                "revoked-home",
                schemas.HeartbeatRequest(operational_certificate=certificate),
            )
        assert heartbeat.value.status_code == 403


def test_new_root_cannot_inherit_alias_level_or_infrastructure_capability(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        old_root_certificate = _certificate()
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="old-infrastructure-alias",
                node_url="https://old.example",
                capabilities=["home"],
                operational_certificate=old_root_certificate,
            )
        )
        with db.get_conn() as conn:
            conn.execute(
                """UPDATE node_capabilities
                   SET trust_status = 'compromised', trust_level = 4
                   WHERE node_id = 'old-infrastructure-alias'"""
            )
            conn.commit()

        new_root_certificate = _certificate()
        with pytest.raises(HTTPException) as alias_takeover:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="old-infrastructure-alias",
                    node_url="https://replacement.example",
                    capabilities=["home"],
                    operational_certificate=new_root_certificate,
                )
            )
        assert alias_takeover.value.status_code == 403

        registry.CAPABILITY_CERTIFICATE_MODE = "enforce"
        with pytest.raises(HTTPException, match="CapabilityCertificate") as inherited_relay:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="new-root-relay-claim",
                    node_url="https://replacement.example",
                    capabilities=["relay"],
                    operational_certificate=new_root_certificate,
                )
            )
        assert inherited_relay.value.status_code == 403

        fresh = registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="new-root-l0",
                node_url="https://replacement.example",
                capabilities=["home"],
                operational_certificate=new_root_certificate,
            )
        )
        assert fresh.identity_node_id == new_root_certificate["node_id"]
        assert fresh.identity_node_id != old_root_certificate["node_id"]
        assert fresh.trust_level == 0
        assert fresh.certified_capabilities == []


def test_discovery_keeps_advertised_and_certified_capabilities_separate(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        operational_certificate = _certificate()
        validators = {f"validator-{index}": SigningKey.generate() for index in range(7)}
        authority = parse_capability_authority_state(
            {
                "epoch": 4,
                "committee": sorted(validators),
                "threshold": 5,
                "validators": {
                    validator_id: {
                        "public_key": public_key_b64(key),
                        "valid_until": "2030-01-01T00:00:00Z",
                        "revoked": False,
                    }
                    for validator_id, key in validators.items()
                },
            }
        )
        registry.load_capability_authority_state = lambda _path: authority
        capability_certificate = build_capability_certificate(
            subject_node_id=operational_certificate["node_id"],
            level=2,
            capabilities=["relay"],
            quotas={"max_connections": 25},
            epoch=4,
            issued_at=datetime.now(timezone.utc) - timedelta(minutes=1),
            valid_until=datetime.now(timezone.utc) + timedelta(days=1),
            committee=sorted(validators),
            threshold=5,
        )
        for validator_id in sorted(validators)[:5]:
            capability_certificate = add_validator_signature(
                capability_certificate,
                validator_id=validator_id,
                validator_signing_key=validators[validator_id],
            )

        response = registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="combined-node",
                node_url="http://combined:8005",
                capabilities=["relay", "storage"],
                operational_certificate=operational_certificate,
                capability_certificate=capability_certificate,
            )
        )

        assert response.capabilities == ["relay", "storage"]
        assert response.certified_capabilities == ["relay"]
        assert response.capability_certificate_status == "valid"
        assert response.certified_level == 2


def test_capability_enforce_refreshes_on_heartbeat_and_expires_from_catalog(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "enforce"
        db.init_db()
        now = datetime.now(timezone.utc)
        operational_certificate = _certificate()
        validators = {f"validator-{index}": SigningKey.generate() for index in range(7)}
        authority = parse_capability_authority_state(
            {
                "epoch": 1,
                "committee": sorted(validators),
                "threshold": 5,
                "validators": {
                    validator_id: {
                        "public_key": public_key_b64(key),
                        "valid_until": (now + timedelta(days=3)).isoformat(),
                        "revoked": False,
                    }
                    for validator_id, key in validators.items()
                },
            }
        )
        registry.load_capability_authority_state = lambda _path: authority

        def capability(epoch, *, previous_hash=None, expires_at=None, quota=25):
            certificate = build_capability_certificate(
                subject_node_id=operational_certificate["node_id"],
                level=2,
                capabilities=["relay"],
                quotas={"max_connections": quota},
                epoch=epoch,
                issued_at=(now - timedelta(hours=2)) if expires_at else (now - timedelta(minutes=1)),
                valid_until=expires_at or (now + timedelta(days=1)),
                committee=sorted(validators),
                threshold=5,
                previous_hash=previous_hash,
            )
            for validator_id in sorted(validators)[:5]:
                certificate = add_validator_signature(
                    certificate,
                    validator_id=validator_id,
                    validator_signing_key=validators[validator_id],
                )
            return certificate

        first = capability(1)
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="renewing-relay",
                node_url="https://relay.example",
                capabilities=["relay"],
                operational_certificate=operational_certificate,
                capability_certificate=first,
            )
        )
        with pytest.raises(HTTPException, match="CapabilityCertificate required") as missing:
            registry.heartbeat(
                "renewing-relay",
                schemas.HeartbeatRequest(
                    operational_certificate=operational_certificate,
                ),
            )
        assert missing.value.status_code == 403

        idempotent = registry.heartbeat(
            "renewing-relay",
            schemas.HeartbeatRequest(
                operational_certificate=operational_certificate,
                capability_certificate=first,
            ),
        )
        assert idempotent.capability_epoch == 1

        second = capability(2, previous_hash=capability_certificate_hash(first))
        refreshed = registry.heartbeat(
            "renewing-relay",
            schemas.HeartbeatRequest(
                operational_certificate=operational_certificate,
                capability_certificate=second,
            ),
        )
        assert refreshed.capability_epoch == 2
        assert refreshed.certified_capabilities == ["relay"]

        conflicting = capability(
            2,
            previous_hash=capability_certificate_hash(first),
            quota=26,
        )
        with pytest.raises(HTTPException, match="same subject epoch") as equivocation:
            registry.heartbeat(
                "renewing-relay",
                schemas.HeartbeatRequest(
                    operational_certificate=operational_certificate,
                    capability_certificate=conflicting,
                ),
            )
        assert equivocation.value.status_code == 403

        expired = capability(
            3,
            previous_hash=capability_certificate_hash(second),
            expires_at=now - timedelta(hours=1),
        )
        import json
        with db.get_conn() as conn:
            conn.execute(
                """UPDATE node_capabilities
                   SET capability_certificate = ?, capability_epoch = 3
                   WHERE node_id = ?""",
                (json.dumps(expired), "renewing-relay"),
            )
            conn.commit()
        assert registry.list_nodes(include_untrusted=False).nodes == []
        assert registry._build_peer_list("other") == []


def test_discovery_persists_valid_signed_node_advertisement(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "report"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        db.init_db()
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        operational = SigningKey.generate()
        certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=operational.verify_key,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=1),
        )
        advertisement = issue_node_advertisement(
            operational_signing_key=operational,
            operational_certificate=certificate,
            endpoints=["https://home-a.example"],
            supported_transports=["https"],
            supported_protocols=["ouo-federation-envelope/1"],
            epoch=8,
            issued_at=now - timedelta(seconds=5),
            expires_at=now + timedelta(hours=1),
        )

        response = registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="home-advertised",
                node_url="https://home-a.example",
                capabilities=["home"],
                operational_certificate=certificate,
                node_advertisement=advertisement,
            )
        )

        assert response.node_advertisement_status == "valid"
        assert response.node_advertisement_epoch == 8
        assert response.advertised_endpoints == ["https://home-a.example"]
        with db.get_conn() as conn:
            row = conn.execute(
                "SELECT node_advertisement, node_advertisement_epoch "
                "FROM node_capabilities WHERE node_id = ?",
                ("home-advertised",),
            ).fetchone()
        assert row["node_advertisement"]
        assert row["node_advertisement_epoch"] == 8


def test_enforce_mode_rejects_registration_without_node_identity(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        db.init_db()

        with pytest.raises(HTTPException) as error:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="unsigned-home",
                    node_url="https://home.example",
                    capabilities=["home"],
                )
            )
        assert error.value.status_code == 403


def test_capability_enforcement_allows_l0_home_but_rejects_uncertified_relay(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "report"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "enforce"
        db.init_db()

        home_certificate = _certificate()
        home = registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="l0-home",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=home_certificate,
            )
        )
        assert home.node_identity_status == "valid"
        assert home.certified_capabilities == []

        relay_certificate = _certificate()
        with pytest.raises(HTTPException) as error:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="uncertified-relay",
                    node_url="https://relay.example",
                    capabilities=["relay"],
                    operational_certificate=relay_certificate,
                )
            )
        assert error.value.status_code == 403


def test_advertisement_enforcement_rejects_unsigned_endpoint(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "enforce"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        certificate = _certificate()

        with pytest.raises(HTTPException) as error:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="home-without-advertisement",
                    node_url="https://home.example",
                    capabilities=["home"],
                    operational_certificate=certificate,
                )
            )
        assert error.value.status_code == 403


def test_advertisement_enforcement_refreshes_on_heartbeat_and_rejects_equivocation(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "enforce"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        operational = SigningKey.generate()
        certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=operational.verify_key,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=1),
        )

        def advertisement(epoch: int):
            return issue_node_advertisement(
                operational_signing_key=operational,
                operational_certificate=certificate,
                endpoints=["https://home.example"],
                supported_transports=["https"],
                supported_protocols=["ouo-federation-envelope/1"],
                epoch=epoch,
                issued_at=now - timedelta(seconds=5),
                expires_at=now + timedelta(hours=1),
            )

        first = advertisement(1)
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="heartbeat-advertised-home",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=certificate,
                node_advertisement=first,
            )
        )
        with pytest.raises(HTTPException, match="NodeAdvertisement required") as missing:
            registry.heartbeat(
                "heartbeat-advertised-home",
                schemas.HeartbeatRequest(operational_certificate=certificate),
            )
        assert missing.value.status_code == 403

        second = advertisement(2)
        refreshed = registry.heartbeat(
            "heartbeat-advertised-home",
            schemas.HeartbeatRequest(
                operational_certificate=certificate,
                node_advertisement=second,
            ),
        )
        assert refreshed.node_advertisement_status == "valid"
        assert refreshed.node_advertisement_epoch == 2

        conflicting = advertisement(2)
        with pytest.raises(HTTPException, match="same subject epoch") as equivocation:
            registry.heartbeat(
                "heartbeat-advertised-home",
                schemas.HeartbeatRequest(
                    operational_certificate=certificate,
                    node_advertisement=conflicting,
                ),
            )
        assert equivocation.value.status_code == 403


def test_enforce_catalog_excludes_expired_stored_advertisement(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "enforce"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        db.init_db()
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        operational = SigningKey.generate()
        certificate = issue_operational_certificate(
            root_signing_key=root,
            operational_verify_key=operational.verify_key,
            issued_at=now - timedelta(hours=3),
            valid_until=now + timedelta(days=1),
        )
        current = issue_node_advertisement(
            operational_signing_key=operational,
            operational_certificate=certificate,
            endpoints=["https://expiring.example"],
            supported_transports=["https"],
            supported_protocols=["ouo-federation-envelope/1"],
            epoch=1,
            issued_at=now - timedelta(seconds=5),
            expires_at=now + timedelta(minutes=5),
        )
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="expiring-home",
                node_url="https://expiring.example",
                capabilities=["home"],
                operational_certificate=certificate,
                node_advertisement=current,
            )
        )
        expired = issue_node_advertisement(
            operational_signing_key=operational,
            operational_certificate=certificate,
            endpoints=["https://expiring.example"],
            supported_transports=["https"],
            supported_protocols=["ouo-federation-envelope/1"],
            epoch=2,
            issued_at=now - timedelta(hours=2),
            expires_at=now - timedelta(hours=1),
        )
        import json
        with db.get_conn() as conn:
            conn.execute(
                """UPDATE node_capabilities
                   SET node_advertisement = ?, node_advertisement_epoch = 2
                   WHERE node_id = ?""",
                (json.dumps(expired), "expiring-home"),
            )
            conn.commit()

        assert registry.list_nodes(include_untrusted=False).nodes == []
        assert registry._build_peer_list("other") == []


def test_discovery_service_has_persistent_root_and_separate_operational_identity(tmp_path):
    with _discovery_modules():
        identity_module = importlib.import_module("app.node_identity")
        identity_module.DISCOVERY_NODE_ROOT_KEY_PATH = str(tmp_path / "root.key")
        identity_module.DISCOVERY_NODE_OPERATIONAL_KEY_PATH = str(tmp_path / "operational.key")
        identity_module.DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH = str(
            tmp_path / "operational-certificate.json"
        )
        identity_module.discovery_node_identity.cache_clear()
        first = identity_module.discovery_node_identity()
        second = identity_module.discovery_node_identity()
        assert first == second
        assert first["operational_certificate"]["node_id"].startswith(NODE_ID_PREFIX)
        assert (tmp_path / "root.key").read_bytes() != (tmp_path / "operational.key").read_bytes()
