"""Tests for profile_settings → media storage profile mapping."""
from app.storage_policy import build_media_user_profile, build_storage_policy_summary


def test_selected_s3_profile():
    settings = {
        "values": {
            "storage.media_location": "selected_s3",
            "storage.s3_endpoint": "https://s3.example.com",
            "storage.s3_bucket": "my-bucket",
            "storage.s3_access_key": "AKIA",
            "storage.s3_secret_key": "secret",
        },
        "lists": {},
    }
    profile = build_media_user_profile("user-1", settings)
    assert profile["backend"] == "s3"
    assert profile["s3"]["bucket"] == "my-bucket"


def test_personal_pc_profile():
    settings = {
        "values": {
            "storage.personal_pc_peer_pubkey": "ed25519:abc",
            "storage.personal_pc_lan_hint": "192.168.1.10:7345",
        },
        "lists": {},
    }
    profile = build_media_user_profile("user-1", settings, default_relay_url="http://relay")
    assert profile["backend"] == "personal_pc"
    assert profile["personal_pc"]["lan_hint"] == "192.168.1.10:7345"
    assert profile["personal_pc"]["relay_url"] == "http://relay"
    assert profile["personal_pc"]["storage_node_id"] == ""


def test_personal_pc_relay_only_profile():
    settings = {
        "values": {
            "storage.personal_pc_peer_pubkey": "ed25519:abc",
            "storage.personal_pc_relay_url": "https://relay.example.com",
            "storage.personal_pc_storage_node_id": "storage-node-1",
        },
        "lists": {},
    }
    profile = build_media_user_profile("user-1", settings)
    assert profile["backend"] == "personal_pc"
    assert profile["personal_pc"]["lan_hint"] == ""
    assert profile["personal_pc"]["relay_url"] == "https://relay.example.com"
    assert profile["personal_pc"]["storage_node_id"] == "storage-node-1"


def test_sender_device_no_server_profile():
    settings = {"values": {"storage.media_location": "sender_device"}, "lists": {}}
    assert build_media_user_profile("user-1", settings) is None


def test_policy_summary():
    settings = {
        "values": {"storage.message_location": "personal_node", "storage.media_location": "personal_node_s3"},
        "lists": {"storage.message_nodes": ["node-a"]},
    }
    summary = build_storage_policy_summary(settings)
    assert summary["message_location"] == "personal_node"
    assert summary["message_nodes"] == ["node-a"]
