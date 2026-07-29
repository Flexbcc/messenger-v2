from typing import Optional
from fastapi import APIRouter, HTTPException, Header, Query
import json

from app.config import ENROLLMENT_MODE
from app.db import get_conn
from app.schemas import (
    RegisterUserRecord,
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
from app.record_signer import sign_user_record, discovery_public_key_b64

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
            """SELECT node_id, node_url, capabilities, cluster_id, trust_level
               FROM node_capabilities
               WHERE trust_status = 'trusted'
                 AND last_heartbeat >= ?
                 AND node_id != ?""",
            (cutoff, exclude_node_id),
        ).fetchall()

    peers = []
    for r in rows:
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
                payload.signing_public_key,
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
