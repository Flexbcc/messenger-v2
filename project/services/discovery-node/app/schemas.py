from pydantic import BaseModel, Field
from typing import List, Optional


class RegisterUserRecord(BaseModel):
    user_id: str
    home_node_url: str
    display_name: Optional[str] = None
    auth_public_key: str  # base64 Ed25519 public key
    cluster_id: str = "default"
    login: Optional[str] = None
    username_search_enabled: bool = True


class UserRecordResponse(BaseModel):
    user_id: str
    home_node_url: str
    display_name: Optional[str] = None
    auth_public_key: str
    cluster_id: str = "default"
    login: Optional[str] = None
    username_search_enabled: bool = True
    updated_at: str
    # Post-R5: set when home_node_url actually changes, so peers/homes can
    # detect a move on the next live resolve (R4-routing.md gap, no full
    # notify/CONTROL yet — see 0203_ROUTING.md "Смена Home").
    previous_home_node_url: Optional[str] = None
    home_updated_at: Optional[str] = None
    # Signed user record (Фаза 2.1).
    # record_signature: Ed25519 sig over "user_id|home_node_url|updated_at"
    # discovery_public_key: base64url Ed25519 pubkey of this Discovery node
    record_signature: Optional[str] = None
    discovery_public_key: Optional[str] = None


class UserHomeRouteResponse(BaseModel):
    """Focused shape for clients/homes that only care about home-change detection."""
    user_id: str
    home_node_url: str
    previous_home_node_url: Optional[str] = None
    home_updated_at: Optional[str] = None
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
    # Runtime host metrics (collected by runtime_metrics.py on home-node)
    cpu_load_1m: Optional[float] = None
    cpu_cores: Optional[int] = None
    cpu_percent_est: Optional[int] = None
    ram_total_bytes: Optional[int] = None
    ram_used_bytes: Optional[int] = None
    ram_percent: Optional[int] = None
    disk_used_bytes: Optional[int] = None
    disk_total_bytes: Optional[int] = None
    disk_percent: Optional[int] = None
    uptime_sec: Optional[int] = None
    ws_connections: Optional[int] = None
    # Rolling 24h counters
    messages_24h: Optional[int] = None
    calls_24h: Optional[int] = None
    error_rate_pct: Optional[float] = None
    messages_total: Optional[int] = None


class NodeMetrics(BaseModel):
    """Runtime metrics snapshot — included in NodeCapabilityResponse."""
    cpu_load_1m: Optional[float] = None
    cpu_cores: Optional[int] = None
    cpu_percent_est: Optional[int] = None
    ram_total_bytes: Optional[int] = None
    ram_used_bytes: Optional[int] = None
    ram_percent: Optional[int] = None
    disk_used_bytes: Optional[int] = None
    disk_total_bytes: Optional[int] = None
    disk_percent: Optional[int] = None
    uptime_sec: Optional[int] = None
    ws_connections: Optional[int] = None
    messages_24h: Optional[int] = None
    calls_24h: Optional[int] = None
    error_rate_pct: Optional[float] = None
    messages_total: Optional[int] = None
    latency_ms: Optional[int] = None


class TrustLevelHistoryEntry(BaseModel):
    from_level: int
    to_level: int
    reason: Optional[str] = None
    actor: str
    changed_at: str


class PromoteCandidateResponse(BaseModel):
    node_id: str
    trust_level: int
    trust_status: str
    messages_total: Optional[int] = None
    messages_24h: Optional[int] = None
    uptime_sec: Optional[int] = None
    error_rate_pct: Optional[float] = None
    meets_threshold: bool
    missing: List[str]


class MeshPeerEntry(BaseModel):
    """Компактная запись о peer-ноде — включается в heartbeat-ответ (Фаза 3.3).
    Позволяет нодам поддерживать актуальный список peers без отдельного запроса к Discovery."""
    node_id: str
    node_url: str
    capabilities: List[str]
    cluster_id: str = "default"
    trust_level: int = 0


class NodeCapabilityResponse(BaseModel):
    node_id: str
    node_url: str
    capabilities: List[str]
    software_version: str
    cluster_id: str = "default"
    trust_status: str = "trusted"
    trust_level: int = 0
    reachability: str = "online"
    last_heartbeat: str
    # Backward compatibility: same as reachability (online/offline).
    status: str = Field(description="Alias for reachability — kept for federation.py and clients")
    build_hash: Optional[str] = None
    tls_cert_fingerprint: Optional[str] = None
    attestation_status: str = "skipped"
    attestation_detail: Optional[str] = None
    signing_public_key: Optional[str] = None
    # Active health-check (may be None until first probe)
    health_status: Optional[str] = None
    last_health_check: Optional[str] = None
    # Vulnerability response
    version_status: str = "ok"
    quarantine_action: str = "off"
    # Runtime metrics (None until first heartbeat with metrics)
    metrics: Optional[NodeMetrics] = None
    # Mesh peer-список (Фаза 3.3): trusted+online ноды, кроме самой себя.
    # None в ответах на регистрацию/GET-запросы; заполняется только в heartbeat.
    peers: Optional[List[MeshPeerEntry]] = None


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


class AdminAuditEntry(BaseModel):
    id: int
    created_at: str
    actor: str
    action: str
    node_id: str
    cluster_id: Optional[str] = None
    detail: Optional[str] = None


class AdminAuditListResponse(BaseModel):
    entries: list[AdminAuditEntry]
    count: int


class SuspendNodeRequest(BaseModel):
    reason: Optional[str] = None


class ReEnrollResponse(AdminActionResponse):
    """Re-enroll always issues a fresh enrollment_secret (shown once), like a
    brand-new strict registration — the recovered node (or its operator) needs
    it to complete POST /registry/enrollment/status again."""
    enrollment_secret: Optional[str] = None


# --- Vulnerability response ------------------------------------------------

class BlockedVersion(BaseModel):
    version: str
    reason: Optional[str] = None
    blocked_at: str


class BlockVersionRequest(BaseModel):
    version: str
    reason: Optional[str] = None


class BlockedVersionListResponse(BaseModel):
    blocked_versions: List[BlockedVersion]


class QuarantineModeRequest(BaseModel):
    mode: str  # off | warn | isolate


class ForceUpgradeRequest(BaseModel):
    force_upgrade: bool


class VulnerabilityPolicyResponse(BaseModel):
    quarantine_mode: str
    force_upgrade: bool
    blocked_versions: List[BlockedVersion]


# --- Health-check ----------------------------------------------------------

class HealthCheckResult(BaseModel):
    node_id: str
    reachability: str
    health_status: str
    last_health_check: str


class HealthCheckRunResponse(BaseModel):
    checked: int
    results: List[HealthCheckResult]
