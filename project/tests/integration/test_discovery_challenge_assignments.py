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

from shared.security.challenge_assignment import (
    add_assignment_signature,
    build_challenge_assignment,
    issue_assignment_ack,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.trust_evidence import issue_reliability_observation


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
        challenge_store = importlib.import_module("app.challenge_assignment_store")
        observation_store = importlib.import_module("app.trust_observation_store")
        yield db, schemas, registry, challenge_store, observation_store
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _identity(now):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=2),
        valid_until=now + timedelta(days=1),
    )
    return operational, certificate


def _register(registry, schemas, alias, certificate):
    return registry.register_node_capability(
        schemas.RegisterNodeCapability(
            node_id=alias,
            node_url=f"https://{alias}.example",
            capabilities=["home"],
            signing_public_key=certificate["operational_public_key"],
            operational_certificate=certificate,
        )
    )


def _authority(tmp_path, now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    data = {
        "epoch": 10,
        "committee": sorted(keys),
        "threshold": 5,
        "validators": {
            validator_id: {
                "public_key": public_key_b64(key),
                "valid_until": (now + timedelta(days=1)).isoformat().replace("+00:00", "Z"),
                "revoked": False,
            }
            for validator_id, key in keys.items()
        },
    }
    path = tmp_path / "authority.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return keys, path


def _assignment(keys, subject_id, observer_ids, now):
    assignment = build_challenge_assignment(
        subject_node_id=subject_id,
        observer_node_ids=observer_ids,
        challenge_type="relay_delivery",
        epoch=10,
        randomness_commitment=hashlib.sha256(b"epoch-10-randomness").hexdigest(),
        not_before=now - timedelta(minutes=1),
        expires_at=now + timedelta(minutes=30),
        committee=sorted(keys),
        threshold=5,
    )
    for validator_id in sorted(keys)[:5]:
        assignment = add_assignment_signature(
            assignment,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return assignment


def _configure(registry, challenge_store, observation_store, authority_path):
    registry.NODE_IDENTITY_MODE = "report"
    registry.NODE_ADVERTISEMENT_MODE = "report"
    registry.CAPABILITY_CERTIFICATE_MODE = "report"
    registry.TRUST_AUTHORITY_STATE_PATH = str(authority_path)
    registry.schedule_mesh_peer_notify = lambda *_args, **_kwargs: None
    registry.require_governance_available = lambda: None
    challenge_store.enrollment_required = lambda: True
    observation_store.enrollment_required = lambda: True


def test_assignment_pull_signed_ack_and_verified_observation_completion(tmp_path):
    with _discovery_modules() as (db, schemas, registry, challenge_store, observation_store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        keys, authority_path = _authority(tmp_path, now)
        _configure(registry, challenge_store, observation_store, authority_path)
        db.init_db()

        observer_key, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _, unrelated_cert = _identity(now)
        _register(registry, schemas, "observer", observer_cert)
        _register(registry, schemas, "subject", subject_cert)
        _register(registry, schemas, "unrelated", unrelated_cert)
        observer_token = "observer-test-token"
        unrelated_token = "unrelated-test-token"
        with db.get_conn() as conn:
            conn.execute(
                "UPDATE node_capabilities SET node_token_hash = ? WHERE node_id = 'observer'",
                (registry.hash_value(observer_token),),
            )
            conn.execute(
                "UPDATE node_capabilities SET node_token_hash = ? WHERE node_id = 'unrelated'",
                (registry.hash_value(unrelated_token),),
            )
            conn.commit()

        assignment = _assignment(
            keys,
            subject_cert["node_id"],
            [observer_cert["node_id"]],
            now,
        )
        first = registry.publish_challenge_assignment(
            schemas.ChallengeAssignmentPublishRequest(assignment=assignment)
        )
        duplicate = registry.publish_challenge_assignment(
            schemas.ChallengeAssignmentPublishRequest(assignment=assignment)
        )
        assert first.accepted is True
        assert duplicate.accepted is False

        with pytest.raises(HTTPException) as unauthenticated:
            registry.get_challenge_assignments(
                observer_cert["node_id"], authorization=None, limit=20
            )
        assert unauthenticated.value.status_code == 401
        pulled = registry.get_challenge_assignments(
            observer_cert["node_id"],
            authorization=f"Bearer {observer_token}",
            limit=20,
        )
        assert len(pulled.assignments) == 1
        assert pulled.assignments[0]["state"] == "pending"
        unrelated = registry.get_challenge_assignments(
            unrelated_cert["node_id"],
            authorization=f"Bearer {unrelated_token}",
            limit=20,
        )
        assert unrelated.assignments == []

        ack = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=observer_cert["node_id"],
            decision="accepted",
            acknowledged_at=now,
            observer_signing_key=observer_key,
        )
        ack_result = registry.publish_challenge_assignment_ack(
            schemas.ChallengeAssignmentAckRequest(ack=ack),
            authorization=f"Bearer {observer_token}",
        )
        assert ack_result.state == "accepted"
        assert ack_result.accepted is True

        observation = issue_reliability_observation(
            observer_node_id=observer_cert["node_id"],
            subject_node_id=subject_cert["node_id"],
            epoch=assignment["epoch"],
            challenge_type=assignment["challenge_type"],
            challenge_commitment=hashlib.sha256(b"actual-challenge").hexdigest(),
            result="success",
            latency_bucket="20_50ms",
            observed_at=now + timedelta(seconds=1),
            expires_at=now + timedelta(hours=1),
            observer_signing_key=observer_key,
        )
        result = registry.publish_trust_observation(
            schemas.TrustObservationPublishRequest(
                observation=observation,
                assignment_id=assignment["assignment_id"],
            ),
            authorization=f"Bearer {observer_token}",
        )
        assert result.accepted is True
        completed = registry.get_challenge_assignments(
            observer_cert["node_id"],
            authorization=f"Bearer {observer_token}",
            limit=20,
        )
        assert completed.assignments[0]["state"] == "completed"
        assert (
            completed.assignments[0]["completed_observation_id"]
            == observation["observation_id"]
        )


def test_assignment_cannot_complete_before_ack_or_with_mismatched_observation(tmp_path):
    with _discovery_modules() as (db, schemas, registry, challenge_store, observation_store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        keys, authority_path = _authority(tmp_path, now)
        _configure(registry, challenge_store, observation_store, authority_path)
        db.init_db()
        observer_key, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer", observer_cert)
        _register(registry, schemas, "subject", subject_cert)
        assignment = _assignment(
            keys,
            subject_cert["node_id"],
            [observer_cert["node_id"]],
            now,
        )
        registry.publish_challenge_assignment(
            schemas.ChallengeAssignmentPublishRequest(assignment=assignment)
        )
        observation = issue_reliability_observation(
            observer_node_id=observer_cert["node_id"],
            subject_node_id=subject_cert["node_id"],
            epoch=assignment["epoch"] + 1,
            challenge_type=assignment["challenge_type"],
            challenge_commitment=hashlib.sha256(b"mismatch").hexdigest(),
            result="success",
            latency_bucket="20_50ms",
            observed_at=now,
            expires_at=now + timedelta(hours=1),
            observer_signing_key=observer_key,
        )
        with pytest.raises(HTTPException) as before_ack:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(
                    observation=observation,
                    assignment_id=assignment["assignment_id"],
                )
            )
        assert before_ack.value.status_code == 409

        ack = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=observer_cert["node_id"],
            decision="accepted",
            acknowledged_at=now,
            observer_signing_key=observer_key,
        )
        registry.publish_challenge_assignment_ack(
            schemas.ChallengeAssignmentAckRequest(ack=ack)
        )
        with pytest.raises(HTTPException) as mismatch:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(
                    observation=observation,
                    assignment_id=assignment["assignment_id"],
                )
            )
        assert mismatch.value.status_code == 409
        assert mismatch.value.detail == "observation does not match assignment"


def test_conflicting_quorum_assignment_freezes_control_plane(tmp_path):
    with _discovery_modules() as (db, schemas, registry, challenge_store, observation_store):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        keys, authority_path = _authority(tmp_path, now)
        _configure(registry, challenge_store, observation_store, authority_path)
        db.init_db()
        _, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer", observer_cert)
        _register(registry, schemas, "subject", subject_cert)

        class Guard:
            frozen_reason = None

            def force_freeze(self, reason):
                self.frozen_reason = reason

        guard = Guard()
        registry.get_network_view_guard = lambda: guard
        first = _assignment(
            keys,
            subject_cert["node_id"],
            [observer_cert["node_id"]],
            now,
        )
        conflicting = _assignment(
            keys,
            subject_cert["node_id"],
            [observer_cert["node_id"]],
            now,
        )
        registry.publish_challenge_assignment(
            schemas.ChallengeAssignmentPublishRequest(assignment=first)
        )
        with pytest.raises(HTTPException) as conflict:
            registry.publish_challenge_assignment(
                schemas.ChallengeAssignmentPublishRequest(assignment=conflicting)
            )
        assert conflict.value.status_code == 409
        assert guard.frozen_reason == "conflicting quorum ChallengeAssignments detected"
