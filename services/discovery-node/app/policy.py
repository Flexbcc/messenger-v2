"""Vulnerability response & version-quarantine policy for the Discovery Control Plane.

Model: ../../ouo-settings-web-spec/docs/vulnerability-response.md
Admin settings: admin-settings-spec.json section "vulnerability".

Two pieces of persistent state live in Discovery:
  * blocked_versions   — set of software_version strings marked vulnerable
  * discovery_settings  — key/value policy (quarantine_mode, force_upgrade)

The functions here are deliberately pure where possible (evaluate_version) so
they can be unit-tested without a running server.
"""
from app.config import (
    FORCE_UPGRADE_DEFAULT,
    QUARANTINE_MODE_DEFAULT,
    QUARANTINE_MODES,
    VERSION_STATUS_BLOCKED,
    VERSION_STATUS_OK,
)
from app.db import get_conn


# --- pure logic ------------------------------------------------------------

def evaluate_version(software_version: str | None, blocked_versions, quarantine_mode: str) -> tuple[str, str]:
    """Decide how a node's reported version is treated.

    Returns (version_status, quarantine_action):
      version_status  — "ok" | "blocked"
      quarantine_action — "off" | "warn" | "isolate"  (only meaningful when blocked)

    A version is blocked when it appears in the blocked_versions collection.
    quarantine_action is the configured quarantine_mode when blocked, else "off".
    """
    mode = quarantine_mode if quarantine_mode in QUARANTINE_MODES else "warn"
    if software_version and software_version in set(blocked_versions):
        return VERSION_STATUS_BLOCKED, mode
    return VERSION_STATUS_OK, "off"


def is_isolated(version_status: str, quarantine_action: str) -> bool:
    """True when a node must be excluded from discovery listings."""
    return version_status == VERSION_STATUS_BLOCKED and quarantine_action == "isolate"


# --- persistent state ------------------------------------------------------

def _seed_settings(conn) -> None:
    for key, value in (
        ("quarantine_mode", QUARANTINE_MODE_DEFAULT if QUARANTINE_MODE_DEFAULT in QUARANTINE_MODES else "warn"),
        ("force_upgrade", "true" if FORCE_UPGRADE_DEFAULT else "false"),
    ):
        conn.execute(
            "INSERT OR IGNORE INTO discovery_settings (key, value) VALUES (?, ?)",
            (key, value),
        )


def get_setting(key: str, default: str | None = None) -> str | None:
    with get_conn() as conn:
        row = conn.execute("SELECT value FROM discovery_settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO discovery_settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            (key, value),
        )
        conn.commit()


def get_quarantine_mode() -> str:
    mode = get_setting("quarantine_mode", QUARANTINE_MODE_DEFAULT)
    return mode if mode in QUARANTINE_MODES else "warn"


def get_force_upgrade() -> bool:
    return (get_setting("force_upgrade", "true") or "true").lower() in ("1", "true", "yes", "on")


def list_blocked_versions() -> list[dict]:
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT version, reason, blocked_at FROM blocked_versions ORDER BY version"
        ).fetchall()
    return [dict(r) for r in rows]


def blocked_version_set() -> set[str]:
    with get_conn() as conn:
        rows = conn.execute("SELECT version FROM blocked_versions").fetchall()
    return {r["version"] for r in rows}


def add_blocked_version(version: str, reason: str | None, blocked_at: str) -> None:
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO blocked_versions (version, reason, blocked_at) VALUES (?, ?, ?)
            ON CONFLICT(version) DO UPDATE SET reason = excluded.reason, blocked_at = excluded.blocked_at
            """,
            (version, reason, blocked_at),
        )
        conn.commit()


def remove_blocked_version(version: str) -> bool:
    with get_conn() as conn:
        cur = conn.execute("DELETE FROM blocked_versions WHERE version = ?", (version,))
        conn.commit()
        return cur.rowcount > 0
