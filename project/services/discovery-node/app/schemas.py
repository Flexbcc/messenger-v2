from pydantic import BaseModel, Field
from typing import Any, Dict, List, Optional


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


class BootstrapRecordPublishRequest(BaseModel):
    record: Dict[str, Any]


class BootstrapRecordResponse(BaseModel):
    record: Dict[str, Any]
    stored_at: str


class RouteDescriptorPublishRequest(BaseModel):
    descriptor: Dict[str, Any]


class RouteDescriptorPublishResponse(BaseModel):
    user_id: str
    route_epoch: int
    descriptor_hash: str
    accepted: bool


class RouteDescriptorListResponse(BaseModel):
    descriptors: List[Dict[str, Any]]


class TrustRecordPublishRequest(BaseModel):
    record: Dict[str, Any]


class TrustRecordPublishResponse(BaseModel):
    record_hash: str
    accepted: bool
    applied: bool


class TrustRecordProposalListResponse(BaseModel):
    proposals: List[Dict[str, Any]]
    action: str
    subject_node_id: str
    new_level: int


class TrustRecordGossipItem(BaseModel):
    sequence: int
    record_hash: str
    record: Dict[str, Any]


class TrustRecordGossipListResponse(BaseModel):
    records: List[TrustRecordGossipItem]
    head_sequence: int


class TrustRecordGossipResponse(TrustRecordPublishResponse):
    sequence: int


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
    operational_certificate: Optional[Dict[str, Any]] = None
    operational_credential_state: Optional[Dict[str, Any]] = None
    node_advertisement: Optional[Dict[str, Any]] = None
    capability_certificate: Optional[Dict[str, Any]] = None
    transport_certificate: Optional[Dict[str, Any]] = None


class HeartbeatRequest(BaseModel):
    software_version: Optional[str] = None
    build_hash: Optional[str] = None
    tls_cert_fingerprint: Optional[str] = None
    release_signature: Optional[str] = None
    signing_public_key: Optional[str] = None
    operational_certificate: Optional[Dict[str, Any]] = None
    operational_credential_state: Optional[Dict[str, Any]] = None
    node_advertisement: Optional[Dict[str, Any]] = None
    capability_certificate: Optional[Dict[str, Any]] = None
    transport_certificate: Optional[Dict[str, Any]] = None
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
    # Node Identity migration: legacy node_id stays the lookup key until every
    # node has a self-certifying identity_node_id.
    identity_node_id: Optional[str] = None
    node_identity_status: str = "absent"
    node_identity_detail: Optional[str] = None
    node_advertisement_status: str = "absent"
    node_advertisement_detail: Optional[str] = None
    node_advertisement_epoch: Optional[int] = None
    advertised_endpoints: List[str] = Field(default_factory=list)
    advertised_transports: List[str] = Field(default_factory=list)
    advertised_protocols: List[str] = Field(default_factory=list)
    # Existing `capabilities` remain self-advertised during report migration.
    certified_capabilities: List[str] = Field(default_factory=list)
    certified_quotas: Dict[str, int] = Field(default_factory=dict)
    certified_level: Optional[int] = None
    capability_certificate_status: str = "absent"
    capability_certificate_detail: Optional[str] = None
    capability_epoch: Optional[int] = None
    transport_certificate: Optional[Dict[str, Any]] = None
    transport_certificate_status: str = "absent"
    transport_certificate_detail: Optional[str] = None
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


class TrustObservationPublishRequest(BaseModel):
    observation: dict
    assignment_id: Optional[str] = None


class TrustObservationPublishResponse(BaseModel):
    observation_id: str
    accepted: bool


class TrustObservationPortablePublishRequest(BaseModel):
    observation: Dict[str, Any]
    assignment_id: str
    operational_certificate: Dict[str, Any]
    operational_credential_state: Optional[Dict[str, Any]] = None


class TrustObservationGossipItem(BaseModel):
    sequence: int
    assignment_id: str
    observation_hash: str
    observation: Dict[str, Any]
    operational_certificate: Dict[str, Any]


