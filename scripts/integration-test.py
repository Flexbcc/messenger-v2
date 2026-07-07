#!/usr/bin/env python3
"""Integration checks against a running local stack (legacy + signed)."""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

HOME = os.environ.get("HOME_URL", "http://localhost:8001")
DISCOVERY = os.environ.get("DISCOVERY_URL", "http://localhost:8003")

failures: list[str] = []
security_mode = "legacy"
envelope_mode = "legacy"
home_node_id = "home-local"


def get(url: str, headers: dict | None = None) -> tuple[int, dict | bytes]:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read()
            try:
                return resp.status, json.loads(body)
            except json.JSONDecodeError:
                return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, body


def post(url: str, payload: dict, headers: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(payload).encode()
    hdrs = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=hdrs, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read()) if e.read else {}


def ok(name: str) -> None:
    print(f"OK  {name}")


def fail(name: str, detail: str) -> None:
    print(f"FAIL {name}: {detail}", file=sys.stderr)
    failures.append(name)


def post_raw(url: str, body: bytes, headers: dict) -> tuple[int, dict]:
    hdrs = {"Content-Type": "application/json", **headers}
    req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"detail": raw.decode(errors="replace")}


def load_security_mode() -> None:
    global security_mode, envelope_mode, home_node_id
    code, body = get(f"{HOME}/health")
    if code == 200:
        sec = body.get("security", {})
        security_mode = sec.get("mode", "legacy")
        envelope_mode = sec.get("envelope_mode", "legacy")
        home_node_id = body.get("node_id", home_node_id)


def test_health_security_block() -> None:
    code, body = get(f"{HOME}/health")
    if code != 200 or body.get("security", {}).get("mode") not in ("legacy", "signed"):
        fail("home health security", str(body))
        return
    ok(
        f"home health security mode={body['security']['mode']} "
        f"envelope={body['security'].get('envelope_mode', '?')}"
    )


def test_gateway_routing() -> None:
    code, body = get("http://localhost:8007/gateway/routing")
    if code != 200 or "defaults" not in body or "home_url" not in body.get("defaults", {}):
        fail("gateway routing", f"code={code} body={body}")
        return
    ok("gateway routing")


def test_gateway_invite() -> None:
    secret = os.environ.get("GATEWAY_INVITE_SECRET", "").strip()
    if not secret:
        print("SKIP gateway invite (GATEWAY_INVITE_SECRET not set)")
        return
    code, created = post(
        "http://localhost:8007/gateway/invite/create",
        {"cluster_id": "default", "ttl_seconds": 120, "label": "integration-test"},
        headers={"X-Gateway-Invite-Secret": secret},
    )
    if code != 200 or "token" not in created:
        fail("gateway invite create", f"code={code} body={created}")
        return
    token = created["token"]
    code2, redeemed = get(f"http://localhost:8007/gateway/invite/redeem/{token}")
    if code2 != 200 or "home_url" not in redeemed:
        fail("gateway invite redeem", f"code={code2} body={redeemed}")
        return
    code3, again = get(f"http://localhost:8007/gateway/invite/redeem/{token}")
    if code3 == 200:
        fail("gateway invite single-use", "second redeem should fail")
        return
    ok("gateway invite create/redeem single-use")


def test_register_and_prekeys() -> None:
    phone = f"+7999{uuid.uuid4().int % 10**7:07d}"
    bundle = {
        "identity_key": "aWtkYXRh",
        "registration_id": 1,
        "signed_prekey": {"id": 1, "public_key": "c3A=", "signature": "c2ln"},
        "prekeys": [
            {"id": 10, "public_key": "cGsx"},
            {"id": 11, "public_key": "cGsy"},
            {"id": 12, "public_key": "cGsz"},
        ],
    }
    code, reg = post(
        f"{HOME}/auth/register",
        {
            "display_name": "Test User",
            "phone": phone,
            "password": "test-password-123",
            "device_name": "test-device",
            "device_type": "desktop",
            "auth_public_key": "dGVzdA==",
            "identity_key_bundle": bundle,
        },
    )
    if code != 200:
        fail("register", f"code={code} {reg}")
        return
    user_id = reg["user_id"]
    ok("register")

    code, legacy = get(f"{HOME}/users/{user_id}/prekey-bundle?v=0")
    if code != 200 or len(legacy.get("bundle", {}).get("prekeys", [])) != 3:
        fail("prekey v=0", f"code={code} prekeys={legacy}")
        return
    ok("prekey v=0 full bundle")

    code, strict = get(f"{HOME}/users/{user_id}/prekey-bundle?v=1")
    if code != 200 or strict.get("api_version") != 1:
        fail("prekey v=1", f"code={code} {strict}")
        return
    if len(strict.get("bundle", {}).get("prekeys", [])) != 1:
        fail("prekey v=1 count", str(strict))
        return
    ok("prekey v=1 one OTP")

    code, strict2 = get(f"{HOME}/users/{user_id}/prekey-bundle?v=1")
    if code != 200 or strict2["bundle"]["prekeys"][0]["id"] == strict["bundle"]["prekeys"][0]["id"]:
        fail("prekey v=1 consume", "same prekey returned twice")
        return
    ok("prekey v=1 consumes OTP")


