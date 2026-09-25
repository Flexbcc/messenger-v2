from fastapi import APIRouter, HTTPException, Query

from app.network_guard import get_network_view_guard
from app.operational_credential_gossip import (
    build_operational_credential_gossip,
    ingest_operational_credential_gossip,
)
from app.operational_credential_revocation_gossip import (
    build_operational_credential_revocation_gossip,
    ingest_operational_credential_revocation_gossip,
)
from app.operational_credential_revocation_store import (
    OperationalCredentialRevocationConflict,
    OperationalCredentialRevocationRollback,
    publish_operational_credential_revocation,
)
from app.operational_credential_store import (
    OperationalCredentialConflict,
    OperationalCredentialRollback,
    publish_operational_credential_state,
)
from app.schemas import (
    OperationalCredentialRevocationGossipListResponse,
    OperationalCredentialRevocationPublishRequest,
    OperationalCredentialRevocationResponse,
    OperationalCredentialRevocationStored,
    OperationalCredentialStateGossipListResponse,
    OperationalCredentialStatePublishRequest,
    OperationalCredentialStateResponse,
    OperationalCredentialStateStored,
)

router = APIRouter()


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
