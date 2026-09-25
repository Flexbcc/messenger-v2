#!/usr/bin/env python3
"""Minimal Gitea webhook → run deploy.sh in background (stdlib only)."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("DEPLOY_WEBHOOK_SECRET", "")
DEPLOY_ROOT = os.environ.get("DEPLOY_ROOT", "/opt/messenger/project")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")
PORT = int(os.environ.get("DEPLOY_WEBHOOK_PORT", "9009"))
LOG_FILE = os.environ.get("DEPLOY_LOG", "/var/log/messenger-deploy.log")
MAX_PAYLOAD_BYTES = 1024 * 1024
_INSECURE_SECRETS = {
    "change_me",
    "change-me",
    "changeme",
    "dev-secret",
    "secret",
}


def _validate_configuration() -> None:
    if (
        len(SECRET.encode("utf-8")) < 32
        or SECRET.strip().lower() in _INSECURE_SECRETS
    ):
        raise RuntimeError(
            "DEPLOY_WEBHOOK_SECRET must contain at least 32 bytes and must not use a development default"
        )
    if not 1 <= PORT <= 65535:
        raise RuntimeError("DEPLOY_WEBHOOK_PORT must be between 1 and 65535")
    if not GIT_BRANCH or len(GIT_BRANCH) > 255 or any(
        character.isspace() for character in GIT_BRANCH
    ):
        raise RuntimeError("GIT_BRANCH is invalid")


def _log(msg: str) -> None:
    line = f"{msg}\n"
    sys.stderr.write(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def _start_deploy() -> None:
    deploy = os.path.join(DEPLOY_ROOT, "deploy.sh")
    if not os.path.isfile(deploy):
        raise FileNotFoundError(deploy)
    with open(LOG_FILE, "a", encoding="utf-8") as out:
        out.write(f"\n--- deploy triggered ---\n")
        subprocess.Popen(
            [deploy],
            cwd=DEPLOY_ROOT,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


class HookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        _log(f"webhook {self.address_string()} {fmt % args}")

    def do_POST(self) -> None:
        if self.path != "/hook":
            self.send_error(404, "not found")
            return

        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length) if raw_length is not None else -1
        except ValueError:
            length = -1
        if length < 0:
            self.send_error(411, "valid Content-Length required")
            return
        if length > MAX_PAYLOAD_BYTES:
            self.send_error(413, "payload too large")
            return
        body = self.rfile.read(length)

        sig = self.headers.get("X-Gitea-Signature", "")
        expected = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
        if (
            len(sig) != hashlib.sha256().digest_size * 2
            or not hmac.compare_digest(sig, expected)
        ):
            _log("webhook rejected: bad signature")
            self.send_error(403, "bad signature")
            return

        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(400, "invalid json")
            return

        if not isinstance(payload, dict):
            self.send_error(400, "invalid payload")
            return
        ref = payload.get("ref")
        want = f"refs/heads/{GIT_BRANCH}"
        if not isinstance(ref, str) or ref != want:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ignored non-target ref\n")
            return

        try:
            _start_deploy()
        except Exception as exc:  # noqa: BLE001 — details stay in the local log
            _log(f"deploy start failed: {exc}")
            self.send_error(500, "deploy could not be started")
            return

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"deploy started\n")

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        self.send_error(404)


def main() -> None:
    try:
        _validate_configuration()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), HookHandler)
    _log(f"deploy webhook listening on 127.0.0.1:{PORT} branch={GIT_BRANCH}")
    server.serve_forever()


if __name__ == "__main__":
    main()
