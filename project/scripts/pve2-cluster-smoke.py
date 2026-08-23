#!/usr/bin/env python3
"""Live PVE2 lab smoke test using only public Home/Gateway APIs.

Run from a container attached to the ``ouo-pve2-lab_ouo-control`` network.
The script prints no access tokens or private key material.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


HOME_A = os.environ.get("OUO_HOME_A", "http://home-a:8001")
HOME_B = os.environ.get("OUO_HOME_B", "http://home-b:8001")


def request(method: str, url: str, *, payload: dict | None = None, token: str | None = None):
    headers: dict[str, str] = {}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url}: HTTP {error.code}: {detail}") from error


def device_material(label: str) -> tuple[str, dict]:
    public_key = base64.b64encode(os.urandom(32)).decode()
    return public_key, {"identity_key": f"lab-{label}-{uuid.uuid4().hex}"}


def register(base: str, label: str, phone: str, password: str) -> dict:
    public_key, bundle = device_material(f"{label}-device-1")
    status, challenge = request("GET", f"{base}/auth/pow-challenge")
    assert status == 200
    nonce = 0
    prefix = "0" * int(challenge["difficulty"])
    while not hashlib.sha256(
        f"{challenge['challenge']}:{nonce}".encode()
    ).hexdigest().startswith(prefix):
        nonce += 1
    status, body = request(
        "POST",
        f"{base}/auth/register",
        payload={
            "display_name": label,
            "phone": phone,
            "password": password,
            "device_name": f"{label} primary",
            "device_type": "desktop",
            "auth_public_key": public_key,
            "identity_key_bundle": bundle,
            "pow_challenge": challenge["challenge"],
            "pow_nonce": str(nonce),
        },
    )
    assert status == 200
    return body


def main() -> None:
    suffix = f"{int(time.time())}{uuid.uuid4().hex[:6]}"
    password = base64.urlsafe_b64encode(os.urandom(18)).decode()
    alice = register(HOME_A, "PVE2 Alice", f"+7001{suffix[-8:]}", password)
    bob_phone = f"+7002{suffix[-8:]}"
    bob = register(HOME_B, "PVE2 Bob", bob_phone, password)

    bob_second_key, bob_second_bundle = device_material("bob-device-2")
    status, bob_second = request(
        "POST",
        f"{HOME_B}/auth/login",
        payload={
            "identifier": bob_phone,
            "password": password,
            "device_name": "PVE2 Bob secondary",
            "device_type": "web",
            "auth_public_key": bob_second_key,
            "identity_key_bundle": bob_second_bundle,
        },
    )
    assert status == 200 and bob_second["user_id"] == bob["user_id"]

    status, devices = request(
        "GET", f"{HOME_B}/users/me/devices", token=bob_second["access_token"]
    )
    assert status == 200 and len(devices) == 2

    status, conversation = request(
        "POST",
        f"{HOME_A}/conversations",
        payload={"type": "direct", "participant_user_ids": [bob["user_id"]]},
        token=alice["access_token"],
    )
    assert status == 200
    conversation_id = conversation["id"]

    status, first = request(
        "POST",
        f"{HOME_A}/conversations/{conversation_id}/messages",
        payload={
            "ciphertext": "opaque-cross-home-first",
            "content_type": "text",
            "crypto_version": "lab-e2ee-v1",
            "client_msg_id": f"first-{suffix}",
        },
        token=alice["access_token"],
    )
    assert status == 200

    time.sleep(0.1)
    status, second = request(
        "POST",
        f"{HOME_A}/conversations/{conversation_id}/messages",
        payload={
            "ciphertext": "opaque-cross-home-second",
            "content_type": "text",
            "crypto_version": "lab-e2ee-v1",
            "client_msg_id": f"second-{suffix}",
        },
        token=alice["access_token"],
    )
    assert status == 200

    query = urllib.parse.urlencode({"after": first["created_at"], "limit": 20})
    status, catchup = request(
        "GET",
        f"{HOME_B}/conversations/{conversation_id}/messages?{query}",
        token=bob_second["access_token"],
    )
    caught = [item for item in catchup["items"] if item["id"] == second["id"]]
    assert status == 200 and len(caught) == 1
    assert caught[0]["ciphertext"] == "opaque-cross-home-second"

    ack_url = f"{HOME_B}/conversations/{conversation_id}/messages/{second['id']}/ack"
    ack_one, _ = request(
        "POST", ack_url, payload={"device_id": bob_second["device_id"]}, token=bob_second["access_token"]
    )
    ack_two, _ = request(
        "POST", ack_url, payload={"device_id": bob_second["device_id"]}, token=bob_second["access_token"]
    )
    assert ack_one == 200 and ack_two == 200

    print(
        json.dumps(
            {
                "cross_home_delivery": True,
                "delivery_ack_idempotent": True,
                "home_a_user": alice["user_id"],
                "home_b_user": bob["user_id"],
                "home_b_devices": len(devices),
                "multi_device_catchup": True,
                "second_packet_id": second["id"],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
