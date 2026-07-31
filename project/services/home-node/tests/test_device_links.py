import asyncio
import base64
import os
import uuid

import httpx
import pytest
from sqlalchemy import select

from app.db import async_session, init_db
from app.main import app
from app.models import Device, User
from app.security import create_access_token, verify_token

pytestmark = pytest.mark.asyncio


@pytest.fixture(scope="session", autouse=True)
def _init_db_once():
    asyncio.run(init_db())


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    )


async def _trusted_account() -> tuple[str, str, str]:
    async with async_session() as db:
        user = User(
            display_name="Trusted",
            phone=f"+7{uuid.uuid4().int % 10**10:010d}",
            password_hash="unused",
        )
        db.add(user)
        await db.flush()
        device = Device(
            user_id=user.id,
            device_name="Existing PC",
            device_type="desktop",
            auth_public_key=base64.b64encode(os.urandom(32)).decode(),
            identity_key_bundle={"identity_key": "old"},
        )
        db.add(device)
        await db.commit()
        token = create_access_token({"sub": user.id, "device_id": device.id})
        return user.id, device.id, token


async def test_existing_device_approves_new_device_and_poll_is_one_time():
    user_id, _, token = await _trusted_account()
    new_auth_key = base64.b64encode(os.urandom(32)).decode()

    async with await _client() as client:
        created = await client.post(
            "/auth/device-links",
            json={
                "device_name": "New phone",
                "device_type": "web",
                "auth_public_key": new_auth_key,
                "identity_key_bundle": {"identity_key": "new"},
            },
        )
        assert created.status_code == 200
        link = created.json()
        assert "ouo_device_link" in link["qr_payload"]

        pending = await client.post(
            f"/auth/device-links/{link['link_id']}/poll",
            json={"secret": link["secret"]},
        )
        assert pending.json()["status"] == "pending"

        approved = await client.post(
            f"/auth/device-links/{link['link_id']}/approve",
            headers={"Authorization": f"Bearer {token}"},
            json={"secret": link["secret"]},
        )
        assert approved.status_code == 200

        completed = await client.post(
            f"/auth/device-links/{link['link_id']}/poll",
            json={"secret": link["secret"]},
        )
        assert completed.status_code == 200
        result = completed.json()
        assert result["status"] == "approved"
        assert result["user_id"] == user_id
        claims = verify_token(result["access_token"])
        assert claims["sub"] == user_id
        assert claims["device_id"] == result["device_id"]

        consumed = await client.post(
            f"/auth/device-links/{link['link_id']}/poll",
            json={"secret": link["secret"]},
        )
        assert consumed.status_code == 404

    async with async_session() as db:
        device = (
            await db.execute(
                select(Device).where(
                    Device.user_id == user_id,
                    Device.auth_public_key == new_auth_key,
                )
            )
        ).scalar_one()
        assert device.device_name == "New phone"


async def test_wrong_qr_secret_cannot_poll_or_approve():
    _, _, token = await _trusted_account()
    async with await _client() as client:
        created = (
            await client.post(
                "/auth/device-links",
                json={
                    "device_name": "Attacker",
                    "device_type": "web",
                    "auth_public_key": base64.b64encode(os.urandom(32)).decode(),
                    "identity_key_bundle": {"identity_key": "x"},
                },
            )
        ).json()
        path = f"/auth/device-links/{created['link_id']}"
        assert (
            await client.post(f"{path}/poll", json={"secret": "wrong"})
        ).status_code == 404
        assert (
            await client.post(
                f"{path}/approve",
                headers={"Authorization": f"Bearer {token}"},
                json={"secret": "wrong"},
            )
        ).status_code == 404
