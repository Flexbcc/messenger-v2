import importlib.util
import json
from pathlib import Path
from unittest.mock import patch


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


def test_public_network_manifest_is_validated():
    payload = json.dumps({
        "schema": "ouo.network.v1",
        "cluster_id": "ouo-public",
        "discovery_url": "https://discovery.ouoapp.ru",
        "home_url": "https://home.ouoapp.ru",
        "media_url": "https://media.ouoapp.ru",
        "relay_url": "https://relay.ouoapp.ru",
    }).encode()

    class Response:
        headers = {"Content-Length": str(len(payload))}
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def read(self, _limit): return payload

    class Opener:
        def open(self, _request, timeout):
            assert timeout == 10
            return Response()

    with patch.object(MODULE.urllib.request, "build_opener", return_value=Opener()):
        config = MODULE.load_network_config("https://www.ouoapp.ru/network.json")
    assert config["cluster_id"] == "ouo-public"
    assert config["discovery_url"] == "https://discovery.ouoapp.ru"
