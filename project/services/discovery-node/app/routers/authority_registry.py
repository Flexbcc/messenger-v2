from fastapi import APIRouter, HTTPException, Query

from app.authority_checkpoint_store import (
    AuthorityCheckpointConflict,
    latest_checkpoint,
    publish_authority_checkpoint,
)
from app.authority_gossip import build_gossip_head, build_gossip_items, ingest_gossip_item
from app.config import TRUST_AUTHORITY_STATE_PATH
from app.network_guard import get_network_view_guard, require_governance_available
from app.node_identity import discovery_node_identity
from app.schemas import (
    AuthorityCheckpointGossipListResponse,
    AuthorityCheckpointGossipRequest,
    AuthorityCheckpointGossipResponse,
    AuthorityCheckpointPublishRequest,
    AuthorityCheckpointPublishResponse,
    AuthorityCheckpointResponse,
)
from shared.security.capability_enrollment import load_capability_authority_state

router = APIRouter()


@router.post(
    "/registry/authority-checkpoints",
    response_model=AuthorityCheckpointPublishResponse,
)
def publish_authority_checkpoint_record(payload: AuthorityCheckpointPublishRequest):
    require_governance_available()
    try:
        bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    except ValueError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"invalid bootstrap authority state: {exc}",
        )
    if bootstrap is None:
        raise HTTPException(
            status_code=503,
            detail="bootstrap authority state is unavailable",
        )
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
        raise HTTPException(
            status_code=404,
            detail="AuthorityCheckpoint is unavailable",
        )
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
