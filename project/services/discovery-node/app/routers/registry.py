from datetime import datetime, timezone
from typing import Optional
from fastapi import APIRouter, HTTPException, Header, Query
import json

from app.config import (
    CAPABILITY_AUTHORITY_STATE_PATH,
    CAPABILITY_CERTIFICATE_MODE,
    ENROLLMENT_MODE,
    NODE_ADVERTISEMENT_MODE,
    NODE_IDENTITY_MODE,
    OPERATIONAL_CREDENTIAL_STATE_MODE,
    TRUST_AUTHORITY_STATE_PATH,
    TRANSPORT_CERTIFICATE_MODE,
)
from app.db import get_conn
from app.schemas import (
    RegisterUserRecord,
    BootstrapRecordPublishRequest,
    BootstrapRecordResponse,
    RouteDescriptorPublishRequest,
    RouteDescriptorPublishResponse,
    RouteDescriptorListResponse,
    TrustRecordPublishRequest,
    TrustRecordPublishResponse,
    TrustRecordProposalListResponse,
    TrustRecordVoteRequest,
    TrustRecordVoteResponse,
    TrustRecordGossipItem,
    TrustRecordGossipListResponse,
    TrustRecordGossipResponse,
    TrustObservationPublishRequest,
    TrustObservationPublishResponse,
    TrustObservationListResponse,
    TrustObservationPortablePublishRequest,
    TrustObservationGossipItem,
    TrustObservationGossipListResponse,
    TrustObservationGossipResponse,
    ChallengeAssignmentPublishRequest,
    ChallengeAssignmentPublishResponse,
    ChallengeAssignmentAckRequest,
    ChallengeAssignmentAckResponse,
    ChallengeAssignmentListResponse,
    ChallengeAssignmentProposalListResponse,
    ChallengeAssignmentPortablePullRequest,
    ChallengeAssignmentPortableAckRequest,
    ChallengeAssignmentGossipItem,
    ChallengeAssignmentGossipListResponse,
    ChallengeAssignmentGossipResponse,
    ChallengeAssignmentAckGossipItem,
    ChallengeAssignmentAckGossipListResponse,
    ChallengeAssignmentAckGossipResponse,
    RandomnessCheckpointPublishRequest,
    RandomnessCheckpointResponse,
    RandomnessCheckpointGossipListResponse,
    RandomnessCheckpointStored,
    OperationalCredentialStatePublishRequest,
    OperationalCredentialStateResponse,
    OperationalCredentialStateStored,
    OperationalCredentialStateGossipListResponse,
    OperationalCredentialRevocationPublishRequest,
    OperationalCredentialRevocationResponse,
    OperationalCredentialRevocationStored,
    OperationalCredentialRevocationGossipListResponse,
    AuthorityCheckpointPublishRequest,
    AuthorityCheckpointPublishResponse,
    AuthorityCheckpointResponse,
    AuthorityCheckpointGossipListResponse,
    AuthorityCheckpointGossipRequest,
    AuthorityCheckpointGossipResponse,
    NodeAdvertisementGossipItem,
    NodeAdvertisementGossipListResponse,
    NodeAdvertisementGossipResponse,
    NodeAdvertisementPeerViewResponse,
    ReliabilitySnapshotResponse,
    TrustDegradationCandidateListResponse,
    TrustEligibilityCandidateListResponse,
    SecurityReputationCandidateListResponse,
    SecurityEvidenceListResponse,
    UserRecordResponse,
    UserHomeRouteResponse,
    RegisterNodeCapability,
    HeartbeatRequest,
    MeshPeerEntry,
    NodeCapabilityResponse,
    NodeCapabilityListResponse,
    NodeMetrics,
    RegisterNodeResponse,
)
from app.security import generate_enrollment_secret, hash_value, verify_hash
from app.attestation_flow import apply_attestation
from app.trust import enrollment_required, initial_trust_status_for_register, now_iso, reachability_for
from app.policy import blocked_version_set, get_quarantine_mode, evaluate_version
from app.mesh_notify import schedule_mesh_peer_notify, should_notify_on_register
from app.network_guard import get_network_view_guard, require_governance_available
from app.trust_observation_store import publish_observation, list_observations
from app.security_reputation import security_evidence, security_reputation_candidates
from app.trust_record_proposals import (
    generate_trust_record_proposals,
    list_trust_record_proposals,
)
from app.trust_record_votes import submit_trust_record_vote
from app.trust_observation_gossip import (
    build_observation_gossip,
    ingest_observation_gossip,
)
from app.challenge_assignment_store import (
    AssignmentConflict,
    acknowledge_assignment,
    publish_assignment,
    pull_assignments,
    pull_assignments_with_proof,
)
from app.challenge_proposal_scheduler import list_challenge_proposals
from app.authority_checkpoint_store import (
    AuthorityCheckpointConflict,
    latest_checkpoint,
    load_effective_authority_state,
    load_authority_state_at_epoch,
    publish_authority_checkpoint,
)
from app.node_identity import discovery_node_identity
from app.authority_gossip import build_gossip_head, build_gossip_items, ingest_gossip_item
from app.node_advertisement_gossip import (
    AdvertisementObservationConflict,
    CapabilityCertificateConflict,
    build_local_gossip_items,
    build_peer_view,
    ingest_advertisement_gossip,
    list_stored_observations,
)
from app.trust_reputation import reliability_snapshot
from app.trust_degradation import list_degradation_candidates
from app.trust_record_service import ingest_trust_record, reconcile_registered_subject
from app.trust_admission import require_node_trust_active
from app.trust_record_gossip import (
    build_trust_record_gossip,
    ingest_trust_record_gossip,
)
from app.challenge_assignment_gossip import (
    build_assignment_gossip,
    ingest_assignment_gossip,
)
from app.challenge_assignment_ack_gossip import (
    build_ack_gossip,
    ingest_ack_gossip,
)
from app.randomness_checkpoint_store import (
    RandomnessCheckpointConflict,
    publish_randomness_checkpoint,
)
from app.randomness_checkpoint_gossip import (
    build_randomness_gossip,
    ingest_randomness_gossip,
)
from app.operational_credential_store import (
    OperationalCredentialConflict,
    OperationalCredentialRollback,
    publish_operational_credential_state,
)
from app.operational_credential_gossip import (
    build_operational_credential_gossip,
    ingest_operational_credential_gossip,
)
from app.operational_credential_revocation_store import (
    OperationalCredentialRevocationConflict,
    OperationalCredentialRevocationRollback,
    publish_operational_credential_revocation,
    require_operational_credential_not_revoked,
)
from app.operational_credential_revocation_gossip import (
    build_operational_credential_revocation_gossip,
    ingest_operational_credential_revocation_gossip,
)
from shared.security.operational_credential_state import (
    validate_operational_credential_state,
)
from app.route_descriptor_store import (
    RouteDescriptorConflict,
    RouteDescriptorIdentityUnavailable,
    list_route_descriptors,
    publish_route_descriptor,
)
from app.record_signer import sign_user_record, discovery_public_key_b64
from shared.security.node_identity_enrollment import evaluate_node_identity_report
from shared.security.node_advertisement_enrollment import evaluate_node_advertisement_report
from app.bootstrap_record_store import (
    BootstrapRecordConflict,
    publish_bootstrap_record as store_bootstrap_record,
)
from app.rendezvous_gossip import local_rendezvous_page
from shared.security.capability_enrollment import (
    evaluate_capability_report,
    load_capability_authority_state,
)
from shared.security.transport_certificate import validate_transport_certificate

router = APIRouter()

INFRASTRUCTURE_CAPABILITIES = frozenset(
    {"relay", "storage", "discovery", "gateway", "turn", "media", "validator"}
)


def _cluster_from_row(row) -> str:
    try:
        return row["cluster_id"] or "default"
    except (KeyError, IndexError):
        return "default"


def _trust_from_row(row) -> str:
    try:
        return row["trust_status"] or "unknown"
    except (KeyError, IndexError):
        return "unknown"


def _cluster_id_from_row(row) -> str:
    try:
        return row["cluster_id"] or "default"
    except (KeyError, IndexError):
        return "default"


