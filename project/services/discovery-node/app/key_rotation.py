"""
Ротация Ed25519 signing key для Discovery Node без даунтайма.

Схема:
  - Ключи хранятся в таблице discovery_signing_keys (SQLite).
  - Активный ключ (status='active') используется для подписи новых записей.
  - При ротации: старый ключ → status='retiring', новый → status='active'.
  - Оба ключа действительны для верификации в течение GRACE_PERIOD_DAYS.
  - После grace period retiring-ключ → status='expired' (автоматически).

GET /discovery-pubkeys — все активные + retiring ключи (для верификации на стороне home-node).
POST /admin/discovery/rotate-key — ручная ротация (требует admin secret).
"""
from __future__ import annotations

import base64
import os
import tempfile
from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from app.config import KEY_ROTATION_GRACE_DAYS
from app.db import get_conn

GRACE_PERIOD_DAYS = KEY_ROTATION_GRACE_DAYS


def _replace_private_key_file(key_path: str, seed: bytes) -> None:
    directory = os.path.dirname(key_path) or "."
    temporary_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=directory,
            prefix=".discovery-signing-",
            delete=False,
        ) as temporary:
            temporary_path = temporary.name
            temporary.write(seed)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, key_path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def _ensure_keys_table(conn) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS discovery_signing_keys (
            key_id      TEXT PRIMARY KEY,
            public_key  TEXT NOT NULL,
            private_key TEXT NOT NULL,
            status      TEXT NOT NULL DEFAULT 'active',
            created_at  TEXT NOT NULL,
            retired_at  TEXT,
            expires_at  TEXT
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_dsk_status ON discovery_signing_keys(status)"
    )


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _pub_b64(private_bytes: bytes) -> str:
    return base64.urlsafe_b64encode(
        SigningKey(private_bytes).verify_key.encode()
    ).decode("ascii")


# ---------------------------------------------------------------------------
# Bootstrap: migrate existing file-based key into DB on first run
# ---------------------------------------------------------------------------

def bootstrap_key_from_file(key_path: str) -> None:
    """
    При первом запуске — переносим существующий файловый ключ в БД.
    Если в БД уже есть активный ключ — ничего не делаем.
    """
    with get_conn() as conn:
        _ensure_keys_table(conn)
        active = conn.execute(
            "SELECT key_id FROM discovery_signing_keys WHERE status='active' LIMIT 1"
        ).fetchone()
        if active:
            return  # уже есть

        # Читаем файловый ключ (или создаём новый если файла нет)
        if os.path.exists(key_path):
            with open(key_path, "rb") as f:
                priv_bytes = f.read()
            if len(priv_bytes) != 32:
                try:
                    decoded = base64.b64decode(
                        priv_bytes.strip(), altchars=b"-_", validate=True
                    )
                except (ValueError, TypeError) as exc:
                    raise RuntimeError(
                        "Discovery signing key file is malformed"
                    ) from exc
                if len(decoded) != 32:
                    raise RuntimeError(
                        "Discovery signing key file must contain a 32-byte seed"
                    )
                # Normalize the legacy textual representation in place. The
                # seed itself is unchanged, so the public trust root remains
                # stable across the migration.
                priv_bytes = decoded
                _replace_private_key_file(key_path, priv_bytes)
            os.chmod(key_path, 0o600)
        else:
            priv_bytes = SigningKey.generate().encode()
            os.makedirs(os.path.dirname(key_path) or ".", exist_ok=True)
            with open(key_path, "xb") as f:
                f.write(priv_bytes)
            os.chmod(key_path, 0o600)

        key_id = f"key-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
        conn.execute("""
            INSERT INTO discovery_signing_keys
                (key_id, public_key, private_key, status, created_at)
            VALUES (?, ?, ?, 'active', ?)
        """, (
            key_id,
            _pub_b64(priv_bytes),
            base64.b64encode(priv_bytes).decode("ascii"),
            _now_iso(),
        ))
        conn.commit()


