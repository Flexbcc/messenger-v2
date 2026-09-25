import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.node_identity import issue_operational_certificate
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
    operational_credential_state_hash,
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
        store = importlib.import_module("app.operational_credential_store")
        yield db, store
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _certificate(root, operational, now, *, expired=False):
    if expired:
        issued_at = now - timedelta(days=2)
        valid_until = now - timedelta(days=1)
    else:
        issued_at = now - timedelta(minutes=1)
        valid_until = now + timedelta(days=1)
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=issued_at,
        valid_until=valid_until,
    )


def _known_subject(db, node_id):
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, last_heartbeat, identity_node_id
               ) VALUES (?, ?, ?, ?, ?)""",
            ("legacy-alias", "http://node.test", "[]", "2026-08-19T12:00:00Z", node_id),
        )
        conn.commit()


def test_credential_chain_replication_and_live_high_watermark(tmp_path):
    with _modules() as (db, store):
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        first = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=0,
        )
        second = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=1,
            previous_state_hash=operational_credential_state_hash(first),
        )

        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _known_subject(db, first["node_id"])
        assert store.publish_operational_credential_state(first, now=now)[1]
        assert store.publish_operational_credential_state(second, now=now)[1]
        page = store.list_operational_credential_states(limit=100)
        assert [item["state"]["credential_epoch"] for item in page] == [0, 1]

        db.DB_PATH = str(tmp_path / "d2.db")
        db.init_db()
        _known_subject(db, first["node_id"])
        for item in page:
            assert store.publish_operational_credential_state(item["state"], now=now)[1]
        assert store.operational_credential_head(first["node_id"])["state"] == second
        store.validate_live_operational_state(second, now=now)
        with pytest.raises(HTTPException, match="high-watermark") as error:
            store.validate_live_operational_state(first, now=now)
        assert error.value.status_code == 409


def test_same_epoch_equivocation_conflicts_and_unknown_subject_is_bounded(tmp_path):
    with _modules() as (db, store):
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        first = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=0,
        )
        conflicting = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=0,
        )
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        with pytest.raises(HTTPException) as unknown:
            store.publish_operational_credential_state(first, now=now)
        assert unknown.value.status_code == 403
        _known_subject(db, first["node_id"])
        store.publish_operational_credential_state(first, now=now)
        unsigned_conflict = dict(conflicting)
        unsigned_conflict["signature"] = "invalid"
        with pytest.raises(HTTPException, match="signature"):
            store.publish_operational_credential_state(unsigned_conflict, now=now)
        with pytest.raises(store.OperationalCredentialConflict):
            store.publish_operational_credential_state(conflicting, now=now)


def test_expired_history_can_replicate_but_cannot_authenticate_live(tmp_path):
    with _modules() as (db, store):
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        state = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(
                root,
                SigningKey.generate(),
                now,
                expired=True,
            ),
            credential_epoch=0,
        )
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _known_subject(db, state["node_id"])
        store.publish_operational_credential_state(state, now=now)
        with pytest.raises(HTTPException, match="not current") as error:
            store.validate_live_operational_state(state, now=now)
        assert error.value.status_code == 403


def test_live_admission_enforces_exact_root_signed_high_watermark(tmp_path):
    with _modules() as (db, store):
        now = datetime.now(timezone.utc)
        root = SigningKey.generate()
        first = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=0,
        )
        second = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, SigningKey.generate(), now),
            credential_epoch=1,
            previous_state_hash=operational_credential_state_hash(first),
        )
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _known_subject(db, first["node_id"])

        assert store.admit_live_operational_credential(
            first["operational_certificate"], first, mode="enforce", now=now
        )
        assert store.admit_live_operational_credential(
            second["operational_certificate"], second, mode="enforce", now=now
        )
        with pytest.raises(HTTPException, match="high-watermark"):
            store.admit_live_operational_credential(
                first["operational_certificate"], first, mode="enforce", now=now
            )
        with pytest.raises(HTTPException, match="required"):
            store.admit_live_operational_credential(
                second["operational_certificate"], None, mode="enforce", now=now
            )
        assert not store.admit_live_operational_credential(
            second["operational_certificate"], None, mode="report", now=now
        )
        with pytest.raises(HTTPException, match="does not match"):
            store.admit_live_operational_credential(
                first["operational_certificate"], second, mode="enforce", now=now
            )
