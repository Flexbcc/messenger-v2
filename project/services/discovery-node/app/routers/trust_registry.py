from typing import Optional

from fastapi import APIRouter, Header, Query

from app.db import get_conn
from app.network_guard import require_governance_available
from app.schemas import (
    SecurityEvidenceListResponse,
    SecurityReputationCandidateListResponse,
    TrustDegradationCandidateListResponse,
    TrustEligibilityCandidateListResponse,
    TrustRecordGossipItem,
    TrustRecordGossipListResponse,
    TrustRecordGossipResponse,
    TrustRecordProposalListResponse,
    TrustRecordPublishRequest,
    TrustRecordPublishResponse,
    TrustRecordVoteRequest,
    TrustRecordVoteResponse,
    TrustObservationGossipItem,
    TrustObservationGossipListResponse,
    TrustObservationGossipResponse,
    TrustObservationListResponse,
    TrustObservationPortablePublishRequest,
    TrustObservationPublishRequest,
    TrustObservationPublishResponse,
    ReliabilitySnapshotResponse,
)
from app.security_reputation import security_evidence, security_reputation_candidates
from app.trust_degradation import list_degradation_candidates
from app.trust_record_gossip import build_trust_record_gossip, ingest_trust_record_gossip
from app.trust_record_proposals import (
    generate_trust_record_proposals,
    list_trust_record_proposals,
)
from app.trust_record_service import ingest_trust_record
from app.trust_record_votes import submit_trust_record_vote
from app.trust_reputation import reliability_snapshot
from app.trust_observation_gossip import (
    build_observation_gossip,
    ingest_observation_gossip,
)
from app.trust_observation_store import list_observations, publish_observation

router = APIRouter()


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


@router.get(
    "/registry/trust-observations/{subject_node_id}",
    response_model=TrustObservationListResponse,
)
def get_trust_observations(
    subject_node_id: str,
    limit: int = Query(100, ge=1, le=100),
):
    return TrustObservationListResponse(
        observations=list_observations(subject_node_id, limit=limit)
    )


@router.get(
    "/registry/reliability/{subject_node_id}",
    response_model=ReliabilitySnapshotResponse,
)
def get_reliability_snapshot(subject_node_id: str):
    return ReliabilitySnapshotResponse(**reliability_snapshot(subject_node_id))


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
        **build_trust_record_gossip(after_sequence=after_sequence, limit=limit)
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
def get_security_reputation_candidates(limit: int = Query(1000, ge=1, le=1000)):
    """Provable violations only; returns proposals and never applies sanctions."""
    require_governance_available()
    return SecurityReputationCandidateListResponse(
        candidates=security_reputation_candidates(limit=limit)
    )


@router.get("/registry/security-evidence", response_model=SecurityEvidenceListResponse)
def get_security_evidence(limit: int = Query(100, ge=1, le=100)):
    """Full signed conflict pairs; validators revalidate before voting."""
    require_governance_available()
    return SecurityEvidenceListResponse(evidence=security_evidence(limit=limit))
