"""
Автоматическая деградация trust level при длительном offline (Фаза 3.1).

Логика:
  - L2 → L1 если нода offline > DEGRADE_L2_AFTER_DAYS (по умолчанию 7 дней)
  - L1 → L0 если нода offline > DEGRADE_L1_AFTER_DAYS (по умолчанию 14 дней)

Проверка раз в DEGRADATION_CHECK_INTERVAL_SECONDS (по умолчанию 1 час).
Все изменения пишутся в trust_level_history с actor="auto".
Настраивается через env-переменные.
"""
from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from app.db import get_conn
from app.trust import now_iso, reachability_for

logger = logging.getLogger(__name__)

# Сколько дней offline до деградации
DEGRADE_L2_AFTER_DAYS = int(os.environ.get("TRUST_DEGRADE_L2_AFTER_DAYS", "7"))
DEGRADE_L1_AFTER_DAYS = int(os.environ.get("TRUST_DEGRADE_L1_AFTER_DAYS", "14"))

# Интервал проверки (секунды)
DEGRADATION_CHECK_INTERVAL_SECONDS = int(
    os.environ.get("TRUST_DEGRADATION_CHECK_INTERVAL_SECONDS", "3600")
)


def _offline_since(last_heartbeat_iso: str) -> timedelta:
    """Сколько времени нода не присылала heartbeat."""
    last = datetime.fromisoformat(last_heartbeat_iso)
    return datetime.now(timezone.utc) - last


def _degrade_once() -> int:
    """Одна итерация проверки. Возвращает количество деградировавших нод."""
    degraded = 0
    now = now_iso()

    with get_conn() as conn:
        rows = conn.execute(
            """SELECT node_id, last_heartbeat, trust_level, trust_status
               FROM node_capabilities
               WHERE trust_status = 'trusted' AND trust_level >= 1"""
        ).fetchall()

    for row in rows:
        node_id = row["node_id"]
        trust_level = row["trust_level"] or 0
        last_hb = row["last_heartbeat"]

        # Считаем offline только по heartbeat — health-check дополнительный,
        # но не обязательный (может быть выключен).
        if reachability_for(last_hb) != "offline":
            continue  # нода живая, пропускаем

        offline_duration = _offline_since(last_hb)
        new_level: int | None = None
        reason: str | None = None

        if trust_level == 2 and offline_duration >= timedelta(days=DEGRADE_L2_AFTER_DAYS):
            new_level = 1
            reason = (
                f"Авто-деградация: L2→L1 — offline {offline_duration.days} дней "
                f"(порог {DEGRADE_L2_AFTER_DAYS} дней)"
            )
        elif trust_level >= 1 and offline_duration >= timedelta(days=DEGRADE_L1_AFTER_DAYS):
            new_level = 0
            reason = (
                f"Авто-деградация: L{trust_level}→L0 — offline {offline_duration.days} дней "
                f"(порог {DEGRADE_L1_AFTER_DAYS} дней)"
            )

        if new_level is None:
            continue

        with get_conn() as conn:
            conn.execute(
                """UPDATE node_capabilities
                   SET trust_level = ?, trust_level_updated_at = ?
                   WHERE node_id = ?""",
                (new_level, now, node_id),
            )
            conn.execute(
                """INSERT INTO trust_level_history
                   (node_id, from_level, to_level, reason, actor, changed_at)
                   VALUES (?, ?, ?, ?, 'auto', ?)""",
                (node_id, trust_level, new_level, reason, now),
            )
            conn.commit()

        logger.warning(
            "trust_degradation: %s L%d → L%d (%s)",
            node_id, trust_level, new_level, reason,
        )
        degraded += 1

    return degraded


async def _degradation_loop() -> None:
    logger.info(
        "Автодеградация trust level запущена: L2 через %d дн, L1 через %d дн, "
        "проверка каждые %d с",
        DEGRADE_L2_AFTER_DAYS,
        DEGRADE_L1_AFTER_DAYS,
        DEGRADATION_CHECK_INTERVAL_SECONDS,
    )
    while True:
        await asyncio.sleep(DEGRADATION_CHECK_INTERVAL_SECONDS)
        try:
            count = _degrade_once()
            if count:
                logger.info("trust_degradation: деградировало нод за итерацию: %d", count)
        except Exception as exc:
            logger.error("trust_degradation: ошибка итерации: %s", exc)


def start_trust_degradation() -> None:
    """Запустить фоновый воркер. Вызывать из on_startup discovery-node."""
    asyncio.create_task(_degradation_loop())
