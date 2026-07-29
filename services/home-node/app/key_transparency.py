"""Key Transparency Log (Task #67).

Append-only журнал смены identity keys. Каждое событие (регистрация устройства,
смена ключа, отзыв устройства) записывается с хэшем предыдущей записи —
образует цепочку которую нельзя переписать незаметно.

Клиент запрашивает GET /users/{user_id}/key-log и проверяет:
  1. Целостность цепочки (каждый entry_hash совпадает с ожидаемым)
  2. Нет ли неожиданной смены ключа с момента последней проверки

Это базовая реализация без CT-logs / witness protocol — аудит локальный.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import KeyTransparencyLog

logger = logging.getLogger(__name__)


def _fingerprint(identity_key_bundle: dict | None) -> Optional[str]:
    """SHA-256 хэш identity key bundle (только identity_key поле если есть)."""
    if not identity_key_bundle:
        return None
    # Берём identity_key из bundle (base64 строка)
    ik = identity_key_bundle.get("identity_key") or identity_key_bundle.get("identityKey")
    if not ik:
        # Fallback: хэш всего bundle в canonical form
        raw = json.dumps(identity_key_bundle, sort_keys=True).encode()
    else:
        raw = ik.encode() if isinstance(ik, str) else ik
    return hashlib.sha256(raw).hexdigest()


def _compute_entry_hash(entry: KeyTransparencyLog) -> str:
    """Детерминированный хэш записи для chain verification."""
    data = json.dumps({
        "id": entry.id,
        "user_id": entry.user_id,
        "device_id": entry.device_id,
        "event_type": entry.event_type,
        "identity_key_fingerprint": entry.identity_key_fingerprint,
        "prev_fingerprint": entry.prev_fingerprint,
        "created_at": entry.created_at.isoformat(),
        "prev_entry_hash": entry.prev_entry_hash,
    }, sort_keys=True).encode()
    return hashlib.sha256(data).hexdigest()


async def _last_entry_hash(db: AsyncSession, user_id: str) -> Optional[str]:
    """Хэш последней записи для данного user_id (для chain linking)."""
    result = await db.execute(
        select(KeyTransparencyLog.entry_hash)
        .where(KeyTransparencyLog.user_id == user_id)
        .order_by(KeyTransparencyLog.created_at.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()


async def _last_fingerprint(db: AsyncSession, user_id: str) -> Optional[str]:
    """Последний зафиксированный fingerprint identity key для user_id."""
    result = await db.execute(
        select(KeyTransparencyLog.identity_key_fingerprint)
        .where(
            KeyTransparencyLog.user_id == user_id,
            KeyTransparencyLog.identity_key_fingerprint.isnot(None),
        )
        .order_by(KeyTransparencyLog.created_at.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()


async def append_key_event(
    db: AsyncSession,
    *,
    user_id: str,
    device_id: Optional[str],
    event_type: str,
    identity_key_bundle: Optional[dict] = None,
) -> KeyTransparencyLog:
    """Добавить событие в key transparency log.

    Автоматически:
    - вычисляет fingerprint нового ключа
    - находит prev_fingerprint из последней записи
    - связывает с предыдущей записью через prev_entry_hash
    - вычисляет entry_hash для цепочки

    event_type: "device_registered" | "identity_key_changed" | "device_revoked"
    """
    fingerprint = _fingerprint(identity_key_bundle)
    prev_fingerprint = await _last_fingerprint(db, user_id)
    prev_entry_hash = await _last_entry_hash(db, user_id)

    entry = KeyTransparencyLog(
        user_id=user_id,
        device_id=device_id,
        event_type=event_type,
        identity_key_fingerprint=fingerprint,
        prev_fingerprint=prev_fingerprint,
        prev_entry_hash=prev_entry_hash,
        created_at=datetime.now(timezone.utc).replace(tzinfo=None),
    )
    # Вычислим entry_hash до сохранения (нужен id — добавим после flush)
    db.add(entry)
    await db.flush()  # получаем entry.id

    entry.entry_hash = _compute_entry_hash(entry)
    await db.commit()
    await db.refresh(entry)

    logger.info(
        "KeyTransparency: user=%s device=%s event=%s fingerprint=%s",
        user_id, device_id, event_type, (fingerprint or "")[:16],
    )
    return entry


async def get_key_log(
    db: AsyncSession,
    user_id: str,
    *,
    limit: int = 50,
    since_id: Optional[str] = None,
) -> list[KeyTransparencyLog]:
    """Получить записи лога для user_id, опционально с момента since_id."""
    query = (
        select(KeyTransparencyLog)
        .where(KeyTransparencyLog.user_id == user_id)
        .order_by(KeyTransparencyLog.created_at.asc())
        .limit(min(limit, 200))
    )
    if since_id:
        # Найти created_at для since_id и вернуть только более новые
        since_result = await db.execute(
            select(KeyTransparencyLog.created_at)
            .where(KeyTransparencyLog.id == since_id)
        )
        since_at = since_result.scalar_one_or_none()
        if since_at:
            query = query.where(KeyTransparencyLog.created_at > since_at)

    result = await db.execute(query)
    return list(result.scalars().all())


def verify_log_chain(entries: list[KeyTransparencyLog]) -> list[str]:
    """Проверить целостность цепочки записей. Возвращает список ошибок (пусто = OK)."""
    errors: list[str] = []
    for i, entry in enumerate(entries):
        # Пересчитаем ожидаемый hash
        expected = _compute_entry_hash(entry)
        if entry.entry_hash != expected:
            errors.append(f"Entry {entry.id}: entry_hash mismatch (tampered?)")
        # Проверяем ссылку на предыдущую
        if i > 0:
            prev = entries[i - 1]
            if entry.prev_entry_hash != prev.entry_hash:
                errors.append(
                    f"Entry {entry.id}: prev_entry_hash does not match previous entry {prev.id}"
                )
    return errors
