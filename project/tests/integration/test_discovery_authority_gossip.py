import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.authority_checkpoint import (
    add_authority_signature,
    authority_checkpoint_hash,
    authority_state_hash,
    build_authority_checkpoint,
)
from shared.security.authority_gossip import issue_authority_announcement
from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.network_view import NetworkViewGuard


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
        store = importlib.import_module("app.authority_checkpoint_store")
        gossip = importlib.import_module("app.authority_gossip")
        yield db, store, gossip
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _authority(prefix, epoch, now):
    keys = {f"{prefix}-{index}": SigningKey.generate() for index in range(7)}
    state = CapabilityAuthorityState(
        epoch=epoch,
        committee=tuple(sorted(keys)),
        threshold=5,
        validators={
            validator_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=now + timedelta(days=30),
            )
            for validator_id, key in keys.items()
        },
    )
    return keys, state


def _write_bootstrap(path, state):
    path.write_text(
        json.dumps(
            {
                "epoch": state.epoch,
                "committee": list(state.committee),
                "threshold": state.threshold,
                "validators": {
                    validator_id: {
                        "public_key": credential.public_key,
                        "valid_until": credential.valid_until.isoformat().replace(
                            "+00:00", "Z"
                        ),
                        "revoked": credential.revoked,
                    }
                    for validator_id, credential in state.validators.items()
                },
            }
        ),
        encoding="utf-8",
    )


def _checkpoint(old_keys, previous, next_state, now):
    checkpoint = build_authority_checkpoint(
        authority_epoch=next_state.epoch,
        previous_hash=authority_state_hash(previous),
        committee=next_state.committee,
        threshold=next_state.threshold,
        validators=next_state.validators,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=7),
    )
    for validator_id in sorted(old_keys)[:5]:
        checkpoint = add_authority_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=old_keys[validator_id],
        )
    return checkpoint


def _source(now):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return operational, certificate


