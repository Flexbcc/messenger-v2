import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.bootstrap_record import issue_bootstrap_record


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


def _record(key, version):
    now = datetime.now(timezone.utc)
    return issue_bootstrap_record(
        identity_signing_key=key,
        identity_version=1,
        ingress_endpoints=["https://ingress.example"],
        record_version=version,
        issued_at=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
    )


def test_discovery_stores_exact_user_signed_record_and_rejects_rollback(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        key = SigningKey.generate()
        v2 = _record(key, 2)
        published = registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=v2)
        )
        resolved = registry.resolve_bootstrap_record(v2["user_id"])
        assert published.record == v2
        assert resolved.record == v2

        with pytest.raises(HTTPException) as error:
            registry.publish_bootstrap_record(
                schemas.BootstrapRecordPublishRequest(record=_record(key, 1))
            )
        assert error.value.status_code == 400


def test_same_version_equivocation_is_rejected(tmp_path):
    with _discovery_modules() as (db, schemas, registry):
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        key = SigningKey.generate()
        first = _record(key, 4)
        registry.publish_bootstrap_record(
            schemas.BootstrapRecordPublishRequest(record=first)
        )
        second = _record(key, 4)
        with pytest.raises(HTTPException) as error:
            registry.publish_bootstrap_record(
                schemas.BootstrapRecordPublishRequest(record=second)
            )
        assert error.value.status_code == 409
