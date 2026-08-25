import hashlib
import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

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
        yield db, schemas, registry
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
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return operational, certificate


def _register(registry, schemas, alias, operational, certificate):
    return registry.register_node_capability(
        schemas.RegisterNodeCapability(
            node_id=alias,
            node_url=f"https://{alias}.example",
            capabilities=["home"],
            signing_public_key=certificate["operational_public_key"],
            operational_certificate=certificate,
        )
    )


def _configure_registry(registry):
    registry.NODE_IDENTITY_MODE = "report"
    registry.NODE_ADVERTISEMENT_MODE = "report"
    registry.CAPABILITY_CERTIFICATE_MODE = "report"
    registry.schedule_mesh_peer_notify = lambda *_args, **_kwargs: None


def _observation(observer_key, observer_id, subject_id, now, *, commitment=None):
    return issue_reliability_observation(
        observer_node_id=observer_id,
        subject_node_id=subject_id,
        epoch=12,
        challenge_type="relay_delivery",
        challenge_commitment=commitment or hashlib.sha256(b"challenge-1").hexdigest(),
        result="success",
        latency_bucket="20_50ms",
        observed_at=now - timedelta(seconds=1),
        expires_at=now + timedelta(hours=1),
        observer_signing_key=observer_key,
    )


def test_signed_external_observation_is_stored_once_and_listed(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        _configure_registry(registry)
        db.init_db()
        observer_key, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer", observer_key, observer_cert)
        _register(registry, schemas, "subject", None, subject_cert)

        observation = _observation(
            observer_key,
            observer_cert["node_id"],
            subject_cert["node_id"],
            now,
        )
        first = registry.publish_trust_observation(
            schemas.TrustObservationPublishRequest(observation=observation)
        )
        second = registry.publish_trust_observation(
            schemas.TrustObservationPublishRequest(observation=observation)
        )
        listed = registry.get_trust_observations(subject_cert["node_id"], limit=10)
        assert first.accepted is True
        assert second.accepted is False
        assert listed.observations == [observation]


def test_tampered_or_self_observation_is_rejected(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        _configure_registry(registry)
        db.init_db()
        observer_key, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer", observer_key, observer_cert)
        _register(registry, schemas, "subject", None, subject_cert)

        tampered = _observation(
            observer_key, observer_cert["node_id"], subject_cert["node_id"], now
        )
        tampered["result"] = "failure"
        with pytest.raises(HTTPException) as bad_signature:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(observation=tampered)
            )
        assert bad_signature.value.status_code == 400

        self_observation = _observation(
            observer_key, observer_cert["node_id"], observer_cert["node_id"], now
        )
        with pytest.raises(HTTPException) as self_error:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(observation=self_observation)
            )
        assert self_error.value.status_code == 400


def test_same_observer_commitment_cannot_be_replayed_under_new_id(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        _configure_registry(registry)
        db.init_db()
        observer_key, observer_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer", observer_key, observer_cert)
        _register(registry, schemas, "subject", None, subject_cert)
        commitment = hashlib.sha256(b"same-challenge").hexdigest()
        first = _observation(
            observer_key,
            observer_cert["node_id"],
            subject_cert["node_id"],
            now,
            commitment=commitment,
        )
        second = _observation(
            observer_key,
            observer_cert["node_id"],
            subject_cert["node_id"],
            now,
            commitment=commitment,
        )
        registry.publish_trust_observation(
            schemas.TrustObservationPublishRequest(observation=first)
        )
        with pytest.raises(HTTPException) as replay:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(observation=second)
            )
        assert replay.value.status_code == 409


def test_reliability_snapshot_caps_observer_weight_and_excludes_suspended(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        _configure_registry(registry)
        db.init_db()
        observer_a_key, observer_a_cert = _identity(now)
        observer_b_key, observer_b_cert = _identity(now)
        _, subject_cert = _identity(now)
        _register(registry, schemas, "observer-a", observer_a_key, observer_a_cert)
        _register(registry, schemas, "observer-b", observer_b_key, observer_b_cert)
        _register(registry, schemas, "subject", None, subject_cert)

        observations = [
            _observation(
                observer_a_key,
                observer_a_cert["node_id"],
                subject_cert["node_id"],
                now,
                commitment=hashlib.sha256(f"a-{index}".encode()).hexdigest(),
            )
            for index in range(2)
        ]
        observations.append(
            _observation(
                observer_b_key,
                observer_b_cert["node_id"],
                subject_cert["node_id"],
                now,
                commitment=hashlib.sha256(b"b-1").hexdigest(),
            )
        )
        for observation in observations:
            registry.publish_trust_observation(
                schemas.TrustObservationPublishRequest(observation=observation)
            )

        snapshot = registry.get_reliability_snapshot(subject_cert["node_id"])
        assert snapshot.raw_observations == 3
        assert snapshot.trusted_observations == 3
        assert snapshot.effective_observations == 2
        assert snapshot.observer_count == 2
        assert snapshot.success_rate_bps == 10_000
        assert snapshot.promotion_decision == "not_eligible"

        with db.get_conn() as conn:
            conn.execute(
                "UPDATE node_capabilities SET trust_status = 'suspended' WHERE node_id = ?",
                ("observer-b",),
            )
            conn.commit()
        after_suspend = registry.get_reliability_snapshot(subject_cert["node_id"])
        assert after_suspend.trusted_observations == 2
        assert after_suspend.effective_observations == 1
        assert after_suspend.observer_count == 1