def test_internal_deliver() -> None:
    conv_id = str(uuid.uuid4())
    packet_id = str(uuid.uuid4())
    payload = {
        "origin_node_id": home_node_id,
        "conversation_meta": {
            "conversation_id": conv_id,
            "type": "direct",
            "name": None,
            "participant_user_ids": [str(uuid.uuid4()), str(uuid.uuid4())],
        },
        "envelope": {
            "packet_id": packet_id,
            "type": "MESSAGE",
            "conversation_id": conv_id,
            "sender_user_id": str(uuid.uuid4()),
            "ciphertext": "encrypted-blob-integration-test",
            "content_type": "text",
        },
    }

    code, body = post(f"{HOME}/internal/deliver", payload)
    if security_mode == "legacy":
        if code != 200:
            fail("internal deliver legacy", f"code={code} {body}")
        else:
            ok("internal deliver legacy open")
        return

    if code not in (401, 403):
        fail("internal deliver unsigned", f"expected 401/403 got {code} {body}")
    else:
        ok("internal deliver signed rejects unsigned")

    key_path = os.environ.get("NODE_SIGNING_KEY_PATH", str(ROOT / "data/home/node_signing_key"))
    if not Path(key_path).is_file():
        fail("signed deliver", f"missing signing key at {key_path}")
        return

    import shared.security.config as sec_cfg
    import shared.security.federation_envelope as fed_env
    from shared.security.federation_auth import sign_federation_request
    from shared.security.keys import load_or_create_signing_key
    from shared.security.payload_builder import build_deliver_payload

    sec_cfg.INTERNAL_SECURITY_MODE = "signed"
    sec_cfg.FEDERATION_ENVELOPE_MODE = envelope_mode
    fed_env.FEDERATION_ENVELOPE_MODE = envelope_mode

    signing_key = load_or_create_signing_key(key_path)
    signed_payload = build_deliver_payload(
        signing_key=signing_key,
        origin_node_id=home_node_id,
        envelope=payload["envelope"],
        conversation_meta=payload["conversation_meta"],
        route="direct",
        target_node_id=home_node_id,
    )
    body_bytes = json.dumps(signed_payload, separators=(",", ":"), ensure_ascii=False).encode()
    fed_headers = sign_federation_request(
        signing_key=signing_key,
        node_id=home_node_id,
        method="POST",
        path="/internal/deliver",
        body=body_bytes,
    )
    code2, body2 = post_raw(f"{HOME}/internal/deliver", body_bytes, fed_headers)
    if code2 != 200:
        fail("signed federation deliver", f"code={code2} {body2}")
    else:
        ok("signed federation deliver accepted")


def test_discovery_nodes() -> None:
    code, body = get(f"{DISCOVERY}/registry/nodes")
    if code != 200 or "nodes" not in body:
        fail("discovery nodes", str(body))
        return
    ok(f"discovery nodes ({len(body['nodes'])} registered)")


def test_turn_credentials() -> None:
    code, _ = post("http://localhost:8006/turn/credentials", {})
    if security_mode == "legacy":
        if code == 200:
            ok("turn credentials legacy open")
        else:
            fail("turn credentials legacy", f"code={code}")
        return
    if code in (401, 403):
        ok("turn credentials signed rejects anonymous")
    else:
        fail("turn credentials signed", f"expected 401 got {code}")


def main() -> int:
    print("=== Integration tests (HOME=%s) ===" % HOME)
    load_security_mode()
    time.sleep(1)  # allow discovery trust cache to warm
    test_health_security_block()
    test_gateway_routing()
    test_gateway_invite()
    test_discovery_nodes()
    test_register_and_prekeys()
    test_internal_deliver()
    test_turn_credentials()
    if failures:
        print(f"\n{len(failures)} failure(s)", file=sys.stderr)
        return 1
    print("\nAll integration checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
