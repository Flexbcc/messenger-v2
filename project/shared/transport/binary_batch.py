"""Strict length-prefixed OUO Basic Transport batch codec."""

import struct
from dataclasses import dataclass
from typing import Sequence


MAGIC = b"OUOB"
VERSION = 1
HEADER = struct.Struct(">4sBBHQH")
LENGTH = struct.Struct(">I")
MAX_CELLS = 256
MAX_CELL_BYTES = 256 * 1024
MAX_BATCH_BYTES = 1024 * 1024


class BatchDecodeError(ValueError):
    pass


@dataclass(frozen=True)
class BinaryBatch:
    sequence: int
    cells: tuple[bytes, ...]


def encode_batch(*, sequence: int, cells: Sequence[bytes]) -> bytes:
    if not isinstance(sequence, int) or isinstance(sequence, bool) or not 0 <= sequence < 2**64:
        raise ValueError("sequence must be an unsigned 64-bit integer")
    if not isinstance(cells, (list, tuple)) or not 1 <= len(cells) <= MAX_CELLS:
        raise ValueError(f"batch must contain 1..{MAX_CELLS} cells")
    normalized = []
    total = HEADER.size
    for cell in cells:
        if not isinstance(cell, bytes):
            raise ValueError("cells must be bytes")
        if not 1 <= len(cell) <= MAX_CELL_BYTES:
            raise ValueError(f"cell must contain 1..{MAX_CELL_BYTES} bytes")
        total += LENGTH.size + len(cell)
        if total > MAX_BATCH_BYTES:
            raise ValueError("batch exceeds maximum size")
        normalized.append(cell)
    output = bytearray(HEADER.pack(MAGIC, VERSION, 0, 0, sequence, len(normalized)))
    for cell in normalized:
        output.extend(LENGTH.pack(len(cell)))
        output.extend(cell)
    return bytes(output)


def decode_batch(data: bytes) -> BinaryBatch:
    if not isinstance(data, bytes):
        raise BatchDecodeError("batch must be bytes")
    if len(data) > MAX_BATCH_BYTES:
        raise BatchDecodeError("batch exceeds maximum size")
    if len(data) < HEADER.size:
        raise BatchDecodeError("truncated batch header")
    magic, version, flags, reserved, sequence, count = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise BatchDecodeError("invalid batch magic")
    if version != VERSION:
        raise BatchDecodeError("unsupported batch version")
    if flags != 0 or reserved != 0:
        raise BatchDecodeError("unknown critical batch flags")
    if not 1 <= count <= MAX_CELLS:
        raise BatchDecodeError("invalid cell count")
    offset = HEADER.size
    cells = []
    for _ in range(count):
        if offset + LENGTH.size > len(data):
            raise BatchDecodeError("truncated cell length")
        (cell_length,) = LENGTH.unpack_from(data, offset)
        offset += LENGTH.size
        if not 1 <= cell_length <= MAX_CELL_BYTES:
            raise BatchDecodeError("invalid cell length")
        end = offset + cell_length
        if end > len(data):
            raise BatchDecodeError("truncated cell payload")
        cells.append(data[offset:end])
        offset = end
    if offset != len(data):
        raise BatchDecodeError("trailing bytes after batch")
    return BinaryBatch(sequence=sequence, cells=tuple(cells))
