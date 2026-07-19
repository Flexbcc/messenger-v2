"""Discovery Control Plane admin API (ADR-0009, step 3)."""
from fastapi import APIRouter, Depends, HTTPException

from app.config import QUARANTINE_MODES
from app.db import get_conn
from app.deps import require_admin
from app import policy
from app.health import run_health_check_once
from app.schemas import (
    AdminActionResponse,
    BlockedVersion,
    BlockedVersionListResponse,
    BlockVersionRequest,
    ForceUpgradeRequest,
    HealthCheckResult,
    HealthCheckRunResponse,
    NodeCapabilityListResponse,
    QuarantineModeRequest,
    SuspendNodeRequest,
    VulnerabilityPolicyResponse,
)
from app.trust import now_iso
from app.routers.registry import _node_response, _apply_version_policy
from app.mesh_notify import schedule_mesh_peer_notify

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


@router.get("/registry/nodes", response_model=NodeCapabilityListResponse)
def list_all_nodes():
    """All nodes including pending/suspended — operator view."""
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM node_capabilities ORDER BY node_id").fetchall()
    return NodeCapabilityListResponse(
        nodes=[_node_response(row, last_heartbeat=row["last_heartbeat"]) for row in rows]
    )


@router.post("/registry/nodes/{node_id}/approve", response_model=AdminActionResponse)
def approve_node(node_id: str):
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
                approved_by = 'admin',
                suspended_at = NULL,
                suspension_reason = NULL
            WHERE node_id = ?
            """,
            (now, node_id),
        )
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
def suspend_node(node_id: str, payload: SuspendNodeRequest = SuspendNodeRequest()):
    now = now_iso()
    with get_conn() as conn:
        row = conn.execute("SELECT node_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
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
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="suspended",
        message="Node suspended",
    )


@router.post("/registry/nodes/{node_id}/reinstate", response_model=AdminActionResponse)
def reinstate_node(node_id: str):
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
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="trusted",
        message="Node reinstated",
    )


@router.post("/registry/nodes/{node_id}/compromise", response_model=AdminActionResponse)
def compromise_node(node_id: str):
    with get_conn() as conn:
        row = conn.execute("SELECT node_id FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id")
        conn.execute(
            """
            UPDATE node_capabilities SET
                trust_status = 'compromised',
                node_token_hash = NULL,
                token_issued_at = NULL,
                token_claimed_at = NULL
            WHERE node_id = ?
            """,
            (node_id,),
        )
        conn.commit()
    return AdminActionResponse(
        node_id=node_id,
        trust_status="compromised",
        message="Node marked compromised; token revoked",
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
