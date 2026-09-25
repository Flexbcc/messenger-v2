import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.authority_checkpoint import (
    add_authority_signature,
    authority_state_hash,
    build_authority_checkpoint,
)
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64


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
        store = importlib.import_module("app.authority_checkpoint_store")
        yield db, schemas, registry, store
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


def _checkpoint(old_keys, previous, next_state, now, signatures=5):
    checkpoint = build_authority_checkpoint(
        authority_epoch=next_state.epoch,
        previous_hash=authority_state_hash(previous),
        committee=next_state.committee,
        threshold=next_state.threshold,
        validators=next_state.validators,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=7),
    )
    for validator_id in sorted(old_keys)[:signatures]:
        checkpoint = add_authority_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=old_keys[validator_id],
        )
    return checkpoint


class _Guard:
    def __init__(self):
        self.observed = []
        self.frozen_reason = None

    def observe_validated_checkpoint(self, **kwargs):
        self.observed.append(kwargs)

    def force_freeze(self, reason):
        self.frozen_reason = reason


def _configure(registry, bootstrap_path, guard):
    registry.TRUST_AUTHORITY_STATE_PATH = str(bootstrap_path)
    registry.require_governance_available = lambda: None
    registry.get_network_view_guard = lambda: guard
    registry.discovery_node_identity = lambda: {
        "operational_certificate": {"node_id": "ouo-node-v1-discovery-test"}
    }


def test_checkpoint_is_persisted_idempotently_and_becomes_effective(tmp_path):
    with _discovery_modules() as (db, schemas, registry, store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        old_keys, previous = _authority("old", 3, now)
        _, next_state = _authority("new", 4, now)
        bootstrap_path = tmp_path / "bootstrap-authority.json"
        _write_bootstrap(bootstrap_path, previous)
        guard = _Guard()
        _configure(registry, bootstrap_path, guard)
        checkpoint = _checkpoint(old_keys, previous, next_state, now)

        first = registry.publish_authority_checkpoint_record(
            schemas.AuthorityCheckpointPublishRequest(checkpoint=checkpoint)
        )
        duplicate = registry.publish_authority_checkpoint_record(
            schemas.AuthorityCheckpointPublishRequest(checkpoint=checkpoint)
        )
        latest = registry.get_latest_authority_checkpoint()
        effective = store.load_effective_authority_state(str(bootstrap_path))
        historical = store.load_authority_state_at_epoch(str(bootstrap_path), 3)
        checkpoint_epoch = store.load_authority_state_at_epoch(str(bootstrap_path), 4)
        assert first.accepted is True
        assert duplicate.accepted is False
        assert latest.checkpoint_hash == first.checkpoint_hash
        assert latest.checkpoint == checkpoint
        assert effective.epoch == 4
        assert effective.committee == next_state.committee
        assert historical.committee == previous.committee
        assert checkpoint_epoch.committee == next_state.committee
        assert store.load_authority_state_at_epoch(str(bootstrap_path), 5) is None
        assert len(guard.observed) == 2


def test_insufficient_quorum_is_rejected_and_epoch_conflict_freezes(tmp_path):
    with _discovery_modules() as (db, schemas, registry, store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        old_keys, previous = _authority("old", 8, now)
        _, next_state = _authority("new", 9, now)
        bootstrap_path = tmp_path / "bootstrap-authority.json"
        _write_bootstrap(bootstrap_path, previous)
        guard = _Guard()
        _configure(registry, bootstrap_path, guard)

        with pytest.raises(HTTPException) as insufficient:
            registry.publish_authority_checkpoint_record(
                schemas.AuthorityCheckpointPublishRequest(
                    checkpoint=_checkpoint(old_keys, previous, next_state, now, signatures=4)
                )
            )
        assert insufficient.value.status_code == 400

        first = _checkpoint(old_keys, previous, next_state, now)
        registry.publish_authority_checkpoint_record(
            schemas.AuthorityCheckpointPublishRequest(checkpoint=first)
        )
        conflicting = _checkpoint(old_keys, previous, next_state, now)
        conflicting["issued_at"] = (now - timedelta(seconds=30)).isoformat().replace(
            "+00:00", "Z"
        )
        # Re-sign the modified body with a valid old quorum.
        conflicting["signatures"] = []
        for validator_id in sorted(old_keys)[:5]:
            conflicting = add_authority_signature(
                conflicting,
                validator_id=validator_id,
                validator_signing_key=old_keys[validator_id],
            )
        with pytest.raises(HTTPException) as conflict:
            registry.publish_authority_checkpoint_record(
                schemas.AuthorityCheckpointPublishRequest(checkpoint=conflicting)
            )
        assert conflict.value.status_code == 409
        assert guard.frozen_reason == "conflicting quorum AuthorityCheckpoints detected"