def _attestation_from_row(row) -> dict:
    try:
        return {
            "build_hash": row["build_hash"],
            "tls_cert_fingerprint": row["tls_cert_fingerprint"],
            "attestation_status": row["attestation_status"] or "skipped",
            "attestation_detail": row["attestation_detail"],
            "signing_public_key": row["signing_public_key"],
        }
    except (KeyError, IndexError):
        return {
            "build_hash": None,
            "tls_cert_fingerprint": None,
            "attestation_status": "skipped",
            "attestation_detail": None,
            "signing_public_key": None,
        }


def _row_field(row, name, default=None):
    try:
        val = row[name]
        return val if val is not None else default
    except (KeyError, IndexError):
        return default


def _identity_from_row(row) -> dict:
    return {
        "identity_node_id": _row_field(row, "identity_node_id"),
        "node_identity_status": _row_field(row, "node_identity_status", "absent"),
        "node_identity_detail": _row_field(row, "node_identity_detail"),
    }


def _json_list_from_row(row, name) -> list[str]:
    raw = _row_field(row, name)
    try:
        value = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def _advertisement_from_row(row) -> dict:
    return {
        "node_advertisement_status": _row_field(
            row, "node_advertisement_status", "absent"
        ),
        "node_advertisement_detail": _row_field(row, "node_advertisement_detail"),
        "node_advertisement_epoch": _row_field(row, "node_advertisement_epoch"),
        "advertised_endpoints": _json_list_from_row(row, "advertised_endpoints"),
        "advertised_transports": _json_list_from_row(row, "advertised_transports"),
        "advertised_protocols": _json_list_from_row(row, "advertised_protocols"),
    }


def _capability_from_row(row) -> dict:
    raw = _row_field(row, "certified_capabilities")
    try:
        certified = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        certified = []
    quotas = {}
    if _row_field(row, "capability_certificate_status", "absent") == "valid":
        certificate_raw = _row_field(row, "capability_certificate")
        try:
            certificate = json.loads(certificate_raw) if certificate_raw else {}
            candidate_quotas = certificate.get("quotas", {})
            if isinstance(candidate_quotas, dict):
                quotas = candidate_quotas
        except (TypeError, ValueError):
            quotas = {}
    return {
        "certified_capabilities": certified,
        "certified_quotas": quotas,
        "certified_level": _row_field(row, "certified_level"),
        "capability_certificate_status": _row_field(
            row, "capability_certificate_status", "absent"
        ),
        "capability_certificate_detail": _row_field(row, "capability_certificate_detail"),
        "capability_epoch": _row_field(row, "capability_epoch"),
    }


def _transport_from_row(row) -> dict:
    raw = _row_field(row, "transport_certificate")
    certificate = None
    if raw:
        try:
            candidate = json.loads(raw)
            certificate = candidate if isinstance(candidate, dict) else None
        except (TypeError, ValueError):
            certificate = None
    return {
        "transport_certificate": certificate,
        "transport_certificate_status": _row_field(
            row, "transport_certificate_status", "absent"
        ),
        "transport_certificate_detail": _row_field(
            row, "transport_certificate_detail"
        ),
    }


def _evaluate_transport_certificate(certificate, *, identity_node_id: str | None):
    if certificate is None:
        return "absent", "transport certificate not supplied", None
    if TRANSPORT_CERTIFICATE_MODE == "off":
        return "ignored", "transport certificate validation disabled", None
    validation = validate_transport_certificate(
        certificate,
        now=datetime.now(timezone.utc),
        expected_node_id=identity_node_id,
    )
    if not validation.valid:
        return "invalid", validation.reason, None
    return "valid", None, json.dumps(
        certificate, sort_keys=True, separators=(",", ":")
    )


def _metrics_from_row(row) -> Optional[NodeMetrics]:
    """Extract runtime metrics from a DB row; returns None if no metrics yet."""
    fields = (
        "cpu_load_1m", "cpu_cores", "cpu_percent_est",
        "ram_total_bytes", "ram_used_bytes", "ram_percent",
        "disk_used_bytes", "disk_total_bytes", "disk_percent",
        "uptime_sec", "ws_connections",
        "messages_24h", "calls_24h", "error_rate_pct",
        "messages_total", "latency_ms",
    )
    data = {f: _row_field(row, f) for f in fields}
    if all(v is None for v in data.values()):
        return None
    return NodeMetrics(**data)


