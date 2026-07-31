"""
Home Node schema — ported and trimmed from ~/secret_room/backend/app/db/models.py
(see ADR-0005). Dropped everything specific to that project's "secret room"
duress/decoy features; kept the parts that map onto spec/0004_GLOSSARY.md:
User, Device, Conversation, ConversationParticipant, Message, PreKey-bundle.
"""
import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import String, ForeignKey, DateTime, Text, JSON, Integer, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


def gen_id() -> str:
    return str(uuid.uuid4())


class User(Base):
    """
    Maps to glossary 'User' — a person, may own multiple Device.

    phone/login/email/password_hash: temporary auth bridge, see ADR-0007.
    Not verified (no OTP) and not the target auth model — Device.auth_public_key
    challenge-response remains the per-device mechanism.
    """
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    display_name: Mapped[str] = mapped_column(String(100))
    phone: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    login: Mapped[Optional[str]] = mapped_column(String(50), unique=True, nullable=True, index=True)
    email: Mapped[Optional[str]] = mapped_column(String(255), unique=True, nullable=True, index=True)
    bio: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    profile_settings: Mapped[Optional[dict]] = mapped_column(JSON, nullable=True)
    # Minimal server-enforced presence policy. This is intentionally separate
    # from local UI settings and contains no recovery/key material.
    presence_policy: Mapped[Optional[dict]] = mapped_column(JSON, nullable=True)
    password_hash: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    devices: Mapped[list["Device"]] = relationship(back_populates="user", cascade="all, delete-orphan")


class Device(Base):
    """
    Maps to glossary 'Device'. Holds two independent keys, deliberately not
    shared (Single Responsibility, see shared/README.md):
    - auth_public_key: Ed25519, used only for login challenge-response.
    - identity_key_bundle: Signal identity key + prekeys, used only for E2EE
      session establishment (X3DH) by other devices, opaque to this server.
    """
    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"))
    device_name: Mapped[str] = mapped_column(String(100))
    device_type: Mapped[str] = mapped_column(String(20))  # ios | android | web | desktop
    auth_public_key: Mapped[str] = mapped_column(Text)
    identity_key_bundle: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_active: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    user: Mapped["User"] = relationship(back_populates="devices")


class Conversation(Base):
    """Maps to glossary 'Conversation'. Mirrored across every Home Node that
    hosts one of its participants (see app/fanout.py)."""
    __tablename__ = "conversations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    type: Mapped[str] = mapped_column(String(20), default="direct")  # direct | group
    name: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    # Исчезающие сообщения (Task #70): TTL в секундах для новых сообщений.
    # 0 / NULL = отключено. Применяется к каждому новому сообщению при создании.
    disappearing_ttl_seconds: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    participants: Mapped[list["ConversationParticipant"]] = relationship(
        back_populates="conversation", cascade="all, delete-orphan"
    )
    messages: Mapped[list["Message"]] = relationship(
        back_populates="conversation", cascade="all, delete-orphan"
    )


class ConversationParticipant(Base):
    """
    user_id is intentionally NOT a foreign key: a participant may be a user
    hosted on a different Home Node entirely (federation) and will never
    exist in this node's `users` table.
    """
    __tablename__ = "conversation_participants"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    conversation_id: Mapped[str] = mapped_column(String(36), ForeignKey("conversations.id", ondelete="CASCADE"))
    user_id: Mapped[str] = mapped_column(String(36), index=True)
    role: Mapped[str] = mapped_column(String(20), default="member")
    joined_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    conversation: Mapped["Conversation"] = relationship(back_populates="participants")


class Message(Base):
    """Maps to glossary 'Message', carried inside an Envelope on the wire
    (see shared/README.md). `ciphertext` is opaque to this server."""
    __tablename__ = "messages"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    conversation_id: Mapped[str] = mapped_column(String(36), ForeignKey("conversations.id", ondelete="CASCADE"))
    sender_user_id: Mapped[str] = mapped_column(String(36), index=True)
    sender_device_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True)
    client_msg_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True, index=True)
    ciphertext: Mapped[str] = mapped_column(Text)
    # Per-device E2EE (Task #57): список [{device_id, ciphertext}].
    # Если заполнен, fanout доставляет каждый конверт конкретному устройству.
    # ciphertext выше — fallback для broadcast/совместимости (группы, legacy).
    device_envelopes: Mapped[Optional[list]] = mapped_column(JSON, nullable=True)
    content_type: Mapped[str] = mapped_column(String(20), default="text")  # text|image|file|voice
    crypto_version: Mapped[str] = mapped_column(String(30), default="signal-v1")
    # Storage federation (Task #63): URL Media-node отправителя.
    # Заполняется при federated deliver если отправитель на другом Home.
    # Используется media_proxy для fallback-скачивания у чужого Media.
    origin_media_node_url: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    # Исчезающие сообщения (Task #70): когда удалить (UTC). NULL = не удалять.
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True, index=True)
    # Редактирование (Task #71): текущий ciphertext — последняя версия после edit.
    # История правок хранится в MessageEdit. NULL = ни разу не редактировалось.
    edited_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    # Статус доставки: sent → delivered → read
    delivery_status: Mapped[str] = mapped_column(String(20), default="sent", index=True)
    delivered_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    read_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)

    conversation: Mapped["Conversation"] = relationship(back_populates="messages")


