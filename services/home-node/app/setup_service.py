"""First-time setup + network onboarding for owner panel."""
from __future__ import annotations

import hashlib
import secrets
import time
from typing import Any

import httpx

from app.config import settings
from app.network_peers import ROLE_LABELS, STATUS_RU, build_anonymous_peers, fetch_registry_nodes
from app.owner_prefs import effective_participation, effective_owner_percent, load_prefs, save_prefs

ROLE_SCORE = {
    "relay": 90,
    "storage": 75,
    "home": 40,
    "media": 60,
    "witness": 50,
    "gateway": 55,
    "turn": 45,
}


def setup_status() -> dict[str, Any]:
    prefs = load_prefs()
    completed = bool(prefs.get("setup_completed"))
    return {
        "setup_completed": completed,
        "setup_skipped": bool(prefs.get("setup_skipped")),
        "owner_display_name": prefs.get("owner_display_name") or "",
        "panel_admin_login": prefs.get("panel_admin_login") or "",
        "panel_password_configured": bool(prefs.get("panel_admin_password_hash")),
        "setup_steps_done": list(prefs.get("setup_steps_done") or []),
        "discovery_configured": bool(settings.discovery_url),
        "node_id": settings.node_id,
        "cluster_id": settings.cluster_id,
        "participation": effective_participation(),
        "owner_resource_percent": effective_owner_percent(),
    }


def save_profile(
    *,
    owner_display_name: str | None = None,
    panel_admin_login: str | None = None,
    panel_admin_password: str | None = None,
    owner_resource_percent: int | None = None,
    participation: dict | None = None,
) -> dict:
    patch: dict[str, Any] = {}
    if owner_display_name is not None:
        patch["owner_display_name"] = owner_display_name.strip()
    if panel_admin_login is not None:
        patch["panel_admin_login"] = panel_admin_login.strip()
    if panel_admin_password:
        # Local panel credential — recommendations only, not federated auth.
        salt = secrets.token_hex(8)
        digest = hashlib.sha256(f"{salt}:{panel_admin_password}".encode()).hexdigest()
        patch["panel_admin_password_hash"] = f"{salt}${digest}"
    if owner_resource_percent is not None:
        patch["owner_resource_percent"] = max(20, min(100, owner_resource_percent))
    if participation is not None:
        patch["participation"] = participation
    save_prefs(patch)
    return setup_status()


def mark_step(step: str) -> list[str]:
    prefs = load_prefs()
    done = list(prefs.get("setup_steps_done") or [])
    if step not in done:
        done.append(step)
    save_prefs({"setup_steps_done": done})
    return done


def complete_setup(*, skipped: bool = False) -> dict:
    save_prefs({"setup_completed": True, "setup_skipped": skipped})
    return setup_status()


async def check_network_connection() -> dict[str, Any]:
    """Verify Discovery is reachable and this node is in the catalog."""
    if not settings.discovery_url:
        return {
            "ok": False,
            "step": "connect",
            "message": "Discovery не настроен на ноде",
        }
    url = settings.discovery_url.rstrip("/")
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            health = await client.get(f"{url}/health")
            if health.status_code >= 400:
                return {"ok": False, "step": "connect", "message": "Discovery недоступен"}
            reg = await client.get(f"{url}/registry/nodes")
            reg.raise_for_status()
            nodes = reg.json().get("nodes") or []
    except Exception as exc:
        return {"ok": False, "step": "connect", "message": f"Не удалось связаться с сетью: {exc}"}

    ms = round((time.perf_counter() - t0) * 1000)
    self_row = next((n for n in nodes if n.get("node_id") == settings.node_id), None)
    online = (self_row.get("reachability") or self_row.get("status") or "offline") == "online" if self_row else False
    mark_step("connect")
    return {
        "ok": True,
        "step": "connect",
        "message": "Нода в сети" if self_row else "Сеть доступна, регистрация ноды ожидается",
        "latency_ms": ms,
        "registered": bool(self_row),
        "online_in_catalog": online,
        "peers_in_catalog": len(nodes),
    }


