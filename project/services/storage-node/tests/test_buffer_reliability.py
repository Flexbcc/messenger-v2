import base64
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from app import db
from app.routers import buffer
from app.schemas import (
    BufferRequest,
    OpaqueMailboxAckRequest,
    OpaqueMailboxFetchRequest,
    OpaqueMailboxStoreRequest,
)
from shared.security.mailbox_capability import generate_mailbox_token
from shared.transport.fixed_cell import seal_fixed_cell


@pytest.fixture
def storage_db(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "storage.db"))
    monkeypatch.setattr(buffer, "get_conn", db.get_conn)
    monkeypatch.setattr(buffer, "verify_incoming_federation", AsyncMock(return_value=None))
    security = MagicMock()
    security.trust_cache = MagicMock()
    security.nonce_store = MagicMock()
    security.audit_log = MagicMock()
    monkeypatch.setattr(buffer, "get_federation_security", lambda: security)
    db.init_db()
    return tmp_path / "storage.db"


def _request(packet_id="packet-1", ciphertext="opaque"):
    return BufferRequest(
        recipient_device_id="device-b",
        envelope={"packet_id": packet_id, "ciphertext": ciphertext},
        ttl_seconds=3600,
    )


@pytest.mark.asyncio
async def test_same_packet_is_buffered_idempotently(storage_db):
    first = await buffer.buffer_envelope(_request(), _verified="home-a")
    second = await buffer.buffer_envelope(_request(), _verified="home-a")
    assert second.id == first.id
    with db.get_conn() as conn:
        assert conn.execute("SELECT COUNT(*) FROM buffered_envelopes").fetchone()[0] == 1


@pytest.mark.asyncio
async def test_buffer_survives_database_reinitialization(storage_db):
    await buffer.buffer_envelope(_request(), _verified="home-a")
    db.init_db()
    result = await buffer.fetch_buffered("device-b", _verified="home-a")
    assert len(result.envelopes) == 1
    assert result.envelopes[0].envelope["packet_id"] == "packet-1"


@pytest.mark.asyncio
async def test_ack_removes_only_existing_entry(storage_db):
    entry = await buffer.buffer_envelope(_request(), _verified="home-a")
    await buffer.ack_delivered(entry.id, _verified="home-a")
    with pytest.raises(HTTPException) as exc:
        await buffer.ack_delivered(entry.id, _verified="home-a")
    assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_size_limit_counts_utf8_bytes(storage_db, monkeypatch):
    monkeypatch.setattr(buffer, "BUFFER_MAX_ENVELOPE_BYTES", 60)
    with pytest.raises(HTTPException) as exc:
        await buffer.buffer_envelope(_request(ciphertext="я" * 40), _verified="home-a")
    assert exc.value.status_code == 413


def test_ttl_is_bounded():
    with pytest.raises(ValidationError):
        BufferRequest(
            recipient_device_id="device-b",
            envelope={"packet_id": "p"},
            ttl_seconds=31 * 24 * 60 * 60,
        )


def _opaque_request(token=None, payload=b"opaque endpoint ciphertext"):
    cell = seal_fixed_cell(payload=payload, key=b"k" * 32, cell_size=4 * 1024)
    return OpaqueMailboxStoreRequest(
        mailbox_token=token or generate_mailbox_token(),
        cell_b64=base64.urlsafe_b64encode(cell).decode("ascii"),
        ttl_seconds=3600,
    )


@pytest.mark.asyncio
async def test_opaque_mailbox_stores_fixed_cell_idempotently(storage_db):
    request = _opaque_request()
    first = await buffer.store_opaque_mailbox_cell(request, _verified="home-a")
    second = await buffer.store_opaque_mailbox_cell(request, _verified="home-a")
    assert first.id == second.id
    assert first.cell_size == 4096
    fetched = await buffer.fetch_opaque_mailbox_cells(
        OpaqueMailboxFetchRequest(mailbox_token=request.mailbox_token),
        _verified="home-a",
    )
    assert len(fetched.cells) == 1
    assert fetched.cells[0].cell_b64 == request.cell_b64
    with db.get_conn() as conn:
        columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(opaque_mailbox_cells)").fetchall()
        }
        assert "recipient_device_id" not in columns
        assert "user_id" not in columns


@pytest.mark.asyncio
async def test_opaque_ack_requires_matching_mailbox_capability(storage_db):
    request = _opaque_request()
    stored = await buffer.store_opaque_mailbox_cell(request, _verified="home-a")
    with pytest.raises(HTTPException) as wrong:
        await buffer.ack_opaque_mailbox_cell(
            OpaqueMailboxAckRequest(
                mailbox_token=generate_mailbox_token(), entry_id=stored.id
            ),
            _verified="home-a",
        )
    assert wrong.value.status_code == 404
    await buffer.ack_opaque_mailbox_cell(
        OpaqueMailboxAckRequest(
            mailbox_token=request.mailbox_token, entry_id=stored.id
        ),
        _verified="home-a",
    )


@pytest.mark.asyncio
async def test_opaque_mailbox_rejects_non_fixed_cell(storage_db):
    request = OpaqueMailboxStoreRequest(
        mailbox_token=generate_mailbox_token(),
        cell_b64=base64.urlsafe_b64encode(b"not-fixed-size").decode("ascii"),
        ttl_seconds=3600,
    )
    with pytest.raises(HTTPException) as invalid:
        await buffer.store_opaque_mailbox_cell(request, _verified="home-a")
    assert invalid.value.status_code == 422


@pytest.mark.asyncio
async def test_opaque_mailbox_quota_is_bounded(storage_db, monkeypatch):
    token = generate_mailbox_token()
    monkeypatch.setattr(buffer, "BUFFER_MAX_ENTRIES_PER_RECIPIENT", 1)
    await buffer.store_opaque_mailbox_cell(
        _opaque_request(token, b"first"), _verified="home-a"
    )
    with pytest.raises(HTTPException) as full:
        await buffer.store_opaque_mailbox_cell(
            _opaque_request(token, b"second"), _verified="home-a"
        )
    assert full.value.status_code == 429


@pytest.mark.asyncio
async def test_opaque_mailbox_fetch_is_bounded_and_reports_more(storage_db):
    token = generate_mailbox_token()
    for index in range(3):
        await buffer.store_opaque_mailbox_cell(
            _opaque_request(token, f"cell-{index}".encode()), _verified="home-a"
        )
    page = await buffer.fetch_opaque_mailbox_cells(
        OpaqueMailboxFetchRequest(mailbox_token=token, limit=2),
        _verified="home-a",
    )
    assert len(page.cells) == 2
    assert page.has_more is True
