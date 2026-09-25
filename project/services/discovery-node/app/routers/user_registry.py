from fastapi import APIRouter, Depends, HTTPException, Query

from app.db import get_conn
from app.fed_security import require_federation
from app.record_signer import discovery_public_key_b64, sign_user_record
from app.schemas import RegisterUserRecord, UserHomeRouteResponse, UserRecordResponse
from app.trust import now_iso
from shared.security.config import INTERNAL_SECURITY_MODE

router = APIRouter()


def _signed_response(data: dict) -> UserRecordResponse:
    data["record_signature"] = sign_user_record(
        data["user_id"],
        data["home_node_url"],
        data["updated_at"],
    )
    data["discovery_public_key"] = discovery_public_key_b64()
    return UserRecordResponse(**data)


def _require_origin_owns_home(
    conn,
    *,
    origin_node_id: str,
    home_node_url: str,
) -> None:
    origin = conn.execute(
        """SELECT node_url FROM node_capabilities
           WHERE node_id = ? OR identity_node_id = ?
           LIMIT 1""",
        (origin_node_id, origin_node_id),
    ).fetchone()
    if origin is None:
        raise HTTPException(status_code=403, detail="Unknown publishing Home node")
    if origin["node_url"].rstrip("/") != home_node_url.rstrip("/"):
        raise HTTPException(
            status_code=403,
            detail="Publishing Home node does not own home_node_url",
        )


@router.post("/registry/users", response_model=UserRecordResponse)
def register_user(
    payload: RegisterUserRecord,
    origin_node_id: str = Depends(require_federation),
):
    now = now_iso()
    with get_conn() as conn:
        _require_origin_owns_home(
            conn,
            origin_node_id=origin_node_id,
            home_node_url=payload.home_node_url,
        )
        existing_user = conn.execute(
            "SELECT home_node_url FROM user_records WHERE user_id = ?",
            (payload.user_id,),
        ).fetchone()
        if (
            INTERNAL_SECURITY_MODE == "signed"
            and existing_user is not None
            and existing_user["home_node_url"].rstrip("/")
            != payload.home_node_url.rstrip("/")
        ):
            raise HTTPException(
                status_code=409,
                detail="Home migration requires an endpoint-signed route descriptor",
            )
        conn.execute(
            """
            INSERT INTO user_records (
                user_id, home_node_url, display_name, auth_public_key, cluster_id,
                login, username_search_enabled, updated_at, home_updated_at,
                previous_home_node_url
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
    return _signed_response(data)


@router.get("/registry/users/search", response_model=UserRecordResponse)
def search_user_by_login(login: str = Query(..., min_length=3, max_length=50)):
    normalized = login.strip().lstrip("@").lower()
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
        raise HTTPException(
            status_code=403,
            detail="Username search disabled for this user",
        )
    if not data.get("login"):
        raise HTTPException(status_code=404, detail="User not found")
    return _signed_response(data)


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
    return _signed_response(data)


@router.get(
    "/registry/users/{user_id}/home-route",
    response_model=UserHomeRouteResponse,
)
def resolve_user_home_route(user_id: str):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM user_records WHERE user_id = ?", (user_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Unknown user_id")
    return UserHomeRouteResponse(**dict(row))