class TrustObservationGossipListResponse(BaseModel):
    observations: List[TrustObservationGossipItem]
    head_sequence: int


class TrustObservationGossipResponse(BaseModel):
    sequence: int
    assignment_id: str
    observation_id: str
    observation_hash: str
    accepted: bool


class TrustObservationListResponse(BaseModel):
    observations: List[dict]


class ChallengeAssignmentPublishRequest(BaseModel):
    assignment: Dict[str, Any]


class ChallengeAssignmentPublishResponse(BaseModel):
    assignment_id: str
    accepted: bool


class ChallengeAssignmentAckRequest(BaseModel):
    ack: Dict[str, Any]


class ChallengeAssignmentAckResponse(BaseModel):
    assignment_id: str
    state: str
    accepted: bool


class ChallengeAssignmentListResponse(BaseModel):
    assignments: List[Dict[str, Any]]


class ChallengeAssignmentProposalListResponse(BaseModel):
    proposals: List[Dict[str, Any]]


class ChallengeAssignmentPortablePullRequest(BaseModel):
    proof: Dict[str, Any]
    limit: int = Field(20, ge=1, le=100)
    operational_credential_state: Optional[Dict[str, Any]] = None


class ChallengeAssignmentPortableAckRequest(BaseModel):
    ack: Dict[str, Any]
    operational_certificate: Dict[str, Any]
    operational_credential_state: Optional[Dict[str, Any]] = None


class ChallengeAssignmentGossipItem(BaseModel):
    sequence: int
    assignment_hash: str
    assignment: Dict[str, Any]


class ChallengeAssignmentGossipListResponse(BaseModel):
    assignments: List[ChallengeAssignmentGossipItem]
    head_sequence: int


class ChallengeAssignmentGossipResponse(BaseModel):
    sequence: int
    assignment_id: str
    assignment_hash: str
    accepted: bool


class ChallengeAssignmentAckGossipItem(BaseModel):
    sequence: int
    ack_hash: str
    ack: Dict[str, Any]
    operational_certificate: Dict[str, Any]


class ChallengeAssignmentAckGossipListResponse(BaseModel):
    acknowledgements: List[ChallengeAssignmentAckGossipItem]
    head_sequence: int


class ChallengeAssignmentAckGossipResponse(BaseModel):
    sequence: int
    assignment_id: str
    observer_node_id: str
    state: str
    ack_hash: str
    accepted: bool


class RandomnessCheckpointPublishRequest(BaseModel):
    checkpoint: Dict[str, Any]


class RandomnessCheckpointResponse(BaseModel):
    challenge_epoch: int
    checkpoint_hash: str
    accepted: bool


class RandomnessCheckpointStored(BaseModel):
    checkpoint: Dict[str, Any]
    checkpoint_hash: str
    stored_at: str


class RandomnessCheckpointGossipListResponse(BaseModel):
    checkpoints: List[RandomnessCheckpointStored]
    head_epoch: int


class OperationalCredentialStatePublishRequest(BaseModel):
    state: Dict[str, Any]


class OperationalCredentialStateResponse(BaseModel):
    node_id: str
    credential_epoch: int
    state_hash: str
    accepted: bool


class OperationalCredentialStateStored(BaseModel):
    sequence: int
    state: Dict[str, Any]
    state_hash: str
    stored_at: str


class OperationalCredentialStateGossipListResponse(BaseModel):
    states: List[OperationalCredentialStateStored]
    head_sequence: int


class OperationalCredentialRevocationPublishRequest(BaseModel):
    revocation: Dict[str, Any]


class OperationalCredentialRevocationResponse(BaseModel):
    node_id: str
    revocation_epoch: int
    revocation_hash: str
    accepted: bool


class OperationalCredentialRevocationStored(BaseModel):
    sequence: int
    revocation: Dict[str, Any]
    revocation_hash: str
    stored_at: str