# ---------------------------------------------------------------------------
# Active key for signing
# ---------------------------------------------------------------------------

def get_active_signing_key() -> SigningKey:
    """Возвращает текущий активный ключ для подписи записей."""
    with get_conn() as conn:
        _ensure_keys_table(conn)
        row = conn.execute(
            "SELECT private_key FROM discovery_signing_keys WHERE status='active' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if not row:
            raise RuntimeError("No active discovery signing key found")
        try:
            priv_bytes = base64.b64decode(row[0], validate=True)
        except (ValueError, TypeError) as exc:
            raise RuntimeError("Active discovery signing key is malformed") from exc
        if len(priv_bytes) != 32:
            raise RuntimeError("Active discovery signing key must contain 32 bytes")
        return SigningKey(priv_bytes)


def get_active_public_key_b64() -> str:
    """Base64url публичный ключ активного signing key."""
    return base64.urlsafe_b64encode(
        get_active_signing_key().verify_key.encode()
    ).decode("ascii")


# ---------------------------------------------------------------------------
# All valid public keys (active + retiring within grace period)
# ---------------------------------------------------------------------------

def get_all_valid_public_keys() -> list[dict]:
    """
    Возвращает все ключи которые должны приниматься для верификации:
      - status='active'
      - status='retiring' если expires_at ещё не истёк
    """
    now = _now_iso()
    with get_conn() as conn:
        _ensure_keys_table(conn)
        rows = conn.execute("""
            SELECT key_id, public_key, status, created_at, retired_at, expires_at
            FROM discovery_signing_keys
            WHERE status = 'active'
               OR (status = 'retiring' AND (expires_at IS NULL OR expires_at > ?))
            ORDER BY created_at DESC
        """, (now,)).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Rotate key
# ---------------------------------------------------------------------------

def rotate_signing_key() -> dict:
    """
    Создаёт новый ключ (active), старый переводит в retiring.
    Возвращает информацию о новом ключе.
    """
    now = _now_iso()
    expires_at = (
        datetime.now(timezone.utc) + timedelta(days=GRACE_PERIOD_DAYS)
    ).isoformat()
    new_priv = SigningKey.generate()
    new_key_id = f"key-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"

    with get_conn() as conn:
        _ensure_keys_table(conn)
        # Переводим все active → retiring
        conn.execute("""
            UPDATE discovery_signing_keys
            SET status='retiring', retired_at=?, expires_at=?
            WHERE status='active'
        """, (now, expires_at))
        # Вставляем новый активный ключ
        conn.execute("""
            INSERT INTO discovery_signing_keys
                (key_id, public_key, private_key, status, created_at)
            VALUES (?, ?, ?, 'active', ?)
        """, (
            new_key_id,
            base64.urlsafe_b64encode(new_priv.verify_key.encode()).decode("ascii"),
            base64.b64encode(new_priv.encode()).decode("ascii"),
            now,
        ))
        conn.commit()

    return {
        "key_id": new_key_id,
        "public_key": base64.urlsafe_b64encode(new_priv.verify_key.encode()).decode("ascii"),
        "status": "active",
        "created_at": now,
        "grace_period_days": GRACE_PERIOD_DAYS,
        "old_keys_expire_at": expires_at,
    }


# ---------------------------------------------------------------------------
# Cleanup expired retiring keys
# ---------------------------------------------------------------------------

def expire_old_keys() -> int:
    """
    Переводит retiring-ключи с истёкшим expires_at → expired.
    Вызывается фоновым воркером раз в час.
    """
    now = _now_iso()
    with get_conn() as conn:
        _ensure_keys_table(conn)
        cur = conn.execute("""
            UPDATE discovery_signing_keys
            SET status='expired'
            WHERE status='retiring' AND expires_at IS NOT NULL AND expires_at <= ?
        """, (now,))
        conn.commit()
        return cur.rowcount
