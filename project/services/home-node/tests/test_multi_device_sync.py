"""Tests for multi-device continuity v0 (roadmap #14 / spec/0405_MULTI_DEVICE.md):
`after=` catch-up cursor on `GET /conversations/{id}/messages`, and the
sender-mirror push added to `app.fanout.fan_out_message` so a sender's other
devices see their own sends over WS.
"""
import asyncio
import uuid
from unittest.mock import AsyncMock

import httpx
import pytest
from sqlalchemy import select

from app.db import async_session, init_db
from app.fanout import fan_out_message
from app.main import app
from app.models import Conversation, ConversationParticipant, Message, User
from app.security import create_access_token

pytestmark = pytest.mark.asyncio


@pytest.fixture(scope="session", autouse=True)
def _init_db_once():
    asyncio.run(init_db())


def _auth_header(user_id: str, device_id: str = "dev-1") -> dict:
    token = create_access_token({"sub": user_id, "device_id": device_id})
    return {"Authorization": f"Bearer {token}"}


async def _create_user(db) -> str:
    user = User(display_name="Test User", phone=f"+1{uuid.uuid4().int % 10**10}", password_hash="x")
    db.add(user)
    await db.commit()
    return user.id


async def _create_conversation(db, participant_ids: list[str]) -> str:
    conv = Conversation(type="direct")
    db.add(conv)
    await db.flush()
    for uid in participant_ids:
        db.add(ConversationParticipant(conversation_id=conv.id, user_id=uid))
    await db.commit()
    return conv.id


async def _create_message(db, conversation_id: str, sender_user_id: str) -> Message:
    message = Message(conversation_id=conversation_id, sender_user_id=sender_user_id, ciphertext="ct")
    db.add(message)
    await db.commit()
    await db.refresh(message)
    return message


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


async def test_after_returns_only_newer_messages_ascending():
    async with async_session() as db:
        user_a = await _create_user(db)
        user_b = await _create_user(db)
        conv_id = await _create_conversation(db, [user_a, user_b])
        older = await _create_message(db, conv_id, user_a)
        cursor = older.created_at.isoformat()
        newer1 = await _create_message(db, conv_id, user_b)
        newer2 = await _create_message(db, conv_id, user_a)

    async with await _client() as client:
        resp = await client.get(
            f"/conversations/{conv_id}/messages",
            params={"after": cursor},
            headers=_auth_header(user_a),
        )

    assert resp.status_code == 200
    body = resp.json()
    ids = [m["id"] for m in body]
    assert older.id not in ids
    assert ids == [newer1.id, newer2.id]  # ascending, oldest of the "new" batch first


async def test_after_with_no_new_messages_returns_empty():
    async with async_session() as db:
        user_a = await _create_user(db)
        user_b = await _create_user(db)
        conv_id = await _create_conversation(db, [user_a, user_b])
        latest = await _create_message(db, conv_id, user_a)
        cursor = latest.created_at.isoformat()

    async with await _client() as client:
        resp = await client.get(
            f"/conversations/{conv_id}/messages",
            params={"after": cursor},
            headers=_auth_header(user_a),
        )

    assert resp.status_code == 200
    assert resp.json() == []


async def test_before_still_works_descending_without_after():
    async with async_session() as db:
        user_a = await _create_user(db)
        user_b = await _create_user(db)
        conv_id = await _create_conversation(db, [user_a, user_b])
        first = await _create_message(db, conv_id, user_a)
        second = await _create_message(db, conv_id, user_b)

    async with await _client() as client:
        resp = await client.get(
            f"/conversations/{conv_id}/messages",
            headers=_auth_header(user_a),
        )

    assert resp.status_code == 200
    ids = [m["id"] for m in resp.json()]
    assert ids == [second.id, first.id]  # unchanged existing behavior: newest first


async def test_after_non_participant_forbidden():
    async with async_session() as db:
        user_a = await _create_user(db)
        outsider = await _create_user(db)
        conv_id = await _create_conversation(db, [user_a])

    async with await _client() as client:
        resp = await client.get(
            f"/conversations/{conv_id}/messages",
            params={"after": "2026-01-01T00:00:00"},
            headers=_auth_header(outsider),
        )

    assert resp.status_code == 403


async def test_fan_out_mirrors_new_message_to_sender_other_devices(monkeypatch):
    """Multi-device mirror v0: fan_out_message must push `new_message` for
    the sender's own user_id (all of their connected sockets), in addition
    to fanning out to the other participant."""
    send_mock = AsyncMock(return_value=True)
    monkeypatch.setattr("app.fanout.manager.send_to_user", send_mock)

    async with async_session() as db:
        sender_id = await _create_user(db)
        other_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, other_id])
        conv = await db.get(Conversation, conv_id)
        message = await _create_message(db, conv_id, sender_id)
        await fan_out_message(db, conv, message)

    sent_to_user_ids = {call.args[0] for call in send_mock.await_args_list}
    assert sender_id in sent_to_user_ids  # mirror to sender's other devices
    assert other_id in sent_to_user_ids  # normal fan-out to the other participant

    mirror_call = next(c for c in send_mock.await_args_list if c.args[0] == sender_id)
    assert mirror_call.args[1]["type"] == "new_message"
    assert mirror_call.args[1]["message"]["packet_id"] == message.id


async def test_after_unknown_conversation_not_found():
    async with async_session() as db:
        user_a = await _create_user(db)

    async with await _client() as client:
        resp = await client.get(
            f"/conversations/{uuid.uuid4()}/messages",
            params={"after": "2026-01-01T00:00:00"},
            headers=_auth_header(user_a),
        )

    assert resp.status_code == 404
