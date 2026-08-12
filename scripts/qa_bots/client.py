"""Minimal HTTP + WebSocket client for home-node."""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import uuid
from typing import Any
from urllib.parse import urlparse, urlunparse

import httpx

try:
    import websockets
except ImportError:  # pragma: no cover
    websockets = None  # type: ignore


DEFAULT_HOME = os.environ.get("HOME_URL", "http://localhost:8001").rstrip("/")
DEFAULT_DISCOVERY = os.environ.get("DISCOVERY_URL", "http://localhost:8003").rstrip("/")


def dummy_identity_bundle() -> dict[str, Any]:
    """Opaque bundle — server does not validate Signal crypto."""
    return {
        "identity_key": base64.b64encode(os.urandom(32)).decode(),
        "registration_id": 1,
        "signed_prekey": {
            "id": 1,
            "public_key": base64.b64encode(os.urandom(32)).decode(),
            "signature": base64.b64encode(os.urandom(64)).decode(),
        },
        "prekeys": [
            {"id": i, "public_key": base64.b64encode(os.urandom(32)).decode()}
            for i in range(10, 13)
        ],
    }


class HomeClient:
    def __init__(
        self,
        home_url: str | None = None,
        discovery_url: str | None = None,
        timeout: float = 20.0,
    ):
        self.home_url = (home_url or DEFAULT_HOME).rstrip("/")
        self.discovery_url = (discovery_url or DEFAULT_DISCOVERY).rstrip("/")
        self._http = httpx.Client(base_url=self.home_url, timeout=timeout)
        self._disc = httpx.Client(base_url=self.discovery_url, timeout=timeout)

    def close(self) -> None:
        self._http.close()
        self._disc.close()

    def __enter__(self) -> HomeClient:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def health(self) -> tuple[int, dict]:
        r = self._http.get("/health")
        return r.status_code, _json(r)

    def discovery_health(self) -> tuple[int, Any]:
        r = self._disc.get("/health")
        return r.status_code, _json(r)

    def discovery_search_login(self, login: str) -> tuple[int, Any]:
        r = self._disc.get("/registry/users/search", params={"login": login})
        return r.status_code, _json(r)

    def discovery_user_by_id(self, user_id: str) -> tuple[int, Any]:
        r = self._disc.get(f"/registry/users/{user_id}")
        return r.status_code, _json(r)

    def request(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        json_body: dict | None = None,
    ) -> tuple[int, Any]:
        headers: dict[str, str] = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        r = self._http.request(method, path, headers=headers, json=json_body)
        return r.status_code, _json(r)

    def register(
        self,
        *,
        display_name: str,
        phone: str,
        password: str,
        device_name: str = "qa-bot",
    ) -> tuple[int, dict]:
        code, challenge_data = self.request("GET", "/auth/pow-challenge")
        if code != 200:
            return code, challenge_data
        challenge = challenge_data.get("challenge", "")
        difficulty = int(challenge_data.get("difficulty", 0))
        nonce = 0
        prefix = "0" * difficulty
        while difficulty and not hashlib.sha256(
            f"{challenge}:{nonce}".encode()
        ).hexdigest().startswith(prefix):
            nonce += 1
        return self.request(
            "POST",
            "/auth/register",
            json_body={
                "display_name": display_name,
                "phone": phone,
                "password": password,
                "device_name": device_name,
                "device_type": "desktop",
                "auth_public_key": base64.b64encode(os.urandom(32)).decode(),
                "identity_key_bundle": dummy_identity_bundle(),
                "pow_challenge": challenge,
                "pow_nonce": str(nonce),
            },
        )

    def login(
        self,
        *,
        identifier: str,
        password: str,
        device_name: str = "qa-bot-login",
    ) -> tuple[int, dict]:
        return self.request(
            "POST",
            "/auth/login",
            json_body={
                "identifier": identifier,
                "password": password,
                "device_name": device_name,
                "device_type": "desktop",
                "auth_public_key": base64.b64encode(os.urandom(32)).decode(),
                "identity_key_bundle": dummy_identity_bundle(),
            },
        )

    def ws_url(self, token: str) -> str:
        parsed = urlparse(self.home_url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        base = urlunparse((scheme, parsed.netloc, "/ws", "", f"token={token}", ""))
        return base


def wait_for_ws_event(
    ws_url: str,
    *,
    predicate,
    timeout: float = 8.0,
) -> dict | None:
    """Connect, wait until predicate(msg) or timeout. Returns message or None."""
    if websockets is None:
        raise RuntimeError("websockets package required: pip install websockets")

    async def _run() -> dict | None:
        async with websockets.connect(ws_url, open_timeout=5) as ws:
            deadline = asyncio.get_event_loop().time() + timeout
            while True:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    return None
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
                except asyncio.TimeoutError:
                    return None
                if isinstance(raw, bytes):
                    raw = raw.decode()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if predicate(msg):
                    return msg

    return asyncio.run(_run())


def collect_ws_events(
    ws_url: str,
    *,
    trigger,
    timeout: float = 8.0,
    max_events: int = 20,
) -> list[dict]:
    """Open WS, run trigger(), collect events until timeout."""
    if websockets is None:
        raise RuntimeError("websockets package required: pip install websockets")

    async def _run() -> list[dict]:
        events: list[dict] = []
        async with websockets.connect(ws_url, open_timeout=5) as ws:
            # Let server register connection before trigger.
            await asyncio.sleep(0.15)
            trigger()
            deadline = asyncio.get_event_loop().time() + timeout
            while len(events) < max_events:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    break
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=min(remaining, 1.0))
                except asyncio.TimeoutError:
                    continue
                if isinstance(raw, bytes):
                    raw = raw.decode()
                try:
                    events.append(json.loads(raw))
                except json.JSONDecodeError:
                    continue
        return events

    return asyncio.run(_run())


def unique_phone(prefix: str = "7999") -> str:
    n = uuid.uuid4().int % 10**7
    return f"+{prefix}{n:07d}"


def unique_label(scenario: str, role: str) -> str:
    stamp = uuid.uuid4().hex[:8]
    return f"qa_bot_{scenario}_{role}_{stamp}"


def unique_login(role: str) -> str:
    """Discovery login: ^[a-zA-Z0-9_]{3,32}$"""
    stamp = uuid.uuid4().hex[:10]
    return f"u{role[:3]}{stamp}"[:32]


def _json(r: httpx.Response) -> Any:
    try:
        return r.json()
    except Exception:
        return {"_raw": r.text, "_status": r.status_code}
