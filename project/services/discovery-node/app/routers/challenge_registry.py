from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Query

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.challenge_assignment_ack_gossip import build_ack_gossip, ingest_ack_gossip
from app.challenge_assignment_gossip import (
    build_assignment_gossip,
    ingest_assignment_gossip,
)
from app.challenge_assignment_store import (
    AssignmentConflict,
    acknowledge_assignment,
    publish_assignment,
    pull_assignments,
    pull_assignments_with_proof,
)
from app.challenge_proposal_scheduler import list_challenge_proposals
from app.config import TRUST_AUTHORITY_STATE_PATH
from app.network_guard import get_network_view_guard, require_governance_available
from app.randomness_checkpoint_gossip import (
    build_randomness_gossip,
    ingest_randomness_gossip,
)
from app.randomness_checkpoint_store import (
    RandomnessCheckpointConflict,
    publish_randomness_checkpoint,
)
from app.schemas import (
    ChallengeAssignmentAckGossipItem,
    ChallengeAssignmentAckGossipListResponse,
    ChallengeAssignmentAckGossipResponse,
    ChallengeAssignmentAckRequest,
    ChallengeAssignmentAckResponse,
    ChallengeAssignmentGossipItem,
    ChallengeAssignmentGossipListResponse,
    ChallengeAssignmentGossipResponse,
    ChallengeAssignmentListResponse,
    ChallengeAssignmentPortableAckRequest,
    ChallengeAssignmentPortablePullRequest,
    ChallengeAssignmentProposalListResponse,
    ChallengeAssignmentPublishRequest,
    ChallengeAssignmentPublishResponse,
    RandomnessCheckpointGossipListResponse,
    RandomnessCheckpointPublishRequest,
    RandomnessCheckpointResponse,
    RandomnessCheckpointStored,
)
from shared.security.capability_enrollment import load_capability_authority_state

router = APIRouter()


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
        raise HTTPException(
            status_code=503,
            detail=f"invalid Trust authority state: {exc}",
        )
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="Trust authority state is unavailable",
        )
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
def publish_challenge_randomness_gossip(payload: RandomnessCheckpointStored):
    return RandomnessCheckpointResponse(
        **ingest_randomness_gossip(payload.model_dump())
    )


@router.get(
    "/registry/challenge-assignments/gossip",
    response_model=ChallengeAssignmentGossipListResponse,
)
def get_challenge_assignment_gossip(
    after_sequence: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=100),
):
    return ChallengeAssignmentGossipListResponse(
        **build_assignment_gossip(after_sequence=after_sequence, limit=limit)
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
