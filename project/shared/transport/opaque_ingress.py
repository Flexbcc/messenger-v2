"""Opaque fixed-size ingress packet contract for the OUO privacy data plane."""

from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping


PROTOCOL_VERSION = "ouo-opaque-ingress/1"
PACKET_FORMAT = "sphinx-provider/1"
PACKET_SIZES = (4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024)
MAX_LIFETIME = timedelta(minutes=5)
MAX_CLOCK_SKEW = timedelta(seconds=30)
FIELDS = {"protocol_version", "packet_format", "packet_b64", "expires_at"}


@dataclass(frozen=True)
class OpaqueIngressPacket:
    packet: bytes
    expires_at: datetime


def _decode_packet(value: Any) -> bytes:
    if not isinstance(value, str) or not value:
        raise ValueError("opaque ingress packet encoding is required")
    try:
        packet = base64.b64decode(
            value.encode("ascii"), altchars=b"-_", validate=True
        )
    except (UnicodeEncodeError, ValueError) as exc:
        raise ValueError("invalid opaque ingress packet encoding") from exc
    if len(packet) not in PACKET_SIZES:
        raise ValueError("unsupported opaque ingress packet size")
    return packet


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("opaque ingress expiry must be a string")
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("opaque ingress expiry must include timezone")
    return parsed.astimezone(timezone.utc)


def build_opaque_ingress_packet(
    packet: bytes, *, expires_at: datetime
) -> dict[str, Any]:
    if not isinstance(packet, bytes) or len(packet) not in PACKET_SIZES:
        raise ValueError("opaque ingress packet must use a fixed size class")
    if expires_at.tzinfo is None or expires_at.utcoffset() is None:
        raise ValueError("opaque ingress expiry must be timezone-aware")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "packet_format": PACKET_FORMAT,
        "packet_b64": base64.urlsafe_b64encode(packet).decode("ascii"),
        "expires_at": expires_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def validate_opaque_ingress_packet(
    value: Mapping[str, Any], *, now: datetime
) -> OpaqueIngressPacket:
    if not isinstance(value, Mapping) or set(value) != FIELDS:
        raise ValueError("invalid opaque ingress fields")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("unsupported opaque ingress protocol_version")
    if value.get("packet_format") != PACKET_FORMAT:
        raise ValueError("unsupported critical packet_format")
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("validation time must be timezone-aware")
    packet = _decode_packet(value.get("packet_b64"))
    expires_at = _parse_time(value.get("expires_at"))
    now_utc = now.astimezone(timezone.utc)
    if expires_at <= now_utc - MAX_CLOCK_SKEW:
        raise ValueError("opaque ingress packet expired")
    if expires_at - now_utc > MAX_LIFETIME + MAX_CLOCK_SKEW:
        raise ValueError("opaque ingress lifetime exceeds limit")
    return OpaqueIngressPacket(packet=packet, expires_at=expires_at)
