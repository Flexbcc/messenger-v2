"""Discovery Control Plane admin API (ADR-0009, step 3)."""
from typing import List, Optional
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel

from app.config import QUARANTINE_MODES
from app.db import get_conn
from app.deps import require_admin
from app import policy
from app.health import run_health_check_once
from app.audit import log_admin_action, list_audit_log
from app.schemas import (
    AdminActionResponse,
    AdminAuditListResponse,
    AdminAuditEntry,
    BlockedVersion,
    BlockedVersionListResponse,
    BlockVersionRequest,
    ForceUpgradeRequest,
    HealthCheckResult,
    HealthCheckRunResponse,
    NodeCapabilityListResponse,
    NodeCapabilityResponse,
    PromoteCandidateResponse,
    QuarantineModeRequest,
    ReEnrollResponse,
    SuspendNodeRequest,
    TrustLevelHistoryEntry,
    VulnerabilityPolicyResponse,
)
from app.security import generate_enrollment_secret, hash_value
from app.trust import now_iso
from app.routers.registry import _node_response, _apply_version_policy, _row_field
from app.mesh_notify import schedule_mesh_peer_notify

# --- Trust level promotion thresholds ---
# To move from L0 → L1: need 1000 total messages AND uptime > 3 days AND error_rate < 5%
# To move from L1 → L2: need 5000 total messages AND uptime > 14 days AND error_rate < 2%
PROMOTION_THRESHOLDS = {
    1: {"messages_total": 1_000, "uptime_days": 3,  "max_error_rate": 5.0},
    2: {"messages_total": 5_000, "uptime_days": 14, "max_error_rate": 2.0},
}

TRUST_LEVEL_LABELS = {0: "local", 1: "relay", 2: "hub"}


class PromoteRequest(BaseModel):
    reason: Optional[str] = None


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


def _actor(x_operator_id: str | None = Header(None, alias="X-Operator-Id")) -> str:
    return (x_operator_id or "").strip() or "operator"


def _client_ip(request: Request) -> str:
    """Возвращает IP клиента с учётом X-Forwarded-For (nginx proxy)."""
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _cluster_for(conn, node_id: str) -> str | None:
    row = conn.execute(
        "SELECT cluster_id FROM node_capabilities WHERE node_id = ?", (node_id,)
    ).fetchone()
    return row["cluster_id"] if row else None


@router.get("/registry/nodes", response_model=NodeCapabilityListResponse)
def list_all_nodes():
    """All nodes including pending/suspended — operator view."""
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM node_capabilities ORDER BY node_id").fetchall()
    return NodeCapabilityListResponse(
        nodes=[_node_response(row, last_heartbeat=row["last_heartbeat"]) for row in rows]
    )


@router.get("/audit/history", response_model=AdminAuditListResponse)
def audit_history(limit: int = 100):
    with get_conn() as conn:
        entries = list_audit_log(conn, limit=limit)
    return AdminAuditListResponse(
        entries=[AdminAuditEntry(**e) for e in entries],
        count=len(entries),
    )


@router.post("/registry/nodes/{node_id}/approve", response_model=AdminActionResponse)
def approve_node(node_id: str, request: Request, actor: str = Depends(_actor)):
    now = now_iso()

    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] == "compromised":
            raise HTTPException(status_code=409, detail="Compromised node must be re-enrolled before approval")

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
    node_id: str,
    request: Request,
    payload: SuspendNodeRequest = SuspendNodeRequest(),
    actor: str = Depends(_actor),
):
    now = now_iso()
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
            (now, payload.reason, node_id),
        )
        log_admin_action(
            conn,
            actor=actor,
            action="suspend",
            node_id=node_id,
            cluster_id=row["cluster_id"],
            detail=payload.reason,
            client_ip=_client_ip(request),
        )
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="suspended",
        message="Node suspended",
    )


@router.post("/registry/nodes/{node_id}/reinstate", response_model=AdminActionResponse)
def reinstate_node(node_id: str, request: Request, actor: str = Depends(_actor)):
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        if row["trust_status"] != "suspended":
            raise HTTPException(status_code=409, detail="Only suspended nodes can be reinstated")
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
def compromise_node(node_id: str, request: Request, actor: str = Depends(_actor)):
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
def re_enroll_node(node_id: str, actor: str = Depends(_actor)):
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
def grandfather_all():
    """One-shot: mark all nodes trusted (migration helper for legacy → strict)."""
    with get_conn() as conn:
        conn.execute(
            """
            UPDATE node_capabilities
            SET trust_status = 'trusted'
            WHERE trust_status IN ('unknown', 'pending')
            """
        )
        conn.commit()
        count = conn.execute(
            "SELECT COUNT(*) FROM node_capabilities WHERE trust_status = 'trusted'"
        ).fetchone()[0]
    return AdminActionResponse(
        node_id="*",
        trust_status="trusted",
        message=f"Grandfathered nodes; trusted count={count}",
    )


# --- Trust level promotion -----------------------------------------------

