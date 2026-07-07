#!/usr/bin/env python3
"""
Messenger Operator Console — local control panel (127.0.0.1 only).

- Runs ONLY on your Mac; nodes never expose this UI.
- OPERATOR_SECRET in config/deploy/laptop.env — only you can act.
- Server admin/enrollment secrets stay on servers; accessed via SSH from here.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OPERATOR_DIR = ROOT / "operator"
LAPTOP_ENV = ROOT / "config" / "deploy" / "laptop.env"
INSTALL_DIR = "/opt/messenger/project"
PORT = int(os.environ.get("OPERATOR_PORT", "9300"))

# service → (ssh host alias, docker compose service name)
NODE_INVENTORY = [
    ("discovery-node", "main", "discovery-node", 8003),
    ("gateway-node", "main", "gateway-node", 8007),
    ("home-node", "worker", "home-node", 8001),
    ("storage-node", "worker", "storage-node", 8002),
    ("media-node", "worker", "media-node", 8004),
    ("relay-node", "worker", "relay-node", 8005),
    ("turn-node", "worker", "turn-node", 8006),
]


def _load_env() -> dict[str, str]:
    cfg: dict[str, str] = {
        "MAIN_HOST": "root@194.67.92.147",
        "WORKER_HOST": "root@161.104.18.45",
        "MAIN_IP": "194.67.92.147",
        "WORKER_IP": "161.104.18.45",
        "LAPTOP_SSH_KEY": os.path.expanduser("~/.ssh/messenger_ops"),
        "OPERATOR_SECRET": "",
    }
    if LAPTOP_ENV.is_file():
        for line in LAPTOP_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip().replace("$HOME", os.path.expanduser("~"))
    cfg["OPERATOR_SECRET"] = os.environ.get("OPERATOR_SECRET", cfg.get("OPERATOR_SECRET", ""))
    return cfg


def _host_for_alias(cfg: dict[str, str], alias: str) -> str:
    if alias == "main":
        return cfg["MAIN_HOST"]
    if alias == "worker":
        return cfg["WORKER_HOST"]
    return alias


def _ssh(cfg: dict[str, str], host: str, remote_cmd: str, timeout: int = 120) -> tuple[int, str]:
    key = cfg.get("LAPTOP_SSH_KEY", "")
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25", "-o", "StrictHostKeyChecking=accept-new"]
    if key and Path(key).is_file():
        cmd += ["-i", key, "-o", "IdentitiesOnly=yes"]
    cmd += [host, remote_cmd]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()
    except subprocess.TimeoutExpired:
        return 1, "SSH timeout"
    except OSError as exc:
        return 1, str(exc)


def _http_json(url: str, timeout: int = 8) -> dict | list | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError):
        return None


def _health(url: str) -> dict:
    data = _http_json(url)
    if not data:
        return {"ok": False, "url": url, "data": {}}
    return {"ok": data.get("status") == "ok", "url": url, "data": data}


def _discovery_nodes(cfg: dict[str, str]) -> list[dict]:
    data = _http_json(f"http://{cfg['MAIN_IP']}:8003/registry/nodes")
    return (data or {}).get("nodes", [])


def _collect_home_stats(cfg: dict[str, str]) -> dict:
    sql = (
        "SELECT (SELECT COUNT(*) FROM users) AS users,"
        " (SELECT COUNT(*) FROM devices) AS devices,"
        " (SELECT COUNT(*) FROM conversations) AS conversations,"
        " (SELECT COUNT(*) FROM messages) AS messages;"
    )
    db = f"{INSTALL_DIR}/data/home/home.db"
    cmd = f"sqlite3 {db} \"{sql}\" 2>/dev/null || echo '0|0|0|0'"
    rc, out = _ssh(cfg, cfg["WORKER_HOST"], cmd, timeout=30)
    parts = (out.split("|") + ["0", "0", "0", "0"])[:4]
    return {
        "users": int(parts[0] or 0),
        "devices": int(parts[1] or 0),
        "conversations": int(parts[2] or 0),
        "messages": int(parts[3] or 0),
        "ok": rc == 0,
    }


def _collect_dashboard(cfg: dict[str, str]) -> dict:
    discovery_h = _health(f"http://{cfg['MAIN_IP']}:8003/health")
    gateway_h = _health(f"http://{cfg['MAIN_IP']}:8007/health")
    home_h = _health(f"http://{cfg['WORKER_IP']}:8001/health")
    media_h = _health(f"http://{cfg['WORKER_IP']}:8004/health")
    turn_h = _health(f"http://{cfg['WORKER_IP']}:8006/health")

    disc_load = discovery_h.get("data", {}).get("load", {})
    home_load = home_h.get("data", {}).get("load", {})
    media_load = media_h.get("data", {}).get("load", {})

    home_stats = _collect_home_stats(cfg)
    nodes = _discovery_nodes(cfg)
    trusted = sum(1 for n in nodes if n.get("trust_status") == "trusted")
    online = sum(1 for n in nodes if (n.get("reachability") or n.get("status")) == "online")

    _, deploy_status = _ssh(cfg, cfg["MAIN_HOST"], f"cat {INSTALL_DIR}/config/deploy/last-deploy.status 2>/dev/null || true")
    _, webhook = _ssh(cfg, cfg["MAIN_HOST"], "systemctl is-active messenger-deploy-webhook 2>/dev/null || echo inactive")
    _, git_head = _ssh(cfg, cfg["MAIN_HOST"], f"git -C {INSTALL_DIR} rev-parse --short HEAD 2>/dev/null || echo unknown")

    services = []
    for node_id, host_alias, compose_svc, port in NODE_INVENTORY:
        host = _host_for_alias(cfg, host_alias)
        ip = cfg["MAIN_IP"] if host_alias == "main" else cfg["WORKER_IP"]
        internal = port in (8002, 8005)
        hurl = f"http://{ip}:{port}/health" if not internal else ""
        h = _health(hurl) if hurl else {"ok": None, "url": "internal", "data": {}}
        _, ps = _ssh(cfg, host, f"cd {INSTALL_DIR} && docker compose ps {compose_svc} 2>/dev/null | tail -n +2 | head -1", timeout=25)
        running = "Up" in ps
        services.append({
            "node_id": node_id,
            "host_alias": host_alias,
            "compose_service": compose_svc,
            "port": port,
            "health_ok": h.get("ok"),
            "running": running,
            "ps_line": ps,
        })

    return {
        "summary": {
            "registered_users_discovery": disc_load.get("registered_users", 0),
            "registered_nodes_discovery": disc_load.get("registered_nodes", 0),
            "nodes_trusted": trusted,
            "nodes_online": online,
            "home_users": home_stats["users"],
            "devices": home_stats["devices"],
            "conversations": home_stats["conversations"],
            "messages": home_stats["messages"],
            "online_users_now": home_load.get("online_users", 0),
            "ws_connections": home_load.get("active_ws_connections", 0),
            "media_files": media_load.get("files_count", 0),
            "media_bytes": media_load.get("bytes_total", 0),
        },
        "features": {
            "messaging": home_stats["messages"] > 0,
            "multi_device": home_stats["devices"] > home_stats["users"],
            "media_uploads": media_load.get("files_count", 0) > 0,
            "realtime_ws": home_load.get("active_ws_connections", 0) > 0,
            "federation_nodes": trusted > 1,
        },
        "health": {
            "discovery": discovery_h,
            "gateway": gateway_h,
            "home": home_h,
            "media": media_h,
            "turn": turn_h,
        },
        "nodes": nodes,
        "services": services,
        "deploy": {
            "status": deploy_status.strip(),
            "webhook": webhook.strip(),
            "git_head": git_head.strip(),
        },
    }


class Handler(BaseHTTPRequestHandler):
    cfg: dict[str, str] = {}

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"operator {fmt % args}\n")

    def _secret(self) -> str:
        return self.cfg.get("OPERATOR_SECRET", "")

    def _auth_ok(self) -> bool:
        secret = self._secret()
        if not secret:
            return True
        token = self.headers.get("X-Operator-Token", "")
        return hmac.compare_digest(token, secret)

    def _json(self, code: int, payload: dict | list) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode())

    def _serve_file(self, rel: str, ctype: str) -> None:
        if ".." in rel:
            self.send_error(403)
            return
        fp = OPERATOR_DIR / rel
        if not fp.is_file():
            self.send_error(404)
            return
        data = fp.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _require_auth(self) -> bool:
        if self._auth_ok():
            return True
        self._json(401, {"error": "Требуется OPERATOR_SECRET"})
        return False

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._serve_file("index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            ctype = "text/css" if rel.endswith(".css") else "application/javascript"
            self._serve_file(rel, ctype)
            return

        if path == "/api/config":
            self._json(200, {
                "main_ip": self.cfg["MAIN_IP"],
                "worker_ip": self.cfg["WORKER_IP"],
                "auth_required": bool(self._secret()),
                "panel": "operator-console",
            })
            return

        if not self._require_auth():
            return

        if path == "/api/dashboard":
            self._json(200, _collect_dashboard(self.cfg))
            return

        if path == "/api/deploy/log":
            q = self.path.split("lines=", 1)
            n = int(q[1]) if len(q) > 1 and q[1].isdigit() else 80
            _, out = _ssh(self.cfg, self.cfg["MAIN_HOST"], f"tail -n {n} /var/log/messenger-deploy.log 2>/dev/null || echo '(пусто)'")
            self._json(200, {"log": out})
            return

        if path == "/api/node/logs":
            # ?service=home-node&lines=80
            import urllib.parse
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[-1] if "?" in self.path else "")
            svc = (qs.get("service") or [""])[0]
            lines = (qs.get("lines") or ["80"])[0]
            if not re.match(r"^[a-z0-9-]+$", svc):
                self._json(400, {"error": "invalid service"})
                return
            host_alias = "main"
            for node_id, ha, compose_svc, _ in NODE_INVENTORY:
                if node_id == svc or compose_svc == svc:
                    host_alias = ha
                    svc = compose_svc
                    break
            host = _host_for_alias(self.cfg, host_alias)
            _, out = _ssh(self.cfg, host, f"cd {INSTALL_DIR} && docker compose logs --tail={lines} {svc} 2>&1", timeout=60)
            self._json(200, {"log": out, "service": svc, "host": host_alias})
            return

        self.send_error(404)

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]

        if path == "/api/auth/verify":
            body = self._read_json()
            secret = self._secret()
            if not secret:
                self._json(200, {"ok": True, "auth_required": False})
                return
            if hmac.compare_digest(body.get("secret", ""), secret):
                self._json(200, {"ok": True, "auth_required": True})
            else:
                self._json(403, {"ok": False, "error": "Неверный ключ"})
            return

        if not self._require_auth():
            return

        c = self.cfg
        body = {}
        try:
            body = self._read_json()
        except json.JSONDecodeError:
            pass

        if path == "/api/deploy/push":
            cmd = [str(ROOT / "scripts" / "push-deploy.sh")]
            if body.get("message"):
                cmd += ["-m", str(body["message"])]
            proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
            self._json(200 if proc.returncode == 0 else 500, {
                "ok": proc.returncode == 0,
                "output": (proc.stdout or "") + (proc.stderr or ""),
            })
            return

        if path == "/api/deploy/trigger":
            rc, out = _ssh(c, c["MAIN_HOST"], f"cd {INSTALL_DIR} && ./deploy.sh", timeout=600)
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        if path == "/api/deploy/ensure":
            proc = subprocess.run([str(ROOT / "scripts" / "ensure-autodeploy.sh")], cwd=ROOT, capture_output=True, text=True, timeout=120)
            self._json(200 if proc.returncode == 0 else 500, {"ok": proc.returncode == 0, "output": (proc.stdout or "") + (proc.stderr or "")})
            return

        if path == "/api/enrollment/approve":
            rc, out = _ssh(c, c["MAIN_HOST"], f"cd {INSTALL_DIR} && ./scripts/approve-pending-nodes.sh", timeout=60)
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        if path == "/api/enrollment/approve-one":
            node_id = body.get("node_id", "")
            if not re.match(r"^[a-zA-Z0-9._-]+$", node_id):
                self._json(400, {"error": "invalid node_id"})
                return
            rc, out = _ssh(c, c["MAIN_HOST"], f"cd {INSTALL_DIR} && ./scripts/approve-pending-nodes.sh {node_id}")
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        if path == "/api/node/restart":
            svc = body.get("service", "")
            if not re.match(r"^[a-z0-9-]+$", svc):
                self._json(400, {"error": "invalid service"})
                return
            host_alias = body.get("host", "worker")
            for node_id, ha, compose_svc, _ in NODE_INVENTORY:
                if node_id == svc:
                    host_alias = ha
                    svc = compose_svc
                    break
            host = _host_for_alias(c, host_alias)
            rc, out = _ssh(c, host, f"cd {INSTALL_DIR} && docker compose restart {svc}", timeout=120)
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        if path == "/api/node/update":
            host_alias = body.get("host", "main")
            host = _host_for_alias(c, host_alias)
            rc, out = _ssh(c, host, f"cd {INSTALL_DIR} && ./scripts/node-update.sh", timeout=600)
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        self.send_error(404)


def main() -> None:
    if not OPERATOR_DIR.is_dir():
        print(f"Missing {OPERATOR_DIR}", file=sys.stderr)
        sys.exit(1)
    Handler.cfg = _load_env()
    secret = Handler.cfg.get("OPERATOR_SECRET", "")
    if not secret:
        print("WARN: OPERATOR_SECRET not set — panel is open without login.", file=sys.stderr)
        print("      Run: ./scripts/setup-operator-secret.sh", file=sys.stderr)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Operator Console: http://127.0.0.1:{PORT}/")
    print("Только локально. Ноды не видят эту панель.")
    server.serve_forever()


if __name__ == "__main__":
    main()
