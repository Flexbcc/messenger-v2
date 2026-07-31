"""
Фоновая очистка устаревших nonce из federation_nonces.db.

Запускается один раз при старте ноды через start_nonce_cleanup().
Интервал проверки настраивается через NONCE_CLEANUP_INTERVAL_SECONDS (default: 300).

Логика:
  - каждые N секунд вызывает nonce_store._purge_expired()
  - логирует количество удалённых записей
  - не падает при ошибках БД (только логирует)
"""
from __future__ import annotations

import asyncio
import logging
import os
import time

logger = logging.getLogger(__name__)

NONCE_CLEANUP_INTERVAL_SECONDS = int(
    os.environ.get("NONCE_CLEANUP_INTERVAL_SECONDS", "300")  # 5 минут
)


async def _cleanup_loop(nonce_store) -> None:
    logger.info(
        "Nonce cleanup worker started (interval=%ds)", NONCE_CLEANUP_INTERVAL_SECONDS
    )
    while True:
        await asyncio.sleep(NONCE_CLEANUP_INTERVAL_SECONDS)
        try:
            deleted = _purge_and_count(nonce_store)
            if deleted > 0:
                logger.info("Nonce cleanup: удалено %d устаревших записей", deleted)
            else:
                logger.debug("Nonce cleanup: устаревших записей нет")
        except Exception as exc:
            logger.warning("Nonce cleanup error (non-fatal): %s", exc)


def _purge_and_count(nonce_store) -> int:
    """Удаляет истёкшие nonce и возвращает количество удалённых."""
    now = time.time()
    if nonce_store._db_path:
        import sqlite3
        try:
            conn = sqlite3.connect(nonce_store._db_path)
            cur = conn.execute(
                "DELETE FROM used_nonces WHERE expires_at < ?", (now,)
            )
            deleted = cur.rowcount
            conn.commit()
            conn.close()
            return deleted
        except Exception:
            raise
    else:
        # in-memory режим
        expired = [k for k, exp in nonce_store._memory.items() if exp < now]
        for k in expired:
            del nonce_store._memory[k]
        return len(expired)


def start_nonce_cleanup(nonce_store) -> None:
    """
    Запускает фоновый воркер очистки nonce.
    Вызывать из @app.on_event("startup") после инициализации nonce_store.

    Пример:
        from shared.security.nonce_cleanup import start_nonce_cleanup
        from app.fed_security import get_federation_security

        @app.on_event("startup")
        async def on_startup():
            fs = get_federation_security()
            start_nonce_cleanup(fs.nonce_store)
    """
    asyncio.create_task(_cleanup_loop(nonce_store))
    logger.info("Nonce cleanup scheduled (interval=%ds)", NONCE_CLEANUP_INTERVAL_SECONDS)
