"""Discovery Control Plane admin API (ADR-0009, step 3)."""
from datetime import datetime, timezone
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from app.config import (
    ALLOW_LEGACY_GRANDFATHER_ALL,
    RECOVERY_AUTHORITY_STATE_PATH,
    TRUST_AUTHORITY_STATE_PATH,
    TRUST_LEDGER_MODE,
)
from app.db import get_conn
from app.deps import require_admin
from app.audit import log_admin_action, list_audit_log
from app.schemas import (
    AdminActionResponse,
    AdminAuditListResponse,
    AdminAuditEntry,
    NodeCapabilityListResponse,
    NodeCapabilityResponse,
    PromoteCandidateResponse,
    ReEnrollResponse,
    SuspendNodeRequest,
    TrustLevelHistoryEntry,
    AuthorityRecoveryRequest,
    AuthorityRecoveryResponse,
)
from app.security import generate_enrollment_secret, hash_value
from app.trust import now_iso
from app.routers.registry import _node_response, _row_field
from app.routers.admin_common import (
    AdminNodeId,
    admin_actor as _actor,
    audit_reason as _audit_reason,
    client_ip as _client_ip,
)
from app.mesh_notify import schedule_mesh_peer_notify
from app.network_guard import get_network_view_guard, require_governance_available
from app.trust_admission import node_trust_denial_at, require_node_trust_active
from app.authority_checkpoint_store import (
    AuthorityCheckpointConflict,
    publish_authority_recovery,
)
from shared.security.capability_enrollment import load_capability_authority_state

# --- Trust level promotion thresholds ---
# To move from L0 → L1: need 1000 total messages AND uptime > 3 days AND error_rate < 5%
# To move from L1 → L2: need 5000 total messages AND uptime > 14 days AND error_rate < 2%
PROMOTION_THRESHOLDS = {
    1: {"messages_total": 1_000, "uptime_days": 3,  "max_error_rate": 5.0},
    2: {"messages_total": 5_000, "uptime_days": 14, "max_error_rate": 2.0},
}

TRUST_LEVEL_LABELS = {0: "local", 1: "relay", 2: "hub"}
MAX_ADMIN_PAGE_SIZE = 1000


class PromoteRequest(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=1000)


class TrustLevelHistoryResponse(BaseModel):
    node_id: str
    history: List[TrustLevelHistoryEntry]


def _check_promotion_thresholds(row, target_level: int) -> tuple[bool, list[str]]:
    """Returns (meets_threshold, list_of_missing_criteria)."""
    thresholds = PROMOTION_THRESHOLDS.get(target_level)
    if thresholds is None:
        return False, [f"No thresholds defined for level {target_level}"]

    missing = []
    messages_total = _row_field(row, "messages_total") or 0
    uptime_sec = _row_field(row, "uptime_sec") or 0
    error_rate = _row_field(row, "error_rate_pct") or 0.0
    uptime_days = uptime_sec / 86400

    if messages_total < thresholds["messages_total"]:
        missing.append(
            f"messages_total {messages_total} < {thresholds['messages_total']}"
        )
    if uptime_days < thresholds["uptime_days"]:
        missing.append(
            f"uptime {uptime_days:.1f}d < {thresholds['uptime_days']}d"
        )
    if error_rate > thresholds["max_error_rate"]:
        missing.append(
            f"error_rate {error_rate:.1f}% > {thresholds['max_error_rate']}%"
        )
    return len(missing) == 0, missing

RE_ENROLLABLE_STATUSES = ("compromised", "suspended")

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


def _cluster_for(conn, node_id: str) -> str | None:
    row = conn.execute(
        "SELECT cluster_id FROM node_capabilities WHERE node_id = ?", (node_id,)
    ).fetchone()
    return row["cluster_id"] if row else None


