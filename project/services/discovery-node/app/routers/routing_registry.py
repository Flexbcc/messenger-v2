import json

from fastapi import APIRouter, HTTPException, Query

from app.bootstrap_record_store import (
    BootstrapRecordConflict,
    publish_bootstrap_record as store_bootstrap_record,
)
from app.db import get_conn
from app.rendezvous_gossip import local_rendezvous_page
from app.route_descriptor_store import (
    RouteDescriptorConflict,
    RouteDescriptorIdentityUnavailable,
    list_route_descriptors,
    publish_route_descriptor,
)
from app.schemas import (
    BootstrapRecordPublishRequest,
    BootstrapRecordResponse,
    RouteDescriptorListResponse,
    RouteDescriptorPublishRequest,
    RouteDescriptorPublishResponse,
)

router = APIRouter()


@router.post("/registry/bootstrap-records", response_model=BootstrapRecordResponse)
def publish_bootstrap_record(payload: BootstrapRecordPublishRequest):
    """Persist a user-signed record without becoming its authority."""
    try:
        result = store_bootstrap_record(payload.record)
    except BootstrapRecordConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return BootstrapRecordResponse(
        record=result["record"], stored_at=result["stored_at"]
    )


@router.get("/registry/rendezvous/gossip")
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
    return BootstrapRecordResponse(
        record=json.loads(row["record_json"]), stored_at=row["stored_at"]
    )


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
