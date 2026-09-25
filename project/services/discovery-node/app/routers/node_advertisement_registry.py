from typing import Optional

from fastapi import APIRouter, HTTPException, Query

from app.network_guard import get_network_view_guard
from app.node_advertisement_gossip import (
    AdvertisementObservationConflict,
    CapabilityCertificateConflict,
    build_local_gossip_items,
    build_peer_view,
    ingest_advertisement_gossip,
    list_stored_observations,
)
from app.schemas import (
    NodeAdvertisementGossipItem,
    NodeAdvertisementGossipListResponse,
    NodeAdvertisementGossipResponse,
    NodeAdvertisementPeerViewResponse,
)

router = APIRouter()


@router.get(
    "/registry/node-advertisements/gossip",
    response_model=NodeAdvertisementGossipListResponse,
)
def get_node_advertisement_gossip(
    after_node_id: str = Query("", max_length=128),
    limit: int = Query(20, ge=1, le=100),
):
    return NodeAdvertisementGossipListResponse(
        observations=build_local_gossip_items(
            after_node_id=after_node_id,
            limit=limit,
        )
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