@router.get("/registry/nodes", response_model=NodeCapabilityListResponse)
def list_all_nodes(
    limit: int = Query(500, ge=1, le=MAX_ADMIN_PAGE_SIZE),
    offset: int = Query(0, ge=0, le=10_000_000),
):
    """All nodes including pending/suspended — operator view."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM node_capabilities ORDER BY node_id LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()
    return NodeCapabilityListResponse(
        nodes=[_node_response(row, last_heartbeat=row["last_heartbeat"]) for row in rows]
    )


@router.get("/audit/history", response_model=AdminAuditListResponse)
def audit_history(limit: int = Query(100, ge=1, le=500)):
    with get_conn() as conn:
        entries = list_audit_log(conn, limit=limit)
    return AdminAuditListResponse(
        entries=[AdminAuditEntry(**e) for e in entries],
        count=len(entries),
    )


@router.post("/authority/recovery", response_model=AuthorityRecoveryResponse)
def recover_authority(
    payload: AuthorityRecoveryRequest,
    request: Request,
    actor: str = Depends(_actor),
):
    """Apply a threshold offline recovery only while control plane is frozen."""
    guard = get_network_view_guard()
    before = guard.decision()
    if before.governance_allowed:
        raise HTTPException(
            status_code=409,
            detail="emergency authority recovery requires frozen control plane",
        )
    try:
        recovery_state = load_capability_authority_state(
            RECOVERY_AUTHORITY_STATE_PATH
        )
        bootstrap_state = load_capability_authority_state(
            TRUST_AUTHORITY_STATE_PATH
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid recovery trust state: {exc}")
    if recovery_state is None:
        raise HTTPException(status_code=503, detail="offline recovery public state is unavailable")
    if bootstrap_state is None:
        raise HTTPException(status_code=503, detail="bootstrap authority state is unavailable")
    try:
        recovery_hash, replacement_hash, authority_epoch, accepted = (
            publish_authority_recovery(
                payload.recovery,
                recovery_state=recovery_state,
                bootstrap_state=bootstrap_state,
                minimum_authority_epoch=before.highest_epoch,
            )
        )
    except AuthorityCheckpointConflict as exc:
        guard.force_freeze("conflicting emergency AuthorityRecovery objects detected")
        raise HTTPException(status_code=409, detail=str(exc))
    after = guard.apply_recovery_checkpoint(
        authority_epoch=authority_epoch,
        checkpoint_hash=replacement_hash,
        quorum_verified=True,
    )
    with get_conn() as conn:
        log_admin_action(
            conn,
            actor=actor,
            action="authority_recovery",
            node_id="authority-control-plane",
            detail=(
                f"epoch={authority_epoch}; recovery_hash={recovery_hash}; "
                f"replacement_hash={replacement_hash}"
            ),
            client_ip=_client_ip(request),
        )
        conn.commit()
    return AuthorityRecoveryResponse(
        recovery_hash=recovery_hash,
        replacement_checkpoint_hash=replacement_hash,
        authority_epoch=authority_epoch,
        accepted=accepted,
        governance_allowed=after.governance_allowed,
    )


@router.post("/registry/nodes/{node_id}/approve", response_model=AdminActionResponse)
def approve_node(node_id: AdminNodeId, request: Request, actor: str = Depends(_actor)):
    now = now_iso()

    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] == "compromised":
            raise HTTPException(status_code=409, detail="Compromised node must be re-enrolled before approval")
        identity_node_id = _row_field(row, "identity_node_id")
        if identity_node_id:
            require_node_trust_active(
                identity_node_id, at_time=datetime.now(timezone.utc)
            )

        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'trusted',
                node_token_hash = NULL,
                token_issued_at = NULL,
                token_claimed_at = NULL,
                approved_at = ?,
                approved_by = ?,
                suspended_at = NULL,
                suspension_reason = NULL
            WHERE node_id = ?
            """,
            (now, actor, node_id),
        )
        log_admin_action(conn, actor=actor, action="approve", node_id=node_id, cluster_id=row["cluster_id"], client_ip=_client_ip(request))
        conn.commit()
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()

    if row:
        schedule_mesh_peer_notify(dict(row), reason="approve")

    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message="Node approved. It will receive node_token via POST /registry/enrollment/status (one-time claim).",
    )


