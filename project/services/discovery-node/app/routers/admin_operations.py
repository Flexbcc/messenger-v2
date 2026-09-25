"""Discovery administrative vulnerability policy and health operations."""

from fastapi import APIRouter, Depends, HTTPException, Request

from app import policy
from app.config import QUARANTINE_MODES
from app.db import get_conn
from app.deps import require_admin
from app.health import health_check_running, run_health_check_once
from app.routers.admin_common import admin_actor, log_control_action_on
from app.routers.registry import _apply_version_policy
from app.schemas import (
    BlockedVersion,
    BlockedVersionListResponse,
    BlockVersionRequest,
    ForceUpgradeRequest,
    HealthCheckResult,
    HealthCheckRunResponse,
    QuarantineModeRequest,
    VulnerabilityPolicyResponse,
)
from app.trust import now_iso

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


def _reevaluate_all_versions(conn) -> None:
    """Recompute quarantine decisions after a vulnerability policy change."""
    blocked_versions = {
        row["version"]
        for row in conn.execute("SELECT version FROM blocked_versions").fetchall()
    }
    mode_row = conn.execute(
        "SELECT value FROM discovery_settings WHERE key = 'quarantine_mode'"
    ).fetchone()
    quarantine_mode = mode_row["value"] if mode_row else "warn"
    rows = conn.execute(
        "SELECT node_id, software_version FROM node_capabilities"
    ).fetchall()
    for row in rows:
        _apply_version_policy(
            conn,
            row["node_id"],
            row["software_version"],
            blocked_versions=blocked_versions,
            quarantine_mode=quarantine_mode,
        )


def _policy_response() -> VulnerabilityPolicyResponse:
    return VulnerabilityPolicyResponse(
        quarantine_mode=policy.get_quarantine_mode(),
        force_upgrade=policy.get_force_upgrade(),
        blocked_versions=[
            BlockedVersion(**blocked) for blocked in policy.list_blocked_versions()
        ],
    )


@router.get("/vulnerability/policy", response_model=VulnerabilityPolicyResponse)
def get_vulnerability_policy():
    return _policy_response()


@router.get(
    "/vulnerability/blocked-versions",
    response_model=BlockedVersionListResponse,
)
def list_blocked_versions():
    return BlockedVersionListResponse(
        blocked_versions=[
            BlockedVersion(**blocked) for blocked in policy.list_blocked_versions()
        ]
    )


@router.post(
    "/vulnerability/blocked-versions",
    response_model=VulnerabilityPolicyResponse,
)
def block_version(
    payload: BlockVersionRequest,
    request: Request,
    actor: str = Depends(admin_actor),
):
    if not payload.version.strip():
        raise HTTPException(status_code=422, detail="version must not be empty")
    with get_conn() as conn:
        policy.add_blocked_version_on(
            conn, payload.version, payload.reason, now_iso()
        )
        _reevaluate_all_versions(conn)
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action="block-version",
            detail=f"version={payload.version}",
        )
        conn.commit()
    return _policy_response()


@router.delete(
    "/vulnerability/blocked-versions/{version}",
    response_model=VulnerabilityPolicyResponse,
)
def unblock_version(
    version: str,
    request: Request,
    actor: str = Depends(admin_actor),
):
    with get_conn() as conn:
        if not policy.remove_blocked_version_on(conn, version):
            raise HTTPException(status_code=404, detail="Version not in blocked list")
        _reevaluate_all_versions(conn)
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action="unblock-version",
            detail=f"version={version}",
        )
        conn.commit()
    return _policy_response()


@router.put(
    "/vulnerability/quarantine-mode",
    response_model=VulnerabilityPolicyResponse,
)
def set_quarantine_mode(
    payload: QuarantineModeRequest,
    request: Request,
    actor: str = Depends(admin_actor),
):
    mode = payload.mode.lower()
    if mode not in QUARANTINE_MODES:
        raise HTTPException(
            status_code=422,
            detail=f"mode must be one of {sorted(QUARANTINE_MODES)}",
        )
    with get_conn() as conn:
        policy.set_setting_on(conn, "quarantine_mode", mode)
        _reevaluate_all_versions(conn)
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action="set-quarantine-mode",
            detail=f"mode={mode}",
        )
        conn.commit()
    return _policy_response()


@router.put(
    "/vulnerability/force-upgrade",
    response_model=VulnerabilityPolicyResponse,
)
def set_force_upgrade(
    payload: ForceUpgradeRequest,
    request: Request,
    actor: str = Depends(admin_actor),
):
    with get_conn() as conn:
        policy.set_setting_on(
            conn,
            "force_upgrade",
            "true" if payload.force_upgrade else "false",
        )
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action="set-force-upgrade",
            detail=f"enabled={str(payload.force_upgrade).lower()}",
        )
        conn.commit()
    return _policy_response()


@router.post("/monitor/health-check", response_model=HealthCheckRunResponse)
async def trigger_health_check(
    request: Request,
    actor: str = Depends(admin_actor),
):
    if health_check_running():
        raise HTTPException(status_code=409, detail="Health check already running")
    results = await run_health_check_once()
    with get_conn() as conn:
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action="health-check",
            detail=f"checked={len(results)}",
        )
        conn.commit()
    return HealthCheckRunResponse(
        checked=len(results),
        results=[HealthCheckResult(**result) for result in results],
    )
