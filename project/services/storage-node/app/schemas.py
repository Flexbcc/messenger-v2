from pydantic import BaseModel, Field
from typing import List, Optional


class BufferRequest(BaseModel):
    recipient_device_id: str = Field(min_length=1, max_length=256)
    envelope: dict  # opaque Message Envelope, see shared/README.md
    ttl_seconds: int = Field(default=60 * 60 * 24 * 30, ge=60, le=60 * 60 * 24 * 30)
    federation: Optional[dict] = None


class BufferedEnvelopeResponse(BaseModel):
    id: str
    recipient_device_id: str
    envelope: dict
    created_at: str
    expires_at: str


class BufferedEnvelopeListResponse(BaseModel):
    envelopes: List[BufferedEnvelopeResponse]


class OpaqueMailboxStoreRequest(BaseModel):
    mailbox_token: str = Field(min_length=43, max_length=43)
    cell_b64: str = Field(min_length=1, max_length=350_000)
    ttl_seconds: int = Field(default=60 * 60 * 24 * 7, ge=60, le=60 * 60 * 24 * 30)


class OpaqueMailboxFetchRequest(BaseModel):
    mailbox_token: str = Field(min_length=43, max_length=43)
    limit: int = Field(default=8, ge=1, le=32)
    padded: bool = False
    cell_size: Optional[int] = None


class OpaqueMailboxAckRequest(BaseModel):
    mailbox_token: str = Field(min_length=43, max_length=43)
    entry_id: str = Field(min_length=36, max_length=36)


class OpaqueMailboxCellResponse(BaseModel):
    id: str
    cell_b64: str
    cell_size: int
    created_at: str
    expires_at: str


class OpaqueMailboxCellListResponse(BaseModel):
    cells: List[OpaqueMailboxCellResponse]
    has_more: bool = False