@router.post("/registry/nodes/{node_id}/suspend", response_model=AdminActionResponse)
def suspend_node(
    node_id: AdminNodeId,
    request: Request,
    payload: SuspendNodeRequest = SuspendNodeRequest(),
    actor: str = Depends(_actor),
):
    now = now_iso()
    reason = _audit_reason(payload.reason)
    with get_conn() as conn:
        row = conn.execute("SELECT node_id, cluster_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'suspended',
                suspended_at = ?,
                suspension_reason = ?
            WHERE node_id = ?
            """,
            (now, reason, node_id),
        )
        log_admin_action(
            conn,
            actor=actor,
            action="suspend",
            node_id=node_id,
            cluster_id=row["cluster_id"],
            detail=reason,
            client_ip=_client_ip(request),
        )
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="suspended",
        message="Node suspended",
    )


@router.post("/registry/nodes/{node_id}/reinstate", response_model=AdminActionResponse)
def reinstate_node(node_id: AdminNodeId, request: Request, actor: str = Depends(_actor)):
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] != "suspended":
            raise HTTPException(status_code=409, detail="Only suspended nodes can be reinstated")
        identity_node_id = _row_field(row, "identity_node_id")
        if identity_node_id:
            require_node_trust_active(
                identity_node_id, at_time=datetime.now(timezone.utc)
            )
        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'trusted',
                suspended_at = NULL,
                suspension_reason = NULL
            WHERE node_id = ?
            """,
            (node_id,),
        )
        log_admin_action(conn, actor=actor, action="reinstate", node_id=node_id, cluster_id=row["cluster_id"], client_ip=_client_ip(request))
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message="Node reinstated",
    )


@router.post("/registry/nodes/{node_id}/compromise", response_model=AdminActionResponse)
def compromise_node(node_id: AdminNodeId, request: Request, actor: str = Depends(_actor)):
    with get_conn() as conn:
        row = conn.execute("SELECT node_id, cluster_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'compromised',
                node_token_hash = NULL,
                token_issued_at = NULL,
                token_claimed_at = NULL,
                suspended_at = NULL,
                suspension_reason = NULL
            WHERE node_id = ?
            """,
            (node_id,),
        )
        log_admin_action(conn, actor=actor, action="compromise", node_id=node_id, cluster_id=row["cluster_id"], client_ip=_client_ip(request))
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="compromised",
        message="Node marked compromised; token revoked",
    )


@router.post("/registry/nodes/{node_id}/re-enroll", response_model=ReEnrollResponse)
def re_enroll_node(
    node_id: AdminNodeId,
    request: Request,
    actor: str = Depends(_actor),
):
    """
    Explicit recovery path for compromised/suspended nodes (Post-R5 fix,
    see docs/reality/R5-security-as-is.md Gaps). Unlike approve, this is not
    blocked by the compromised-sticky guard: it deliberately resets the node
    to `pending` and issues a brand-new enrollment_secret (revoking the old
    node_token), so it must complete the enrollment handshake again before an
    operator approves it — same as a fresh strict registration.
    """
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] not in RE_ENROLLABLE_STATUSES:
            raise HTTPException(
                status_code=409,
                detail=f"Only {'/'.join(RE_ENROLLABLE_STATUSES)} nodes can be re-enrolled",
            )
        identity_node_id = _row_field(row, "identity_node_id")
        if identity_node_id:
            require_node_trust_active(
                identity_node_id, at_time=datetime.now(timezone.utc)
            )

        enrollment_secret_plain = generate_enrollment_secret()
        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'pending',
                enrollment_secret_hash = ?,
                node_token_hash = NULL,
                token_issued_at = NULL,
                token_claimed_at = NULL,
                approved_at = NULL,
                approved_by = NULL,
                suspended_at = NULL,
                suspension_reason = NULL
            WHERE node_id = ?
            """,
            (hash_value(enrollment_secret_plain), node_id),
        )
        log_admin_action(
            conn,
            actor=actor,
            action="re-enroll",
            node_id=node_id,
            cluster_id=row["cluster_id"],
            detail=f"from {row['trust_status']}",
            client_ip=_client_ip(request),
        )
        conn.commit()

    return ReEnrollResponse(
        node_id=node_id,
        trust_status="pending",
        message="Node reset to pending. Give it the enrollment_secret to poll "
        "POST /registry/enrollment/status, then approve once it appears again.",
        enrollment_secret=enrollment_secret_plain,
    )


