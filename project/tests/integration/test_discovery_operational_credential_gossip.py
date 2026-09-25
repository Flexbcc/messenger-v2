import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
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
        gossip = importlib.import_module("app.operational_credential_gossip")
        yield db, store, gossip
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


def _certificate(root, now):
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )


def _states(now):
    root = SigningKey.generate()
    first = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=_certificate(root, now),
        credential_epoch=0,
    )
    second = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=_certificate(root, now),
        credential_epoch=1,
        previous_state_hash=operational_credential_state_hash(first),
    )
    return root, first, second


def _known(db, node_id):
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, last_heartbeat, identity_node_id
               ) VALUES (?, ?, ?, ?, ?)""",
            ("alias", "http://node.test", "[]", "2026-08-19T12:00:00Z", node_id),
        )
        conn.commit()


def test_operational_credential_gossip_converges_and_equivocation_freezes(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        root, first, second = _states(now)
        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _known(db, first["node_id"])
        store.publish_operational_credential_state(first, now=now)
        store.publish_operational_credential_state(second, now=now)
        page = gossip.build_operational_credential_gossip(limit=100)
        assert page["head_sequence"] == 2

        db.DB_PATH = str(tmp_path / "d2.db")
        db.init_db()
        _known(db, first["node_id"])
        guard = _Guard()
        gossip.get_network_view_guard = lambda: guard
        for item in page["states"]:
            assert gossip.ingest_operational_credential_gossip(item)["accepted"]
        assert store.operational_credential_head(first["node_id"])["state"] == second

        conflicting = issue_operational_credential_state(
            root_signing_key=root,
            operational_certificate=_certificate(root, now),
            credential_epoch=1,
            previous_state_hash=operational_credential_state_hash(first),
        )
        conflict_item = dict(page["states"][1])
        conflict_item["state"] = conflicting
        conflict_item["state_hash"] = operational_credential_state_hash(conflicting)
        with pytest.raises(HTTPException) as error:
            gossip.ingest_operational_credential_gossip(conflict_item)
        assert error.value.status_code == 409
        assert guard.frozen_reason == (
            "conflicting root-signed Operational Credential states detected"
        )


@pytest.mark.asyncio
async def test_operational_credential_background_pull_revalidates_chain(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        _root, first, second = _states(now)

        db.DB_PATH = str(tmp_path / "source.db")
        db.init_db()
        _known(db, first["node_id"])
        store.publish_operational_credential_state(first, now=now)
        store.publish_operational_credential_state(second, now=now)
        page = gossip.build_operational_credential_gossip(limit=100)

        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        _known(db, first["node_id"])
        gossip._peer_cursors.clear()

        def handler(request):
            assert request.url.path == gossip.GOSSIP_PATH
            return httpx.Response(200, json=page)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await gossip.poll_operational_credential_peers_once(
                peers=("http://d1.test",),
                client=client,
            )
        assert result == {"fetched": 2, "accepted": 2, "failed_peers": 0}
        assert store.operational_credential_head(first["node_id"])["state"] == second
