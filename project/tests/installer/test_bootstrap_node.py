import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "bootstrap-node.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_node", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def test_public_node_always_includes_headless_management():
    assert MODULE.service_plan("public", False) == [
        "home-node",
        "management-node",
    ]


def test_web_admin_is_an_independent_optional_service():
    assert MODULE.service_plan("public", True) == [
        "home-node",
        "management-node",
        "admin",
    ]


def test_private_network_keeps_management_but_can_omit_web_admin():
    services = MODULE.service_plan("private", False)
    assert "management-node" in services
    assert "admin" not in services
    assert "discovery-node" in services
    assert "storage-node" in services
