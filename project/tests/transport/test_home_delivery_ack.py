"""Focused lifecycle checks for Home-node endpoint delivery acknowledgements."""
from __future__ import annotations

import importlib
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine


SERVICE_ROOT = Path(__file__).parents[2] / "services" / "home-node"


def _load_home_modules():
    # These values are test-only and are set before app.config is imported.
    os.environ.setdefault("HOME_NODE_PUBLIC_URL", "http://localhost:8001")
    os.environ.setdefault("DISCOVERY_NODE_URL", "http://localhost:8003")
    os.environ.setdefault("ROUTE_RESOLUTION_MODE", "off")
    os.environ.setdefault("JWT_SECRET", "test-jwt-secret-at-least-thirty-two-bytes")
    os.environ.setdefault("OWNER_PANEL_SECRET", "test-owner-secret-at-least-thirty-two")
    for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
        del sys.modules[name]
    sys.path.insert(0, str(SERVICE_ROOT))
    try:
        models = importlib.import_module("app.models")
        fanout = importlib.import_module("app.fanout")
        db_module = importlib.import_module("app.db")
    finally:
        sys.path.remove(str(SERVICE_ROOT))
    return models, fanout, db_module


@pytest.fixture
async def home_db():
    models, fanout, db_module = _load_home_modules()
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as connection:
        await connection.run_sync(db_module.Base.metadata.create_all)
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    async with sessions() as session:
        yield session, models, fanout
    await engine.dispose()


async def _seed_two_device_message(session, models):
    sender = models.User(
        id="sender", display_name="Sender", phone="+1000", password_hash="x"
    )
    recipient = models.User(
        id="recipient", display_name="Recipient", phone="+2000", password_hash="x"
    )
    recipient.devices.extend(
        [
            models.Device(
                id="device-a", device_name="A", device_type="web",
                auth_public_key="a", identity_key_bundle={}, trusted=True,
            ),
            models.Device(
                id="device-b", device_name="B", device_type="desktop",
                auth_public_key="b", identity_key_bundle={}, trusted=True,
            ),
        ]
    )
    conversation = models.Conversation(id="conversation", type="direct")
    conversation.participants.extend(
        [
            models.ConversationParticipant(user_id="sender"),
            models.ConversationParticipant(user_id="recipient"),
        ]
    )
    message = models.Message(
        id="packet", conversation_id="conversation", sender_user_id="sender",
        ciphertext="opaque", delivery_target_device_ids=["device-a", "device-b"],
    )
    session.add_all([sender, recipient, conversation, message])
    await session.commit()
    return message


@pytest.mark.asyncio
async def test_ack_completes_only_after_every_target_device(home_db):
    session, models, fanout = home_db
    message = await _seed_two_device_message(session, models)

    _, inserted = await fanout.upsert_delivery_ack(
        session, packet_id=message.id, conversation_id=message.conversation_id,
        from_user_id="recipient", from_device_id="device-a",
    )
    assert inserted is True
    assert await fanout.delivery_ack_complete(session, message=message) is False
    assert await fanout.user_delivery_ack_complete(
        session, message=message, user_id="recipient"
    ) is False

    _, inserted = await fanout.upsert_delivery_ack(
        session, packet_id=message.id, conversation_id=message.conversation_id,
        from_user_id="recipient", from_device_id="device-b",
    )
    assert inserted is True
    assert await fanout.delivery_ack_complete(session, message=message) is True
    assert await fanout.user_delivery_ack_complete(
        session, message=message, user_id="recipient"
    ) is True

    # Repeating the same device ACK is idempotent and creates no third row.
    _, inserted = await fanout.upsert_delivery_ack(
        session, packet_id=message.id, conversation_id=message.conversation_id,
        from_user_id="recipient", from_device_id="device-b",
    )
    assert inserted is False


@pytest.mark.asyncio
async def test_mixed_online_offline_delivery_keeps_mailbox_copy(home_db, monkeypatch):
    session, models, fanout = home_db
    await _seed_two_device_message(session, models)
    envelope = {
        "packet_id": "packet",
        "sender_user_id": "sender",
        "device_envelopes": [
            {"device_id": "device-a", "ciphertext": "opaque-a"},
            {"device_id": "device-b", "ciphertext": "opaque-b"},
        ],
    }
    send = AsyncMock(side_effect=lambda device_id, _payload: device_id == "device-a")
    buffer = AsyncMock()
    monkeypatch.setattr(fanout.manager, "send_to_device", send)
    monkeypatch.setattr(fanout, "buffer_for_offline_user", buffer)

    channel = await fanout._deliver_locally(session, "recipient", envelope)

    assert channel == "mixed"
    assert send.await_count == 2
    buffer.assert_awaited_once_with("recipient", envelope)


@pytest.mark.asyncio
async def test_partial_ack_for_local_sender_does_not_fake_completion(home_db, monkeypatch):
    session, models, fanout = home_db
    message = await _seed_two_device_message(session, models)
    notify = AsyncMock()
    monkeypatch.setattr(fanout.manager, "send_to_user", notify)

    await fanout.handle_delivery_ack(
        session,
        message=message,
        from_user_id="recipient",
        from_device_id="device-a",
        acked_at=datetime.now(timezone.utc),
        delivery_complete=False,
    )

    assert message.delivery_status == "sent"
    notify.assert_not_awaited()


@pytest.mark.asyncio
async def test_remote_ack_failure_is_propagated_for_retry(home_db, monkeypatch):
    session, models, fanout = home_db
    message = await _seed_two_device_message(session, models)
    # This Home has only the recipient copy; the sender lives remotely.
    await session.delete(await session.get(models.User, "sender"))
    await session.commit()
    resolve = AsyncMock(return_value="https://sender-home.example")
    notify = AsyncMock(side_effect=OSError("unreachable"))
    monkeypatch.setattr(fanout, "resolve_home_node", resolve)
    monkeypatch.setattr(fanout, "notify_remote_delivery_ack", notify)

    with pytest.raises(RuntimeError, match="forwarding failed"):
        await fanout.handle_delivery_ack(
            session,
            message=message,
            from_user_id="recipient",
            from_device_id="device-b",
            acked_at=datetime.now(timezone.utc),
            delivery_complete=True,
        )

    assert message.delivery_status == "delivered"
    notify.assert_awaited_once()
