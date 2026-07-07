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


class SendMessageRequest(BaseModel):
    ciphertext: str
    content_type: str = "text"
    crypto_version: str = "signal-v1"
    client_msg_id: Optional[str] = None


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


class InternalDeliverRequest(BaseModel):
    envelope: dict
    conversation_meta: dict
    origin_node_id: str
    federation: Optional[dict] = None


class MeResponse(BaseModel):
    user_id: str
    display_name: str
    phone: str
    login: Optional[str]
    email: Optional[str]
    created_at: datetime


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
