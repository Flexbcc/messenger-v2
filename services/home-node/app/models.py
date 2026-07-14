"""
Home Node schema — ported and trimmed from ~/secret_room/backend/app/db/models.py
(see ADR-0005). Dropped everything specific to that project's "secret room"
duress/decoy features; kept the parts that map onto spec/0004_GLOSSARY.md:
User, Device, Conversation, ConversationParticipant, Message, PreKey-bundle.
"""
import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import String, ForeignKey, DateTime, Text, JSON
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
    content_type: Mapped[str] = mapped_column(String(20), default="text")  # text|image|file|voice
    crypto_version: Mapped[str] = mapped_column(String(30), default="signal-v1")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)

    conversation: Mapped["Conversation"] = relationship(back_populates="messages")
