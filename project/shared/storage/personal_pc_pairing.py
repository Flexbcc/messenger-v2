"""Pairing helpers for storage-app (QR JSON → POST /ppc/pair).

Shared between home-node (owner panel API) and media-node backend.
Spec: storage-app/docs/{WIRE,PAIRING}.md
"""
from __future__ import annotations

import base64
import json
import time
from typing import Any
from urllib.parse import urlparse

import httpx


class PairingPayloadError(ValueError):
    """Invalid or expired pairing payload."""


def parse_pairing_payload(raw: str | dict[str, Any]) -> dict[str, Any]:
    """Parse QR / pasted JSON (kind ``ouo_ppc_pair``)."""
    if isinstance(raw, str):
        raw = raw.strip()
        if not raw:
            raise PairingPayloadError("empty payload")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            raise PairingPayloadError(f"invalid JSON: {e}") from e
    else:
        data = raw

    if data.get("kind") != "ouo_ppc_pair":
        raise PairingPayloadError(f"unexpected kind: {data.get('kind')!r}")
    code = str(data.get("code") or "").strip()
    if len(code) != 6 or not code.isdigit():
        raise PairingPayloadError("code must be 6 digits")
    storage_pubkey = str(data.get("storage_pubkey") or "").strip()
    if not storage_pubkey.startswith("ed25519:"):
        raise PairingPayloadError("storage_pubkey missing or invalid")
    expires_at = int(data.get("expires_at") or 0)
    if expires_at and expires_at < int(time.time()):
        raise PairingPayloadError("pairing code expired")
    return data


