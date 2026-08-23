import hashlib
import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey
from starlette.requests import Request

from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.trust_ledger import (
    TrustLedgerStore,
    add_trust_record_signature,
    build_trust_record,
    trust_record_hash,
)


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"


@contextmanager
def _modules():
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
        admission = importlib.import_module("app.trust_admission")
        assignment_store = importlib.import_module("app.challenge_assignment_store")
        admin = importlib.import_module("app.routers.admin_enrollment")
        yield db, schemas, registry, admission, assignment_store, admin
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _authority(now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    credentials = {
        validator_id: ValidatorCredential(
            public_key=public_key_b64(key),
            valid_until=now + timedelta(days=2),
        )
        for validator_id, key in keys.items()
    }
    return keys, credentials


def _identity(now):
    return issue_operational_certificate(
        root_signing_key=SigningKey.generate(),
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )


def _record(
    subject,
    keys,
    *,
    action,
    epoch,
    decided_at,
    previous_hash=None,
    previous_level=0,
    new_level=0,
):
    record = build_trust_record(
        subject_node_id=subject,
        previous_level=previous_level,
        new_level=new_level,
        action=action,
        epoch=epoch,
        metrics_commitment=hashlib.sha256(
            f"{subject}-{action}-{epoch}".encode()
        ).hexdigest(),
        committee=sorted(keys),
        threshold=5,
        previous_hash=previous_hash,
        decided_at=decided_at,
    )
    for validator_id in sorted(keys)[:5]:
        record = add_trust_record_signature(
            record,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return record


def _append(ledger, record, keys, credentials, now):
    ledger.append_validated(
        record,
        now=now,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )


def test_terminal_denial_uses_event_time_and_rejects_later_promotion(tmp_path):
    with _modules() as (_db, _schemas, _registry, admission, _assignment_store, _admin):
        now = datetime.now(timezone.utc)
        keys, credentials = _authority(now)
        subject = _identity(now)["node_id"]
        ledger_path = str(tmp_path / "trust.db")
        ledger = TrustLedgerStore(ledger_path)
        revocation = _record(
            subject,
            keys,
            action="revocation",
            epoch=12,
            decided_at=now,
        )
        _append(ledger, revocation, keys, credentials, now)
        later_promotion = _record(
            subject,
            keys,
            action="promotion",
            epoch=13,
            decided_at=now + timedelta(seconds=1),
            previous_hash=trust_record_hash(revocation),
            previous_level=0,
            new_level=1,
        )
        with pytest.raises(ValueError, match="terminal"):
            _append(
                ledger,
                later_promotion,
                keys,
                credentials,
                now + timedelta(seconds=1),
            )
        admission.TRUST_LEDGER_MODE = "enforce"

        assert admission.node_trust_denial_at(
            subject,
            at_time=now - timedelta(microseconds=1),
            ledger_path=ledger_path,
        ) is None
        assert admission.node_trust_denial_at(
            subject,
            at_time=now + timedelta(seconds=2),
            ledger_path=ledger_path,
        )["action"] == "revocation"


def test_quorum_revoked_unknown_subject_cannot_create_registration_row(tmp_path):
    with _modules() as (db, schemas, registry, admission, _assignment_store, _admin):
        now = datetime.now(timezone.utc)
        keys, credentials = _authority(now)
        certificate = _identity(now)
        ledger_path = str(tmp_path / "trust.db")
        ledger = TrustLedgerStore(ledger_path)
        _append(
            ledger,
            _record(
                certificate["node_id"],
                keys,
                action="revocation",
                epoch=12,
                decided_at=now,
            ),
            keys,
            credentials,
            now,
        )
        admission.TRUST_LEDGER_MODE = "enforce"
        admission.TRUST_LEDGER_DB_PATH = ledger_path
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        registry.NODE_IDENTITY_MODE = "enforce"
        registry.NODE_ADVERTISEMENT_MODE = "report"
        registry.CAPABILITY_CERTIFICATE_MODE = "report"

        with pytest.raises(HTTPException, match="revocation") as error:
            registry.register_node_capability(
                schemas.RegisterNodeCapability(
                    node_id="revoked-before-register",
                    node_url="https://revoked.example",
                    capabilities=["home"],
                    operational_certificate=certificate,
                )
            )
        assert error.value.status_code == 403
        with db.get_conn() as conn:
            assert conn.execute("SELECT COUNT(*) FROM node_capabilities").fetchone()[0] == 0


def test_historical_portable_event_before_denial_is_allowed_but_live_is_denied(tmp_path):
    with _modules() as (db, _schemas, _registry, admission, assignment_store, _admin):
        now = datetime.now(timezone.utc)
        keys, credentials = _authority(now)
        certificate = _identity(now)
        subject = certificate["node_id"]
        ledger_path = str(tmp_path / "trust.db")
        ledger = TrustLedgerStore(ledger_path)
        denial_time = now + timedelta(seconds=1)
        suspension = _record(
            subject,
            keys,
            action="suspension",
            epoch=12,
            decided_at=denial_time,
            previous_level=1,
            new_level=1,
        )
        _append(
            ledger,
            suspension,
            keys,
            credentials,
            denial_time,
        )
        admission.TRUST_LEDGER_MODE = "enforce"
        assignment_store.TRUST_LEDGER_DB_PATH = ledger_path
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        with db.get_conn() as conn:
            conn.execute(
                """INSERT INTO node_capabilities (
                       node_id, node_url, capabilities, last_heartbeat,
                       identity_node_id, operational_certificate,
                       node_identity_status, trust_status
                   ) VALUES ('observer', 'https://observer.example', '[]', ?, ?, ?,
                             'valid', 'suspended')""",
                (now.isoformat(), subject, json.dumps(certificate)),
            )
            conn.commit()
            assignment_store.require_portable_observer_allowed(
                conn,
                subject,
                at_time=now,
                historical_event=True,
                policy_time=denial_time + timedelta(seconds=1),
            )
            with pytest.raises(HTTPException, match="suspended"):
                assignment_store.require_portable_observer_allowed(
                    conn,
                    subject,
                    at_time=denial_time,
                    historical_event=False,
                )

            pending = _identity(now)["node_id"]
            conn.execute(
                """INSERT INTO node_capabilities (
                       node_id, node_url, capabilities, last_heartbeat,
                       identity_node_id, node_identity_status, trust_status
                   ) VALUES ('pending', 'https://pending.example', '[]', ?, ?,
                             'valid', 'pending')""",
                (now.isoformat(), pending),
            )
            conn.commit()
            with pytest.raises(HTTPException, match="not trusted"):
                assignment_store.require_portable_observer_allowed(
                    conn,
                    pending,
                    at_time=now,
                    historical_event=True,
                )

        reinstatement_time = denial_time + timedelta(seconds=1)
        reinstatement = _record(
            subject,
            keys,
            action="reinstatement",
            epoch=13,
            decided_at=reinstatement_time,
            previous_hash=trust_record_hash(suspension),
            previous_level=1,
            new_level=1,
        )
        _append(
            ledger,
            reinstatement,
            keys,
            credentials,
            reinstatement_time,
        )
        assert admission.node_trust_denial_at(
            subject,
            at_time=denial_time + timedelta(microseconds=1),
            ledger_path=ledger_path,
        )["action"] == "suspension"
        assert admission.node_trust_denial_at(
            subject,
            at_time=reinstatement_time,
            ledger_path=ledger_path,
        ) is None


def test_admin_cannot_override_quorum_deny_or_manual_level_in_enforce(tmp_path):
    with _modules() as (db, _schemas, _registry, admission, _assignment_store, admin):
        now = datetime.now(timezone.utc)
        keys, credentials = _authority(now)
        revoked = _identity(now)["node_id"]
        clean = _identity(now)["node_id"]
        ledger_path = str(tmp_path / "trust.db")
        ledger = TrustLedgerStore(ledger_path)
        _append(
            ledger,
            _record(
                revoked,
                keys,
                action="revocation",
                epoch=12,
                decided_at=now,
            ),
            keys,
            credentials,
            now,
        )
        admission.TRUST_LEDGER_MODE = "enforce"
        admission.TRUST_LEDGER_DB_PATH = ledger_path
        admin.TRUST_LEDGER_MODE = "enforce"
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        with db.get_conn() as conn:
            for alias, identity in (("revoked", revoked), ("clean", clean)):
                conn.execute(
                    """INSERT INTO node_capabilities (
                           node_id, node_url, capabilities, last_heartbeat,
                           identity_node_id, node_identity_status, trust_status,
                           trust_level
                       ) VALUES (?, ?, '[]', ?, ?, 'valid', 'pending', 0)""",
                    (alias, f"https://{alias}.example", now.isoformat(), identity),
                )
            conn.commit()

        request = Request(
            {
                "type": "http",
                "method": "POST",
                "path": "/",
                "headers": [],
                "client": ("127.0.0.1", 12345),
            }
        )
        with pytest.raises(HTTPException, match="revocation"):
            admin.approve_node("revoked", request, actor="test")
        with db.get_conn() as conn:
            conn.execute(
                "UPDATE node_capabilities SET trust_status = 'suspended' WHERE node_id = 'revoked'"
            )
            conn.commit()
        with pytest.raises(HTTPException, match="revocation"):
            admin.reinstate_node("revoked", request, actor="test")
        with pytest.raises(HTTPException, match="revocation"):
            admin.re_enroll_node("revoked", actor="test")
        with pytest.raises(HTTPException, match="quorum TrustRecord"):
            admin.promote_node("clean", actor="test")
        with pytest.raises(HTTPException, match="quorum TrustRecord"):
            admin.demote_node("clean", actor="test")

        with db.get_conn() as conn:
            conn.execute(
                "UPDATE node_capabilities SET trust_status = 'pending' WHERE node_id = 'revoked'"
            )
            conn.commit()
        result = admin.grandfather_all()
        with db.get_conn() as conn:
            statuses = {
                row["node_id"]: row["trust_status"]
                for row in conn.execute(
                    "SELECT node_id, trust_status FROM node_capabilities"
                ).fetchall()
            }
        assert statuses == {"revoked": "pending", "clean": "trusted"}
        assert "trusted count=1" in result.message
