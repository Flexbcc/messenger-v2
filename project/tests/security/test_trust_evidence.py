import hashlib
from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.trust_evidence import (
    ObserverCredential,
    issue_reliability_observation,
    validate_reliability_observation,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _identity(key):
    return node_id_from_root_public_key(bytes(key.verify_key))


def _observation(observer_key=None, subject_key=None):
    observer_key = observer_key or SigningKey.generate()
    subject_key = subject_key or SigningKey.generate()
    observer_id = _identity(observer_key)
    observation = issue_reliability_observation(
        observer_node_id=observer_id,
        subject_node_id=_identity(subject_key),
        epoch=8,
        challenge_type="relay_delivery",
        challenge_commitment=hashlib.sha256(b"opaque challenge").hexdigest(),
        result="success",
        latency_bucket="20_50ms",
        observed_at=NOW - timedelta(seconds=1),
        expires_at=NOW + timedelta(hours=1),
        observer_signing_key=observer_key,
    )
    credentials = {
        observer_id: ObserverCredential(
            public_key=public_key_b64(observer_key),
            valid_until=NOW + timedelta(days=1),
        )
    }
    return observation, credentials


def test_valid_external_observation_is_accepted():
    observation, credentials = _observation()
    assert validate_reliability_observation(
        observation, now=NOW, observer_credentials=credentials, minimum_epoch=8
    ).valid


def test_self_observation_is_rejected_even_with_valid_signature():
    key = SigningKey.generate()
    observation, credentials = _observation(observer_key=key, subject_key=key)
    result = validate_reliability_observation(
        observation, now=NOW, observer_credentials=credentials
    )
    assert not result.valid
    assert result.reason == "self-observation is not external evidence"


def test_tampered_result_is_rejected():
    observation, credentials = _observation()
    observation["result"] = "failure"
    result = validate_reliability_observation(
        observation, now=NOW, observer_credentials=credentials
    )
    assert not result.valid
    assert result.reason == "invalid observer signature"


def test_revoked_observer_is_rejected():
    observation, credentials = _observation()
    observer_id = observation["observer_node_id"]
    credentials[observer_id] = ObserverCredential(
        public_key=credentials[observer_id].public_key,
        valid_until=NOW + timedelta(days=1),
        revoked=True,
    )
    result = validate_reliability_observation(
        observation, now=NOW, observer_credentials=credentials
    )
    assert not result.valid
    assert result.reason == "observer is revoked"


def test_extra_metadata_field_is_rejected():
    observation, credentials = _observation()
    observation["user_id"] = "must-not-be-collected"
    result = validate_reliability_observation(
        observation, now=NOW, observer_credentials=credentials
    )
    assert not result.valid
    assert result.reason == "invalid observation fields"