@router.post("/registry/grandfather-all", response_model=AdminActionResponse)
def grandfather_all(request: Request, actor: str = Depends(_actor)):
    """One-shot: mark all nodes trusted (migration helper for legacy → strict)."""
    require_governance_available()
    if not ALLOW_LEGACY_GRANDFATHER_ALL:
        raise HTTPException(
            status_code=403,
            detail="legacy bulk enrollment is disabled",
        )
    if TRUST_LEDGER_MODE == "enforce":
        raise HTTPException(
            status_code=409,
            detail="legacy bulk enrollment is incompatible with enforced Trust Ledger",
        )
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT node_id, identity_node_id FROM node_capabilities
               WHERE trust_status IN ('unknown', 'pending')"""
        )
        newly_trusted = 0
        now = datetime.now(timezone.utc)
        for row in rows:
            identity_node_id = _row_field(row, "identity_node_id")
            if identity_node_id and node_trust_denial_at(
                identity_node_id, at_time=now
            ) is not None:
                continue
            conn.execute(
                "UPDATE node_capabilities SET trust_status = 'trusted' "
                "WHERE node_id = ?",
                (row["node_id"],),
            )
            newly_trusted += 1
        count = conn.execute(
            "SELECT COUNT(*) FROM node_capabilities WHERE trust_status = 'trusted'"
        ).fetchone()[0]
        log_admin_action(
            conn,
            actor=actor,
            action="grandfather-all",
            node_id="*",
            detail=f"newly_trusted={newly_trusted}; trusted_total={count}",
            client_ip=_client_ip(request),
        )
        conn.commit()
    return AdminActionResponse(
        node_id="*",
        trust_status="trusted",
        message=f"Grandfathered nodes; trusted count={count}",
    )


# --- Trust level promotion -----------------------------------------------

@router.get("/registry/nodes/{node_id}/trust-level/history", response_model=TrustLevelHistoryResponse)
def trust_level_history(
    node_id: AdminNodeId,
    limit: int = Query(500, ge=1, le=MAX_ADMIN_PAGE_SIZE),
    offset: int = Query(0, ge=0, le=10_000_000),
):
    """Full promotion/demotion history for a node."""
    with get_conn() as conn:
        row = conn.execute("SELECT node_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        entries = conn.execute(
            "SELECT from_level, to_level, reason, actor, changed_at "
            "FROM trust_level_history WHERE node_id = ? "
            "ORDER BY changed_at DESC, rowid DESC LIMIT ? OFFSET ?",
            (node_id, limit, offset),
        ).fetchall()
    return TrustLevelHistoryResponse(
        node_id=node_id,
        history=[TrustLevelHistoryEntry(**dict(e)) for e in entries],
    )


@router.get("/registry/promotion-candidates", response_model=List[PromoteCandidateResponse])
def promotion_candidates(
    limit: int = Query(500, ge=1, le=MAX_ADMIN_PAGE_SIZE),
    offset: int = Query(0, ge=0, le=10_000_000),
):
    """
    Nodes that are trusted + meet thresholds for the next trust level.
    Use this to decide who to promote manually.
    """
    candidates = []
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM node_capabilities WHERE trust_status = 'trusted' "
            "AND COALESCE(trust_level, 0) < 2 "
            "ORDER BY trust_level, node_id LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()
    for row in rows:
        current_level = _row_field(row, "trust_level") or 0
        target_level = current_level + 1
        if target_level not in PROMOTION_THRESHOLDS:
            continue
        meets, missing = _check_promotion_thresholds(row, target_level)
        candidates.append(PromoteCandidateResponse(
            node_id=row["node_id"],
            trust_level=current_level,
            trust_status=row["trust_status"],
            messages_total=_row_field(row, "messages_total"),
            messages_24h=_row_field(row, "messages_24h"),
            uptime_sec=_row_field(row, "uptime_sec"),
            error_rate_pct=_row_field(row, "error_rate_pct"),
            meets_threshold=meets,
            missing=missing,
        ))
    return candidates


@router.post("/registry/nodes/{node_id}/promote", response_model=AdminActionResponse)
def promote_node(
    node_id: AdminNodeId,
    request: Request,
    payload: PromoteRequest = PromoteRequest(),
    actor: str = Depends(_actor),
):
    """
    Manually promote a node to the next trust level.
    Checks thresholds but operator can override with explicit reason.
    Requires: trust_status=trusted.
    """
    require_governance_available()
    if TRUST_LEDGER_MODE == "enforce":
        raise HTTPException(
            status_code=409,
            detail="manual promotion is disabled; quorum TrustRecord required",
        )
    now = now_iso()
    reason = _audit_reason(payload.reason)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] != "trusted":
            raise HTTPException(
                status_code=409,
                detail=f"Node must be trusted to promote (current: {row['trust_status']})"
            )
        current_level = _row_field(row, "trust_level") or 0
        target_level = current_level + 1
        if target_level > 2:
            raise HTTPException(status_code=409, detail="Node is already at maximum trust level (2=hub)")

        meets, missing = _check_promotion_thresholds(row, target_level)
        if not meets and not reason:
            raise HTTPException(
                status_code=422,
                detail={
                    "message": "Thresholds not met. Provide a reason to override.",
                    "missing": missing,
                },
            )

        conn.execute(
            "UPDATE node_capabilities SET trust_level = ?, trust_level_updated_at = ? WHERE node_id = ?",
            (target_level, now, node_id),
        )
        conn.execute(
            """INSERT INTO trust_level_history
               (node_id, from_level, to_level, reason, actor, changed_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                node_id, current_level, target_level,
                reason or (f"thresholds met: {TRUST_LEVEL_LABELS.get(target_level, str(target_level))}"),
                actor, now,
            ),
        )
        log_admin_action(
            conn, actor=actor, action="promote",
            node_id=node_id, cluster_id=_cluster_for(conn, node_id),
            detail=f"L{current_level}→L{target_level}",
            client_ip=_client_ip(request),
        )
        conn.commit()

    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message=f"Node promoted to trust_level={target_level} ({TRUST_LEVEL_LABELS.get(target_level, '')})",
    )


