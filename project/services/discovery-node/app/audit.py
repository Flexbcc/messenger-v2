"""Operator action audit log (approve / suspend / compromise)."""
from __future__ import annotations

import json
import sqlite3

from app.trust import now_iso


def ensure_audit_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS admin_audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            node_id TEXT NOT NULL,
            cluster_id TEXT,
            detail TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_audit_created ON admin_audit_log(created_at DESC)"
    )


def log_admin_action(
    conn: sqlite3.Connection,
    *,
    actor: str,
    action: str,
    node_id: str,
    cluster_id: str | None = None,
    detail: str | None = None,
    client_ip: str | None = None,
) -> None:
    ensure_audit_table(conn)
    # Добавляем client_ip в detail если передан
    full_detail = detail or ""
    if client_ip:
        full_detail = f"ip={client_ip}" + (f" {full_detail}" if full_detail else "")
    conn.execute(
        """
        INSERT INTO admin_audit_log (created_at, actor, action, node_id, cluster_id, detail)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (now_iso(), actor or "operator", action, node_id, cluster_id, full_detail or None),
    )


def list_audit_log(conn: sqlite3.Connection, *, limit: int = 100) -> list[dict]:
    ensure_audit_table(conn)
    rows = conn.execute(
        """
        SELECT id, created_at, actor, action, node_id, cluster_id, detail
        FROM admin_audit_log
        ORDER BY id DESC
        LIMIT ?
        """,
        (max(1, min(limit, 500)),),
    ).fetchall()
    return [dict(row) for row in rows]
