import os

import pytest

from shared.transport.fixed_cell import (
    CELL_SIZES,
    FixedCellError,
    max_payload_bytes,
    open_fixed_cell,
    seal_fixed_cell,
    select_cell_size,
)


def test_real_and_dummy_cells_have_identical_external_size():
    key = os.urandom(32)
    real = seal_fixed_cell(payload=b"secret text", key=key, cell_size=4096)
    dummy = seal_fixed_cell(payload=None, key=key, cell_size=4096)
    assert len(real) == len(dummy) == 4096
    assert open_fixed_cell(cell=real, key=key).payload == b"secret text"
    assert open_fixed_cell(cell=dummy, key=key).is_dummy


def test_padding_and_nonce_make_equal_payload_cells_different():
    key = os.urandom(32)
    first = seal_fixed_cell(payload=b"same", key=key, cell_size=4096)
    second = seal_fixed_cell(payload=b"same", key=key, cell_size=4096)
    assert first != second


def test_tamper_and_wrong_key_fail_authentication():
    key = os.urandom(32)
    cell = bytearray(seal_fixed_cell(payload=b"opaque", key=key, cell_size=4096))
    cell[-1] ^= 1
    with pytest.raises(FixedCellError, match="authentication failed"):
        open_fixed_cell(cell=bytes(cell), key=key)
    with pytest.raises(FixedCellError, match="authentication failed"):
        open_fixed_cell(
            cell=seal_fixed_cell(payload=b"opaque", key=key, cell_size=4096),
            key=os.urandom(32),
        )


def test_smallest_fitting_size_class_is_selected():
    assert select_cell_size(max_payload_bytes(4096)) == 4096
    assert select_cell_size(max_payload_bytes(4096) + 1) == 16384
    assert tuple(sorted(CELL_SIZES)) == CELL_SIZES


def test_oversized_payload_is_rejected():
    with pytest.raises(ValueError, match="does not fit"):
        select_cell_size(max_payload_bytes(256 * 1024) + 1)