class OperationalCredentialRevocationGossipListResponse(BaseModel):
    revocations: List[OperationalCredentialRevocationStored]
    head_sequence: int


class AuthorityCheckpointPublishRequest(BaseModel):
    checkpoint: Dict[str, Any]


class AuthorityCheckpointPublishResponse(BaseModel):
    authority_epoch: int
    checkpoint_hash: str
    accepted: bool


class AuthorityCheckpointResponse(BaseModel):
    checkpoint: Dict[str, Any]
    checkpoint_hash: str
    stored_at: str


class AuthorityCheckpointGossipItem(AuthorityCheckpointResponse):
    announcement: Dict[str, Any]


class AuthorityCheckpointGossipListResponse(BaseModel):
    checkpoints: List[AuthorityCheckpointGossipItem]
    head: Optional[AuthorityCheckpointGossipItem] = None


class AuthorityCheckpointGossipRequest(BaseModel):
    checkpoint: Dict[str, Any]
    announcement: Dict[str, Any]


class AuthorityCheckpointGossipResponse(BaseModel):
    source_node_id: str
    authority_epoch: int
    checkpoint_hash: str
    checkpoint_accepted: bool
    announcement_accepted: bool


class NodeAdvertisementGossipItem(BaseModel):
    advertisement: Dict[str, Any]
    capability_certificate: Dict[str, Any]
    transport_certificate: Dict[str, Any]
    observation: Dict[str, Any]


class NodeAdvertisementGossipListResponse(BaseModel):
    observations: List[NodeAdvertisementGossipItem]


class NodeAdvertisementGossipResponse(BaseModel):
    source_node_id: str
    subject_node_id: str
    advertisement_epoch: int
    advertisement_hash: str
    accepted: bool


class NodeAdvertisementPeerViewResponse(BaseModel):
    candidates: List[Dict[str, Any]]
    conflicts: List[str]
    rejected_count: int
    trusted_source_count: int


class AuthorityRecoveryRequest(BaseModel):
    recovery: Dict[str, Any]


class AuthorityRecoveryResponse(BaseModel):
    recovery_hash: str
    replacement_checkpoint_hash: str
    authority_epoch: int
    accepted: bool
    governance_allowed: bool


class ReliabilitySnapshotResponse(BaseModel):
    subject_node_id: str
    subject_known: bool
    generated_at: str
    raw_observations: int
    trusted_observations: int
    effective_observations: int
    observer_count: int
    observer_diversity: str
    result_counts: Dict[str, int]
    latency_buckets: Dict[str, int]
    challenge_types: Dict[str, int]
    minimum_epoch: Optional[int] = None
    maximum_epoch: Optional[int] = None
    success_rate_bps: Optional[int] = None
    assigned_observer_slots: int
    completed_observer_slots: int
    expired_incomplete_observer_slots: int
    assignment_completion_bps: Optional[int] = None
    current_level: Optional[int] = None
    proposed_level: Optional[int] = None
    eligibility_missing: List[str] = Field(default_factory=list)
    evidence_commitment: str
    eligibility_policy: Dict[str, Any]
    evidence_decided_at: str
    promotion_decision: str


class TrustDegradationCandidateListResponse(BaseModel):
    candidates: List[Dict[str, Any]]


class TrustRecordVoteRequest(BaseModel):
    proposal: Dict[str, Any]
    validator_id: str = Field(..., min_length=1, max_length=256)
    signature: str = Field(..., min_length=88, max_length=88)


class TrustRecordVoteResponse(BaseModel):
    record_id: str
    validator_id: str
    votes: int
    threshold: int
    quorum_reached: bool
    accepted: bool
    ledger: Optional[Dict[str, Any]] = None
    record_commitment: Optional[str] = None


class TrustEligibilityCandidateListResponse(BaseModel):
    candidates: List[ReliabilitySnapshotResponse]


class SecurityReputationCandidateListResponse(BaseModel):
    candidates: List[Dict[str, Any]]


class SecurityEvidenceListResponse(BaseModel):
    evidence: List[Dict[str, Any]]


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