@router.post("/registry/nodes/{node_id}/demote", response_model=AdminActionResponse)
def demote_node(
    node_id: AdminNodeId,
    request: Request,
    payload: PromoteRequest = PromoteRequest(),
    actor: str = Depends(_actor),
):
    """Manually demote a node's trust level by one step."""
    require_governance_available()
    if TRUST_LEDGER_MODE == "enforce":
        raise HTTPException(
            status_code=409,
            detail="manual demotion is disabled; quorum TrustRecord required",
        )
    now = now_iso()
    reason = _audit_reason(payload.reason)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        current_level = _row_field(row, "trust_level") or 0
        if current_level == 0:
            raise HTTPException(status_code=409, detail="Node is already at minimum trust level (0=local)")
        target_level = current_level - 1
        conn.execute(
            "UPDATE node_capabilities SET trust_level = ?, trust_level_updated_at = ? WHERE node_id = ?",
            (target_level, now, node_id),
        )
        conn.execute(
            """INSERT INTO trust_level_history
               (node_id, from_level, to_level, reason, actor, changed_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (node_id, current_level, target_level, reason or "manual demotion", actor, now),
        )
        log_admin_action(
            conn, actor=actor, action="demote",
            node_id=node_id, cluster_id=_cluster_for(conn, node_id),
            detail=f"L{current_level}→L{target_level}",
            client_ip=_client_ip(request),
        )
        conn.commit()

    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message=f"Node demoted to trust_level={target_level} ({TRUST_LEVEL_LABELS.get(target_level, '')})",
    )