@router.get("/registry/nodes/{node_id}/trust-level/history", response_model=TrustLevelHistoryResponse)
def trust_level_history(node_id: str):
    """Full promotion/demotion history for a node."""
    with get_conn() as conn:
        row = conn.execute("SELECT node_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        entries = conn.execute(
            "SELECT from_level, to_level, reason, actor, changed_at "
            "FROM trust_level_history WHERE node_id = ? ORDER BY changed_at DESC",
            (node_id,),
        ).fetchall()
    return TrustLevelHistoryResponse(
        node_id=node_id,
        history=[TrustLevelHistoryEntry(**dict(e)) for e in entries],
    )


@router.get("/registry/promotion-candidates", response_model=List[PromoteCandidateResponse])
def promotion_candidates():
    """
    Nodes that are trusted + meet thresholds for the next trust level.
    Use this to decide who to promote manually.
    """
    candidates = []
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM node_capabilities WHERE trust_status = 'trusted' ORDER BY trust_level, node_id"
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
def promote_node(node_id: str, payload: PromoteRequest = PromoteRequest(), actor: str = Depends(_actor)):
    """
    Manually promote a node to the next trust level.
    Checks thresholds but operator can override with explicit reason.
    Requires: trust_status=trusted.
    """
    now = now_iso()
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
        if not meets and not payload.reason:
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
                payload.reason or (f"thresholds met: {TRUST_LEVEL_LABELS.get(target_level, str(target_level))}"),
                actor, now,
            ),
        )
        log_admin_action(
            conn, actor=actor, action="promote",
            node_id=node_id, cluster_id=_cluster_for(conn, node_id),
            detail=f"L{current_level}→L{target_level}",
        )
        conn.commit()

    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message=f"Node promoted to trust_level={target_level} ({TRUST_LEVEL_LABELS.get(target_level, '')})",
    )


@router.post("/registry/nodes/{node_id}/demote", response_model=AdminActionResponse)
def demote_node(node_id: str, payload: PromoteRequest = PromoteRequest(), actor: str = Depends(_actor)):
    """Manually demote a node's trust level by one step."""
    now = now_iso()
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
            (node_id, current_level, target_level, payload.reason or "manual demotion", actor, now),
        )
        log_admin_action(
            conn, actor=actor, action="demote",
            node_id=node_id, cluster_id=_cluster_for(conn, node_id),
            detail=f"L{current_level}→L{target_level}",
        )
        conn.commit()

    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message=f"Node demoted to trust_level={target_level} ({TRUST_LEVEL_LABELS.get(target_level, '')})",
    )


# --- Vulnerability response (ADR-model vulnerability-response.md) -----------

def _reevaluate_all_versions() -> None:
    """Recompute version_status/quarantine_action for every node after a policy change."""
    with get_conn() as conn:
        rows = conn.execute("SELECT node_id, software_version FROM node_capabilities").fetchall()
        for row in rows:
            _apply_version_policy(conn, row["node_id"], row["software_version"])
        conn.commit()


def _policy_response() -> VulnerabilityPolicyResponse:
    return VulnerabilityPolicyResponse(
        quarantine_mode=policy.get_quarantine_mode(),
        force_upgrade=policy.get_force_upgrade(),
        blocked_versions=[BlockedVersion(**bv) for bv in policy.list_blocked_versions()],
    )


@router.get("/vulnerability/policy", response_model=VulnerabilityPolicyResponse)
def get_vulnerability_policy():
    return _policy_response()


@router.get("/vulnerability/blocked-versions", response_model=BlockedVersionListResponse)
def list_blocked_versions():
    return BlockedVersionListResponse(
        blocked_versions=[BlockedVersion(**bv) for bv in policy.list_blocked_versions()]
    )


@router.post("/vulnerability/blocked-versions", response_model=VulnerabilityPolicyResponse)
def block_version(payload: BlockVersionRequest):
    if not payload.version.strip():
        raise HTTPException(status_code=422, detail="version must not be empty")
    policy.add_blocked_version(payload.version, payload.reason, now_iso())
    _reevaluate_all_versions()
    return _policy_response()


@router.delete("/vulnerability/blocked-versions/{version}", response_model=VulnerabilityPolicyResponse)
def unblock_version(version: str):
    if not policy.remove_blocked_version(version):
        raise HTTPException(status_code=404, detail="Version not in blocked list")
    _reevaluate_all_versions()
    return _policy_response()


@router.put("/vulnerability/quarantine-mode", response_model=VulnerabilityPolicyResponse)
def set_quarantine_mode(payload: QuarantineModeRequest):
    mode = payload.mode.lower()
    if mode not in QUARANTINE_MODES:
        raise HTTPException(status_code=422, detail=f"mode must be one of {sorted(QUARANTINE_MODES)}")
    policy.set_setting("quarantine_mode", mode)
    _reevaluate_all_versions()
    return _policy_response()


@router.put("/vulnerability/force-upgrade", response_model=VulnerabilityPolicyResponse)
def set_force_upgrade(payload: ForceUpgradeRequest):
    policy.set_setting("force_upgrade", "true" if payload.force_upgrade else "false")
    return _policy_response()


# --- Active health-check ---------------------------------------------------

@router.post("/monitor/health-check", response_model=HealthCheckRunResponse)
async def trigger_health_check():
    """Probe every registered node's /health once and persist the result."""
    results = await run_health_check_once()
    return HealthCheckRunResponse(
        checked=len(results),
        results=[HealthCheckResult(**r) for r in results],
    )
