from pydantic import BaseModel
from typing import List, Optional


class BufferRequest(BaseModel):
    recipient_device_id: str
    envelope: dict  # opaque Message Envelope, see shared/README.md
    ttl_seconds: int = 60 * 60 * 24 * 30  # 30 days default retention
    federation: Optional[dict] = None


class BufferedEnvelopeResponse(BaseModel):
    id: str
    recipient_device_id: str
    envelope: dict
    created_at: str
    expires_at: str


class BufferedEnvelopeListResponse(BaseModel):
    envelopes: List[BufferedEnvelopeResponse]