def _insert_source(
    db,
    certificate,
    authority_keys,
    authority_state,
    current_time,
    *,
    certified=True,
):
    now = current_time.isoformat().replace("+00:00", "Z")
    capability = build_capability_certificate(
        subject_node_id=certificate["node_id"],
        level=4,
        capabilities=["discovery"],
        quotas={"max_connections": 100},
        epoch=authority_state.epoch,
        issued_at=current_time - timedelta(minutes=1),
        valid_until=current_time + timedelta(days=1),
        committee=authority_state.committee,
        threshold=authority_state.threshold,
    )
    for validator_id in sorted(authority_keys)[: authority_state.threshold]:
        capability = add_validator_signature(
            capability,
            validator_id=validator_id,
            validator_signing_key=authority_keys[validator_id],
        )
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, software_version,
                   last_heartbeat, trust_status, registered_at,
                   signing_public_key, identity_node_id, operational_certificate,
                   node_identity_status, capability_certificate,
                   capability_certificate_status,
                   certified_capabilities
               ) VALUES (?, ?, ?, 'test', ?, 'trusted', ?, ?, ?, ?, 'valid', ?, ?, ?)""",
            (
                f"source-{certificate['serial']}",
                "https://discovery-source.example",
                json.dumps(["discovery"]),
                now,
                now,
                certificate["operational_public_key"],
                certificate["node_id"],
                json.dumps(certificate),
                json.dumps(capability) if certified else None,
                "valid" if certified else "absent",
                json.dumps(["discovery"] if certified else []),
            ),
        )
        conn.commit()


def _item(checkpoint, source_key, source_certificate, now):
    digest = authority_checkpoint_hash(checkpoint)
    return {
        "checkpoint": checkpoint,
        "checkpoint_hash": digest,
        "stored_at": now.isoformat().replace("+00:00", "Z"),
        "announcement": issue_authority_announcement(
            source_node_id=source_certificate["node_id"],
            authority_epoch=checkpoint["authority_epoch"],
            checkpoint_hash=digest,
            announced_at=now,
            expires_at=now + timedelta(minutes=5),
            source_signing_key=source_key,
        ),
    }


class _Guard:
    def __init__(self):
        self.observed = []
        self.frozen_reason = None

    def decision(self):
        return SimpleNamespace(governance_allowed=True, frozen_reason=None)

    def observe_validated_checkpoint(self, **kwargs):
        self.observed.append(kwargs)

    def force_freeze(self, reason):
        self.frozen_reason = reason


def _configure(gossip, bootstrap_path, guard):
    gossip.TRUST_AUTHORITY_STATE_PATH = str(bootstrap_path)
    gossip.get_network_view_guard = lambda: guard


def test_same_signed_checkpoint_converges_independently_on_three_discovery_dbs(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        old_keys, previous = _authority("old", 20, now)
        _, next_state = _authority("new", 21, now)
        checkpoint = _checkpoint(old_keys, previous, next_state, now)
        source_key, source_certificate = _source(now)
        item = _item(checkpoint, source_key, source_certificate, now)
        bootstrap_path = tmp_path / "bootstrap.json"
        _write_bootstrap(bootstrap_path, previous)
        hashes = []
        for index in range(3):
            db.DB_PATH = str(tmp_path / f"d{index + 1}.db")
            db.init_db()
            _insert_source(
                db, source_certificate, old_keys, previous, now
            )
            guard = _Guard()
            _configure(gossip, bootstrap_path, guard)
            result = gossip.ingest_gossip_item(item, now=now)
            hashes.append(result["checkpoint_hash"])
            assert result["checkpoint_accepted"] is True
            assert guard.observed[0]["source_node_id"] == source_certificate["node_id"]
            assert store.load_effective_authority_state(str(bootstrap_path)).epoch == 21
        assert len(set(hashes)) == 1


def test_gossip_rejects_tampered_or_uncertified_source(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        old_keys, previous = _authority("old", 2, now)
        _, next_state = _authority("new", 3, now)
        checkpoint = _checkpoint(old_keys, previous, next_state, now)
        source_key, source_certificate = _source(now)
        _insert_source(
            db,
            source_certificate,
            old_keys,
            previous,
            now,
            certified=False,
        )
        bootstrap_path = tmp_path / "bootstrap.json"
        _write_bootstrap(bootstrap_path, previous)
        _configure(gossip, bootstrap_path, _Guard())
        item = _item(checkpoint, source_key, source_certificate, now)
        with pytest.raises(HTTPException) as uncertified:
            gossip.ingest_gossip_item(item, now=now)
        assert uncertified.value.status_code == 403

        with db.get_conn() as conn:
            capability = build_capability_certificate(
                subject_node_id=source_certificate["node_id"],
                level=4,
                capabilities=["discovery"],
                quotas={"max_connections": 100},
                epoch=previous.epoch,
                issued_at=now - timedelta(minutes=1),
                valid_until=now + timedelta(days=1),
                committee=previous.committee,
                threshold=previous.threshold,
            )
            for validator_id in sorted(old_keys)[: previous.threshold]:
                capability = add_validator_signature(
                    capability,
                    validator_id=validator_id,
                    validator_signing_key=old_keys[validator_id],
                )
            conn.execute(
                """UPDATE node_capabilities
                   SET capability_certificate=?, capability_certificate_status='valid',
                       certified_capabilities='[\"discovery\"]'
                   WHERE identity_node_id=?""",
                (json.dumps(capability), source_certificate["node_id"]),
            )
            conn.commit()
        item["announcement"]["checkpoint_hash"] = "0" * 64
        with pytest.raises(HTTPException) as tampered:
            gossip.ingest_gossip_item(item, now=now)
        assert tampered.value.status_code == 400


@pytest.mark.asyncio
async def test_configured_pull_ingests_signed_chain_without_trusting_http(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        old_keys, previous = _authority("old", 30, now)
        _, next_state = _authority("new", 31, now)
        checkpoint = _checkpoint(old_keys, previous, next_state, now)
        source_key, source_certificate = _source(now)
        _insert_source(db, source_certificate, old_keys, previous, now)
        bootstrap_path = tmp_path / "bootstrap.json"
        _write_bootstrap(bootstrap_path, previous)
        guard = _Guard()
        _configure(gossip, bootstrap_path, guard)
        item = _item(checkpoint, source_key, source_certificate, now)

        def handler(request):
            assert request.url.host == "d2.test"
            assert request.url.params["after_epoch"] == "30"
            return httpx.Response(200, json={"checkpoints": [item]})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await gossip.poll_authority_peers_once(
                peers=("https://d2.test",), client=client
            )
        assert result == {"fetched": 1, "accepted": 1, "failed_peers": 0}
        assert store.load_effective_authority_state(str(bootstrap_path)).epoch == 31
        assert guard.observed[0]["source_node_id"] == source_certificate["node_id"]


def test_multiple_discovery_sources_converge_and_conflicting_gossip_freezes(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        old_keys, previous = _authority("old", 40, now)
        _, next_state = _authority("new", 41, now)
        checkpoint = _checkpoint(old_keys, previous, next_state, now)
        source_a_key, source_a_cert = _source(now)
        source_b_key, source_b_cert = _source(now)
        _insert_source(db, source_a_cert, old_keys, previous, now)
        _insert_source(db, source_b_cert, old_keys, previous, now)
        bootstrap_path = tmp_path / "bootstrap.json"
        _write_bootstrap(bootstrap_path, previous)
        guard = _Guard()
        _configure(gossip, bootstrap_path, guard)

        first = gossip.ingest_gossip_item(
            _item(checkpoint, source_a_key, source_a_cert, now), now=now
        )
        second = gossip.ingest_gossip_item(
            _item(checkpoint, source_b_key, source_b_cert, now), now=now
        )
        assert first["checkpoint_accepted"] is True
        assert second["checkpoint_accepted"] is False
        assert {entry["source_node_id"] for entry in guard.observed} == {
            source_a_cert["node_id"],
            source_b_cert["node_id"],
        }

        conflicting = build_authority_checkpoint(
            authority_epoch=next_state.epoch,
            previous_hash=authority_state_hash(previous),
            committee=next_state.committee,
            threshold=next_state.threshold,
            validators=next_state.validators,
            issued_at=now - timedelta(seconds=20),
            valid_until=now + timedelta(days=7),
        )
        for validator_id in sorted(old_keys)[:5]:
            conflicting = add_authority_signature(
                conflicting,
                validator_id=validator_id,
                validator_signing_key=old_keys[validator_id],
            )
        with pytest.raises(HTTPException) as conflict:
            gossip.ingest_gossip_item(
                _item(conflicting, source_b_key, source_b_cert, now), now=now
            )
        assert conflict.value.status_code == 409
        assert guard.frozen_reason == (
            "conflicting quorum AuthorityCheckpoint gossip detected"
        )


def test_three_signed_heads_with_large_stale_gap_freeze_control_plane(tmp_path):
    with _modules() as (db, store, gossip):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        keys, current_state = _authority("authority-6", 6, now)
        bootstrap_state = current_state
        bootstrap_path = tmp_path / "bootstrap.json"
        _write_bootstrap(bootstrap_path, bootstrap_state)
        checkpoints = {}
        states = {6: bootstrap_state}
        previous_hash = authority_state_hash(bootstrap_state)
        previous_keys = keys
        for epoch in range(7, 11):
            next_keys, next_state = _authority(f"authority-{epoch}", epoch, now)
            checkpoint = build_authority_checkpoint(
                authority_epoch=epoch,
                previous_hash=previous_hash,
                committee=next_state.committee,
                threshold=next_state.threshold,
                validators=next_state.validators,
                issued_at=now - timedelta(minutes=1),
                valid_until=now + timedelta(days=7),
            )
            for validator_id in sorted(previous_keys)[:5]:
                checkpoint = add_authority_signature(
                    checkpoint,
                    validator_id=validator_id,
                    validator_signing_key=previous_keys[validator_id],
                )
            store.publish_authority_checkpoint(
                checkpoint, bootstrap_state=bootstrap_state, now=now
            )
            checkpoints[epoch] = checkpoint
            states[epoch] = next_state
            previous_hash = authority_checkpoint_hash(checkpoint)
            previous_keys = next_keys

        current_a_key, current_a_cert = _source(now)
        current_b_key, current_b_cert = _source(now)
        stale_key, stale_cert = _source(now)
        _insert_source(
            db, current_a_cert, previous_keys, states[10], now
        )
        _insert_source(
            db, current_b_cert, previous_keys, states[10], now
        )
        # The third certified Discovery reports a signed, locally known but
        # stale head. Its current capability authenticates the source; the
        # announcement still binds the old checkpoint hash and epoch.
        _insert_source(db, stale_cert, previous_keys, states[10], now)

        guard = NetworkViewGuard(
            str(tmp_path / "network-view.json"), max_stale_epoch_gap=2
        )
        _configure(gossip, bootstrap_path, guard)
        gossip.ingest_gossip_item(
            _item(checkpoints[10], current_a_key, current_a_cert, now), now=now
        )
        gossip.ingest_gossip_item(
            _item(checkpoints[10], current_b_key, current_b_cert, now), now=now
        )
        gossip.ingest_gossip_item(
            _item(checkpoints[7], stale_key, stale_cert, now), now=now
        )
        decision = guard.decision()
        assert decision.governance_allowed is False
        assert decision.data_plane_allowed is True
        assert "stale epoch gap" in decision.frozen_reason
