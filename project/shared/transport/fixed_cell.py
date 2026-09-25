"""Authenticated fixed-size OUO transport cells using PyNaCl XChaCha20-Poly1305."""

import os
import struct
from dataclasses import dataclass
from typing import Optional

from nacl.exceptions import CryptoError
from nacl.secret import Aead


PROTOCOL_VERSION = 1
DOMAIN = b"OUO/FIXED_CELL/v1\x00"
CELL_SIZES = (4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024)
HEADER = struct.Struct(">BI")  # kind:u8, payload_length:u32 (inside AEAD)
KIND_DUMMY = 0
KIND_REAL = 1


class FixedCellError(ValueError):
    pass


@dataclass(frozen=True)
class OpenedCell:
    is_dummy: bool
    payload: bytes
    size: int


def max_payload_bytes(cell_size: int) -> int:
    if cell_size not in CELL_SIZES:
        raise ValueError("unsupported cell size")
    return cell_size - Aead.NONCE_SIZE - Aead.MACBYTES - HEADER.size


def select_cell_size(payload_length: int) -> int:
    if not isinstance(payload_length, int) or isinstance(payload_length, bool) or payload_length < 0:
        raise ValueError("payload_length must be a non-negative integer")
    for size in CELL_SIZES:
        if payload_length <= max_payload_bytes(size):
            return size
    raise ValueError("payload does not fit any v1 cell size")


def seal_fixed_cell(
    *, payload: Optional[bytes], key: bytes, cell_size: Optional[int] = None
) -> bytes:
    if not isinstance(key, bytes) or len(key) != Aead.KEY_SIZE:
        raise ValueError("fixed-cell key must be 32 bytes")
    if payload is not None and not isinstance(payload, bytes):
        raise ValueError("payload must be bytes or None")
    real_payload = payload or b""
    kind = KIND_DUMMY if payload is None else KIND_REAL
    size = cell_size or select_cell_size(len(real_payload))
    capacity = max_payload_bytes(size)
    if len(real_payload) > capacity:
        raise ValueError("payload exceeds selected cell size")
    plaintext = (
        HEADER.pack(kind, len(real_payload))
        + real_payload
        + os.urandom(capacity - len(real_payload))
    )
    associated_data = DOMAIN + struct.pack(">BI", PROTOCOL_VERSION, size)
    encrypted = bytes(Aead(key).encrypt(plaintext, aad=associated_data))
    if len(encrypted) != size:
        raise AssertionError("fixed-cell construction produced unexpected size")
    return encrypted


def open_fixed_cell(*, cell: bytes, key: bytes) -> OpenedCell:
    if not isinstance(cell, bytes) or len(cell) not in CELL_SIZES:
        raise FixedCellError("unsupported fixed cell size")
    if not isinstance(key, bytes) or len(key) != Aead.KEY_SIZE:
        raise FixedCellError("fixed-cell key must be 32 bytes")
    associated_data = DOMAIN + struct.pack(">BI", PROTOCOL_VERSION, len(cell))
    try:
        plaintext = Aead(key).decrypt(cell, aad=associated_data)
    except CryptoError as exc:
        raise FixedCellError("fixed cell authentication failed") from exc
    if len(plaintext) != len(cell) - Aead.NONCE_SIZE - Aead.MACBYTES:
        raise FixedCellError("invalid fixed cell plaintext size")
    try:
        kind, payload_length = HEADER.unpack_from(plaintext)
    except struct.error as exc:
        raise FixedCellError("truncated fixed cell header") from exc
    if kind not in (KIND_DUMMY, KIND_REAL):
        raise FixedCellError("invalid fixed cell kind")
    capacity = max_payload_bytes(len(cell))
    if payload_length > capacity:
        raise FixedCellError("invalid fixed cell payload length")
    if kind == KIND_DUMMY and payload_length != 0:
        raise FixedCellError("dummy cell cannot contain payload")
    return OpenedCell(
        is_dummy=kind == KIND_DUMMY,
        payload=plaintext[HEADER.size : HEADER.size + payload_length],
        size=len(cell),
    )
