import asyncio
import uuid

import httpx
import pytest

from app.db import async_session, init_db
from app.main import app
from app.models import Conversation, ConversationParticipant, Device, User
from app.security import create_access_token

pytestmark = pytest.mark.asyncio


@pytest.fixture(scope="session", autouse=True)
def _init_db_once():
    asyncio.run(init_db())


async def _create_user(db, *, policy=None) -> tuple[str, str]:
    user = User(
        display_name="Presence User",
        phone=f"+1{uuid.uuid4().int % 10**10}",
        password_hash="x",
        presence_policy=policy,
    )
    db.add(user)
    await db.flush()
    device = Device(
        user_id=user.id,
        device_name="web",
        device_type="web",
        auth_public_key="pk",
        identity_key_bundle={},
    )
    db.add(device)
    await db.commit()
    return user.id, device.id


def _headers(user_id: str, device_id: str) -> dict[str, str]:
    token = create_access_token({"sub": user_id, "device_id": device_id})
    return {"Authorization": f"Bearer {token}"}


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    )


async def test_presence_policy_hides_status_from_stranger(monkeypatch):
    async with async_session() as db:
        target_id, target_device = await _create_user(
            db,
            policy={
                "online_status": True,
                "last_seen": "contacts",
                "selected_user_ids": [],
                "invisible": False,
            },
        )
        viewer_id, viewer_device = await _create_user(db)

    monkeypatch.setattr("app.routers.users.manager.is_online", lambda _: True)
    async with await _client() as client:
        response = await client.get(
            f"/users/{target_id}/presence",
            headers=_headers(viewer_id, viewer_device),
        )

    assert response.status_code == 200
    assert response.json()["online"] is False
    assert response.json()["last_seen"] is None


async def test_presence_policy_allows_direct_contact(monkeypatch):
    async with async_session() as db:
        target_id, _target_device = await _create_user(
            db,
            policy={
                "online_status": True,
                "last_seen": "contacts",
                "selected_user_ids": [],
                "invisible": False,
            },
        )
        viewer_id, viewer_device = await _create_user(db)
        conversation = Conversation(type="direct")
        db.add(conversation)
        await db.flush()
        db.add_all(
            [
                ConversationParticipant(
                    conversation_id=conversation.id,
                    user_id=target_id,
                ),
                ConversationParticipant(
                    conversation_id=conversation.id,
                    user_id=viewer_id,
                ),
            ]
        )
        await db.commit()

    monkeypatch.setattr("app.routers.users.manager.is_online", lambda _: True)
    async with await _client() as client:
        response = await client.get(
            f"/users/{target_id}/presence",
            headers=_headers(viewer_id, viewer_device),
        )

    assert response.status_code == 200
    assert response.json()["online"] is True
    assert response.json()["last_seen"] is not None


async def test_invisible_mode_hides_presence_even_from_contact(monkeypatch):
    async with async_session() as db:
        target_id, _target_device = await _create_user(
            db,
            policy={
                "online_status": True,
                "last_seen": "everyone",
                "selected_user_ids": [],
                "invisible": True,
            },
        )
        viewer_id, viewer_device = await _create_user(db)

    monkeypatch.setattr("app.routers.users.manager.is_online", lambda _: True)
    async with await _client() as client:
        response = await client.get(
            f"/users/{target_id}/presence",
            headers=_headers(viewer_id, viewer_device),
        )

    assert response.status_code == 200
    assert response.json()["online"] is False
    assert response.json()["last_seen"] is None
