"""Tests for the Post-R5 semantic e2e delivery ACK (spec/0202_DELIVERY.md):
POST /conversations/{id}/messages/{packet_id}/ack — participant/idempotency
checks on the wire, plus the local-WS-push vs. federation-forward branches
in app.fanout.handle_delivery_ack.
"""
import asyncio
import uuid
from unittest.mock import AsyncMock

import httpx
import pytest
from sqlalchemy import select

from app.config import settings
from app.db import async_session, init_db
from app.fed_security import require_federation
from app.main import app
from app.models import Conversation, ConversationParticipant, Message, MessageDeliveryAck, User
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


async def _create_message(db, conversation_id: str, sender_user_id: str) -> str:
    message = Message(conversation_id=conversation_id, sender_user_id=sender_user_id, ciphertext="ct")
    db.add(message)
    await db.commit()
    return message.id


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


async def test_ack_local_sender_persists_and_pushes_ws(monkeypatch):
    send_mock = AsyncMock(return_value=True)
    monkeypatch.setattr("app.ws.manager.send_to_user", send_mock)

    async with async_session() as db:
        sender_id = await _create_user(db)
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, sender_id)

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={},
            headers=_auth_header(acker_id),
        )

    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}

    send_mock.assert_awaited_once()
    call_user_id, call_payload = send_mock.call_args.args
    assert call_user_id == sender_id
    assert call_payload["type"] == "delivery_ack"
    assert call_payload["packet_id"] == packet_id
    assert call_payload["conversation_id"] == conv_id
    assert call_payload["from_user_id"] == acker_id
    assert "acked_at" in call_payload

    async with async_session() as db:
        result = await db.execute(
            select(MessageDeliveryAck).where(
                MessageDeliveryAck.packet_id == packet_id,
                MessageDeliveryAck.from_user_id == acker_id,
            )
        )
        rows = result.scalars().all()
    assert len(rows) == 1
    assert rows[0].conversation_id == conv_id


async def test_ack_is_idempotent(monkeypatch):
    monkeypatch.setattr("app.ws.manager.send_to_user", AsyncMock(return_value=True))

    async with async_session() as db:
        sender_id = await _create_user(db)
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, sender_id)

    async with await _client() as client:
        first = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={"device_id": "dev-1"},
            headers=_auth_header(acker_id),
        )
        second = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={},
            headers=_auth_header(acker_id),
        )

    assert first.status_code == 200
    assert second.status_code == 200

    async with async_session() as db:
        result = await db.execute(
            select(MessageDeliveryAck).where(
                MessageDeliveryAck.packet_id == packet_id,
                MessageDeliveryAck.from_user_id == acker_id,
            )
        )
        rows = result.scalars().all()
    assert len(rows) == 1


async def test_ack_omitted_body_defaults_ok(monkeypatch):
    monkeypatch.setattr("app.ws.manager.send_to_user", AsyncMock(return_value=True))

    async with async_session() as db:
        sender_id = await _create_user(db)
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, sender_id)

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            headers=_auth_header(acker_id),
        )

    assert resp.status_code == 200


async def test_ack_non_participant_forbidden():
    async with async_session() as db:
        sender_id = await _create_user(db)
        acker_id = await _create_user(db)
        outsider_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, sender_id)

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={},
            headers=_auth_header(outsider_id),
        )

    assert resp.status_code == 403


async def test_ack_unknown_packet_not_found():
    async with async_session() as db:
        sender_id = await _create_user(db)
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id, acker_id])

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{uuid.uuid4()}/ack",
            json={},
            headers=_auth_header(acker_id),
        )

    assert resp.status_code == 404


async def test_ack_remote_sender_forwards_via_federation(monkeypatch):
    """Sender has no local User row (simulating a remote-Home sender) —
    handle_delivery_ack should resolve their Home and forward the ack there
    instead of pushing WS locally."""
    notify_mock = AsyncMock()
    monkeypatch.setattr("app.fanout.resolve_home_node", AsyncMock(return_value="http://peer-home.invalid"))
    monkeypatch.setattr("app.fanout.notify_remote_delivery_ack", notify_mock)
    send_mock = AsyncMock(return_value=True)
    monkeypatch.setattr("app.ws.manager.send_to_user", send_mock)

    remote_sender_id = str(uuid.uuid4())
    async with async_session() as db:
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [remote_sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, remote_sender_id)

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={},
            headers=_auth_header(acker_id),
        )

    assert resp.status_code == 200
    send_mock.assert_not_awaited()
    notify_mock.assert_awaited_once()
    _, kwargs = notify_mock.call_args
    assert kwargs["packet_id"] == packet_id
    assert kwargs["conversation_id"] == conv_id
    assert kwargs["from_user_id"] == acker_id


async def test_ack_remote_sender_unresolvable_home_is_noop(monkeypatch):
    monkeypatch.setattr("app.fanout.resolve_home_node", AsyncMock(return_value=None))
    notify_mock = AsyncMock()
    monkeypatch.setattr("app.fanout.notify_remote_delivery_ack", notify_mock)

    remote_sender_id = str(uuid.uuid4())
    async with async_session() as db:
        acker_id = await _create_user(db)
        conv_id = await _create_conversation(db, [remote_sender_id, acker_id])
        packet_id = await _create_message(db, conv_id, remote_sender_id)

    async with await _client() as client:
        resp = await client.post(
            f"/conversations/{conv_id}/messages/{packet_id}/ack",
            json={},
            headers=_auth_header(acker_id),
        )

    assert resp.status_code == 200
    notify_mock.assert_not_awaited()


async def test_internal_delivery_ack_pushes_ws_to_local_sender(monkeypatch):
    send_mock = AsyncMock(return_value=True)
    monkeypatch.setattr("app.ws.manager.send_to_user", send_mock)

    async with async_session() as db:
        sender_id = await _create_user(db)
        conv_id = await _create_conversation(db, [sender_id])
        packet_id = await _create_message(db, conv_id, sender_id)

    body = {
        "packet_id": packet_id,
        "conversation_id": conv_id,
        "from_user_id": str(uuid.uuid4()),
        "acked_at": "2026-07-22T20:00:00Z",
        "origin_node_id": "peer-home",
        "envelope": {"packet_id": packet_id, "ciphertext": ""},
    }

    app.dependency_overrides[require_federation] = lambda: "peer-home"
    try:
        async with await _client() as client:
            resp = await client.post("/internal/delivery-ack", json=body)
    finally:
        app.dependency_overrides.pop(require_federation, None)

    assert resp.status_code == 200
    send_mock.assert_awaited_once_with(
        sender_id,
        {
            "type": "delivery_ack",
            "packet_id": packet_id,
            "conversation_id": conv_id,
            "from_user_id": body["from_user_id"],
            "acked_at": body["acked_at"],
        },
    )
