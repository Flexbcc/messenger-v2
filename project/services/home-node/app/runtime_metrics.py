"""Host + node runtime metrics for the Home Node monitor (no PII)."""
from __future__ import annotations

import os
import shutil
from pathlib import Path


def _uptime_sec() -> float | None:
    try:
        with open("/proc/uptime", encoding="utf-8") as f:
            return float(f.read().split()[0])
    except OSError:
        return None


def _mem_bytes() -> dict[str, int]:
    try:
        info: dict[str, int] = {}
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                key, rest = line.split(":", 1)
                info[key.strip()] = int(rest.split()[0]) * 1024
        total = info.get("MemTotal", 0)
        available = info.get("MemAvailable", info.get("MemFree", 0))
        return {"ram_total_bytes": total, "ram_used_bytes": max(0, total - available)}
    except OSError:
        return {}


def collect_host_metrics(data_path: str = "/data") -> dict:
    load = os.getloadavg() if hasattr(os, "getloadavg") else (0.0, 0.0, 0.0)
    cpus = os.cpu_count() or 1
    disk_path = data_path if Path(data_path).exists() else "/"
    try:
        disk = shutil.disk_usage(disk_path)
        disk_used, disk_total = disk.used, disk.total
    except OSError:
        disk_used, disk_total = 0, 0

    mem = _mem_bytes()
    uptime = _uptime_sec()
    ram_total = mem.get("ram_total_bytes", 0)
    ram_used = mem.get("ram_used_bytes", 0)
    return {
        "cpu_load_1m": round(load[0], 2),
        "cpu_cores": cpus,
        "cpu_percent_est": min(100, round((load[0] / cpus) * 100)),
        **mem,
        "ram_percent": round((ram_used / ram_total) * 100) if ram_total else None,
        "disk_used_bytes": disk_used,
        "disk_total_bytes": disk_total,
        "disk_percent": round((disk_used / disk_total) * 100) if disk_total else None,
        "disk_path": disk_path,
        "uptime_sec": round(uptime) if uptime is not None else None,
    }


def compute_health_score(metrics: dict, ws_connections: int) -> int:
    """
    Composite 0–100 score for routing and UI.

    Disk penalty is soft: Docker Desktop / shared host volumes are often near
    capacity and must not alone mark a healthy node as Overloaded.
    Primary drivers: CPU, RAM, connection pressure.
    """
    score = 100.0

    ram_pct = (metrics.get("ram_percent") or 0) / 100.0
    if ram_pct > 0.92:
        score -= 28
    elif ram_pct > 0.80:
        score -= 14
    elif ram_pct > 0.70:
        score -= 6

    disk_pct = (metrics.get("disk_percent") or 0) / 100.0
    if disk_pct > 0.98:
        score -= 18
    elif disk_pct > 0.95:
        score -= 10
    elif disk_pct > 0.90:
        score -= 5

    cpu_pct = metrics.get("cpu_percent_est") or 0
    if cpu_pct > 90:
        score -= 30
    elif cpu_pct > 70:
        score -= 15
    elif cpu_pct > 50:
        score -= 6

    if ws_connections > 200:
        score -= 20
    elif ws_connections > 100:
        score -= 10
    elif ws_connections > 50:
        score -= 5

    return max(0, min(100, int(round(score))))


def runtime_status_label(health_score: int, metrics: dict, ws_connections: int) -> str:
    cpu = metrics.get("cpu_percent_est") or 0
    ram_pct = metrics.get("ram_percent") or 0

    if health_score < 40 or cpu >= 95 or ram_pct >= 95:
        return "critical"
    if health_score < 55 or cpu >= 85 or ws_connections > 100:
        return "overloaded"
    if health_score < 75 or cpu >= 60 or ws_connections > 40:
        return "busy"
    return "normal"


def status_label_ru(status: str) -> str:
    return {
        "normal": "Норма",
        "busy": "Нагрузка",
        "overloaded": "Перегруз",
        "critical": "Критично",
        "offline": "Оффлайн",
        "online": "Онлайн",
    }.get(status, status)
