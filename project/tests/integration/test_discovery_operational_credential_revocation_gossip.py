import hashlib
import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.capability_enrollment import parse_capability_authority_state
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.operational_credential_revocation import (
    add_operational_credential_revocation_signature,
    build_operational_credential_revocation,
)
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
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
        state_store = importlib.import_module("app.operational_credential_store")
        revocation_store = importlib.import_module(
            "app.operational_credential_revocation_store"
        )
        gossip = importlib.import_module(
            "app.operational_credential_revocation_gossip"
        )
        yield db, state_store, revocation_store, gossip
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


class _Guard:
    def __init__(self):
        self.frozen_reason = None

    def force_freeze(self, reason):
        self.frozen_reason = reason


def _authority(now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    state = parse_capability_authority_state(
        {
            "epoch": 12,
            "committee": sorted(keys),
            "threshold": 5,
            "validators": {
                validator_id: {
                    "public_key": public_key_b64(key),
                    "valid_until": (now + timedelta(days=2)).isoformat(),
                    "revoked": False,
                }
                for validator_id, key in keys.items()
            },
        }
    )
    return keys, state


def _known_subject(db, node_id, alias):
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, last_heartbeat,
                   identity_node_id, node_identity_status, trust_status
               ) VALUES (?, 'http://node.test', '[]', ?, ?, 'valid', 'trusted')""",
            (alias, datetime.now(timezone.utc).isoformat(), node_id),
        )
        conn.commit()


def _credential(now):
    root = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    state = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=certificate,
        credential_epoch=0,
    )
    return certificate, state


def _revocation(certificate, keys, now, reason=b"compromised-key"):
    revocation = build_operational_credential_revocation(
        operational_certificate=certificate,
        credential_epoch=0,
        revocation_epoch=0,
        authority_epoch=12,
        reason_commitment=hashlib.sha256(reason).hexdigest(),
        committee=sorted(keys),
        threshold=5,
        decided_at=now,
    )
    for validator_id in sorted(keys)[:5]:
        revocation = add_operational_credential_revocation_signature(
            revocation,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return revocation


def _configure(revocation_store, authority, guard):
    revocation_store.OPERATIONAL_CREDENTIAL_REVOCATION_MODE = "enforce"
    revocation_store.load_capability_authority_state = lambda _path: authority
    revocation_store.load_authority_state_at_epoch = (
        lambda *_args, **_kwargs: authority
    )
    revocation_store.require_governance_available = lambda: None
    revocation_store.get_network_view_guard = lambda: guard


def test_quorum_revocation_converges_on_three_discovery_nodes(tmp_path):
    with _modules() as (db, state_store, revocation_store, gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        certificate, state = _credential(now)
        revocation = _revocation(certificate, keys, now)

        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _known_subject(db, certificate["node_id"], "node-d1")
        state_store.publish_operational_credential_state(state, now=now)
        _configure(revocation_store, authority, _Guard())
        digest, accepted = revocation_store.publish_operational_credential_revocation(
            revocation, now=now
        )
        assert accepted
        page = gossip.build_operational_credential_revocation_gossip()
        assert page["head_sequence"] == 1
        assert page["revocations"][0]["revocation_hash"] == digest

        for index in (2, 3):
            db.DB_PATH = str(tmp_path / f"d{index}.db")
            db.init_db()
            _known_subject(db, certificate["node_id"], f"node-d{index}")
            state_store.publish_operational_credential_state(state, now=now)
            _configure(revocation_store, authority, _Guard())
            result = gossip.ingest_operational_credential_revocation_gossip(
                page["revocations"][0]
            )
            assert result["accepted"]
            assert revocation_store.operational_credential_is_revoked(
                certificate, at_time=now
            )


def test_enforce_rejects_live_but_preserves_pre_revocation_event_time(tmp_path):
    with _modules() as (db, state_store, revocation_store, _gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        certificate, state = _credential(now)
        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _known_subject(db, certificate["node_id"], "node-d1")
        state_store.publish_operational_credential_state(state, now=now)
        _configure(revocation_store, authority, _Guard())
        revocation_store.publish_operational_credential_revocation(
            _revocation(certificate, keys, now), now=now
        )

        assert revocation_store.require_operational_credential_not_revoked(
            certificate, at_time=now - timedelta(microseconds=1)
        )
        with pytest.raises(HTTPException, match="revoked") as error:
            revocation_store.require_operational_credential_not_revoked(
                certificate, at_time=now
            )
        assert error.value.status_code == 403


def test_same_revocation_epoch_conflict_freezes_control_plane(tmp_path):
    with _modules() as (db, state_store, revocation_store, _gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        certificate, state = _credential(now)
        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _known_subject(db, certificate["node_id"], "node-d1")
        state_store.publish_operational_credential_state(state, now=now)
        guard = _Guard()
        _configure(revocation_store, authority, guard)
        revocation_store.publish_operational_credential_revocation(
            _revocation(certificate, keys, now, b"first-evidence"), now=now
        )

        unsigned_conflict = _revocation(
            certificate, keys, now, b"anonymous-freeze-attempt"
        )
        unsigned_conflict["signatures"] = []
        with pytest.raises(HTTPException, match="insufficient"):
            revocation_store.publish_operational_credential_revocation(
                unsigned_conflict, now=now
            )
        assert guard.frozen_reason is None

        with pytest.raises(
            revocation_store.OperationalCredentialRevocationConflict
        ):
            revocation_store.publish_operational_credential_revocation(
                _revocation(certificate, keys, now, b"conflicting-evidence"),
                now=now,
            )
        assert "conflicting quorum" in guard.frozen_reason