class KeyTransparencyLog(Base):
    """Append-only журнал смены identity keys (Task #67 — Key Transparency).

    Каждый раз когда пользователь регистрирует новое устройство, меняет
    identity key или отзывает устройство — добавляется запись.
    Клиент может запросить историю и детектировать неожиданную смену ключа
    (признак потенциальной компрометации или MITM).

    Записи НИКОГДА не удаляются — append-only, нельзя переписать историю.
    """
    __tablename__ = "key_transparency_log"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True)
    device_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True)
    # event_type: "device_registered" | "identity_key_changed" | "device_revoked"
    event_type: Mapped[str] = mapped_column(String(40))
    # SHA-256 хэш нового identity key (не сам ключ — он в Device.identity_key_bundle)
    identity_key_fingerprint: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    # prev_fingerprint — хэш предыдущего ключа (для chain verification)
    prev_fingerprint: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    # SHA-256 хэш предыдущей записи (merkle-like chain)
    prev_entry_hash: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    # SHA-256 хэш этой записи (для верификации chain)
    entry_hash: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)


class FederatedMediaRef(Base):
    """Storage federation (Task #63): маппинг media_id → origin Media-node URL.

    Создаётся при получении federated сообщения содержащего media_node_url.
    Позволяет /media/{id} найти правильный origin Media-node для fallback
    вместо слепого поиска по всем сообщениям.

    media_id хранится как опак строка — сервер не знает что внутри ciphertext,
    но клиент передаёт media_id явно через SendMessageRequest.media_ids[].
    Пока используем packet_id как суррогат (один файл = одно сообщение MVP).
    """
    __tablename__ = "federated_media_refs"

    media_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    origin_media_node_url: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class MessageOutbox(Base):
    """
    Durable federation retry queue — Post-R5 (see docs/reality/R3-message-lifecycle.md
    Gaps: "Нет outbox на federation fail", spec/0202_DELIVERY.md "Durable outbox на
    Local Home при fail federation"). A row is created by fan_out_message
    (app/fanout.py) when deliver_to_remote_home_node exhausts direct delivery + all
    relay fallbacks for one target_user_id. The background worker (app/outbox.py)
    retries with exponential backoff until delivered (row deleted) or attempts
    exceed MAX_ATTEMPTS (status -> dead). Scope is server-side federation DLQ only,
    no client ACK packet.
    """
    __tablename__ = "message_outbox"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    packet_id: Mapped[str] = mapped_column(String(36), index=True)  # == Message.id
    target_user_id: Mapped[str] = mapped_column(String(36), index=True)
    target_home_url: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    envelope: Mapped[dict] = mapped_column(JSON)
    conversation_meta: Mapped[dict] = mapped_column(JSON)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    last_error: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="pending", index=True)  # pending|delivered|dead
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class MessageDeliveryAck(Base):
    """
    Post-R5 semantic e2e delivery ACK (spec/0202_DELIVERY.md) — recorded when
    a recipient confirms receipt of a Message via POST
    .../messages/{packet_id}/ack. Distinct from MessageOutbox above, which is
    a server-side federation DLQ and says nothing about client delivery.
    unique(packet_id, from_user_id) makes re-acking the same packet from the
    same user idempotent (ack twice -> 200, original acked_at kept).
    """
    __tablename__ = "message_delivery_acks"
    __table_args__ = (UniqueConstraint("packet_id", "from_user_id", name="uq_delivery_ack_packet_user"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    packet_id: Mapped[str] = mapped_column(String(36), index=True)  # == Message.id
    conversation_id: Mapped[str] = mapped_column(String(36), index=True)
    from_user_id: Mapped[str] = mapped_column(String(36), index=True)
    acked_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class MessageEdit(Base):
    """История правок сообщения (Task #71 — редактирование сообщений).

    При каждом редактировании:
    - Текущий ciphertext переносится в MessageEdit (как old_ciphertext)
    - Message.ciphertext обновляется новым значением
    - Message.edited_at ставится в now()

    Только отправитель может редактировать, только в пределах EDIT_WINDOW_SECONDS.
    Клиент показывает "(изменено)" если Message.edited_at is not None.
    """
    __tablename__ = "message_edits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=gen_id)
    message_id: Mapped[str] = mapped_column(String(36), ForeignKey("messages.id", ondelete="CASCADE"), index=True)
    # Зашифрованный текст предыдущей версии (до правки)
    old_ciphertext: Mapped[str] = mapped_column(Text)
    edited_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
