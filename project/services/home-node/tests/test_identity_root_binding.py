from datetime import datetime, timezone

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from app.models import Device, User
from app.routers.users import bind_identity_root
from app.schemas import UserIdentityBindingRequest
from shared.security.keys import public_key_b64
from shared.security.user_identity_binding import issue_user_identity_binding


class _Db:
    def __init__(self, user: User, device: Device):
        self.user = user
        self.device = device
        self.commits = 0

    async def get(self, model, identifier):
        if model is User and identifier == self.user.id:
            return self.user
        if model is Device and identifier == self.device.id:
            return self.device
        return None

    async def commit(self):
        self.commits += 1


def _objects(device_key: SigningKey):
    user = User(
        id="user-a",
        display_name="Alice",
        phone="+10000000000",
        password_hash="unused",
    )
    device = Device(
        id="device-a",
        user_id=user.id,
        device_name="phone",
        device_type="android",
        auth_public_key=public_key_b64(device_key),
        identity_key_bundle={},
        trusted=True,
    )
    return user, device


@pytest.mark.asyncio
async def test_authenticated_device_can_dual_sign_first_root_binding():
    root_key, device_key = SigningKey.generate(), SigningKey.generate()
    user, device = _objects(device_key)
    db = _Db(user, device)
    binding = issue_user_identity_binding(
        user_id=user.id,
        identity_signing_key=root_key,
        identity_version=1,
        authorizing_device_id=device.id,
        device_signing_key=device_key,
        issued_at=datetime.now(timezone.utc),
    )

    response = await bind_identity_root(
        UserIdentityBindingRequest(**binding),
        current=(user.id, device.id),
        db=db,
    )

    assert response.identity_root_public_key == public_key_b64(root_key)
    assert user.identity_binding == binding
    assert db.commits == 1


@pytest.mark.asyncio
async def test_existing_root_cannot_be_silently_replaced():
    old_root, new_root, device_key = (
        SigningKey.generate(),
        SigningKey.generate(),
        SigningKey.generate(),
    )
    user, device = _objects(device_key)
    user.identity_root_public_key = public_key_b64(old_root)
    user.identity_version = 1
    db = _Db(user, device)
    binding = issue_user_identity_binding(
        user_id=user.id,
        identity_signing_key=new_root,
        identity_version=1,
        authorizing_device_id=device.id,
        device_signing_key=device_key,
        issued_at=datetime.now(timezone.utc),
    )

    with pytest.raises(HTTPException) as exc:
        await bind_identity_root(
            UserIdentityBindingRequest(**binding),
            current=(user.id, device.id),
            db=db,
        )

    assert exc.value.status_code == 400
    assert "replacement requires transition" in str(exc.value.detail)
    assert db.commits == 0
