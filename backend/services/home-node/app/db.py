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
        await conn.run_sync(_migrate_user_columns)


def _migrate_user_columns(connection):
    """Add columns to existing SQLite DBs without Alembic."""
    import sqlalchemy as sa

    insp = sa.inspect(connection)
    if "users" not in insp.get_table_names():
        return
    cols = {c["name"] for c in insp.get_columns("users")}
    if "bio" not in cols:
        connection.execute(sa.text("ALTER TABLE users ADD COLUMN bio TEXT"))
    if "profile_settings" not in cols:
        connection.execute(sa.text("ALTER TABLE users ADD COLUMN profile_settings JSON"))


async def get_db():
    async with async_session() as session:
        yield session
