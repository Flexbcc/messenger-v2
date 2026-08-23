import importlib
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey

from shared.security.node_identity import node_id_from_root_public_key


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"


@contextmanager
def _modules():
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
        degradation = importlib.import_module("app.trust_degradation")
        yield db, degradation
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _insert_node(db, *, now, trust_level=2):
    identity = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, software_version,
                   last_heartbeat, trust_status, registered_at,
                   identity_node_id, node_identity_status, trust_level
               ) VALUES ('relay-a', 'https://relay-a.example', '[\"relay\"]',
                         'test', ?, 'trusted', ?, ?, 'valid', ?)""",
            (
                (now - timedelta(days=15)).isoformat(),
                (now - timedelta(days=30)).isoformat(),
                identity,
                trust_level,
            ),
        )
        conn.commit()
    return identity


def test_observe_mode_emits_candidate_without_changing_authoritative_level(tmp_path):
    with _modules() as (db, degradation):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        subject = _insert_node(db, now=now, trust_level=2)
        degradation.TRUST_DEGRADATION_MODE = "observe"

        assert degradation._degrade_once(now=now) == 1
        with db.get_conn() as conn:
            node = conn.execute(
                "SELECT trust_level FROM node_capabilities WHERE node_id = 'relay-a'"
            ).fetchone()
            history_count = conn.execute("SELECT COUNT(*) FROM trust_level_history").fetchone()[0]
        assert node["trust_level"] == 2
        assert history_count == 0
        candidates = degradation.list_degradation_candidates()
        assert len(candidates) == 1
        assert candidates[0]["subject_node_id"] == subject
        assert candidates[0]["previous_level"] == 2
        assert candidates[0]["proposed_level"] == 1
        assert len(candidates[0]["evidence_commitment"]) == 64


def test_legacy_mode_is_the_only_path_that_directly_mutates_level(tmp_path):
    with _modules() as (db, degradation):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, now=now, trust_level=2)
        degradation.TRUST_DEGRADATION_MODE = "legacy"

        assert degradation._degrade_once(now=now) == 1
        with db.get_conn() as conn:
            node = conn.execute(
                "SELECT trust_level FROM node_capabilities WHERE node_id = 'relay-a'"
            ).fetchone()
            actor = conn.execute("SELECT actor FROM trust_level_history").fetchone()[0]
        assert node["trust_level"] == 1
        assert actor == "legacy-auto"


def test_observe_refresh_removes_stale_candidate_when_node_recovers(tmp_path):
    with _modules() as (db, degradation):
        now = datetime.now(timezone.utc)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, now=now, trust_level=2)
        degradation.TRUST_DEGRADATION_MODE = "observe"
        degradation._degrade_once(now=now)
        with db.get_conn() as conn:
            conn.execute(
                "UPDATE node_capabilities SET last_heartbeat = ? WHERE node_id = 'relay-a'",
                (now.isoformat(),),
            )
            conn.commit()
        assert degradation._degrade_once(now=now) == 0
        assert degradation.list_degradation_candidates() == []
