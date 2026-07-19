from typing import Optional
from fastapi import APIRouter, HTTPException, Header, Query
import json

from app.config import ENROLLMENT_MODE
from app.db import get_conn
from app.schemas import (
    RegisterUserRecord,
    UserRecordResponse,
    RegisterNodeCapability,
    HeartbeatRequest,
    NodeCapabilityResponse,
    NodeCapabilityListResponse,
    RegisterNodeResponse,
)
from app.security import generate_enrollment_secret, hash_value, verify_hash
from app.attestation_flow import apply_attestation
from app.trust import enrollment_required, initial_trust_status_for_register, now_iso, reachability_for
from app.policy import blocked_version_set, get_quarantine_mode, evaluate_version
from app.mesh_notify import schedule_mesh_peer_notify, should_notify_on_register

router = APIRouter()


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
        reachability=reachability,
        last_heartbeat=last_heartbeat,
        status=reachability,
        health_status=_row_field(row, "health_status"),
        last_health_check=_row_field(row, "last_health_check"),
        version_status=_row_field(row, "version_status", "ok"),
        quarantine_action=_row_field(row, "quarantine_action", "off"),
        **att,
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
        conn.execute(
            """
            INSERT INTO user_records (user_id, home_node_url, display_name, auth_public_key, cluster_id, login, username_search_enabled, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                home_node_url=excluded.home_node_url,
                display_name=excluded.display_name,
                auth_public_key=excluded.auth_public_key,
                cluster_id=excluded.cluster_id,
                login=COALESCE(excluded.login, user_records.login),
                username_search_enabled=excluded.username_search_enabled,
                updated_at=excluded.updated_at
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
            ),
        )
        conn.commit()
    return UserRecordResponse(
        user_id=payload.user_id,
        home_node_url=payload.home_node_url,
        display_name=payload.display_name,
        auth_public_key=payload.auth_public_key,
        cluster_id=payload.cluster_id,
        login=payload.login,
        username_search_enabled=payload.username_search_enabled,
        updated_at=now,
    )


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
    return UserRecordResponse(**data)


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
    return UserRecordResponse(**data)


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

        conn.execute(
            """
            INSERT INTO node_capabilities (
                node_id, node_url, capabilities, software_version, cluster_id,
                last_heartbeat, trust_status, registered_at, enrollment_secret_hash,
                build_hash, tls_cert_fingerprint, release_signature,
                attestation_status, attestation_detail, signing_public_key
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                payload.signing_public_key,
            ),
        )
        _apply_version_policy(conn, payload.node_id, payload.software_version)
        row = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
        notify = should_notify_on_register(existing, payload, _trust_from_row(row))
        conn.commit()

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

        version = payload.software_version or row["software_version"]
        att_status, att_detail = apply_attestation(
            node_id=node_id,
            software_version=version,
            build_hash=payload.build_hash,
            tls_cert_fingerprint=payload.tls_cert_fingerprint,
            release_signature=payload.release_signature,
            existing_row=row,
        )
        conn.execute(
            """
            UPDATE node_capabilities SET
                last_heartbeat = ?,
                software_version = ?,
                build_hash = COALESCE(?, build_hash),
                tls_cert_fingerprint = COALESCE(?, tls_cert_fingerprint),
                release_signature = COALESCE(?, release_signature),
                attestation_status = ?,
                attestation_detail = ?,
                signing_public_key = COALESCE(?, signing_public_key)
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
                payload.signing_public_key,
                node_id,
            ),
        )
        _apply_version_policy(conn, node_id, version)
        conn.commit()
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()

    return _node_response(row, last_heartbeat=now)


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
