import hashlib
import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
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
        service = importlib.import_module("app.trust_record_service")
        gossip = importlib.import_module("app.trust_record_gossip")
        yield db, service, gossip
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
            "epoch": 9,
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


def _subject(now):
    certificate = issue_operational_certificate(
        root_signing_key=SigningKey.generate(),
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return certificate["node_id"]


def _record(subject, keys, now, *, record_id=None):
    record = build_trust_record(
        subject_node_id=subject,
        previous_level=0,
        new_level=1,
        action="promotion",
        epoch=9,
        metrics_commitment=hashlib.sha256(b"independent-observations").hexdigest(),
        committee=sorted(keys),
        threshold=5,
        previous_hash=None,
        decided_at=now,
        record_id=record_id,
    )
    for validator_id in sorted(keys)[:5]:
        record = add_trust_record_signature(
            record,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return record


def _insert_subject(db, subject, alias):
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, software_version,
                   last_heartbeat, trust_status, registered_at,
                   identity_node_id, node_identity_status, trust_level
               ) VALUES (?, 'https://home.example', '[\"home\"]', 'test',
                         ?, 'trusted', ?, ?, 'valid', 0)""",
            (alias, now, now, subject),
        )
        conn.commit()


def _configure(service, gossip, authority, guard, ledger_path):
    service.TRUST_LEDGER_DB_PATH = str(ledger_path)
    service.TRUST_LEDGER_MODE = "enforce"
    service.load_capability_authority_state = lambda _path: authority
    service.load_authority_state_at_epoch = lambda *_args, **_kwargs: authority
    service.require_governance_available = lambda: None
    service.get_network_view_guard = lambda: guard
    gossip.TRUST_LEDGER_DB_PATH = str(ledger_path)


def test_quorum_record_converges_on_three_discovery_ledgers_and_applies_late(tmp_path):
    with _modules() as (db, service, gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        subject = _subject(now)
        record = _record(subject, keys, now)

        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        guard = _Guard()
        _configure(service, gossip, authority, guard, tmp_path / "d1-ledger.db")
        _insert_subject(db, subject, "home-d1")
        local = service.ingest_trust_record(record, now=now)
        assert local["accepted"] is True
        assert local["applied"] is True
        page = gossip.build_trust_record_gossip(after_sequence=0, limit=100)
        assert page["head_sequence"] == 1

        for index in (2, 3):
            db.DB_PATH = str(tmp_path / f"d{index}.db")
            db.init_db()
            guard = _Guard()
            _configure(
                service,
                gossip,
                authority,
                guard,
                tmp_path / f"d{index}-ledger.db",
            )
            replicated = gossip.ingest_trust_record_gossip(page["records"][0])
            assert replicated["accepted"] is True
            assert replicated["applied"] is False
            _insert_subject(db, subject, f"home-d{index}")
            assert service.reconcile_registered_subject(subject) == 1
            with db.get_conn() as conn:
                level = conn.execute(
                    "SELECT trust_level FROM node_capabilities WHERE identity_node_id = ?",
                    (subject,),
                ).fetchone()["trust_level"]
            assert level == 1


def test_conflicting_quorum_gossip_freezes_control_plane(tmp_path):
    with _modules() as (db, service, gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        subject = _subject(now)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        guard = _Guard()
        _configure(service, gossip, authority, guard, tmp_path / "ledger.db")
        first = _record(subject, keys, now)
        service.ingest_trust_record(first, now=now)
        conflicting = _record(subject, keys, now)
        item = {
            "sequence": 2,
            "record_hash": trust_record_hash(conflicting),
            "record": conflicting,
        }
        with pytest.raises(HTTPException) as error:
            gossip.ingest_trust_record_gossip(item)
        assert error.value.status_code == 409
        assert guard.frozen_reason == "conflicting quorum TrustRecords detected"


@pytest.mark.asyncio
async def test_pull_revalidates_records_without_trusting_http(tmp_path):
    with _modules() as (db, service, gossip):
        now = datetime.now(timezone.utc)
        keys, authority = _authority(now)
        subject = _subject(now)
        record = _record(subject, keys, now)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        _configure(service, gossip, authority, _Guard(), tmp_path / "receiver-ledger.db")
        gossip._peer_cursors.clear()
        item = {"sequence": 1, "record_hash": trust_record_hash(record), "record": record}

        def handler(request):
            assert request.url.host == "d2.test"
            return httpx.Response(200, json={"records": [item], "head_sequence": 1})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await gossip.poll_trust_record_peers_once(
                peers=("https://d2.test",),
                client=client,
            )
        assert result == {
            "fetched": 1,
            "accepted": 1,
            "applied": 0,
            "failed_peers": 0,
        }
