import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.authority_checkpoint import authority_state_hash
from shared.security.capability_enrollment import parse_capability_authority_state
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.randomness_checkpoint import (
    add_randomness_signature,
    build_randomness_checkpoint,
    randomness_checkpoint_hash,
)
from shared.security.challenge_assignment import (
    add_assignment_signature,
    build_challenge_assignment,
)
from shared.security.challenge_scheduler import selected_observers_from_checkpoint


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
        store = importlib.import_module("app.randomness_checkpoint_store")
        gossip = importlib.import_module("app.randomness_checkpoint_gossip")
        assignment_store = importlib.import_module("app.challenge_assignment_store")
        yield db, store, gossip, assignment_store
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


def _authority(tmp_path, now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    raw = {
        "epoch": 4,
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
    path = tmp_path / "authority.json"
    path.write_text(json.dumps(raw), encoding="utf-8")
    return keys, parse_capability_authority_state(raw), path


def _checkpoint(keys, authority, now, *, seed="42" * 32):
    observers = [
        {
            "node_id": node_id_from_root_public_key(bytes([index]) * 32),
            "diversity_group": f"operator-{index}",
        }
        for index in range(1, 9)
    ]
    checkpoint = build_randomness_checkpoint(
        challenge_epoch=7,
        authority_epoch=authority.epoch,
        previous_hash=authority_state_hash(authority),
        randomness_seed=seed,
        eligible_observers=observers,
        observer_count=5,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(hours=1),
        committee=authority.committee,
        threshold=authority.threshold,
    )
    for validator_id in sorted(keys)[:5]:
        checkpoint = add_randomness_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return checkpoint


def _configure(gossip, authority_path, guard):
    gossip.TRUST_AUTHORITY_STATE_PATH = str(authority_path)
    gossip.require_governance_available = lambda: None
    gossip.get_network_view_guard = lambda: guard


def test_randomness_checkpoint_converges_and_conflict_freezes(tmp_path):
    with _modules() as (db, store, gossip, _assignment_store):
        now = datetime.now(timezone.utc)
        keys, authority, path = _authority(tmp_path, now)
        checkpoint = _checkpoint(keys, authority, now)

        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        digest, accepted = store.publish_randomness_checkpoint(
            checkpoint,
            authority_state=authority,
            now=now,
        )
        assert accepted is True
        assert digest == randomness_checkpoint_hash(checkpoint)
        page = gossip.build_randomness_gossip(after_epoch=-1, limit=100)
        assert page["head_epoch"] == 7

        db.DB_PATH = str(tmp_path / "d2.db")
        db.init_db()
        guard = _Guard()
        _configure(gossip, path, guard)
        result = gossip.ingest_randomness_gossip(page["checkpoints"][0])
        assert result["accepted"] is True
        assert store.latest_randomness_checkpoint()["checkpoint"] == checkpoint

        conflicting = _checkpoint(keys, authority, now, seed="24" * 32)
        item = {
            "checkpoint": conflicting,
            "checkpoint_hash": randomness_checkpoint_hash(conflicting),
            "stored_at": now.isoformat(),
        }
        with pytest.raises(HTTPException) as error:
            gossip.ingest_randomness_gossip(item)
        assert error.value.status_code == 409
        assert guard.frozen_reason == "conflicting quorum RandomnessCheckpoints detected"


@pytest.mark.asyncio
async def test_background_pull_revalidates_randomness_checkpoint(tmp_path):
    with _modules() as (db, _store, gossip, _assignment_store):
        now = datetime.now(timezone.utc)
        keys, authority, path = _authority(tmp_path, now)
        checkpoint = _checkpoint(keys, authority, now)
        item = {
            "checkpoint": checkpoint,
            "checkpoint_hash": randomness_checkpoint_hash(checkpoint),
            "stored_at": now.isoformat(),
        }
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        _configure(gossip, path, _Guard())
        gossip._peer_cursors.clear()

        def handler(request):
            assert request.url.path == gossip.GOSSIP_PATH
            return httpx.Response(
                200,
                json={"checkpoints": [item], "head_epoch": 7},
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await gossip.poll_randomness_peers_once(
                peers=("https://d1.test",), client=client
            )
        assert result == {"fetched": 1, "accepted": 1, "failed_peers": 0}


def test_assignment_enforce_recomputes_observer_set_from_checkpoint(tmp_path):
    with _modules() as (db, store, _gossip, assignment_store):
        now = datetime.now(timezone.utc)
        keys, authority, _path = _authority(tmp_path, now)
        checkpoint = _checkpoint(keys, authority, now)
        db.DB_PATH = str(tmp_path / "assignment-enforce.db")
        db.init_db()
        store.publish_randomness_checkpoint(
            checkpoint,
            authority_state=authority,
            now=now,
        )
        assignment_store.RANDOMNESS_CHECKPOINT_MODE = "enforce"
        subject = node_id_from_root_public_key(b"s" * 32)
        expected = selected_observers_from_checkpoint(
            checkpoint=checkpoint,
            subject_node_id=subject,
            challenge_type="relay_delivery",
        )
        wrong = [
            item["node_id"]
            for item in checkpoint["eligible_observers"]
            if item["node_id"] not in expected
        ]
        wrong = sorted((wrong + list(expected))[: len(expected)])
        if wrong == list(expected):
            wrong = sorted(
                [checkpoint["eligible_observers"][-1]["node_id"], *expected[1:]]
            )
        assignment = build_challenge_assignment(
            subject_node_id=subject,
            observer_node_ids=wrong,
            challenge_type="relay_delivery",
            epoch=checkpoint["challenge_epoch"],
            authority_epoch=authority.epoch,
            randomness_commitment=randomness_checkpoint_hash(checkpoint),
            not_before=now - timedelta(minutes=1),
            expires_at=now + timedelta(minutes=30),
            committee=authority.committee,
            threshold=authority.threshold,
        )
        for validator_id in sorted(keys)[:5]:
            assignment = add_assignment_signature(
                assignment,
                validator_id=validator_id,
                validator_signing_key=keys[validator_id],
            )
        with pytest.raises(HTTPException) as error:
            assignment_store.publish_assignment(
                assignment,
                authority=authority,
                now=now,
                require_registered_participants=False,
            )
        assert error.value.status_code == 400
        assert error.value.detail == "observer set does not match external selection"
