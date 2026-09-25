#!/usr/bin/env python3
"""Create real lab identities and verify cross-Home encrypted delivery.

Private client material and the machine-readable report are written only to
the ignored operator directory.  The server receives an opaque AEAD envelope;
the verifier decrypts it exclusively with the recipient's client-side key.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


HOMES = [f"https://home-{letter}:8001" for letter in "abcde"]


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def solve_pow(challenge: str, difficulty: int) -> str:
    nonce = 0
    prefix = "0" * difficulty
    while not hashlib.sha256(f"{challenge}:{nonce}".encode()).hexdigest().startswith(prefix):
        nonce += 1
    return str(nonce)


def signal_public_key() -> str:
    key = ec.generate_private_key(ec.SECP256R1()).public_key()
    raw = key.public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.CompressedPoint,
    )
    return b64(raw)


def identity_bundle() -> dict[str, Any]:
    return {
        "identity_key": signal_public_key(),
        "registration_id": (int.from_bytes(os.urandom(4), "big") & 0x7FFFFFFF) or 1,
        "signed_prekey": {
            "id": 1,
            "public_key": signal_public_key(),
            "signature": b64(os.urandom(64)),
        },
        "prekeys": [
            {"id": index, "public_key": signal_public_key()}
            for index in range(10, 15)
        ],
    }


def derive_key(shared_secret: bytes, conversation_id: str) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=("OUO/LAB-E2EE/" + conversation_id).encode(),
    ).derive(shared_secret)


def encrypt_for(recipient_public_b64: str, conversation_id: str, plaintext: str) -> str:
    recipient = x25519.X25519PublicKey.from_public_bytes(base64.b64decode(recipient_public_b64))
    ephemeral = x25519.X25519PrivateKey.generate()
    nonce = os.urandom(12)
    key = derive_key(ephemeral.exchange(recipient), conversation_id)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext.encode(), conversation_id.encode())
    envelope = {
        "v": 1,
        "epk": b64(ephemeral.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )),
        "nonce": b64(nonce),
        "ciphertext": b64(ciphertext),
    }
    return b64(json.dumps(envelope, separators=(",", ":")).encode())


def decrypt_with(private_b64: str, conversation_id: str, envelope_b64: str) -> str:
    envelope = json.loads(base64.b64decode(envelope_b64))
    private = x25519.X25519PrivateKey.from_private_bytes(base64.b64decode(private_b64))
    peer = x25519.X25519PublicKey.from_public_bytes(base64.b64decode(envelope["epk"]))
    key = derive_key(private.exchange(peer), conversation_id)
    plaintext = AESGCM(key).decrypt(
        base64.b64decode(envelope["nonce"]),
        base64.b64decode(envelope["ciphertext"]),
        conversation_id.encode(),
    )
    return plaintext.decode()


def request(client: httpx.Client, method: str, path: str, *, token: str | None = None,
            body: dict[str, Any] | None = None) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    response = client.request(method, path, headers=headers, json=body)
    if response.status_code >= 300:
        raise RuntimeError(f"{method} {path}: HTTP {response.status_code} {response.text[:400]}")
    return response.json()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--users-per-home", type=int, default=5)
    parser.add_argument("--messages", type=int, default=100)
    args = parser.parse_args()
    if not 1 <= args.users_per_home <= 10:
        raise SystemExit("--users-per-home must be between 1 and 10")

    clients = [httpx.Client(base_url=url, verify=args.ca_file, timeout=30) for url in HOMES]
    users: list[dict[str, Any]] = []
    run_id = uuid.uuid4().hex[:10]
    try:
        readiness_deadline = time.monotonic() + 90
        while True:
            ready = True
            for client in clients:
                try:
                    health = request(client, "GET", "/health")
                    peer_state = health["load"]["signed_peer_selection"]
                    ready = ready and peer_state.get("state_valid") is True
                    ready = ready and peer_state.get("auxiliary_counts", {}).get("storage", 0) >= 2
                    ready = ready and peer_state.get("relay_count", 0) >= 2
                except (KeyError, OSError, RuntimeError):
                    ready = False
            if ready:
                break
            if time.monotonic() >= readiness_deadline:
                raise RuntimeError("signed peer selection did not become ready on all Home nodes")
            time.sleep(1)

        for home_index, client in enumerate(clients):
            for local_index in range(args.users_per_home):
                challenge = request(client, "GET", "/auth/pow-challenge")
                auth_private = ed25519.Ed25519PrivateKey.generate()
                e2ee_private = x25519.X25519PrivateKey.generate()
                user_number = home_index * args.users_per_home + local_index
                body = request(
                    client,
                    "POST",
                    "/auth/register",
                    body={
                        "display_name": f"Lab user {user_number + 1}",
                        "phone": f"+990{run_id[:6]}{user_number:03d}",
                        "login": f"lab_{run_id}_{user_number}",
                        "device_name": f"lab-device-{user_number + 1}",
                        "device_type": "desktop",
                        "auth_public_key": b64(auth_private.public_key().public_bytes(
                            serialization.Encoding.Raw, serialization.PublicFormat.Raw
                        )),
                        "identity_key_bundle": identity_bundle(),
                        "pow_challenge": challenge["challenge"],
                        "pow_nonce": solve_pow(challenge["challenge"], int(challenge["difficulty"])),
                    },
                )
                users.append({
                    "home": HOMES[home_index],
                    "home_index": home_index,
                    "user_id": body["user_id"],
                    "device_id": body["device_id"],
                    "access_token": body["access_token"],
                    "auth_private_key": b64(auth_private.private_bytes(
                        serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                        serialization.NoEncryption()
                    )),
                    "e2ee_private_key": b64(e2ee_private.private_bytes(
                        serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                        serialization.NoEncryption()
                    )),
                    "e2ee_public_key": b64(e2ee_private.public_key().public_bytes(
                        serialization.Encoding.Raw, serialization.PublicFormat.Raw
                    )),
                })

        # Signed user records need time to fan out to at least two Discovery sources.
        time.sleep(4)
        sent: list[dict[str, Any]] = []
        for index in range(args.messages):
            sender = users[index % len(users)]
            # Cross-Home by construction and evenly distributed around the ring.
            recipient = users[(index + args.users_per_home) % len(users)]
            sender_client = clients[sender["home_index"]]
            conversation = request(
                sender_client,
                "POST",
                "/conversations",
                token=sender["access_token"],
                body={"type": "direct", "participant_user_ids": [recipient["user_id"]]},
            )
            conversation_id = conversation["id"]
            marker = f"OUO-LAB-PLAINTEXT-{run_id}-{index:04d}"
            ciphertext = encrypt_for(recipient["e2ee_public_key"], conversation_id, marker)
            message = request(
                sender_client,
                "POST",
                f"/conversations/{conversation_id}/messages",
                token=sender["access_token"],
                body={
                    "ciphertext": ciphertext,
                    "content_type": "text",
                    "crypto_version": "ouo-lab-aead-v1",
                    "client_msg_id": str(uuid.uuid4()),
                },
            )
            recipient_client = clients[recipient["home_index"]]
            deadline = time.monotonic() + 15
            observed = None
            while time.monotonic() < deadline:
                response = recipient_client.get(
                    f"/conversations/{conversation_id}/messages?limit=10",
                    headers={"Authorization": f"Bearer {recipient['access_token']}"},
                )
                if response.status_code == 404:
                    time.sleep(0.15)
                    continue
                if response.status_code >= 300:
                    raise RuntimeError(
                        f"recipient history: HTTP {response.status_code} {response.text[:400]}"
                    )
                page = response.json()
                observed = next((item for item in page["items"] if item["id"] == message["id"]), None)
                if observed:
                    break
                time.sleep(0.15)
            if not observed:
                raise RuntimeError(f"message {message['id']} was not delivered cross-Home")
            if decrypt_with(recipient["e2ee_private_key"], conversation_id, observed["ciphertext"]) != marker:
                raise RuntimeError(f"message {message['id']} failed recipient-only decrypt")
            sent.append({
                "message_id": message["id"],
                "conversation_id": conversation_id,
                "recipient_user_id": recipient["user_id"],
                "recipient_home_index": recipient["home_index"],
                "sender_home": sender["home"],
                "recipient_home": recipient["home"],
                "ciphertext": ciphertext,
                "plaintext_marker": marker,
            })

        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({
            "run_id": run_id,
            "users": users,
            "messages": sent,
            "summary": {
                "homes": len(HOMES),
                "users": len(users),
                "messages_sent": len(sent),
                "messages_decrypted_by_recipient": len(sent),
            },
        }, indent=2), encoding="utf-8")
        output.chmod(0o600)
        print(f"Verified {len(users)} users and {len(sent)} recipient-decrypted cross-Home messages")
    finally:
        for client in clients:
            client.close()


if __name__ == "__main__":
    main()
