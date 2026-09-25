import pytest
from fastapi import HTTPException

from shared.mesh import router


def test_signed_mesh_router_requires_notify_secret(monkeypatch):
    monkeypatch.setattr(router, "INTERNAL_SECURITY_MODE", "signed")
    monkeypatch.setattr(router, "MESH_NOTIFY_SECRET", "")
    with pytest.raises(RuntimeError, match="MESH_NOTIFY_SECRET is required"):
        router.create_mesh_router()


def test_legacy_mesh_router_keeps_backward_compatible_bootstrap(monkeypatch):
    monkeypatch.setattr(router, "INTERNAL_SECURITY_MODE", "legacy")
    monkeypatch.setattr(router, "MESH_NOTIFY_SECRET", "")
    assert router.create_mesh_router().prefix == "/internal/mesh"


def test_mesh_notify_secret_is_enforced(monkeypatch):
    monkeypatch.setattr(router, "MESH_NOTIFY_SECRET", "independent-mesh-secret")
    with pytest.raises(HTTPException) as error:
        router._check_mesh_notify_secret("wrong")
    assert getattr(error.value, "status_code", None) == 403
    router._check_mesh_notify_secret("independent-mesh-secret")
