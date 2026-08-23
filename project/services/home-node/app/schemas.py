from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel


class RegisterRequest(BaseModel):
    display_name: str
    phone: str  # required — see ADR-0007 (temporary, unverified)
    login: Optional[str] = None
    email: Optional[str] = None
    password: str  # hashed server-side (argon2id), see ADR-0007
    device_name: str
    device_type: str  # ios | android | web | desktop
    auth_public_key: str  # base64 Ed25519 public key for this device
    identity_key_bundle: dict  # opaque Signal identity key + prekeys
    # Anti-spam PoW (Task #69): challenge выданный сервером + найденный nonce
    pow_challenge: Optional[str] = None
    pow_nonce: Optional[str] = None


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
    identifier: str  # phone, login, or email
    password: str
    device_name: str
    device_type: str
    auth_public_key: str
    identity_key_bundle: dict


class LoginResponse(BaseModel):
    user_id: str
    device_id: str
    access_token: str


class ChallengeRequest(BaseModel):
    device_id: str


class ChallengeResponse(BaseModel):
    nonce: str  # base64, sign this with the device's auth private key
    expires_at: str


class VerifyRequest(BaseModel):
    device_id: str
    nonce: str
    signature: str  # base64 Ed25519 signature over nonce bytes


class VerifyResponse(BaseModel):
    access_token: str
    user_id: str
    device_id: str


class CreateConversationRequest(BaseModel):
    type: str = "direct"  # direct | group
    name: Optional[str] = None
    participant_user_ids: List[str]


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
    device_id: str
    ciphertext: str


class SendMessageRequest(BaseModel):
    ciphertext: str  # Fallback/broadcast ciphertext (groups, legacy)
    content_type: str = "text"
    crypto_version: str = "signal-v1"
    client_msg_id: Optional[str] = None
    # Per-device E2EE: если задан, fanout доставляет каждый конверт
    # конкретному устройству. ciphertext выше — fallback если device не online.
    device_envelopes: Optional[list[DeviceEnvelope]] = None
    # Storage federation (Task #63): URL Media-node отправителя.
    # Клиент передаёт AppConfig.mediaNodeUrl чтобы получатели на других Home
    # могли скачать медиа через federation если локально нет.
    media_node_url: Optional[str] = None
    # Список media_id содержащихся в сообщении — нужен для federation маппинга.
    # Клиент передаёт ID файлов которые он загрузил (могут быть зашифрованы
    # в ciphertext, но сами ID видны серверу для роутинга).
    media_ids: Optional[list[str]] = None


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


class InternalDeliverRequest(BaseModel):
    envelope: dict
    conversation_meta: dict
    origin_node_id: str
    forwarded_by_node_id: Optional[str] = None
    federation: Optional[dict] = None


class InternalDeliveryAckRequest(BaseModel):
    """Post-R5 e2e delivery ACK (spec/0202_DELIVERY.md) forwarded by a
    recipient's Home to the sender's Home — see app.federation.notify_remote_delivery_ack."""
    packet_id: str
    conversation_id: str
    from_user_id: str
    acked_at: str
    origin_node_id: str
    envelope: dict
    federation: Optional[dict] = None


class HomeChangedRequest(BaseModel):
    """Post-R5 CONTROL notify (docs/reality/R4-routing.md Gaps "Нет notify
    смены Home"): no chat ciphertext, just enough for the receiving Home to
    refresh its own state for user_id."""
    user_id: str
    home_node_url: str
    home_updated_at: Optional[str] = None
    origin_node_id: str
    envelope: dict
    federation: Optional[dict] = None


class MeResponse(BaseModel):
    user_id: str
    display_name: str
    phone: str
    login: Optional[str]
    email: Optional[str]
    bio: Optional[str] = None
    created_at: datetime


class UpdateProfileRequest(BaseModel):
    display_name: Optional[str] = None
    login: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    bio: Optional[str] = None


class ProfileSettingsPayload(BaseModel):
    values: dict = {}
    lists: dict = {}


class PresencePolicyPayload(BaseModel):
    online_status: bool = True
    last_seen: str = "contacts"  # nobody | contacts | selected | everyone
    selected_user_ids: List[str] = []
    invisible: bool = False


class PresenceResponse(BaseModel):
    user_id: str
    online: bool
    last_seen: Optional[datetime] = None


class UpdateDisplayNameRequest(BaseModel):
    display_name: str


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str


class DeviceSummaryResponse(BaseModel):
    id: str
    device_name: str
    device_type: str
    created_at: datetime
    last_active: datetime
    is_current: bool
