import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.bootstrap_record import issue_bootstrap_record
from shared.security.route_descriptor import (
    issue_route_descriptor,
    route_descriptor_commitment,
    route_descriptor_hash,
)


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"
INGRESS = [
    {
        "node_id": "ingress-a",
        "endpoint": "https://ingress-a.example",
        "transport": "https",
    }
]


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


def _bootstrap(key: SigningKey, now: datetime) -> dict:
    return issue_bootstrap_record(
        identity_signing_key=key,
        identity_version=1,
        ingress_endpoints=["https://ingress-a.example"],
        record_version=1,
        issued_at=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
    )


def _route(
    key: SigningKey,
    now: datetime,
    epoch: int,
    *,
    previous_hash: str | None = None,
    next_descriptor_commitment: str | None = None,
) -> dict:
    return issue_route_descriptor(
        identity_signing_key=key,
        identity_version=1,
        route_epoch=epoch,
        ingress_set=INGRESS,
        valid_from=now - timedelta(minutes=1),
        valid_until=now + timedelta(hours=2),
        previous_hash=previous_hash,
        next_descriptor_commitment=next_descriptor_commitment,
    )


def test_discovery_caches_exact_route_chain_and_retains_three_epochs(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        now = datetime.now(timezone.utc)
        key = SigningKey.generate()
        bootstrap = _bootstrap(key, now)
        registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=bootstrap)
        )

        current = _route(key, now, 10)
        first = registry.publish_route_descriptor_record(
            schemas.RouteDescriptorPublishRequest(descriptor=current)
        )
        duplicate = registry.publish_route_descriptor_record(
            schemas.RouteDescriptorPublishRequest(descriptor=current)
        )
        assert first.accepted is True
        assert duplicate.accepted is False

        chain = [current]
        for epoch in (11, 12, 13):
            descriptor = _route(
                key,
                now,
                epoch,
                previous_hash=route_descriptor_hash(chain[-1]),
            )
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=descriptor)
            )
            chain.append(descriptor)

        resolved = registry.resolve_route_descriptors(bootstrap["user_id"])
        assert [item["route_epoch"] for item in resolved.descriptors] == [11, 12, 13]
        assert resolved.descriptors == chain[-3:]


def test_route_rollback_gap_equivocation_and_tamper_fail_closed(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        now = datetime.now(timezone.utc)
        key = SigningKey.generate()
        bootstrap = _bootstrap(key, now)
        registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=bootstrap)
        )
        current = _route(key, now, 20)
        registry.publish_route_descriptor_record(
            schemas.RouteDescriptorPublishRequest(descriptor=current)
        )

        with pytest.raises(HTTPException) as rollback:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=_route(key, now, 19))
            )
        assert rollback.value.status_code == 400

        with pytest.raises(HTTPException) as gap:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(
                    descriptor=_route(
                        key,
                        now,
                        22,
                        previous_hash=route_descriptor_hash(current),
                    )
                )
            )
        assert gap.value.status_code == 409

        equivocation = _route(key, now, 20)
        with pytest.raises(HTTPException) as conflict:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=equivocation)
            )
        assert conflict.value.status_code == 409

        next_descriptor = _route(
            key,
            now,
            21,
            previous_hash=route_descriptor_hash(current),
        )
        next_descriptor["ingress_set"][0]["endpoint"] = "https://evil.example"
        with pytest.raises(HTTPException) as tamper:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=next_descriptor)
            )
        assert tamper.value.status_code == 400


def test_route_requires_matching_validated_bootstrap_identity(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        now = datetime.now(timezone.utc)
        key = SigningKey.generate()
        descriptor = _route(key, now, 1)
        with pytest.raises(HTTPException) as missing:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=descriptor)
            )
        assert missing.value.status_code == 404

        other_key = SigningKey.generate()
        bootstrap = _bootstrap(other_key, now)
        registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=bootstrap)
        )
        # Changing the signed user_id to the other identity leaves the
        # original signature invalid and must not bind the route to it.
        descriptor["user_id"] = bootstrap["user_id"]
        with pytest.raises(HTTPException) as mismatch:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=descriptor)
            )
        assert mismatch.value.status_code == 400


def test_next_commitment_is_enforced_by_persistent_transition(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        now = datetime.now(timezone.utc)
        key = SigningKey.generate()
        bootstrap = _bootstrap(key, now)
        registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=bootstrap)
        )
        draft = _route(key, now, 31, previous_hash="0" * 64)
        current = _route(
            key,
            now,
            30,
            next_descriptor_commitment=route_descriptor_commitment(draft),
        )
        registry.publish_route_descriptor_record(
            schemas.RouteDescriptorPublishRequest(descriptor=current)
        )
        wrong_next = issue_route_descriptor(
            identity_signing_key=key,
            identity_version=1,
            route_epoch=31,
            ingress_set=[
                {
                    "node_id": "ingress-b",
                    "endpoint": "wss://ingress-b.example/ws",
                    "transport": "wss",
                }
            ],
            valid_from=now - timedelta(minutes=1),
            valid_until=now + timedelta(hours=2),
            previous_hash=route_descriptor_hash(current),
        )
        with pytest.raises(HTTPException) as commitment:
            registry.publish_route_descriptor_record(
                schemas.RouteDescriptorPublishRequest(descriptor=wrong_next)
            )
        assert commitment.value.status_code == 409