def reach_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Normalize v2 ``reach`` or legacy flat ``lan``/``port``."""
    reach = payload.get("reach")
    if isinstance(reach, dict):
        return reach
    return {
        "lan": payload.get("lan") or [],
        "port": int(payload.get("port") or 7345),
        "mdns": payload.get("mdns", True),
    }


def lan_hints_from_payload(payload: dict[str, Any]) -> list[str]:
    """Build ``host:port`` hints for all entries in ``reach.lan``."""
    reach = reach_from_payload(payload)
    port = int(reach.get("port") or 7345)
    hints: list[str] = []
    for entry in reach.get("lan") or []:
        host = str(entry).strip()
        if host:
            hints.append(f"{host}:{port}")
    return hints


def lan_hint_from_payload(payload: dict[str, Any]) -> str:
    """Build ``host:port`` for LAN-direct from ``reach.lan`` + ``reach.port``."""
    hints = lan_hints_from_payload(payload)
    if not hints:
        raise PairingPayloadError("no LAN host in payload")
    return hints[0]


def discover_ppc_lan_hints(timeout_s: float = 3.0) -> list[str]:
    """Browse ``_ouo-ppc._tcp.local``; return ``host:port`` hints (IP preferred)."""
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        return []

    hints: list[str] = []
    seen: set[str] = set()

    class _PpcListener:
        def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            info = zc.get_service_info(type_, name)
            if info is None:
                return
            port = info.port or 7345
            addrs = info.parsed_addresses()
            if addrs:
                for addr in addrs:
                    hint = f"{addr}:{port}"
                    if hint not in seen:
                        seen.add(hint)
                        hints.append(hint)
            elif info.server:
                host = info.server.rstrip(".")
                hint = f"{host}:{port}"
                if hint not in seen:
                    seen.add(hint)
                    hints.append(hint)

        def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

        def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

    zc = Zeroconf()
    browser = None
    try:
        browser = ServiceBrowser(zc, "_ouo-ppc._tcp.local.", _PpcListener())
        time.sleep(max(0.0, timeout_s))
    finally:
        if browser is not None:
            browser.cancel()
        zc.close()

    return hints


def relay_reach_from_payload(payload: dict[str, Any]) -> dict[str, str] | None:
    reach = reach_from_payload(payload)
    relay = reach.get("relay")
    if not isinstance(relay, dict):
        return None
    relay_url = str(relay.get("relay_url") or "").strip()
    storage_node_id = str(relay.get("storage_node_id") or "").strip()
    if not relay_url or not storage_node_id:
        return None
    return {"relay_url": relay_url, "storage_node_id": storage_node_id}


def ppc_relay_invoke(
    *,
    relay_url: str,
    storage_node_id: str,
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    body: bytes = b"",
    signing_key_path: str = "",
    caller_node_id: str = "",
    timeout_s: float = 30.0,
) -> tuple[int, bytes, dict[str, str]]:
    """POST /relay/ppc/{storage_node_id}/invoke → (status, body, headers)."""
    import asyncio

    async def _run() -> tuple[int, bytes, dict[str, str]]:
        from shared.security.config import INTERNAL_SECURITY_MODE
        from shared.security.federation_auth import sign_federation_request
        from shared.security.keys import load_or_create_signing_key

        invoke_body = {
            "method": method.upper(),
            "path": path,
            "headers": headers or {},
            "body_b64": base64.b64encode(body).decode() if body else "",
        }
        url = f"{relay_url.rstrip('/')}/relay/ppc/{storage_node_id}/invoke"
        api_path = f"/relay/ppc/{storage_node_id}/invoke"
        raw = json.dumps(invoke_body, separators=(",", ":"), ensure_ascii=False).encode()
        hdrs = {"Content-Type": "application/json"}
        if INTERNAL_SECURITY_MODE not in ("legacy", "off", "") and signing_key_path:
            sk = load_or_create_signing_key(signing_key_path)
            hdrs.update(
                sign_federation_request(
                    signing_key=sk,
                    node_id=caller_node_id or "home-local",
                    method="POST",
                    path=api_path,
                    body=raw,
                )
            )
        async with httpx.AsyncClient(timeout=timeout_s) as client:
            resp = await client.post(url, content=raw, headers=hdrs)
        data = resp.json()
        status = int(data.get("status") or resp.status_code)
        resp_body = base64.b64decode(data.get("body_b64") or "")
        resp_headers = {str(k): str(v) for k, v in (data.get("headers") or {}).items()}
        return status, resp_body, resp_headers

    return asyncio.run(_run())


def pair_with_storage_app_via_relay(
    *,
    relay_url: str,
    storage_node_id: str,
    code: str,
    peer_pubkey: str,
    node_id: str,
    name: str,
    signing_key_path: str = "",
    caller_node_id: str = "",
) -> dict[str, Any]:
    """Pair through relay PPC agent (NAT / remote home-node)."""
    body = json.dumps(
        {
            "code": code,
            "peer_pubkey": peer_pubkey,
            "node_id": node_id,
            "name": name,
        },
        separators=(",", ":"),
    ).encode()
    status, resp_body, _ = ppc_relay_invoke(
        relay_url=relay_url,
        storage_node_id=storage_node_id,
        method="POST",
        path="/ppc/pair",
        headers={"Content-Type": "application/json"},
        body=body,
        signing_key_path=signing_key_path,
        caller_node_id=caller_node_id,
    )
    if status == 403:
        raise PairingPayloadError("bad or expired pairing code")
    if status >= 400:
        raise PairingPayloadError(f"relay pair failed HTTP {status}: {resp_body[:200]!r}")
    try:
        data = json.loads(resp_body.decode() or "{}")
    except ValueError as e:
        raise PairingPayloadError(f"invalid relay pair JSON: {e}") from e
    if not str(data.get("storage_pubkey", "")).startswith("ed25519:"):
        raise PairingPayloadError("relay response missing storage_pubkey")
    return data


def _parse_lan_base(lan_hint: str) -> str:
    hint = (lan_hint or "").strip()
    if not hint:
        raise PairingPayloadError("lan_hint empty")
    if "://" in hint:
        parsed = urlparse(hint)
        host = parsed.hostname or ""
        port = parsed.port or 7345
        scheme = parsed.scheme or "http"
        return f"{scheme}://{host}:{port}"
    if ":" in hint and hint.rsplit(":", 1)[-1].isdigit():
        return f"http://{hint}"
    return f"http://{hint}:7345"


def node_peer_pubkey(signing_key_path: str) -> str:
    """Node Ed25519 public key in WIRE format ``ed25519:<base64>``."""
    from nacl.signing import SigningKey

    try:
        text = open(signing_key_path, "r", encoding="utf-8").read().strip()
    except OSError as e:
        raise PairingPayloadError(f"cannot read signing key: {e}") from e
    if not text:
        raise PairingPayloadError("signing key empty")
    seed = base64.urlsafe_b64decode(text.encode())
    sk = SigningKey(seed)
    pub = base64.b64encode(bytes(sk.verify_key)).decode()
    return f"ed25519:{pub}"


def pair_with_storage_app(
    *,
    lan_hint: str,
    code: str,
    peer_pubkey: str,
    node_id: str,
    name: str,
    connect_timeout_s: float = 5.0,
    request_timeout_s: float = 15.0,
) -> dict[str, Any]:
    """Call ``POST /ppc/pair`` on storage-app. Returns JSON body on success."""
    base = _parse_lan_base(lan_hint)
    url = f"{base.rstrip('/')}/ppc/pair"
    body = {
        "code": code,
        "peer_pubkey": peer_pubkey,
        "node_id": node_id,
        "name": name,
    }
    try:
        resp = httpx.post(
            url,
            json=body,
            timeout=httpx.Timeout(request_timeout_s, connect=connect_timeout_s),
        )
    except httpx.HTTPError as e:
        raise PairingPayloadError(f"storage-app unreachable: {e}") from e

    if resp.status_code == 403:
        raise PairingPayloadError("bad or expired pairing code")
    if resp.status_code >= 400:
        detail = resp.text[:200]
        try:
            detail = resp.json().get("detail") or resp.json().get("error") or detail
        except Exception:
            pass
        raise PairingPayloadError(f"pair failed HTTP {resp.status_code}: {detail}")

    try:
        data = resp.json()
    except ValueError as e:
        raise PairingPayloadError(f"invalid response JSON: {e}") from e
    if not str(data.get("storage_pubkey", "")).startswith("ed25519:"):
        raise PairingPayloadError("response missing storage_pubkey")
    return data


def pair_from_qr_payload(
    payload_raw: str | dict[str, Any],
    *,
    signing_key_path: str,
    node_id: str,
    name: str,
    caller_node_id: str = "",
) -> dict[str, Any]:
    """Parse QR → pair (LAN → mDNS → relay) → merged profile fields."""
    payload = parse_pairing_payload(payload_raw)
    reach = reach_from_payload(payload)
    relay_meta = relay_reach_from_payload(payload)
    peer_pubkey = node_peer_pubkey(signing_key_path)
    code = str(payload["code"])
    errors: list[str] = []

    result: dict[str, Any] | None = None
    lan_hint = ""

    for hint in lan_hints_from_payload(payload):
        try:
            result = pair_with_storage_app(
                lan_hint=hint,
                code=code,
                peer_pubkey=peer_pubkey,
                node_id=node_id,
                name=name,
            )
            lan_hint = hint
            break
        except PairingPayloadError as e:
            errors.append(f"lan({hint}): {e}")

    if result is None and reach.get("mdns", True):
        for hint in discover_ppc_lan_hints():
            try:
                result = pair_with_storage_app(
                    lan_hint=hint,
                    code=code,
                    peer_pubkey=peer_pubkey,
                    node_id=node_id,
                    name=name,
                )
                lan_hint = hint
                break
            except PairingPayloadError as e:
                errors.append(f"mdns({hint}): {e}")

    if result is None and relay_meta:
        try:
            result = pair_with_storage_app_via_relay(
                relay_url=relay_meta["relay_url"],
                storage_node_id=relay_meta["storage_node_id"],
                code=code,
                peer_pubkey=peer_pubkey,
                node_id=node_id,
                name=name,
                signing_key_path=signing_key_path,
                caller_node_id=caller_node_id or node_id,
            )
            lan_hint = ""
        except PairingPayloadError as e:
            errors.append(f"relay: {e}")

    if result is None:
        raise PairingPayloadError("; ".join(errors) or "no route to storage-app")

    out: dict[str, Any] = {
        "storage_pubkey": result["storage_pubkey"],
        "lan_hint": lan_hint,
        "fingerprint": payload.get("fingerprint"),
        "peer_pubkey": peer_pubkey,
        "port": int(reach.get("port") or 7345),
        "intent": payload.get("intent") or "node",
    }
    if relay_meta:
        out["relay_url"] = relay_meta["relay_url"]
        out["storage_node_id"] = relay_meta["storage_node_id"]
    return out
