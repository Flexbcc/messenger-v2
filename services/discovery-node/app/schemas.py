from pydantic import BaseModel, Field
from typing import List, Optional


class RegisterUserRecord(BaseModel):
    user_id: str
    home_node_url: str
    display_name: Optional[str] = None
    auth_public_key: str  # base64 Ed25519 public key
    cluster_id: str = "default"


class UserRecordResponse(BaseModel):
    user_id: str
    home_node_url: str
    display_name: Optional[str] = None
    auth_public_key: str
    cluster_id: str = "default"
    updated_at: str


class RegisterNodeCapability(BaseModel):
    node_id: str
    node_url: str
    capabilities: List[str]  # e.g. ["relay"], ["storage"], ["media"], ["gateway"]
    software_version: str = "unknown"
    cluster_id: str = "default"
    build_hash: Optional[str] = None
    tls_cert_fingerprint: Optional[str] = None
    release_signature: Optional[str] = None
    signing_public_key: Optional[str] = None


class HeartbeatRequest(BaseModel):
    software_version: Optional[str] = None
    build_hash: Optional[str] = None
    tls_cert_fingerprint: Optional[str] = None
    release_signature: Optional[str] = None
    signing_public_key: Optional[str] = None


class NodeCapabilityResponse(BaseModel):
    node_id: str
    node_url: str
    capabilities: List[str]
    software_version: str
    cluster_id: str = "default"
    trust_status: str = "trusted"
    reachability: str = "online"
    last_heartbeat: str
    # Backward compatibility: same as reachability (online/offline).
    status: str = Field(description="Alias for reachability — kept for federation.py and clients")
    build_hash: Optional[str] = None
    tls_cert_fingerprint: Optional[str] = None
    attestation_status: str = "skipped"
    attestation_detail: Optional[str] = None
    signing_public_key: Optional[str] = None


class NodeCapabilityListResponse(BaseModel):
    nodes: List[NodeCapabilityResponse]


class RegisterNodeResponse(NodeCapabilityResponse):
    """Registration may include a one-time enrollment_secret when trust_status=pending."""
    enrollment_secret: Optional[str] = None


class EnrollmentStatusRequest(BaseModel):
    node_id: str
    enrollment_secret: str


class EnrollmentStatusResponse(BaseModel):
    node_id: str
    trust_status: str
    node_token: Optional[str] = None
    message: Optional[str] = None


class AdminActionResponse(BaseModel):
    node_id: str
    trust_status: str
    message: str


class SuspendNodeRequest(BaseModel):
    reason: Optional[str] = None
