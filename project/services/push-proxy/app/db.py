"""SQLite-backed token store via aiosqlite."""
import aiosqlite

from app.config import settings

_DB: aiosqlite.Connection | None = None


async def get_db() -> aiosqlite.Connection:
    global _DB
    if _DB is None or not _DB.is_alive():
        _DB = await aiosqlite.connect(settings.database_url)
        _DB.row_factory = aiosqlite.Row
    return _DB


async def init_db() -> None:
    db = await get_db()
    await db.execute("""
        CREATE TABLE IF NOT EXISTS push_tokens (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     TEXT NOT NULL,
            device_id   TEXT NOT NULL,
            platform    TEXT NOT NULL,   -- fcm | apns | webpush
            token       TEXT NOT NULL,
            updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(user_id, device_id)
        )
    """)
    await db.execute("CREATE INDEX IF NOT EXISTS idx_push_user ON push_tokens(user_id)")
    await db.commit()
