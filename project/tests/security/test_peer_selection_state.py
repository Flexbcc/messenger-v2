from datetime import datetime, timedelta, timezone

import pytest

from shared.security.peer_selection_state import (
    load_or_create_selection_seed,
    load_peer_selection_state,
    save_peer_selection_state,
)
from shared.security.node_identity import node_id_from_root_public_key
from nacl.signing import SigningKey


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
RELAY_A = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))


def _state():
    return {
        "state_version": 1,
        "selection_epoch": 12,
        "guards": [
            {
                "node_id": RELAY_A,
                "endpoint": "https://relay-a.example",
                "diversity_group": "operator-a",
            }
        ],
        "rotating": [],
        "reserves": [],
        "updated_at": NOW.isoformat().replace("+00:00", "Z"),
        "valid_until": (NOW + timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
    }


def test_private_selection_seed_is_stable_and_exactly_32_bytes(tmp_path):
    path = tmp_path / "selection.seed"
    first = load_or_create_selection_seed(str(path))
    second = load_or_create_selection_seed(str(path))
    assert first == second
    assert len(first) == 32
    assert path.stat().st_mode & 0o077 == 0


def test_peer_state_roundtrip_rejects_expiry_and_cross_bucket_duplicates(tmp_path):
    path = tmp_path / "peer-state.json"
    state = _state()
    save_peer_selection_state(str(path), state, now=NOW)
    assert load_peer_selection_state(str(path), now=NOW) == state
    assert path.stat().st_mode & 0o077 == 0
    with pytest.raises(ValueError, match="expired"):
        load_peer_selection_state(str(path), now=NOW + timedelta(minutes=6))

    duplicate = _state()
    duplicate["reserves"] = list(duplicate["guards"])
    with pytest.raises(ValueError, match="duplicate"):
        save_peer_selection_state(str(path), duplicate, now=NOW)


def test_malformed_existing_seed_fails_closed(tmp_path):
    path = tmp_path / "selection.seed"
    path.write_text("not-a-secret")
    with pytest.raises(ValueError, match="peer selection seed"):
        load_or_create_selection_seed(str(path))
