#!/usr/bin/env python3
"""Local Operator Console — manage all nodes from your Mac (127.0.0.1 only)."""
from __future__ import annotations

import json
import os
import re
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
TOKEN = os.environ.get("OPERATOR_TOKEN", "")


def _load_env() -> dict[str, str]:
    cfg: dict[str, str] = {
        "MAIN_HOST": "root@194.67.92.147",
        "WORKER_HOST": "root@161.104.18.45",
        "MAIN_IP": "194.67.92.147",
        "WORKER_IP": "161.104.18.45",
        "LAPTOP_SSH_KEY": os.path.expanduser("~/.ssh/messenger_ops"),
        "GITEA_SSH": f"ssh://git@194.67.92.147:2222/flex/messenger.git",
    }
    if LAPTOP_ENV.is_file():
        for line in LAPTOP_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip().replace("$HOME", os.path.expanduser("~"))
    return cfg


def _ssh(cfg: dict[str, str], host: str, remote_cmd: str, timeout: int = 120) -> tuple[int, str]:
    key = cfg.get("LAPTOP_SSH_KEY", "")
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20"]
    if key and Path(key).is_file():
        cmd += ["-i", key, "-o", "IdentitiesOnly=yes"]
    cmd += [host, remote_cmd]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 1, "SSH timeout"
    except OSError as exc:
        return 1, str(exc)


def _http_json(url: str, timeout: int = 8) -> dict | list | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None


def _health(url: str) -> dict:
    data = _http_json(url)
    if not data:
        return {"ok": False, "url": url}
    return {"ok": data.get("status") == "ok", "url": url, "data": data}


def _discovery_nodes(cfg: dict[str, str]) -> list[dict]:
    url = f"http://{cfg['MAIN_IP']}:8003/registry/nodes"
    data = _http_json(url)
    if not data:
        return []
    return data.get("nodes", [])


class Handler(BaseHTTPRequestHandler):
    cfg = _load_env()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"operator {fmt % args}\n")

    def _auth_ok(self) -> bool:
        if not TOKEN:
            return True
        return self.headers.get("X-Operator-Token", "") == TOKEN

    def _json(self, code: int, payload: dict | list) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode())

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            html = (OPERATOR_DIR / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            if ".." in rel:
                self.send_error(403)
                return
            fp = OPERATOR_DIR / rel
            if not fp.is_file():
                self.send_error(404)
                return
            data = fp.read_bytes()
            ctype = "text/css" if fp.suffix == ".css" else "application/javascript"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/api/config":
            c = self.cfg
            self._json(200, {
                "main_host": c["MAIN_HOST"],
                "worker_host": c["WORKER_HOST"],
                "main_ip": c["MAIN_IP"],
                "worker_ip": c["WORKER_IP"],
                "install_dir": INSTALL_DIR,
                "auth_required": bool(TOKEN),
            })
            return

        if path == "/api/status":
            c = self.cfg
            main_h = _health(f"http://{c['MAIN_IP']}:8003/health")
            gw_h = _health(f"http://{c['MAIN_IP']}:8007/health")
            home_h = _health(f"http://{c['WORKER_IP']}:8001/health")
            media_h = _health(f"http://{c['WORKER_IP']}:8004/health")
            rc, deploy_status = _ssh(c, c["MAIN_HOST"], f"cat {INSTALL_DIR}/config/deploy/last-deploy.status 2>/dev/null || echo status=unknown")
            rc2, webhook = _ssh(c, c["MAIN_HOST"], "systemctl is-active messenger-deploy-webhook 2>/dev/null || echo inactive")
            self._json(200, {
                "health": {
                    "discovery": main_h,
                    "gateway": gw_h,
                    "home": home_h,
                    "media": media_h,
                },
                "nodes": _discovery_nodes(c),
                "deploy_status": deploy_status,
                "webhook": webhook.strip(),
            })
            return

        if path == "/api/deploy/log":
            c = self.cfg
            lines = self.path.split("lines=", 1)
            n = 80
            if len(lines) > 1 and lines[1].isdigit():
                n = int(lines[1])
            rc, out = _ssh(c, c["MAIN_HOST"], f"tail -n {n} /var/log/messenger-deploy.log 2>/dev/null || echo 'no log'")
            self._json(200, {"log": out, "rc": rc})
            return

        if path == "/api/workers":
            c = self.cfg
            rc, out = _ssh(c, c["MAIN_HOST"], f"cat {INSTALL_DIR}/config/deploy/workers.list 2>/dev/null || true")
            hosts = [ln.strip() for ln in out.splitlines() if ln.strip() and not ln.strip().startswith("#")]
            self._json(200, {"workers": hosts, "rc": rc})
            return

        self.send_error(404)

    def do_POST(self) -> None:
        if not self._auth_ok():
            self._json(401, {"error": "X-Operator-Token required"})
            return

        path = self.path.split("?", 1)[0]
        c = self.cfg

        if path == "/api/deploy/push":
            msg = ""
            try:
                body = self._read_json()
                msg = body.get("message", "")
            except json.JSONDecodeError:
                pass
            cmd = [str(ROOT / "scripts" / "push-deploy.sh")]
            if msg:
                cmd += ["-m", msg]
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

        if path == "/api/enrollment/approve":
            rc, out = _ssh(c, c["MAIN_HOST"], f"cd {INSTALL_DIR} && ./scripts/approve-pending-nodes.sh", timeout=60)
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        if path == "/api/enrollment/approve-one":
            try:
                body = self._read_json()
                node_id = body.get("node_id", "")
            except json.JSONDecodeError:
                node_id = ""
            if not re.match(r"^[a-zA-Z0-9._-]+$", node_id):
                self._json(400, {"error": "invalid node_id"})
                return
            rc, out = _ssh(c, c["MAIN_HOST"], f"cd {INSTALL_DIR} && ./scripts/approve-pending-nodes.sh {node_id}")
            self._json(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
            return

        self.send_error(404)


def main() -> None:
    if not OPERATOR_DIR.is_dir():
        print(f"Missing {OPERATOR_DIR}", file=sys.stderr)
        sys.exit(1)
    Handler.cfg = _load_env()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Operator Console: http://127.0.0.1:{PORT}/")
    print("Ctrl+C to stop.")
    server.serve_forever()


if __name__ == "__main__":
    main()
