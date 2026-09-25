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
    if "devices" in tables:
        cols = {c["name"] for c in insp.get_columns("devices")}
        if "trusted" not in cols:
            # Existing devices predate approval state and were already usable;
            # preserve that state while making future password devices opt-in.
            connection.execute(sa.text(
                "ALTER TABLE devices ADD COLUMN trusted BOOLEAN NOT NULL DEFAULT 1"
            ))

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
        # Per-device Signal envelopes. Existing development databases created
        # before Task #57 need the JSON column as well as fresh installations.
        if "device_envelopes" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN device_envelopes JSON"
            ))
        if "delivery_target_device_ids" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN delivery_target_device_ids JSON"
            ))
        if "media_ids" not in cols:
            connection.execute(sa.text(
                "ALTER TABLE messages ADD COLUMN media_ids JSON"
            ))

    # The original ACK table was unique per user and therefore could not
    # represent two devices owned by one recipient. SQLite cannot alter a
    # unique constraint in place, so rebuild it once while preserving legacy
    # ACKs with an explicit empty device id.
    if "message_delivery_acks" in tables:
        ack_cols = {c["name"] for c in insp.get_columns("message_delivery_acks")}
        if "from_device_id" not in ack_cols:
            connection.execute(sa.text(
                """
                CREATE TABLE message_delivery_acks_v2 (
                    id VARCHAR(36) NOT NULL PRIMARY KEY,
                    packet_id VARCHAR(36) NOT NULL,
                    conversation_id VARCHAR(36) NOT NULL,
                    from_user_id VARCHAR(36) NOT NULL,
                    from_device_id VARCHAR(36) NOT NULL DEFAULT '',
                    acked_at DATETIME NOT NULL,
                    CONSTRAINT uq_delivery_ack_packet_user_device
                      UNIQUE (packet_id, from_user_id, from_device_id)
                )
                """
            ))
            connection.execute(sa.text(
                """
                INSERT INTO message_delivery_acks_v2
                    (id, packet_id, conversation_id, from_user_id, from_device_id, acked_at)
                SELECT id, packet_id, conversation_id, from_user_id, '', acked_at
                FROM message_delivery_acks
                """
            ))
            connection.execute(sa.text("DROP TABLE message_delivery_acks"))
            connection.execute(sa.text(
                "ALTER TABLE message_delivery_acks_v2 RENAME TO message_delivery_acks"
            ))
            connection.execute(sa.text(
                "CREATE INDEX ix_message_delivery_acks_packet_id ON message_delivery_acks (packet_id)"
            ))
            connection.execute(sa.text(
                "CREATE INDEX ix_message_delivery_acks_conversation_id ON message_delivery_acks (conversation_id)"
            ))
            connection.execute(sa.text(
                "CREATE INDEX ix_message_delivery_acks_from_user_id ON message_delivery_acks (from_user_id)"
            ))

    # Backfill the normalized media authorization index for databases created
    # before MessageMediaRef existed. INSERT OR IGNORE keeps startup idempotent.
    if "messages" in tables and "message_media_refs" in tables:
        connection.execute(sa.text(
            """
            INSERT OR IGNORE INTO message_media_refs
                (media_id, message_id, conversation_id, created_at)
            SELECT media.value, messages.id, messages.conversation_id, CURRENT_TIMESTAMP
            FROM messages, json_each(messages.media_ids) AS media
            WHERE json_valid(messages.media_ids)
              AND length(media.value) = 64
              AND media.value NOT GLOB '*[^0-9a-f]*'
            """
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
