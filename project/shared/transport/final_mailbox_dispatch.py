"""Exit-hop payload that deposits one endpoint-encrypted cell into Storage."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any, Mapping

from shared.security.mailbox_capability import mailbox_token_bytes
from shared.transport.fixed_cell import CELL_SIZES


PROTOCOL_VERSION = "ouo-final-mailbox-dispatch/1"
FIELDS = {"protocol_version", "mailbox_token", "cell_b64", "ttl_seconds"}
FINAL_CELL_SIZES = CELL_SIZES[:-1]


@dataclass(frozen=True)
class FinalMailboxDispatch:
    mailbox_token: str
    cell: bytes
    ttl_seconds: int


def encode_final_mailbox_dispatch(
    *, mailbox_token: str, cell: bytes, ttl_seconds: int
) -> bytes:
    mailbox_token_bytes(mailbox_token)
    if not isinstance(cell, bytes) or len(cell) not in FINAL_CELL_SIZES:
        raise ValueError("final mailbox cell must use a fixed size class")
    if not isinstance(ttl_seconds, int) or isinstance(ttl_seconds, bool) or not 60 <= ttl_seconds <= 2_592_000:
        raise ValueError("invalid final mailbox TTL")
    return json.dumps(
        {
            "protocol_version": PROTOCOL_VERSION,
            "mailbox_token": mailbox_token,
            "cell_b64": base64.urlsafe_b64encode(cell).decode(),
            "ttl_seconds": ttl_seconds,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def decode_final_mailbox_dispatch(payload: bytes) -> FinalMailboxDispatch:
    if not isinstance(payload, bytes) or not 1 <= len(payload) <= 350_000:
        raise ValueError("invalid final mailbox payload size")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid final mailbox payload") from exc
    if not isinstance(value, Mapping) or set(value) != FIELDS:
        raise ValueError("invalid final mailbox fields")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("unsupported final mailbox protocol")
    mailbox_token_bytes(value.get("mailbox_token"))
    ttl = value.get("ttl_seconds")
    if not isinstance(ttl, int) or isinstance(ttl, bool) or not 60 <= ttl <= 2_592_000:
        raise ValueError("invalid final mailbox TTL")
    try:
        cell = base64.b64decode(value.get("cell_b64"), altchars=b"-_", validate=True)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid final mailbox cell encoding") from exc
    if len(cell) not in FINAL_CELL_SIZES:
        raise ValueError("invalid final mailbox cell size")
    return FinalMailboxDispatch(value["mailbox_token"], cell, ttl)
