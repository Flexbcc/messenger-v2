from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from app.config import settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(f"sqlite+aiosqlite:///{settings.db_path}", echo=False)
async_session = async_sessionmaker(engine, expire_on_commit=False)


async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(_migrate_columns)


def _migrate_columns(connection):
    """Add columns to existing SQLite DBs without Alembic."""
    import sqlalchemy as sa

    insp = sa.inspect(connection)
    tables = insp.get_table_names()

    # users table
    if "users" in tables:
        cols = {c["name"] for c in insp.get_columns("users")}
        if "bio" not in cols:
            connection.execute(sa.text("ALTER TABLE users ADD COLUMN bio TEXT"))
        if "profile_settings" not in cols:
            connection.execute(sa.text("ALTER TABLE users ADD COLUMN profile_settings JSON"))
        if "presence_policy" not in cols:
            connection.execute(sa.text("ALTER TABLE users ADD COLUMN presence_policy JSON"))

    # messages table — статус доставки + исчезающие + редактирование
    if "messages" in tables:
        cols = {c["name"] for c in insp.get_columns("messages")}
        if "delivery_status" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN delivery_status TEXT NOT NULL DEFAULT 'sent'"
            ))
        if "delivered_at" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN delivered_at DATETIME"
            ))
        if "read_at" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN read_at DATETIME"
            ))
        # Task #70: исчезающие сообщения
        if "expires_at" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN expires_at DATETIME"
            ))
        # Task #71: редактирование
        if "edited_at" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN edited_at DATETIME"
            ))
        # Storage federation (Task #63)
        if "origin_media_node_url" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN origin_media_node_url TEXT"
            ))

    # conversations table — TTL исчезающих (Task #70)
    if "conversations" in tables:
        cols = {c["name"] for c in insp.get_columns("conversations")}
        if "disappearing_ttl_seconds" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE conversations ADD COLUMN disappearing_ttl_seconds INTEGER"
            ))


async def get_db():
    async with async_session() as session:
        yield session
