from datetime import datetime, timedelta, timezone

import pytest
from nacl.signing import SigningKey

from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.synthetic_challenge import (
    challenge_commitment,
    latency_bucket,
    run_synthetic_challenge,
)
from shared.security.trust_evidence import ObserverCredential, validate_reliability_observation


def _node_id(key):
    return node_id_from_root_public_key(bytes(key.verify_key))


@pytest.mark.asyncio
async def test_successful_challenge_emits_valid_minimized_observation():
    observer = SigningKey.generate()
    subject = SigningKey.generate()
    seen = {}

    async def action(context):
        seen["context"] = context
        return True

    execution = await run_synthetic_challenge(
        observer_node_id=_node_id(observer),
        subject_node_id=_node_id(subject),
        epoch=9,
        challenge_type="relay_delivery",
        observer_signing_key=observer,
        action=action,
    )
    observation = execution.observation
    assert observation["result"] == "success"
    assert "user_id" not in observation
    assert "route" not in observation
    context = seen["context"]
    assert context.challenge_commitment == challenge_commitment(
        challenge_id=context.challenge_id,
        secret=context.secret,
        observer_node_id=observation["observer_node_id"],
        subject_node_id=observation["subject_node_id"],
        challenge_type=observation["challenge_type"],
        epoch=observation["epoch"],
    )
    now = datetime.now(timezone.utc)
    assert validate_reliability_observation(
        observation,
        now=now,
        observer_credentials={
            _node_id(observer): ObserverCredential(
                public_key=public_key_b64(observer),
                valid_until=now + timedelta(days=1),
            )
        },
    ).valid


@pytest.mark.asyncio
async def test_failure_is_signed_without_publishing_exception_detail():
    observer = SigningKey.generate()
    subject = SigningKey.generate()

    async def action(_context):
        raise TimeoutError("private target details")

    execution = await run_synthetic_challenge(
        observer_node_id=_node_id(observer),
        subject_node_id=_node_id(subject),
        epoch=1,
        challenge_type="storage_store_get",
        observer_signing_key=observer,
        action=action,
    )
    assert execution.observation["result"] == "failure"
    assert "private target details" not in str(execution.observation)
    assert "private target details" in execution.local_detail


@pytest.mark.parametrize(
    "value,expected",
    [(0, "lt_20ms"), (20, "20_50ms"), (50, "50_100ms"), (1000, "gte_1000ms")],
)
def test_latency_buckets(value, expected):
    assert latency_bucket(value) == expected
