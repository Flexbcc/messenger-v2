#!/usr/bin/env python3
"""
Демо-режим пульта — посмотреть интерфейс без серверов и Docker.

ЗАЧЕМ
    Проверить, удобно ли пользоваться, до того как поднимать федерацию.
    Данные выдуманные, но структура ответов ровно та же, что у настоящего
    admin-server — значит по внешнему виду можно судить о реальном.

ЧЕГО ЗДЕСЬ НЕТ
    Кнопки действий отвечают «так точно», но ничего не делают.
    Никаких сертификатов и SSH — соединений наружу не происходит вовсе.

ЗАПУСК
    python3 demo_server.py
    открыть http://127.0.0.1:9301

Работает на стандартной библиотеке: ни FastAPI, ни Docker не нужны.
"""
from __future__ import annotations

import json
import random
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = 9301
ADMIN_DIR = Path(__file__).resolve().parent.parent / "project" / "admin"


# ── Выдуманное, но правдоподобное состояние федерации ───────────────────────

def _nodes() -> dict:
    base = [
        ("core",     True,  "trusted",   "online"),
        ("client-1", False, "trusted",   "online"),
        ("client-2", False, "trusted",   "online"),
        ("client-3", False, "pending",   "offline"),
        ("friend-a", False, "trusted",   "online"),
        ("friend-b", False, "suspended", "offline"),
    ]
    out = []
    for node_id, owned, trust, reach in base:
        online = reach == "online"
        out.append({
            "node_id": node_id,
            "is_owned": owned,
            "trust_level": trust,
            "trust_status": trust,
            "reachability": reach,
            "software_version": "0.9.3" if node_id != "friend-b" else "0.8.1",
            "metrics": {
                "cpu_percent_est": random.randint(4, 61) if online else None,
                "ram_percent": random.randint(28, 74) if online else None,
                "disk_percent": random.randint(18, 55) if online else None,
                "messages_24h": random.randint(120, 9800) if online else 0,
                "ws_connections": random.randint(1, 42) if online else 0,
                "uptime_sec": random.randint(3600, 900000) if online else 0,
            },
        })
    return {"nodes": out}


def _services() -> dict:
    inv = [
        ("discovery-node", "main",   True),
        ("gateway-node",   "main",   True),
        ("home-node",      "worker", True),
        ("storage-node",   "worker", True),
        ("media-node",     "worker", True),
        ("relay-node",     "worker", False),
        ("turn-node",      "worker", True),
    ]
    return {
        "services": [
            {
                "service": svc,
                "host_alias": host,
                "running": up,
                "ps_line": (
                    f"{svc}  Up {random.randint(2, 340)} hours"
                    if up else f"{svc}  Exited (1) 12 minutes ago"
                ),
            }
            for svc, host, up in inv
        ]
    }


def _status() -> dict:
    return {
        "variant": "operator",
        "demo": True,
        "mtls": {
            "certificates": {
                "cert_dir": "/certs",
                "client_cert": {"path": "/certs/operator.crt", "exists": True},
                "client_key": {"path": "/certs/operator.key", "exists": True},
                "ca_cert": {"path": "/certs/ca.crt", "exists": True},
                "ready": True,
            },
            "gateways": {
                "discovery": "https://node.example.com:9443",
                "home": "https://node.example.com:9444",
            },
        },
        "ssh": {
            "configured": True,
            "key": {"path": "/ssh/id_operator", "exists": True},
            "hosts": {"main": "root@194.67.92.147", "worker": "root@161.104.18.45"},
            "install_dir": "/opt/messenger/project",
            "inventory": [],
        },
        "owned_nodes": ["core"],
    }


def _audit() -> dict:
    now = datetime.now(timezone.utc)
    rows = [
        ("approve",   "friend-a", "alex-macbook", "нода принята в федерацию"),
        ("promote",   "client-1", "alex-macbook", "trust: pending → trusted"),
        ("suspend",   "friend-b", "alex-macbook", "устаревшая версия 0.8.1"),
        ("reinstate", "client-2", "alex-macbook", "восстановлена после обновления"),
        ("demote",    "client-3", "alex-laptop",  "нет heartbeat более 72 часов"),
    ]
    return {
        "entries": [
            {
                "created_at": (now - timedelta(hours=i * 7 + 1)).isoformat(),
                "action": act,
                "node_id": node,
                "cluster_id": "msng-test",
                "actor": actor,
                "detail": detail,
            }
            for i, (act, node, actor, detail) in enumerate(rows)
        ]
    }


def _deploy() -> dict:
    return {
        "git_head": "3fd8b4f",
        "git_branch": "main",
        "last_deploy": "ok 2026-07-28T06:14:22Z (3fd8b4f)",
        "webhook_active": True,
    }


def _logs(service: str) -> dict:
    now = datetime.now(timezone.utc)
    lines = [
        f"{(now - timedelta(seconds=s)).strftime('%Y-%m-%d %H:%M:%S')} "
        f"INFO  [{service}] {msg}"
        for s, msg in [
            (240, "startup complete, listening on 0.0.0.0:8001"),
            (180, "heartbeat sent to discovery: ok"),
            (120, "federation: 4 peers reachable"),
            (95,  "ws: client connected (device 7f3a…)"),
            (60,  "disappearing sweep: 12 messages expired"),
            (30,  "heartbeat sent to discovery: ok"),
            (5,   "ws: 18 active connections"),
        ]
    ]
    return {"service": service, "ok": True, "lines": lines}


ROUTES = {
    "/api/operator/status":        _status,
    "/api/operator/nodes":         _nodes,
    "/api/operator/services":      _services,
    "/api/operator/audit":         _audit,
    "/api/operator/deploy/status": _deploy,
    "/api/monitor/audit/history":  _audit,
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # тихо — иначе консоль тонет в запросах за статикой

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, code: int = 200):
        self._send(code, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_GET(self):
        path = urlparse(self.path).path

        if path in ROUTES:
            return self._json(ROUTES[path]())

        # /api/operator/services/<имя>/logs
        if path.startswith("/api/operator/services/") and path.endswith("/logs"):
            service = path.split("/")[-2]
            return self._json(_logs(service))

        if path.startswith("/api/"):
            return self._json({"detail": "В демо-режиме этот вызов не реализован"}, 501)

        # Страницы
        pages = {
            "/": "operator.html",
            "/operator": "operator.html",
            "/audit": "audit.html",
            "/nodes": "nodes.html",
        }
        name = pages.get(path, path.lstrip("/"))
        f = ADMIN_DIR / name
        if f.is_file():
            ctype = {
                ".html": "text/html; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8",
            }.get(f.suffix, "application/octet-stream")
            return self._send(200, f.read_bytes(), ctype)

        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        path = urlparse(self.path).path
        if path.startswith("/api/operator/"):
            return self._json({"ok": True, "demo": True,
                               "detail": "Демо-режим: действие не выполнено"})
        self._json({"detail": "not found"}, 404)


def main():
    if not ADMIN_DIR.is_dir():
        print(f"✗ Не найдена папка админки: {ADMIN_DIR}", file=sys.stderr)
        sys.exit(1)

    print(f"""
══════════════════════════════════════════════════════════
  Пульт — демо-режим
══════════════════════════════════════════════════════════

  http://127.0.0.1:{PORT}

  Данные выдуманные, наружу ничего не уходит.
  Кнопки отвечают, но ничего не делают.

  Остановить: Ctrl+C
""")
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nОстановлено.")


if __name__ == "__main__":
    main()
