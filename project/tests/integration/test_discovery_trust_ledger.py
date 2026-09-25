import hashlib
import importlib
import sys
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.capability_enrollment import parse_capability_authority_state
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.trust_ledger import (
    add_trust_record_signature,
    build_trust_record,
    trust_record_hash,
)
from shared.security.network_view import NetworkViewGuard


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"


@contextmanager
def _discovery_modules():
    previous = {
        name: module
        for name, module in sys.modules.items()
        if name == "app" or name.startswith("app.")
    }
    for name in previous:
        del sys.modules[name]
    sys.path.insert(0, str(DISCOVERY_ROOT))
    try:
        db = importlib.import_module("app.db")
        schemas = importlib.import_module("app.schemas")
        registry = importlib.import_module("app.routers.registry")
        service = importlib.import_module("app.trust_record_service")
        yield db, schemas, registry, service
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _setup_authority(now):
    validators = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    authority = parse_capability_authority_state(
        {
            "epoch": 4,
            "committee": sorted(validators),
            "threshold": 5,
            "validators": {
                validator_id: {
                    "public_key": public_key_b64(key),
                    "valid_until": (now + timedelta(days=2)).isoformat(),
                    "revoked": False,
                }
                for validator_id, key in validators.items()
            },
        }
    )
    return validators, authority


def _node_certificate(now):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )


def _promotion(subject, validators, now, signature_count):
    record = build_trust_record(
        subject_node_id=subject,
        previous_level=0,
        new_level=1,
        action="promotion",
        epoch=4,
        metrics_commitment=hashlib.sha256(b"external-evidence-set").hexdigest(),
        committee=sorted(validators),
        threshold=5,
        previous_hash=None,
        decided_at=now,
    )
    for validator_id in sorted(validators)[:signature_count]:
        record = add_trust_record_signature(
            record,
            validator_id=validator_id,
            validator_signing_key=validators[validator_id],
        )
    return record


def _decision(
    subject,
    validators,
    now,
    *,
    action,
    epoch,
    previous_level,
    new_level,
    previous_hash=None,
):
    record = build_trust_record(
        subject_node_id=subject,
        previous_level=previous_level,
        new_level=new_level,
        action=action,
        epoch=epoch,
        metrics_commitment=hashlib.sha256(
            f"{action}-{epoch}".encode()
        ).hexdigest(),
        committee=sorted(validators),
        threshold=5,
        previous_hash=previous_hash,
        decided_at=now,
    )
    for validator_id in sorted(validators)[:5]:
        record = add_trust_record_signature(
            record,
            validator_id=validator_id,
            validator_signing_key=validators[validator_id],
        )
    return record


def test_quorum_trust_record_updates_legacy_state_only_with_five_of_seven(tmp_path):
    with _discovery_modules() as (db, schemas, registry, service):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        service.TRUST_LEDGER_DB_PATH = str(tmp_path / "trust-ledger.db")
        service.TRUST_LEDGER_MODE = "enforce"
        registry.NODE_IDENTITY_MODE = "report"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        validators, authority = _setup_authority(now)
        next_authority = replace(authority, epoch=5)
        service.load_capability_authority_state = lambda _path: authority
        service.load_authority_state_at_epoch = (
            lambda _path, epoch, **_kwargs: {
                4: authority,
                5: next_authority,
            }.get(epoch)
        )
        guard = NetworkViewGuard(str(tmp_path / "network-view.json"))
        service.get_network_view_guard = lambda: guard
        service.require_governance_available = lambda: None
        db.init_db()
        certificate = _node_certificate(now)
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="home-trust-subject",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=certificate,
            )
        )

        with pytest.raises(HTTPException) as error:
            registry.publish_trust_record(
                schemas.TrustRecordPublishRequest(
                    record=_promotion(certificate["node_id"], validators, now, 4)
                )
            )
        assert error.value.status_code == 400

        record = _promotion(certificate["node_id"], validators, now, 5)
        response = registry.publish_trust_record(
            schemas.TrustRecordPublishRequest(record=record)
        )
        assert response.accepted is True
        assert response.applied is True
        with db.get_conn() as conn:
            row = conn.execute(
                "SELECT trust_level FROM node_capabilities WHERE node_id = ?",
                ("home-trust-subject",),
            ).fetchone()
        assert row["trust_level"] == 1

        replay = registry.publish_trust_record(
            schemas.TrustRecordPublishRequest(record=record)
        )
        assert replay.accepted is False
        assert replay.applied is False

        conflicting = _promotion(certificate["node_id"], validators, now, 5)
        with pytest.raises(HTTPException) as conflict_error:
            registry.publish_trust_record(
                schemas.TrustRecordPublishRequest(record=conflicting)
            )
        assert conflict_error.value.status_code == 409
        assert not guard.decision().governance_allowed
        assert guard.decision().data_plane_allowed


def test_quorum_reinstatement_is_the_only_recovery_from_suspension(tmp_path):
    with _discovery_modules() as (db, schemas, registry, service):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        service.TRUST_LEDGER_DB_PATH = str(tmp_path / "trust-ledger.db")
        service.TRUST_LEDGER_MODE = "enforce"
        registry.NODE_IDENTITY_MODE = "report"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"
        validators, authority = _setup_authority(now)
        next_authority = replace(authority, epoch=5)
        service.load_capability_authority_state = lambda _path: authority
        service.load_authority_state_at_epoch = (
            lambda _path, epoch, **_kwargs: {
                4: authority,
                5: next_authority,
            }.get(epoch)
        )
        service.require_governance_available = lambda: None
        db.init_db()
        certificate = _node_certificate(now)
        registry.register_node_capability(
            schemas.RegisterNodeCapability(
                node_id="temporarily-suspended",
                node_url="https://home.example",
                capabilities=["home"],
                operational_certificate=certificate,
            )
        )
        suspension = _decision(
            certificate["node_id"],
            validators,
            now,
            action="suspension",
            epoch=4,
            previous_level=0,
            new_level=0,
        )
        suspended = service.ingest_trust_record(suspension, now=now)
        assert suspended["applied"]
        with db.get_conn() as conn:
            assert conn.execute(
                "SELECT trust_status FROM node_capabilities WHERE node_id = 'temporarily-suspended'"
            ).fetchone()["trust_status"] == "suspended"

        reinstatement = _decision(
            certificate["node_id"],
            validators,
            now + timedelta(seconds=1),
            action="reinstatement",
            epoch=5,
            previous_level=0,
            new_level=0,
            previous_hash=trust_record_hash(suspension),
        )
        restored = service.ingest_trust_record(
            reinstatement, now=now + timedelta(seconds=1)
        )
        assert restored["applied"]
        with db.get_conn() as conn:
            row = conn.execute(
                """SELECT trust_status, suspended_at, suspension_reason
                   FROM node_capabilities WHERE node_id = 'temporarily-suspended'"""
            ).fetchone()
        assert row["trust_status"] == "trusted"
        assert row["suspended_at"] is None
        assert row["suspension_reason"] is None