async def discover_peers_action() -> dict[str, Any]:
    data = await build_anonymous_peers(probe=True)
    allowed = [p for p in data["peers"] if not p["is_self"] and p["online"]]
    mark_step("discover")
    return {
        "ok": True,
        "step": "discover",
        "message": f"Найдено {len(allowed)} доступных соседей",
        "peers": allowed,
        "summary": data["summary"],
    }


async def _run_benchmark() -> tuple[list[dict], str]:
    nodes = await fetch_registry_nodes()
    if not nodes:
        return [], "Каталог сети пуст"

    results: list[dict] = []
    async with httpx.AsyncClient(timeout=3.0) as client:
        for raw in nodes:
            if raw.get("node_id") == settings.node_id:
                continue
            node_url = raw.get("node_url")
            if not node_url:
                continue
            caps = raw.get("capabilities") or []
            role = str(caps[0]).lower() if caps else "node"
            t0 = time.perf_counter()
            try:
                resp = await client.get(f"{node_url.rstrip('/')}/health")
                ms = round((time.perf_counter() - t0) * 1000)
                ok = resp.status_code < 400
            except Exception:
                ms = None
                ok = False
            if ok:
                idx = len([r for r in results if r["role"] == role]) + 1
                label = ROLE_LABELS.get(role, role.title())
                results.append(
                    {
                        "peer_ref": hashlib.sha256(f"{settings.node_id}|{raw.get('node_id')}".encode()).hexdigest()[:10],
                        "role": role,
                        "role_label": label,
                        "display_name": label if idx == 1 else f"{label} · {idx}",
                        "latency_ms": ms,
                        "online": True,
                        "status": "online",
                        "status_label": STATUS_RU["online"],
                    }
                )

    results.sort(key=lambda r: r.get("latency_ms") or 9999)
    return results, f"Проверено {len(results)} нод по скорости"


async def benchmark_network() -> dict[str, Any]:
    ranked, message = await _run_benchmark()
    mark_step("benchmark")
    return {
        "ok": bool(ranked),
        "step": "benchmark",
        "message": message,
        "ranked": ranked[:12],
    }


async def recommend_peers() -> dict[str, Any]:
    ranked, _ = await _run_benchmark()
    recommendations: list[dict] = []
    for row in ranked:
        role = row["role"]
        latency = row.get("latency_ms") or 999
        if latency > 500:
            continue
        score = ROLE_SCORE.get(role, 30) - min(latency // 10, 40)
        reason = []
        if role == "relay":
            reason.append("быстрая пересылка")
        if role == "storage":
            reason.append("буфер медиа")
        if latency < 80:
            reason.append("низкая задержка")
        recommendations.append(
            {
                **row,
                "score": score,
                "reason": ", ".join(reason) or "онлайн",
            }
        )
    recommendations.sort(key=lambda r: r["score"], reverse=True)
    mark_step("recommend")
    return {
        "ok": bool(recommendations),
        "step": "recommend",
        "message": f"Подобрано {len(recommendations[:5])} лучших вариантов",
        "recommendations": recommendations[:5],
    }


async def auto_setup() -> dict[str, Any]:
    """Skip wizard — apply sensible defaults and run all checks."""
    save_profile(
        owner_resource_percent=40,
        participation={
            "relay": True,
            "storage": True,
            "witness": False,
            "media_cache": False,
            "nat_assist": False,
        },
    )
    results = []
    for fn in (check_network_connection, discover_peers_action, benchmark_network, recommend_peers):
        try:
            results.append(await fn())
        except Exception as exc:
            results.append({"ok": False, "message": str(exc)})
    complete_setup(skipped=True)
    return {"status": "auto_complete", "results": results, **setup_status()}
