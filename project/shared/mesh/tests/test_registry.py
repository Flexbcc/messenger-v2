"""Unit tests for mesh peer registry."""
from shared.mesh.registry import MeshPeerRegistry


def test_upsert_and_urls_for_capability():
    reg = MeshPeerRegistry()
    reg.configure(self_node_id="home-a", cluster_id="default")
    reg.upsert_peer(
        node_id="relay-b",
        node_url="http://relay-b:8005",
        capabilities=["relay"],
        cluster_id="default",
    )
    reg.upsert_peer(
        node_id="storage-c",
        node_url="http://storage-c:8002",
        capabilities=["storage"],
        cluster_id="default",
    )
    assert reg.urls_for_capability("relay") == ["http://relay-b:8005"]
    assert reg.self_node_id not in {p.node_id for p in reg.list_peers()}


def test_replace_from_discovery_excludes_self():
    reg = MeshPeerRegistry()
    nodes = [
        {
            "node_id": "home-a",
            "node_url": "http://home-a:8001",
            "capabilities": ["home"],
            "cluster_id": "default",
            "trust_status": "trusted",
            "software_version": "0.1.0",
        },
        {
            "node_id": "relay-b",
            "node_url": "http://relay-b:8005",
            "capabilities": ["relay"],
            "cluster_id": "default",
            "trust_status": "trusted",
            "software_version": "0.1.0",
        },
    ]
    count = reg.replace_from_discovery(nodes, self_node_id="home-a", cluster_id="default")
    assert count == 1
    assert reg.urls_for_capability("relay") == ["http://relay-b:8005"]
