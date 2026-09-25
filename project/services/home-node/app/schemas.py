import base64
import math
import re
from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.federation_schemas import (
    HomeChangedRequest,
    InternalDeliverRequest,
    InternalDeliveryAckRequest,
    MAX_MESSAGE_CIPHERTEXT_CHARS,
)


def _require_base64_bytes(value: str, expected_length: int, field_name: str) -> str:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError(f"{field_name} must be valid base64") from exc
    if len(decoded) != expected_length:
        raise ValueError(f"{field_name} must encode {expected_length} bytes")
    return value


class PublicPreKey(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: int = Field(ge=0, le=2_147_483_647)
    public_key: str = Field(min_length=40, max_length=128)

    @field_validator("public_key")
    @classmethod
    def validate_public_key(cls, value: str) -> str:
        return _require_base64_bytes(value, 33, "public_key")


class SignedPublicPreKey(PublicPreKey):
    signature: str = Field(min_length=80, max_length=128)

    @field_validator("signature")
    @classmethod
    def validate_signature(cls, value: str) -> str:
        return _require_base64_bytes(value, 64, "signature")


class IdentityKeyBundle(BaseModel):
    model_config = ConfigDict(extra="forbid")

    identity_key: str = Field(min_length=40, max_length=128)
    registration_id: int = Field(ge=1, le=2_147_483_647)
    signed_prekey: SignedPublicPreKey
    prekeys: list[PublicPreKey] = Field(min_length=1, max_length=256)
    consumed_prekey_ids: list[int] = Field(default_factory=list, max_length=256)

    @field_validator("identity_key")
    @classmethod
    def validate_identity_key(cls, value: str) -> str:
        return _require_base64_bytes(value, 33, "identity_key")

    @model_validator(mode="after")
    def validate_prekey_ids(self):
        prekey_ids = [prekey.id for prekey in self.prekeys]
        if len(prekey_ids) != len(set(prekey_ids)):
            raise ValueError("prekey ids must be unique")
        consumed = self.consumed_prekey_ids
        if len(consumed) != len(set(consumed)):
            raise ValueError("consumed prekey ids must be unique")
        if not set(consumed).issubset(prekey_ids):
            raise ValueError("consumed prekey ids must refer to published prekeys")
        return self


class RegisterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: str = Field(min_length=1, max_length=100)
    phone: str = Field(min_length=1, max_length=32)
    login: Optional[str] = Field(default=None, min_length=1, max_length=50)
    email: Optional[str] = Field(default=None, min_length=3, max_length=255)
    password: Optional[str] = Field(default=None, min_length=8, max_length=1024)
    device_name: str = Field(min_length=1, max_length=100)
    device_type: str = Field(min_length=1, max_length=20)
    auth_public_key: str = Field(min_length=40, max_length=128)
    identity_key_bundle: IdentityKeyBundle
    # Anti-spam PoW (Task #69): challenge выданный сервером + найденный nonce
    pow_challenge: Optional[str] = Field(default=None, max_length=256)
    pow_nonce: Optional[str] = Field(default=None, max_length=256)

    @field_validator("auth_public_key")
    @classmethod
    def validate_auth_public_key(cls, value: str) -> str:
        return _require_base64_bytes(value, 32, "auth_public_key")


class RegisterResponse(BaseModel):
    user_id: str
    device_id: str
    access_token: str


class LoginRequest(BaseModel):
    """
    Temporary bridge login — see ADR-0007. Not the target auth model.
    Logging in from a device not seen before registers it as a new Device
    under the existing User (each Device keeps its own Signal identity —
    see spec/0300_CRYPTO.md — password login cannot change that).
    """
    model_config = ConfigDict(extra="forbid")

    identifier: str = Field(min_length=1, max_length=255)
    password: str = Field(min_length=1, max_length=1024)
    device_name: str = Field(min_length=1, max_length=100)
    device_type: str = Field(min_length=1, max_length=20)
    auth_public_key: str = Field(min_length=40, max_length=128)
    identity_key_bundle: IdentityKeyBundle

    @field_validator("auth_public_key")
    @classmethod
    def validate_auth_public_key(cls, value: str) -> str:
        return _require_base64_bytes(value, 32, "auth_public_key")


class LoginResponse(BaseModel):
    user_id: str
    device_id: str
    access_token: str


class ChallengeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    device_id: str = Field(min_length=1, max_length=64)


class ChallengeResponse(BaseModel):
    nonce: str  # base64, sign this with the device's auth private key
    expires_at: str


class VerifyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    device_id: str = Field(min_length=1, max_length=64)
    nonce: str = Field(min_length=40, max_length=64)
    signature: str = Field(min_length=80, max_length=128)

    @field_validator("nonce")
    @classmethod
    def validate_nonce(cls, value: str) -> str:
        return _require_base64_bytes(value, 32, "nonce")

    @field_validator("signature")
    @classmethod
    def validate_verify_signature(cls, value: str) -> str:
        return _require_base64_bytes(value, 64, "signature")


class VerifyResponse(BaseModel):
    access_token: str
    user_id: str
    device_id: str


class CreateConversationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: str = Field(default="direct", pattern="^(direct|group)$")
    name: Optional[str] = Field(default=None, max_length=100)
    participant_user_ids: List[str] = Field(min_length=1, max_length=256)

    @field_validator("participant_user_ids")
    @classmethod
    def validate_participant_ids(cls, values: List[str]) -> List[str]:
        if any(not value or len(value) > 64 for value in values):
            raise ValueError("participant user ids must contain 1 to 64 characters")
        if len(values) != len(set(values)):
            raise ValueError("participant user ids must be unique")
        return values


class ConversationResponse(BaseModel):
    id: str
    type: str
    name: Optional[str]
    participant_user_ids: List[str]
    # Best-effort: only populated for participants hosted on this Home Node.
    # Remote/unknown participants are omitted; client falls back to its own
    # locally-cached label (see shared/README.md — no global directory by design).
    participant_display_names: dict
    created_at: datetime
    updated_at: datetime


class DeviceEnvelope(BaseModel):
    """Per-device E2EE ciphertext (Task #57). Sent from client when it
    knows all recipients' devices and encrypts separately for each."""
    model_config = ConfigDict(extra="forbid")

    device_id: str = Field(min_length=1, max_length=36)
    ciphertext: str = Field(
        min_length=1, max_length=MAX_MESSAGE_CIPHERTEXT_CHARS
    )


class SendMessageRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ciphertext: str = Field(
        min_length=1, max_length=MAX_MESSAGE_CIPHERTEXT_CHARS
    )
    content_type: str = Field(default="text", min_length=1, max_length=20, pattern=r"^[a-z][a-z0-9_]*$")
    crypto_version: str = Field(default="signal-v1", min_length=1, max_length=30)
    client_msg_id: Optional[str] = Field(default=None, min_length=1, max_length=64)
    # Per-device E2EE: если задан, fanout доставляет каждый конверт
    # конкретному устройству. ciphertext выше — fallback если device не online.
    device_envelopes: Optional[list[DeviceEnvelope]] = Field(default=None, max_length=512)
    # Storage federation (Task #63): URL Media-node отправителя.
    # Клиент передаёт AppConfig.mediaNodeUrl чтобы получатели на других Home
    # могли скачать медиа через federation если локально нет.
    media_node_url: Optional[str] = Field(default=None, min_length=1, max_length=255)
    # Список media_id содержащихся в сообщении — нужен для federation маппинга.
    # Клиент передаёт ID файлов которые он загрузил (могут быть зашифрованы
    # в ciphertext, но сами ID видны серверу для роутинга).
    media_ids: Optional[list[str]] = Field(default=None, max_length=256)

    @field_validator("media_ids")
    @classmethod
    def validate_media_ids(cls, values: Optional[list[str]]) -> Optional[list[str]]:
        from shared.security.media_id import validate_media_id

        if values is None:
            return None
        for value in values:
            validate_media_id(value)
        if len(values) != len(set(values)):
            raise ValueError("media ids must be unique")
        return values

    @model_validator(mode="after")
    def validate_combined_ciphertext_size(self) -> "SendMessageRequest":
        total = len(self.ciphertext)
        if self.device_envelopes:
            total += sum(len(item.ciphertext) for item in self.device_envelopes)
            device_ids = [item.device_id for item in self.device_envelopes]
            if len(device_ids) != len(set(device_ids)):
                raise ValueError("device envelope ids must be unique")
        if total > MAX_MESSAGE_CIPHERTEXT_CHARS:
            raise ValueError("combined ciphertext is too large")
        return self


class MessageResponse(BaseModel):
    id: str
    conversation_id: str
    sender_user_id: str
    sender_device_id: Optional[str]
    sender_display_name: Optional[str] = None
    ciphertext: str
    content_type: str
    crypto_version: str
    created_at: datetime
    delivery_status: str = "sent"   # sent | delivered | read
    delivered_at: Optional[datetime] = None
    read_at: Optional[datetime] = None
    # Исчезающие сообщения (Task #70)
    expires_at: Optional[datetime] = None
    # Редактирование (Task #71): None = не редактировалось
    edited_at: Optional[datetime] = None


class MessagePage(BaseModel):
    """Страница истории чата с курсором для следующего запроса.

    Пагинация назад (load more):
        GET /conversations/{id}/messages?limit=50
        → has_more=True, next_cursor=<created_at первого сообщения>
        GET /conversations/{id}/messages?limit=50&before=<next_cursor>

    Догон новых сообщений (multi-device catch-up):
        GET /conversations/{id}/messages?after=<last_seen_created_at>&limit=200
        → items в порядке asc, has_more=False (или повтор с after=last.created_at)
    """
    items: List[MessageResponse]
    has_more: bool
    next_cursor: Optional[str] = None   # ISO datetime для следующего before=


class UpdateDeliveryStatusRequest(BaseModel):
    status: str  # "delivered" | "read"


class MessageStatusUpdateEvent(BaseModel):
    """WS-событие — рассылается отправителю при смене статуса."""
    type: str = "message_status_update"
    message_id: str
    conversation_id: str
    status: str
    updated_by: str
    updated_at: datetime


class AckMessageRequest(BaseModel):
    device_id: Optional[str] = None


class DeliveryAckResponse(BaseModel):
    status: str = "ok"


class MeResponse(BaseModel):
    user_id: str
    display_name: str
    phone: str
    login: Optional[str]
    email: Optional[str]
    bio: Optional[str] = None
    created_at: datetime


class UpdateProfileRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: Optional[str] = Field(default=None, min_length=1, max_length=100)
    login: Optional[str] = Field(default=None, max_length=50)
    email: Optional[str] = Field(default=None, max_length=255)
    phone: Optional[str] = Field(default=None, max_length=32)
    bio: Optional[str] = Field(default=None, max_length=2000)

    @field_validator("email")
    @classmethod
    def validate_optional_email_length(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and value.strip() and len(value.strip()) < 3:
            raise ValueError("email must contain at least 3 characters")
        return value


class ProfileSettingsPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    values: dict[str, bool | int | float | str | list[str] | None] = Field(
        default_factory=dict,
        max_length=256,
    )
    lists: dict[str, list[str]] = Field(default_factory=dict, max_length=64)

    @model_validator(mode="after")
    def validate_settings(self) -> "ProfileSettingsPayload":
        key_pattern = re.compile(r"^[a-z][a-z0-9_.-]{0,127}$")
        total_items = 0
        for key, value in self.values.items():
            if not key_pattern.fullmatch(key):
                raise ValueError("profile setting key is invalid")
            if isinstance(value, str) and len(value) > 4096:
                raise ValueError("profile setting string is too long")
            if isinstance(value, list) and (
                len(value) > 256 or any(len(item) > 256 for item in value)
            ):
                raise ValueError("profile setting selection is too large")
            if isinstance(value, list):
                total_items += len(value)
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError("profile setting number must be finite")
        for key, values in self.lists.items():
            if not key_pattern.fullmatch(key):
                raise ValueError("profile list key is invalid")
            if len(values) > 256 or any(len(value) > 256 for value in values):
                raise ValueError("profile list is too large")
            total_items += len(values)
        if total_items > 2048:
            raise ValueError("profile lists contain too many entries")
        return self


class PresencePolicyPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    online_status: bool = True
    last_seen: str = Field(
        default="contacts",
        pattern="^(nobody|contacts|selected|everyone)$",
    )
    selected_user_ids: List[str] = Field(default_factory=list, max_length=256)
    invisible: bool = False

    @field_validator("selected_user_ids")
    @classmethod
    def validate_selected_user_ids(cls, values: List[str]) -> List[str]:
        if any(not value or len(value) > 128 for value in values):
            raise ValueError("selected user id is invalid")
        if len(values) != len(set(values)):
            raise ValueError("selected user ids must be unique")
        return values


class PresenceResponse(BaseModel):
    user_id: str
    online: bool
    last_seen: Optional[datetime] = None


class UpdateDisplayNameRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    display_name: str = Field(min_length=1, max_length=100)


class ChangePasswordRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    current_password: str = Field(min_length=1, max_length=1024)
    new_password: str = Field(min_length=8, max_length=1024)


class DeviceSummaryResponse(BaseModel):
    id: str
    device_name: str
    device_type: str
    created_at: datetime
    last_active: datetime
    is_current: bool
    trusted: bool


class DeviceTrustUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    trusted: bool
