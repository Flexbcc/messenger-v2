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

from shared.security.authority_checkpoint import (
    add_authority_signature,
    authority_state_hash,
    build_authority_checkpoint,
)
from shared.security.authority_recovery import (
    add_recovery_signature,
    build_authority_recovery,
)
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64
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
        schemas = importlib.import_module("app.schemas")
        admin = importlib.import_module("app.routers.admin_enrollment")
        store = importlib.import_module("app.authority_checkpoint_store")
        yield db, schemas, admin, store
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _state(prefix, count, threshold, epoch, now):
    keys = {f"{prefix}-{index}": SigningKey.generate() for index in range(count)}
    state = CapabilityAuthorityState(
        epoch=epoch,
        committee=tuple(sorted(keys)),
        threshold=threshold,
        validators={
            key_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=now + timedelta(days=30),
            )
            for key_id, key in keys.items()
        },
    )
    return keys, state


def _write_state(path, state):
    path.write_text(
        json.dumps(
            {
                "epoch": state.epoch,
                "committee": list(state.committee),
                "threshold": state.threshold,
                "validators": {
                    key_id: {
                        "public_key": credential.public_key,
                        "valid_until": credential.valid_until.isoformat().replace(
                            "+00:00", "Z"
                        ),
                        "revoked": credential.revoked,
                    }
                    for key_id, credential in state.validators.items()
                },
            }
        ),
        encoding="utf-8",
    )


def _recovery(recovery_keys, recovery_state, old_state, new_state, now, count=3):
    replacement = build_authority_checkpoint(
        authority_epoch=new_state.epoch,
        previous_hash=authority_state_hash(old_state),
        committee=new_state.committee,
        threshold=new_state.threshold,
        validators=new_state.validators,
        issued_at=now,
        valid_until=now + timedelta(days=7),
    )
    recovery = build_authority_recovery(
        compromised_authority_epoch=old_state.epoch,
        replacement_checkpoint=replacement,
        reason_code="authority_quorum_compromise",
        issued_at=now,
        expires_at=now + timedelta(hours=1),
        recovery_committee=recovery_state.committee,
        recovery_threshold=recovery_state.threshold,
    )
    for key_id in sorted(recovery_keys)[:count]:
        recovery = add_recovery_signature(
            recovery,
            recovery_key_id=key_id,
            recovery_signing_key=recovery_keys[key_id],
        )
    return recovery


def _request():
    return Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/admin/authority/recovery",
            "headers": [],
            "client": ("127.0.0.1", 12345),
        }
    )


def _configure(admin, bootstrap_path, recovery_path, guard):
    admin.TRUST_AUTHORITY_STATE_PATH = str(bootstrap_path)
    admin.RECOVERY_AUTHORITY_STATE_PATH = str(recovery_path)
    admin.get_network_view_guard = lambda: guard


def test_three_of_five_recovery_unfreezes_and_replaces_effective_authority(tmp_path):
    with _modules() as (db, schemas, admin, store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _, old_state = _state("old", 7, 5, 20, now)
        new_keys, new_state = _state("new", 7, 5, 21, now)
        recovery_keys, recovery_state = _state("recovery", 5, 3, 1, now)
        bootstrap_path = tmp_path / "bootstrap.json"
        recovery_path = tmp_path / "recovery-public.json"
        _write_state(bootstrap_path, old_state)
        _write_state(recovery_path, recovery_state)
        guard = NetworkViewGuard(str(tmp_path / "network-view.json"))
        guard.observe_validated_checkpoint(
            source_node_id="d1",
            authority_epoch=old_state.epoch,
            checkpoint_hash=authority_state_hash(old_state),
            previous_hash=None,
        )
        guard.force_freeze("test authority compromise")
        _configure(admin, bootstrap_path, recovery_path, guard)
        recovery = _recovery(
            recovery_keys, recovery_state, old_state, new_state, now
        )

        response = admin.recover_authority(
            schemas.AuthorityRecoveryRequest(recovery=recovery),
            _request(),
            actor="offline-ceremony",
        )
        assert response.accepted is True
        assert response.authority_epoch == 21
        assert response.governance_allowed is True
        assert store.load_effective_authority_state(str(bootstrap_path)).epoch == 21

        # Normal governance resumes from the emergency replacement hash and
        # must be signed by the recovered authority, not the compromised one.
        _, next_state = _state("next", 7, 5, 22, now)
        checkpoint = build_authority_checkpoint(
            authority_epoch=22,
            previous_hash=response.replacement_checkpoint_hash,
            committee=next_state.committee,
            threshold=next_state.threshold,
            validators=next_state.validators,
            issued_at=now + timedelta(minutes=1),
            valid_until=now + timedelta(days=7),
        )
        for validator_id in sorted(new_keys)[:5]:
            checkpoint = add_authority_signature(
                checkpoint,
                validator_id=validator_id,
                validator_signing_key=new_keys[validator_id],
            )
        digest, accepted = store.publish_authority_checkpoint(
            checkpoint,
            bootstrap_state=old_state,
            now=now + timedelta(minutes=1),
        )
        assert accepted is True
        assert len(digest) == 64
        assert store.load_effective_authority_state(str(bootstrap_path)).epoch == 22


def test_recovery_requires_frozen_state_and_full_offline_threshold(tmp_path):
    with _modules() as (db, schemas, admin, store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _, old_state = _state("old", 7, 5, 5, now)
        _, new_state = _state("new", 7, 5, 6, now)
        recovery_keys, recovery_state = _state("recovery", 5, 3, 1, now)
        bootstrap_path = tmp_path / "bootstrap.json"
        recovery_path = tmp_path / "recovery-public.json"
        _write_state(bootstrap_path, old_state)
        _write_state(recovery_path, recovery_state)
        guard = NetworkViewGuard(str(tmp_path / "network-view.json"))
        guard.observe_validated_checkpoint(
            source_node_id="d1",
            authority_epoch=old_state.epoch,
            checkpoint_hash=authority_state_hash(old_state),
            previous_hash=None,
        )
        _configure(admin, bootstrap_path, recovery_path, guard)
        valid = _recovery(recovery_keys, recovery_state, old_state, new_state, now)
        with pytest.raises(HTTPException) as not_frozen:
            admin.recover_authority(
                schemas.AuthorityRecoveryRequest(recovery=valid),
                _request(),
                actor="operator",
            )
        assert not_frozen.value.status_code == 409

        guard.force_freeze("test")
        insufficient = _recovery(
            recovery_keys,
            recovery_state,
            old_state,
            new_state,
            now,
            count=2,
        )
        with pytest.raises(HTTPException) as threshold:
            admin.recover_authority(
                schemas.AuthorityRecoveryRequest(recovery=insufficient),
                _request(),
                actor="operator",
            )
        assert threshold.value.status_code == 400
        assert guard.decision().governance_allowed is False
        assert store.load_effective_authority_state(str(bootstrap_path)).epoch == 5
