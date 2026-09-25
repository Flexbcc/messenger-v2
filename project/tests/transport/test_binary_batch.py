import struct

import pytest

from shared.transport.binary_batch import (
    HEADER,
    MAGIC,
    VERSION,
    BatchDecodeError,
    decode_batch,
    encode_batch,
)


def test_binary_batch_roundtrip():
    encoded = encode_batch(sequence=42, cells=[b"opaque-a", b"opaque-b"])
    decoded = decode_batch(encoded)
    assert decoded.sequence == 42
    assert decoded.cells == (b"opaque-a", b"opaque-b")


@pytest.mark.parametrize(
    "payload,reason",
    [
        (b"", "truncated batch header"),
        (b"BAD!" + b"\x00" * (HEADER.size - 4), "invalid batch magic"),
        (HEADER.pack(MAGIC, VERSION + 1, 0, 0, 1, 1), "unsupported batch version"),
        (HEADER.pack(MAGIC, VERSION, 1, 0, 1, 1), "unknown critical batch flags"),
        (HEADER.pack(MAGIC, VERSION, 0, 0, 1, 1), "truncated cell length"),
    ],
)
def test_malformed_batch_fails_closed(payload, reason):
    with pytest.raises(BatchDecodeError, match=reason):
        decode_batch(payload)


def test_truncated_cell_and_trailing_bytes_are_rejected():
    encoded = encode_batch(sequence=1, cells=[b"abc"])
    with pytest.raises(BatchDecodeError, match="truncated cell payload"):
        decode_batch(encoded[:-1])
    with pytest.raises(BatchDecodeError, match="trailing bytes"):
        decode_batch(encoded + b"x")


def test_declared_oversized_cell_is_rejected_before_allocation():
    payload = HEADER.pack(MAGIC, VERSION, 0, 0, 1, 1) + struct.pack(">I", 256 * 1024 + 1)
    with pytest.raises(BatchDecodeError, match="invalid cell length"):
        decode_batch(payload)