def _build_peer_list(exclude_node_id: str) -> list[MeshPeerEntry]:
    """Возвращает компактный список trusted+online нод (кроме самой себя) для
    включения в heartbeat-ответ. Ноды используют его для обновления mesh-кэша
    без отдельного запроса к Discovery (Фаза 3.3)."""
    from app.config import OFFLINE_THRESHOLD_SECONDS
    from datetime import datetime, timedelta, timezone

    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=OFFLINE_THRESHOLD_SECONDS)).isoformat()
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT * FROM node_capabilities
               WHERE trust_status = 'trusted'
                 AND last_heartbeat >= ?
                 AND node_id != ?""",
            (cutoff, exclude_node_id),
        ).fetchall()

    peers = []
    for r in rows:
        if NODE_ADVERTISEMENT_MODE == "enforce" and not _row_has_current_advertisement(r):
            continue
        if CAPABILITY_CERTIFICATE_MODE == "enforce" and not _row_has_current_capability(r):
            continue
        try:
            caps = json.loads(r["capabilities"]) if r["capabilities"] else []
        except (ValueError, TypeError):
            caps = []
        peers.append(MeshPeerEntry(
            node_id=r["node_id"],
            node_url=r["node_url"],
            capabilities=caps,
            cluster_id=r["cluster_id"] or "default",
            trust_level=r["trust_level"] or 0,
        ))
    return peers


def _row_has_current_advertisement(row) -> bool:
    raw = _row_field(row, "node_advertisement")
    if not raw:
        return False
    try:
        advertisement = json.loads(raw)
    except (TypeError, ValueError):
        return False
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=datetime.now(timezone.utc),
        identity_node_id=_row_field(row, "identity_node_id"),
        advertised_node_url=_row_field(row, "node_url", ""),
        minimum_epoch=_row_field(row, "node_advertisement_epoch", 0),
        existing_advertisement_json=raw,
    )
    return report.status == "valid"


def _row_has_current_capability(row) -> bool:
    try:
        requested = set(json.loads(_row_field(row, "capabilities", "[]")))
    except (TypeError, ValueError):
        return False
    requested_infrastructure = requested & INFRASTRUCTURE_CAPABILITIES
    if not requested_infrastructure:
        return True
    raw = _row_field(row, "capability_certificate")
    if not raw:
        return False
    try:
        certificate = json.loads(raw)
        authority_state = load_effective_authority_state(
            CAPABILITY_AUTHORITY_STATE_PATH,
            bootstrap_state=load_capability_authority_state(
                CAPABILITY_AUTHORITY_STATE_PATH
            ),
        )
    except (TypeError, ValueError):
        return False
    report = evaluate_capability_report(
        certificate,
        mode="report",
        now=datetime.now(timezone.utc),
        identity_node_id=_row_field(row, "identity_node_id"),
        authority_state=authority_state,
        minimum_epoch=_row_field(row, "capability_epoch", 0),
        existing_certificate_json=raw,
    )
    return report.status == "valid" and requested_infrastructure.issubset(
        set(report.certified_capabilities)
    )


def _node_response(row, *, last_heartbeat: str) -> NodeCapabilityResponse:
    reachability = reachability_for(last_heartbeat)
    trust_status = _trust_from_row(row)
    att = _attestation_from_row(row)
    return NodeCapabilityResponse(
        node_id=row["node_id"],
        node_url=row["node_url"],
        capabilities=json.loads(row["capabilities"]),
        software_version=row["software_version"],
        cluster_id=_cluster_id_from_row(row),
        trust_status=trust_status,
        trust_level=_row_field(row, "trust_level", 0),
        reachability=reachability,
        last_heartbeat=last_heartbeat,
        status=reachability,
        health_status=_row_field(row, "health_status"),
        last_health_check=_row_field(row, "last_health_check"),
        version_status=_row_field(row, "version_status", "ok"),
        quarantine_action=_row_field(row, "quarantine_action", "off"),
        metrics=_metrics_from_row(row),
        **att,
        **_identity_from_row(row),
        **_advertisement_from_row(row),
        **_capability_from_row(row),
        **_transport_from_row(row),
    )


def _register_response(row, *, last_heartbeat: str, enrollment_secret: Optional[str] = None) -> RegisterNodeResponse:
    base = _node_response(row, last_heartbeat=last_heartbeat)
    return RegisterNodeResponse(**base.model_dump(), enrollment_secret=enrollment_secret)


def _apply_version_policy(conn, node_id: str, software_version: str) -> None:
    """Recompute version_status/quarantine_action for a node against blocked_versions."""
    version_status, quarantine_action = evaluate_version(
        software_version, blocked_version_set(), get_quarantine_mode()
    )
    conn.execute(
        "UPDATE node_capabilities SET version_status = ?, quarantine_action = ? WHERE node_id = ?",
        (version_status, quarantine_action, node_id),
    )


def _sign_user_response(data: dict) -> dict:
    """Attach Ed25519 signature and discovery public key to a user record dict."""
    try:
        data["record_signature"] = sign_user_record(
            data["user_id"],
            data["home_node_url"],
            data["updated_at"],
        )
        data["discovery_public_key"] = discovery_public_key_b64()
    except Exception:
        # Signing is best-effort: fail open so resolve still works if key is
        # temporarily unavailable. Home-node will treat missing sig as unverified.
        data.setdefault("record_signature", None)
        data.setdefault("discovery_public_key", None)
    return data


def _bearer_token(authorization: Optional[str]) -> Optional[str]:
    if not authorization:
        return None
    parts = authorization.split(None, 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    return None


@router.post("/registry/users", response_model=UserRecordResponse)
def register_user(payload: RegisterUserRecord):
    now = now_iso()
    with get_conn() as conn:
        # home_updated_at/previous_home_node_url only move when home_node_url
        # actually changes — first upsert counts as a change too (home_updated_at
        # gets set, previous_home_node_url stays NULL since there was none).
        conn.execute(
            """
            INSERT INTO user_records (
                user_id, home_node_url, display_name, auth_public_key, cluster_id,
                login, username_search_enabled, updated_at, home_updated_at, previous_home_node_url
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(user_id) DO UPDATE SET
                home_node_url=excluded.home_node_url,
                display_name=excluded.display_name,
                auth_public_key=excluded.auth_public_key,
                cluster_id=excluded.cluster_id,
                login=COALESCE(excluded.login, user_records.login),
                username_search_enabled=excluded.username_search_enabled,
                updated_at=excluded.updated_at,
                previous_home_node_url=CASE
                    WHEN user_records.home_node_url != excluded.home_node_url
                    THEN user_records.home_node_url
                    ELSE user_records.previous_home_node_url
                END,
                home_updated_at=CASE
                    WHEN user_records.home_node_url != excluded.home_node_url
                    THEN excluded.updated_at
                    ELSE user_records.home_updated_at
                END
            """,
            (
                payload.user_id,
                payload.home_node_url,
                payload.display_name,
                payload.auth_public_key,
                payload.cluster_id,
                payload.login,
                1 if payload.username_search_enabled else 0,
                now,
                now,
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM user_records WHERE user_id = ?", (payload.user_id,)
        ).fetchone()
    data = dict(row)
    data.setdefault("cluster_id", "default")
    return UserRecordResponse(**_sign_user_response(data))


@router.get("/registry/users/search", response_model=UserRecordResponse)
def search_user_by_login(login: str = Query(..., min_length=3)):
    normalized = login.strip().lstrip('@').lower()
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM user_records WHERE LOWER(login) = ? LIMIT 1",
            (normalized,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    data = dict(row)
    data.setdefault("cluster_id", "default")
    if not data.get("username_search_enabled", 1):
        raise HTTPException(status_code=403, detail="Username search disabled for this user")
    if not data.get("login"):
        raise HTTPException(status_code=404, detail="User not found")
    return UserRecordResponse(**_sign_user_response(data))


@router.get("/registry/users/{user_id}", response_model=UserRecordResponse)
def resolve_user(user_id: str):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM user_records WHERE user_id = ?", (user_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Unknown user_id")
    data = dict(row)
    data.setdefault("cluster_id", "default")
    return UserRecordResponse(**_sign_user_response(data))


@router.get("/registry/users/{user_id}/home-route", response_model=UserHomeRouteResponse)
def resolve_user_home_route(user_id: str):
    """Minimal Post-R5 "home changed" signal — lets a client/home detect a
    Home move without a full CONTROL notify (see R4-routing.md Gaps)."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM user_records WHERE user_id = ?", (user_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Unknown user_id")
    return UserHomeRouteResponse(**dict(row))


@router.post("/registry/bootstrap-records", response_model=BootstrapRecordResponse)
def publish_bootstrap_record(payload: BootstrapRecordPublishRequest):
    """Persist a user-signed record without re-signing or becoming authority."""
    try:
        result = store_bootstrap_record(payload.record)
    except BootstrapRecordConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return BootstrapRecordResponse(
        record=result["record"], stored_at=result["stored_at"]
    )


@router.get(
    "/registry/rendezvous/gossip",
)
def get_rendezvous_gossip(
    after_user_id: str = Query("", max_length=256),
    after_route_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return local_rendezvous_page(
        after_user_id=after_user_id,
        after_route_sequence=after_route_sequence,
        limit=limit,
    )


@router.get(
    "/registry/bootstrap-records/{user_id}", response_model=BootstrapRecordResponse
)
def resolve_bootstrap_record(user_id: str):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT record_json, stored_at FROM bootstrap_records WHERE user_id = ?",
            (user_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Unknown BootstrapRecord")
    return BootstrapRecordResponse(record=json.loads(row["record_json"]), stored_at=row["stored_at"])


@router.post(
    "/registry/route-descriptors",
    response_model=RouteDescriptorPublishResponse,
)
def publish_route_descriptor_record(payload: RouteDescriptorPublishRequest):
    """Cache an endpoint-signed route without becoming its route authority."""
    try:
        result = publish_route_descriptor(payload.descriptor)
    except RouteDescriptorIdentityUnavailable as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except RouteDescriptorConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return RouteDescriptorPublishResponse(**result)


@router.get(
    "/registry/route-descriptors/{user_id}",
    response_model=RouteDescriptorListResponse,
)
def resolve_route_descriptors(user_id: str):
    descriptors = list_route_descriptors(user_id)
    if not descriptors:
        raise HTTPException(status_code=404, detail="RouteDescriptor is unavailable")
    return RouteDescriptorListResponse(descriptors=descriptors)


@router.post("/registry/trust-records", response_model=TrustRecordPublishResponse)
def publish_trust_record(payload: TrustRecordPublishRequest):
    """Validate/store a quorum decision; mutate legacy state only in enforce mode."""
    return TrustRecordPublishResponse(**ingest_trust_record(payload.record))


@router.get(
    "/registry/trust-record-proposals",
    response_model=TrustRecordProposalListResponse,
)
def get_trust_record_proposals(limit: int = Query(100, ge=1, le=1000)):
    """Unsigned evidence-bound transitions for independent validator signing."""
    require_governance_available()
    generate_trust_record_proposals()
    return TrustRecordProposalListResponse(
        proposals=list_trust_record_proposals(limit=limit)
    )


@router.post(
    "/registry/trust-record-proposal-votes",
    response_model=TrustRecordVoteResponse,
)
def publish_trust_record_vote(payload: TrustRecordVoteRequest):
    """Collect one validator signature; publish only after exact quorum."""
    return TrustRecordVoteResponse(
        **submit_trust_record_vote(
            proposal=payload.proposal,
            validator_id=payload.validator_id,
            signature=payload.signature,
        )
    )


@router.get(
    "/registry/trust-records/gossip",
    response_model=TrustRecordGossipListResponse,
)
def get_trust_record_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return TrustRecordGossipListResponse(
        **build_trust_record_gossip(
            after_sequence=after_sequence,
            limit=limit,
        )
    )


@router.post(
    "/registry/trust-records/gossip",
    response_model=TrustRecordGossipResponse,
)
def publish_trust_record_gossip(payload: TrustRecordGossipItem):
    return TrustRecordGossipResponse(
        **ingest_trust_record_gossip(payload.model_dump())
    )


@router.get(
    "/registry/trust-degradation-candidates",
    response_model=TrustDegradationCandidateListResponse,
)
def get_trust_degradation_candidates(limit: int = Query(100, ge=1, le=1000)):
    """Reliability evidence only; this endpoint never changes a node level."""
    return TrustDegradationCandidateListResponse(
        candidates=list_degradation_candidates(limit=limit)
    )


@router.get(
    "/registry/trust-eligibility-candidates",
    response_model=TrustEligibilityCandidateListResponse,
)
def get_trust_eligibility_candidates(
    eligible_only: bool = Query(True),
    limit: int = Query(100, ge=1, le=1000),
):
    """External-evidence proposals only; never mutates level or capability."""
    require_governance_available()
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT identity_node_id FROM node_capabilities
               WHERE identity_node_id IS NOT NULL
               ORDER BY identity_node_id LIMIT ?""",
            (limit,),
        ).fetchall()
    snapshots = [reliability_snapshot(row["identity_node_id"]) for row in rows]
    if eligible_only:
        snapshots = [
            item
            for item in snapshots
            if item["promotion_decision"] == "eligible_for_quorum_review"
        ]
    return TrustEligibilityCandidateListResponse(candidates=snapshots)


@router.get(
    "/registry/security-reputation-candidates",
    response_model=SecurityReputationCandidateListResponse,
)
def get_security_reputation_candidates(
    limit: int = Query(1000, ge=1, le=1000),
):
    """Provable violations only; returns proposals and never applies sanctions."""
    require_governance_available()
    return SecurityReputationCandidateListResponse(
        candidates=security_reputation_candidates(limit=limit)
    )


@router.get(
    "/registry/security-evidence",
    response_model=SecurityEvidenceListResponse,
)
def get_security_evidence(limit: int = Query(100, ge=1, le=100)):
    """Full signed conflict pairs; validators revalidate before voting."""
    require_governance_available()
    return SecurityEvidenceListResponse(evidence=security_evidence(limit=limit))


@router.post("/registry/nodes", response_model=RegisterNodeResponse)
def register_node_capability(payload: RegisterNodeCapability):
    now = now_iso()
    caps_json = json.dumps(payload.capabilities)
    enrollment_secret_plain: Optional[str] = None

    with get_conn() as conn:
        existing = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
        existing_trust = existing["trust_status"] if existing else None
        trust_status = initial_trust_status_for_register(existing_trust)

        secret_hash = existing["enrollment_secret_hash"] if existing else None
        if trust_status == "pending" and enrollment_required():
            if not secret_hash:
                enrollment_secret_plain = generate_enrollment_secret()
                secret_hash = hash_value(enrollment_secret_plain)

        att_status, att_detail = apply_attestation(
            node_id=payload.node_id,
            software_version=payload.software_version,
            build_hash=payload.build_hash,
            tls_cert_fingerprint=payload.tls_cert_fingerprint,
            release_signature=payload.release_signature,
            existing_row=existing,
        )
        identity_report = evaluate_node_identity_report(
            payload.operational_certificate,
            mode=NODE_IDENTITY_MODE,
            now=datetime.now(timezone.utc),
            existing_identity_node_id=_row_field(existing, "identity_node_id") if existing else None,
            existing_operational_certificate_json=(
                _row_field(existing, "operational_certificate") if existing else None
            ),
            advertised_signing_public_key=payload.signing_public_key,
        )
        if NODE_IDENTITY_MODE == "enforce" and identity_report.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=f"valid Node Identity required: {identity_report.detail or identity_report.status}",
            )
        if identity_report.status == "valid" and payload.operational_certificate is not None:
            require_node_trust_active(
                identity_report.identity_node_id,
                at_time=datetime.now(timezone.utc),
            )
            require_operational_credential_not_revoked(
                payload.operational_certificate,
                at_time=datetime.now(timezone.utc),
            )
        credential_state = payload.operational_credential_state
        if (
            OPERATIONAL_CREDENTIAL_STATE_MODE == "enforce"
            and credential_state is None
        ):
            raise HTTPException(
                status_code=403,
                detail="Operational Credential state is required for registration",
            )
        if credential_state is not None:
            if (
                payload.operational_certificate is None
                or credential_state.get("operational_certificate")
                != payload.operational_certificate
            ):
                raise HTTPException(
                    status_code=403,
                    detail="registration certificate does not match credential state",
                )
            state_validation = validate_operational_credential_state(
                credential_state,
                now=datetime.now(timezone.utc),
                expected_node_id=identity_report.identity_node_id,
                require_current_certificate=True,
            )
            if not state_validation.valid:
                raise HTTPException(
                    status_code=403,
                    detail=(
                        "invalid registration Operational Credential state: "
                        f"{state_validation.reason}"
                    ),
                )
        effective_signing_public_key = payload.signing_public_key
        if identity_report.status == "valid":
            effective_signing_public_key = identity_report.operational_public_key
        elif existing is not None:
            effective_signing_public_key = _row_field(existing, "signing_public_key")
        bound_identity = identity_report.identity_node_id or (
            _row_field(existing, "identity_node_id") if existing else None
        )
        advertisement_report = evaluate_node_advertisement_report(
            payload.node_advertisement,
            mode=NODE_ADVERTISEMENT_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=bound_identity if identity_report.status == "valid" else None,
            advertised_node_url=payload.node_url,
            minimum_epoch=_row_field(existing, "node_advertisement_epoch", 0)
            if existing else 0,
            existing_advertisement_json=(
                _row_field(existing, "node_advertisement") if existing else None
            ),
        )
        if NODE_ADVERTISEMENT_MODE == "enforce" and advertisement_report.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid NodeAdvertisement required: "
                    f"{advertisement_report.detail or advertisement_report.status}"
                ),
            )
        try:
            authority_state = load_effective_authority_state(
                CAPABILITY_AUTHORITY_STATE_PATH,
                bootstrap_state=load_capability_authority_state(
                    CAPABILITY_AUTHORITY_STATE_PATH
                ),
            )
            authority_error = None
        except ValueError as exc:
            authority_state = None
            authority_error = str(exc)
        capability_report = evaluate_capability_report(
            payload.capability_certificate,
            mode=CAPABILITY_CERTIFICATE_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=bound_identity,
            authority_state=authority_state,
            minimum_epoch=_row_field(existing, "capability_epoch", 0) if existing else 0,
            existing_certificate_json=(
                _row_field(existing, "capability_certificate") if existing else None
            ),
        )
        if authority_error and payload.capability_certificate is not None:
            capability_report = capability_report.__class__(
                "unverifiable", f"invalid local authority state: {authority_error}"
            )
        if CAPABILITY_CERTIFICATE_MODE == "enforce":
            requested_infrastructure = set(payload.capabilities) & INFRASTRUCTURE_CAPABILITIES
            if requested_infrastructure and capability_report.status != "valid":
                raise HTTPException(
                    status_code=403,
                    detail=(
                        "valid CapabilityCertificate required for infrastructure roles: "
                        f"{capability_report.detail or capability_report.status}"
                    ),
                )
            if capability_report.status == "valid" and not set(payload.capabilities).issubset(
                set(capability_report.certified_capabilities) | {"home"}
            ):
                raise HTTPException(
                    status_code=403,
                    detail="advertised capabilities exceed certified capabilities",
                )
            if requested_infrastructure:
                require_governance_available()

        transport_status, transport_detail, transport_json = (
            _evaluate_transport_certificate(
                payload.transport_certificate,
                identity_node_id=bound_identity,
            )
        )
        if TRANSPORT_CERTIFICATE_MODE == "enforce" and transport_status != "valid":
            raise HTTPException(
                status_code=403,
                detail=f"valid Transport Certificate required: {transport_detail}",
            )

        conn.execute(
            """
            INSERT INTO node_capabilities (
                node_id, node_url, capabilities, software_version, cluster_id,
                last_heartbeat, trust_status, registered_at, enrollment_secret_hash,
                build_hash, tls_cert_fingerprint, release_signature,
                attestation_status, attestation_detail, signing_public_key,
                identity_node_id, operational_certificate,
                node_identity_status, node_identity_detail,
                node_advertisement, node_advertisement_status,
                node_advertisement_detail, node_advertisement_epoch,
                advertised_endpoints, advertised_transports, advertised_protocols,
                capability_certificate, capability_certificate_status,
                capability_certificate_detail, certified_capabilities,
                certified_level, capability_epoch
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(node_id) DO UPDATE SET
                node_url=excluded.node_url,
                capabilities=excluded.capabilities,
                software_version=excluded.software_version,
                cluster_id=excluded.cluster_id,
                last_heartbeat=excluded.last_heartbeat,
                enrollment_secret_hash=COALESCE(excluded.enrollment_secret_hash, node_capabilities.enrollment_secret_hash),
                build_hash=COALESCE(excluded.build_hash, node_capabilities.build_hash),
                tls_cert_fingerprint=COALESCE(excluded.tls_cert_fingerprint, node_capabilities.tls_cert_fingerprint),
                release_signature=COALESCE(excluded.release_signature, node_capabilities.release_signature),
                attestation_status=excluded.attestation_status,
                attestation_detail=excluded.attestation_detail,
                signing_public_key=COALESCE(excluded.signing_public_key, node_capabilities.signing_public_key),
                identity_node_id=COALESCE(excluded.identity_node_id, node_capabilities.identity_node_id),
                operational_certificate=COALESCE(excluded.operational_certificate, node_capabilities.operational_certificate),
                node_identity_status=excluded.node_identity_status,
                node_identity_detail=excluded.node_identity_detail,
                node_advertisement=COALESCE(excluded.node_advertisement, node_capabilities.node_advertisement),
                node_advertisement_status=excluded.node_advertisement_status,
                node_advertisement_detail=excluded.node_advertisement_detail,
                node_advertisement_epoch=COALESCE(excluded.node_advertisement_epoch, node_capabilities.node_advertisement_epoch),
                advertised_endpoints=COALESCE(excluded.advertised_endpoints, node_capabilities.advertised_endpoints),
                advertised_transports=COALESCE(excluded.advertised_transports, node_capabilities.advertised_transports),
                advertised_protocols=COALESCE(excluded.advertised_protocols, node_capabilities.advertised_protocols),
                capability_certificate=COALESCE(excluded.capability_certificate, node_capabilities.capability_certificate),
                capability_certificate_status=excluded.capability_certificate_status,
                capability_certificate_detail=excluded.capability_certificate_detail,
                certified_capabilities=COALESCE(excluded.certified_capabilities, node_capabilities.certified_capabilities),
                certified_level=COALESCE(excluded.certified_level, node_capabilities.certified_level),
                capability_epoch=COALESCE(excluded.capability_epoch, node_capabilities.capability_epoch),
                trust_status=CASE
                    WHEN node_capabilities.trust_status IN ('suspended', 'compromised')
                    THEN node_capabilities.trust_status
                    WHEN node_capabilities.trust_status = 'trusted'
                    THEN node_capabilities.trust_status
                    ELSE excluded.trust_status
                END,
                registered_at=COALESCE(node_capabilities.registered_at, excluded.registered_at)
            """,
            (
                payload.node_id,
                payload.node_url,
                caps_json,
                payload.software_version,
                payload.cluster_id,
                now,
                trust_status,
                now,
                secret_hash,
                payload.build_hash,
                payload.tls_cert_fingerprint,
                payload.release_signature,
                att_status,
                att_detail,
                effective_signing_public_key,
                identity_report.identity_node_id,
                identity_report.operational_certificate_json,
                identity_report.status,
                identity_report.detail,
                advertisement_report.advertisement_json,
                advertisement_report.status,
                advertisement_report.detail,
                advertisement_report.epoch,
                json.dumps(advertisement_report.endpoints)
                if advertisement_report.status == "valid" else None,
                json.dumps(advertisement_report.supported_transports)
                if advertisement_report.status == "valid" else None,
                json.dumps(advertisement_report.supported_protocols)
                if advertisement_report.status == "valid" else None,
                capability_report.certificate_json,
                capability_report.status,
                capability_report.detail,
                json.dumps(capability_report.certified_capabilities)
                if capability_report.status == "valid" else None,
                capability_report.certified_level,
                capability_report.epoch,
            ),
        )
        conn.execute(
            """UPDATE node_capabilities SET
                   transport_certificate = COALESCE(?, transport_certificate),
                   transport_certificate_status = ?,
                   transport_certificate_detail = ?
               WHERE node_id = ?""",
            (
                transport_json,
                transport_status,
                transport_detail,
                payload.node_id,
            ),
        )
        _apply_version_policy(conn, payload.node_id, payload.software_version)
        if credential_state is not None:
            try:
                publish_operational_credential_state(
                    credential_state,
                    connection=conn,
                    require_known_subject=True,
                )
            except OperationalCredentialConflict as exc:
                get_network_view_guard().force_freeze(
                    "conflicting root-signed Operational Credential states detected"
                )
                raise HTTPException(status_code=409, detail=str(exc))
            except OperationalCredentialRollback as exc:
                raise HTTPException(status_code=409, detail=str(exc))
        row = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
        notify = should_notify_on_register(existing, payload, _trust_from_row(row))
        conn.commit()

    if bound_identity:
        reconcile_registered_subject(bound_identity)
        with get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
            ).fetchone()

    if notify and row:
        schedule_mesh_peer_notify(dict(row), reason="register")

    return _register_response(row, last_heartbeat=now, enrollment_secret=enrollment_secret_plain)


@router.post("/registry/nodes/{node_id}/heartbeat", response_model=NodeCapabilityResponse)
def heartbeat(
    node_id: str,
    payload: HeartbeatRequest = HeartbeatRequest(),
    authorization: Optional[str] = Header(None),
):
    now = now_iso()
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id — register first via POST /registry/nodes")

        trust = _trust_from_row(row)
        if trust == "pending":
            raise HTTPException(status_code=403, detail="Node enrollment pending approval")
        if trust in ("suspended", "compromised"):
            raise HTTPException(status_code=403, detail=f"Node trust_status is {trust}")

        if row["node_token_hash"] and enrollment_required():
            token = _bearer_token(authorization)
            if not verify_hash(token or "", row["node_token_hash"]):
                raise HTTPException(status_code=401, detail="Invalid or missing node_token")

        heartbeat_identity = evaluate_node_identity_report(
            payload.operational_certificate,
            mode=NODE_IDENTITY_MODE,
            now=datetime.now(timezone.utc),
            existing_identity_node_id=_row_field(row, "identity_node_id"),
            existing_operational_certificate_json=_row_field(
                row, "operational_certificate"
            ),
            advertised_signing_public_key=payload.signing_public_key,
        )
        if NODE_IDENTITY_MODE == "enforce" and heartbeat_identity.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid Node Identity required for heartbeat: "
                    f"{heartbeat_identity.detail or heartbeat_identity.status}"
                ),
            )
        if heartbeat_identity.status == "valid" and payload.operational_certificate is not None:
            require_node_trust_active(
                heartbeat_identity.identity_node_id,
                at_time=datetime.now(timezone.utc),
            )
            require_operational_credential_not_revoked(
                payload.operational_certificate,
                at_time=datetime.now(timezone.utc),
            )
        heartbeat_advertisement = evaluate_node_advertisement_report(
            payload.node_advertisement,
            mode=NODE_ADVERTISEMENT_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=(
                heartbeat_identity.identity_node_id
                if heartbeat_identity.status == "valid"
                else None
            ),
            advertised_node_url=row["node_url"],
            minimum_epoch=_row_field(row, "node_advertisement_epoch", 0),
            existing_advertisement_json=_row_field(row, "node_advertisement"),
        )
        if NODE_ADVERTISEMENT_MODE == "enforce" and heartbeat_advertisement.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid NodeAdvertisement required for heartbeat: "
                    f"{heartbeat_advertisement.detail or heartbeat_advertisement.status}"
                ),
            )
        try:
            heartbeat_authority_state = load_effective_authority_state(
                CAPABILITY_AUTHORITY_STATE_PATH,
                bootstrap_state=load_capability_authority_state(
                    CAPABILITY_AUTHORITY_STATE_PATH
                ),
            )
            heartbeat_authority_error = None
        except ValueError as exc:
            heartbeat_authority_state = None
            heartbeat_authority_error = str(exc)
        heartbeat_capability = evaluate_capability_report(
            payload.capability_certificate,
            mode=CAPABILITY_CERTIFICATE_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=(
                heartbeat_identity.identity_node_id
                if heartbeat_identity.status == "valid"
                else None
            ),
            authority_state=heartbeat_authority_state,
            minimum_epoch=_row_field(row, "capability_epoch", 0),
            existing_certificate_json=_row_field(row, "capability_certificate"),
        )
        if heartbeat_authority_error and payload.capability_certificate is not None:
            heartbeat_capability = heartbeat_capability.__class__(
                "unverifiable",
                f"invalid local authority state: {heartbeat_authority_error}",
            )
        if CAPABILITY_CERTIFICATE_MODE == "enforce":
            requested_infrastructure = set(json.loads(row["capabilities"])) & INFRASTRUCTURE_CAPABILITIES
            if requested_infrastructure and heartbeat_capability.status != "valid":
                raise HTTPException(
                    status_code=403,
                    detail=(
                        "valid CapabilityCertificate required for heartbeat: "
                        f"{heartbeat_capability.detail or heartbeat_capability.status}"
                    ),
                )
            if heartbeat_capability.status == "valid" and not requested_infrastructure.issubset(
                set(heartbeat_capability.certified_capabilities)
            ):
                raise HTTPException(
                    status_code=403,
                    detail="heartbeat capabilities exceed certified capabilities",
                )
        heartbeat_transport_status, heartbeat_transport_detail, heartbeat_transport_json = (
            _evaluate_transport_certificate(
                payload.transport_certificate,
                identity_node_id=_row_field(row, "identity_node_id"),
            )
        )
        if (
            TRANSPORT_CERTIFICATE_MODE == "enforce"
            and heartbeat_transport_status != "valid"
        ):
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid Transport Certificate required for heartbeat: "
                    f"{heartbeat_transport_detail}"
                ),
            )
        heartbeat_state = payload.operational_credential_state
        if (
            OPERATIONAL_CREDENTIAL_STATE_MODE == "enforce"
            and heartbeat_state is None
        ):
            raise HTTPException(
                status_code=403,
                detail="Operational Credential state is required for heartbeat",
            )
        if heartbeat_state is not None:
            if (
                payload.operational_certificate is None
                or heartbeat_state.get("operational_certificate")
                != payload.operational_certificate
            ):
                raise HTTPException(
                    status_code=403,
                    detail="heartbeat certificate does not match credential state",
                )
            state_validation = validate_operational_credential_state(
                heartbeat_state,
                now=datetime.now(timezone.utc),
                expected_node_id=_row_field(row, "identity_node_id"),
                require_current_certificate=True,
            )
            if not state_validation.valid:
                raise HTTPException(
                    status_code=403,
                    detail=(
                        "invalid heartbeat Operational Credential state: "
                        f"{state_validation.reason}"
                    ),
                )
            try:
                publish_operational_credential_state(
                    heartbeat_state,
                    connection=conn,
                    require_known_subject=True,
                )
            except OperationalCredentialConflict as exc:
                get_network_view_guard().force_freeze(
                    "conflicting root-signed Operational Credential states detected"
                )
                raise HTTPException(status_code=409, detail=str(exc))
            except OperationalCredentialRollback as exc:
                raise HTTPException(status_code=409, detail=str(exc))

        effective_heartbeat_signing_key = None
        effective_heartbeat_certificate = None
        if heartbeat_identity.status == "valid":
            effective_heartbeat_signing_key = heartbeat_identity.operational_public_key
            effective_heartbeat_certificate = heartbeat_identity.operational_certificate_json

        version = payload.software_version or row["software_version"]
        att_status, att_detail = apply_attestation(
            node_id=node_id,
            software_version=version,
            build_hash=payload.build_hash,
            tls_cert_fingerprint=payload.tls_cert_fingerprint,
            release_signature=payload.release_signature,
            existing_row=row,
        )
        # Accumulate messages_total: add delta from 24h counter if provided
        # and the counter increased since last heartbeat (simple monotonic check).
        msg_total_expr = "messages_total"
        msg_total_params: list = []
        if payload.messages_24h is not None:
            prev_24h = _row_field(row, "messages_24h") or 0
            delta = max(0, payload.messages_24h - prev_24h)
            if delta > 0:
                msg_total_expr = "messages_total + ?"
                msg_total_params = [delta]

        conn.execute(
            f"""
            UPDATE node_capabilities SET
                last_heartbeat = ?,
                software_version = ?,
                build_hash = COALESCE(?, build_hash),
                tls_cert_fingerprint = COALESCE(?, tls_cert_fingerprint),
                release_signature = COALESCE(?, release_signature),
                attestation_status = ?,
                attestation_detail = ?,
                signing_public_key = COALESCE(?, signing_public_key),
                operational_certificate = COALESCE(?, operational_certificate),
                node_advertisement = COALESCE(?, node_advertisement),
                node_advertisement_status = ?,
                node_advertisement_detail = ?,
                node_advertisement_epoch = COALESCE(?, node_advertisement_epoch),
                advertised_endpoints = COALESCE(?, advertised_endpoints),
                advertised_transports = COALESCE(?, advertised_transports),
                advertised_protocols = COALESCE(?, advertised_protocols),
                capability_certificate = COALESCE(?, capability_certificate),
                capability_certificate_status = ?,
                capability_certificate_detail = ?,
                certified_capabilities = COALESCE(?, certified_capabilities),
                certified_level = COALESCE(?, certified_level),
                capability_epoch = COALESCE(?, capability_epoch),
                cpu_load_1m       = COALESCE(?, cpu_load_1m),
                cpu_cores         = COALESCE(?, cpu_cores),
                cpu_percent_est   = COALESCE(?, cpu_percent_est),
                ram_total_bytes   = COALESCE(?, ram_total_bytes),
                ram_used_bytes    = COALESCE(?, ram_used_bytes),
                ram_percent       = COALESCE(?, ram_percent),
                disk_used_bytes   = COALESCE(?, disk_used_bytes),
                disk_total_bytes  = COALESCE(?, disk_total_bytes),
                disk_percent      = COALESCE(?, disk_percent),
                uptime_sec        = COALESCE(?, uptime_sec),
                ws_connections    = COALESCE(?, ws_connections),
                messages_24h      = COALESCE(?, messages_24h),
                calls_24h         = COALESCE(?, calls_24h),
                error_rate_pct    = COALESCE(?, error_rate_pct),
                messages_total    = {msg_total_expr}
            WHERE node_id = ?
            """,
            (
                now,
                version,
                payload.build_hash,
                payload.tls_cert_fingerprint,
                payload.release_signature,
                att_status,
                att_detail,
                effective_heartbeat_signing_key,
                effective_heartbeat_certificate,
                heartbeat_advertisement.advertisement_json,
                heartbeat_advertisement.status,
                heartbeat_advertisement.detail,
                heartbeat_advertisement.epoch,
                json.dumps(heartbeat_advertisement.endpoints)
                if heartbeat_advertisement.status == "valid" else None,
                json.dumps(heartbeat_advertisement.supported_transports)
                if heartbeat_advertisement.status == "valid" else None,
                json.dumps(heartbeat_advertisement.supported_protocols)
                if heartbeat_advertisement.status == "valid" else None,
                heartbeat_capability.certificate_json,
                heartbeat_capability.status,
                heartbeat_capability.detail,
                json.dumps(heartbeat_capability.certified_capabilities)
                if heartbeat_capability.status == "valid" else None,
                heartbeat_capability.certified_level,
                heartbeat_capability.epoch,
                payload.cpu_load_1m,
                payload.cpu_cores,
                payload.cpu_percent_est,
                payload.ram_total_bytes,
                payload.ram_used_bytes,
                payload.ram_percent,
                payload.disk_used_bytes,
                payload.disk_total_bytes,
                payload.disk_percent,
                payload.uptime_sec,
                payload.ws_connections,
                payload.messages_24h,
                payload.calls_24h,
                payload.error_rate_pct,
                *msg_total_params,
                node_id,
            ),
        )
        conn.execute(
            """UPDATE node_capabilities SET
                   transport_certificate = COALESCE(?, transport_certificate),
                   transport_certificate_status = ?,
                   transport_certificate_detail = ?
               WHERE node_id = ?""",
            (
                heartbeat_transport_json,
                heartbeat_transport_status,
                heartbeat_transport_detail,
                node_id,
            ),
        )
        _apply_version_policy(conn, node_id, version)
        conn.commit()
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()

    response = _node_response(row, last_heartbeat=now)
    # Фаза 3.3: включаем актуальный peer-список в heartbeat-ответ.
    # Нода обновит свой mesh-кэш из этого списка — меньше запросов к Discovery.
    response.peers = _build_peer_list(exclude_node_id=node_id)
    return response


@router.get("/registry/nodes", response_model=NodeCapabilityListResponse)
def list_nodes(
    capability: Optional[str] = None,
    cluster_id: Optional[str] = None,
    include_untrusted: bool = Query(False, description="Operator-only: include non-trusted nodes"),
):
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM node_capabilities").fetchall()
    nodes = []
    for row in rows:
        trust = _trust_from_row(row)
        if not include_untrusted and trust != "trusted":
            continue
        if (
            not include_untrusted
            and NODE_ADVERTISEMENT_MODE == "enforce"
            and not _row_has_current_advertisement(row)
        ):
            continue
        if (
            not include_untrusted
            and CAPABILITY_CERTIFICATE_MODE == "enforce"
            and not _row_has_current_capability(row)
        ):
            continue
        # Vulnerability quarantine (isolate): exclude blocked nodes from the
        # public listing so they receive no relay/storage/discovery work.
        if not include_untrusted and _row_field(row, "quarantine_action", "off") == "isolate":
            continue
        caps = json.loads(row["capabilities"])
        if capability and capability not in caps:
            continue
        if cluster_id and _cluster_id_from_row(row) != cluster_id:
            continue
        nodes.append(_node_response(row, last_heartbeat=row["last_heartbeat"]))
    return NodeCapabilityListResponse(nodes=nodes)


@router.post(
    "/registry/trust-observations",
    response_model=TrustObservationPublishResponse,
)
def publish_trust_observation(
    payload: TrustObservationPublishRequest,
    authorization: Optional[str] = Header(None),
):
    observation_id, accepted = publish_observation(
        payload.observation,
        authorization=authorization,
        assignment_id=payload.assignment_id,
    )
    return TrustObservationPublishResponse(
        observation_id=observation_id,
        accepted=accepted,
    )


@router.post(
    "/registry/trust-observations/portable",
    response_model=TrustObservationPublishResponse,
)
def publish_trust_observation_portable(
    payload: TrustObservationPortablePublishRequest,
):
    observation_id, accepted = publish_observation(
        payload.observation,
        authorization=None,
        assignment_id=payload.assignment_id,
        observer_certificate=payload.operational_certificate,
        operational_credential_state=payload.operational_credential_state,
    )
    return TrustObservationPublishResponse(
        observation_id=observation_id,
        accepted=accepted,
    )


@router.get(
    "/registry/trust-observations/gossip",
    response_model=TrustObservationGossipListResponse,
)
def get_trust_observation_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return TrustObservationGossipListResponse(
        **build_observation_gossip(after_sequence=after_sequence, limit=limit)
    )


@router.post(
    "/registry/trust-observations/gossip",
    response_model=TrustObservationGossipResponse,
)
def publish_trust_observation_gossip(payload: TrustObservationGossipItem):
    return TrustObservationGossipResponse(
        **ingest_observation_gossip(payload.model_dump())
    )


@router.post(
    "/registry/authority-checkpoints",
    response_model=AuthorityCheckpointPublishResponse,
)
def publish_authority_checkpoint_record(payload: AuthorityCheckpointPublishRequest):
    require_governance_available()
    try:
        bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid bootstrap authority state: {exc}")
    if bootstrap is None:
        raise HTTPException(status_code=503, detail="bootstrap authority state is unavailable")
    try:
        digest, accepted = publish_authority_checkpoint(
            payload.checkpoint,
            bootstrap_state=bootstrap,
        )
    except AuthorityCheckpointConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum AuthorityCheckpoints detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    identity = discovery_node_identity()["operational_certificate"]
    get_network_view_guard().observe_validated_checkpoint(
        source_node_id=identity["node_id"],
        authority_epoch=payload.checkpoint["authority_epoch"],
        checkpoint_hash=digest,
        previous_hash=payload.checkpoint["previous_hash"],
    )
    return AuthorityCheckpointPublishResponse(
        authority_epoch=payload.checkpoint["authority_epoch"],
        checkpoint_hash=digest,
        accepted=accepted,
    )


@router.get(
    "/registry/authority-checkpoints/latest",
    response_model=AuthorityCheckpointResponse,
)
def get_latest_authority_checkpoint():
    current = latest_checkpoint()
    if current is None:
        raise HTTPException(status_code=404, detail="AuthorityCheckpoint is unavailable")
    return AuthorityCheckpointResponse(**current)


@router.get(
    "/registry/authority-checkpoints/gossip",
    response_model=AuthorityCheckpointGossipListResponse,
)
def get_authority_checkpoint_gossip(
    after_epoch: int = Query(-1, ge=-1),
    limit: int = Query(20, ge=1, le=100),
):
    return AuthorityCheckpointGossipListResponse(
        checkpoints=build_gossip_items(after_epoch=after_epoch, limit=limit),
        head=build_gossip_head(),
    )


@router.post(
    "/registry/authority-checkpoints/gossip",
    response_model=AuthorityCheckpointGossipResponse,
)
def publish_authority_checkpoint_gossip(payload: AuthorityCheckpointGossipRequest):
    return AuthorityCheckpointGossipResponse(
        **ingest_gossip_item(
            {
                "checkpoint": payload.checkpoint,
                "announcement": payload.announcement,
            }
        )
    )


@router.get(
    "/registry/node-advertisements/gossip",
    response_model=NodeAdvertisementGossipListResponse,
)
def get_node_advertisement_gossip(
    after_node_id: str = Query("", max_length=128),
    limit: int = Query(20, ge=1, le=100),
):
    return NodeAdvertisementGossipListResponse(
        observations=build_local_gossip_items(after_node_id=after_node_id, limit=limit)
    )


@router.post(
    "/registry/node-advertisements/gossip",
    response_model=NodeAdvertisementGossipResponse,
)
def publish_node_advertisement_gossip(payload: NodeAdvertisementGossipItem):
    try:
        return NodeAdvertisementGossipResponse(
            **ingest_advertisement_gossip(payload.model_dump())
        )
    except AdvertisementObservationConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except CapabilityCertificateConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum CapabilityCertificates detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))


@router.get(
    "/registry/node-advertisements/observations",
    response_model=NodeAdvertisementGossipListResponse,
)
def get_node_advertisement_observations(
    subject_node_id: Optional[str] = Query(None, max_length=128),
    limit: int = Query(100, ge=1, le=1000),
):
    return NodeAdvertisementGossipListResponse(
        observations=list_stored_observations(
            subject_node_id=subject_node_id,
            limit=limit,
        )
    )


@router.get(
    "/registry/node-advertisements/peer-view",
    response_model=NodeAdvertisementPeerViewResponse,
)
def get_node_advertisement_peer_view(
    capability: Optional[str] = Query(None, min_length=1, max_length=32),
    minimum_sources: int = Query(2, ge=2, le=16),
):
    return NodeAdvertisementPeerViewResponse(
        **build_peer_view(
            capability=capability,
            minimum_sources=minimum_sources,
        )
    )


@router.post(
    "/registry/challenge-assignments",
    response_model=ChallengeAssignmentPublishResponse,
)
def publish_challenge_assignment(payload: ChallengeAssignmentPublishRequest):
    require_governance_available()
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    try:
        authority = load_authority_state_at_epoch(
            TRUST_AUTHORITY_STATE_PATH,
            payload.assignment.get("authority_epoch"),
            bootstrap_state=bootstrap,
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid Trust authority state: {exc}")
    if authority is None:
        raise HTTPException(status_code=503, detail="Trust authority state is unavailable")
    try:
        assignment_id, accepted = publish_assignment(
            payload.assignment,
            authority=authority,
        )
    except AssignmentConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum ChallengeAssignments detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    return ChallengeAssignmentPublishResponse(
        assignment_id=assignment_id,
        accepted=accepted,
    )


@router.get(
    "/registry/challenge-assignment-proposals",
    response_model=ChallengeAssignmentProposalListResponse,
)
def get_challenge_assignment_proposals(
    after_epoch: int = Query(-1, ge=-1),
    limit: int = Query(100, ge=1, le=1000),
):
    """Unsigned deterministic inputs for validator quorum signing."""
    require_governance_available()
    return ChallengeAssignmentProposalListResponse(
        proposals=list_challenge_proposals(after_epoch=after_epoch, limit=limit)
    )


@router.post(
    "/registry/randomness-checkpoints",
    response_model=RandomnessCheckpointResponse,
)
def publish_challenge_randomness_checkpoint(
    payload: RandomnessCheckpointPublishRequest,
):
    require_governance_available()
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    authority = load_authority_state_at_epoch(
        TRUST_AUTHORITY_STATE_PATH,
        payload.checkpoint.get("authority_epoch"),
        bootstrap_state=bootstrap,
    )
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="authority state for RandomnessCheckpoint is unavailable",
        )
    try:
        digest, accepted = publish_randomness_checkpoint(
            payload.checkpoint,
            authority_state=authority,
        )
    except RandomnessCheckpointConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum RandomnessCheckpoints detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    return RandomnessCheckpointResponse(
        challenge_epoch=payload.checkpoint["challenge_epoch"],
        checkpoint_hash=digest,
        accepted=accepted,
    )


@router.get(
    "/registry/randomness-checkpoints/gossip",
    response_model=RandomnessCheckpointGossipListResponse,
)
def get_challenge_randomness_gossip(
    after_epoch: int = Query(-1, ge=-1),
    limit: int = Query(100, ge=1, le=100),
):
    return RandomnessCheckpointGossipListResponse(
        **build_randomness_gossip(after_epoch=after_epoch, limit=limit)
    )


@router.post(
    "/registry/randomness-checkpoints/gossip",
    response_model=RandomnessCheckpointResponse,
)
def publish_challenge_randomness_gossip(
    payload: RandomnessCheckpointStored,
):
    return RandomnessCheckpointResponse(
        **ingest_randomness_gossip(payload.model_dump())
    )


@router.post(
    "/registry/operational-credential-states",
    response_model=OperationalCredentialStateResponse,
)
def publish_node_operational_credential_state(
    payload: OperationalCredentialStatePublishRequest,
):
    try:
        digest, accepted = publish_operational_credential_state(payload.state)
    except OperationalCredentialConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting root-signed Operational Credential states detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    except OperationalCredentialRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    return OperationalCredentialStateResponse(
        node_id=payload.state["node_id"],
        credential_epoch=payload.state["credential_epoch"],
        state_hash=digest,
        accepted=accepted,
    )


@router.get(
    "/registry/operational-credential-states/gossip",
    response_model=OperationalCredentialStateGossipListResponse,
)
def get_operational_credential_state_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return OperationalCredentialStateGossipListResponse(
        **build_operational_credential_gossip(
            after_sequence=after_sequence,
            limit=limit,
        )
    )


@router.post(
    "/registry/operational-credential-states/gossip",
    response_model=OperationalCredentialStateResponse,
)
def publish_operational_credential_state_gossip(
    payload: OperationalCredentialStateStored,
):
    return OperationalCredentialStateResponse(
        **ingest_operational_credential_gossip(payload.model_dump())
    )


@router.post(
    "/registry/operational-credential-revocations",
    response_model=OperationalCredentialRevocationResponse,
)
def publish_node_operational_credential_revocation(
    payload: OperationalCredentialRevocationPublishRequest,
):
    try:
        digest, accepted = publish_operational_credential_revocation(
            payload.revocation
        )
    except OperationalCredentialRevocationConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except OperationalCredentialRevocationRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    return OperationalCredentialRevocationResponse(
        node_id=payload.revocation["node_id"],
        revocation_epoch=payload.revocation["revocation_epoch"],
        revocation_hash=digest,
        accepted=accepted,
    )


@router.get(
    "/registry/operational-credential-revocations/gossip",
    response_model=OperationalCredentialRevocationGossipListResponse,
)
def get_operational_credential_revocation_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return OperationalCredentialRevocationGossipListResponse(
        **build_operational_credential_revocation_gossip(
            after_sequence=after_sequence, limit=limit
        )
    )


@router.post(
    "/registry/operational-credential-revocations/gossip",
    response_model=OperationalCredentialRevocationResponse,
)
def publish_operational_credential_revocation_gossip(
    payload: OperationalCredentialRevocationStored,
):
    result = ingest_operational_credential_revocation_gossip(payload.model_dump())
    result.pop("sequence", None)
    return OperationalCredentialRevocationResponse(**result)


@router.get(
    "/registry/challenge-assignments/gossip",
    response_model=ChallengeAssignmentGossipListResponse,
)
def get_challenge_assignment_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return ChallengeAssignmentGossipListResponse(
        **build_assignment_gossip(
            after_sequence=after_sequence,
            limit=limit,
        )
    )


@router.post(
    "/registry/challenge-assignments/gossip",
    response_model=ChallengeAssignmentGossipResponse,
)
def publish_challenge_assignment_gossip(payload: ChallengeAssignmentGossipItem):
    return ChallengeAssignmentGossipResponse(
        **ingest_assignment_gossip(payload.model_dump())
    )


@router.get(
    "/registry/challenge-assignments/{observer_node_id}",
    response_model=ChallengeAssignmentListResponse,
)
def get_challenge_assignments(
    observer_node_id: str,
    authorization: Optional[str] = Header(None),
    limit: int = Query(20, ge=1, le=100),
):
    return ChallengeAssignmentListResponse(
        assignments=pull_assignments(
            observer_node_id,
            authorization=authorization,
            limit=limit,
        )
    )


@router.post(
    "/registry/challenge-assignments/pull",
    response_model=ChallengeAssignmentListResponse,
)
def pull_challenge_assignments_portable(
    payload: ChallengeAssignmentPortablePullRequest,
):
    return ChallengeAssignmentListResponse(
        assignments=pull_assignments_with_proof(
            payload.proof,
            limit=payload.limit,
            operational_credential_state=payload.operational_credential_state,
        )
    )


@router.post(
    "/registry/challenge-assignment-acks",
    response_model=ChallengeAssignmentAckResponse,
)
def publish_challenge_assignment_ack(
    payload: ChallengeAssignmentAckRequest,
    authorization: Optional[str] = Header(None),
):
    assignment_id, state, accepted = acknowledge_assignment(
        payload.ack,
        authorization=authorization,
    )
    return ChallengeAssignmentAckResponse(
        assignment_id=assignment_id,
        state=state,
        accepted=accepted,
    )


@router.post(
    "/registry/challenge-assignment-acks/portable",
    response_model=ChallengeAssignmentAckResponse,
)
def publish_challenge_assignment_ack_portable(
    payload: ChallengeAssignmentPortableAckRequest,
):
    assignment_id, state, accepted = acknowledge_assignment(
        payload.ack,
        authorization=None,
        observer_certificate=payload.operational_certificate,
        operational_credential_state=payload.operational_credential_state,
    )
    return ChallengeAssignmentAckResponse(
        assignment_id=assignment_id,
        state=state,
        accepted=accepted,
    )


@router.get(
    "/registry/challenge-assignment-acks/gossip",
    response_model=ChallengeAssignmentAckGossipListResponse,
)
def get_challenge_assignment_ack_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return ChallengeAssignmentAckGossipListResponse(
        **build_ack_gossip(after_sequence=after_sequence, limit=limit)
    )


@router.post(
    "/registry/challenge-assignment-acks/gossip",
    response_model=ChallengeAssignmentAckGossipResponse,
)
def publish_challenge_assignment_ack_gossip(
    payload: ChallengeAssignmentAckGossipItem,
):
    return ChallengeAssignmentAckGossipResponse(
        **ingest_ack_gossip(payload.model_dump())
    )


@router.get(
    "/registry/trust-observations/{subject_node_id}",
    response_model=TrustObservationListResponse,
)
def get_trust_observations(subject_node_id: str, limit: int = Query(100, ge=1, le=100)):
    return TrustObservationListResponse(
        observations=list_observations(subject_node_id, limit=limit)
    )


@router.get(
    "/registry/reliability/{subject_node_id}",
    response_model=ReliabilitySnapshotResponse,
)
def get_reliability_snapshot(subject_node_id: str):
    return ReliabilitySnapshotResponse(**reliability_snapshot(subject_node_id))
