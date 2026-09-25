#!/usr/bin/env python3
"""Verify that the lab's encrypted history survives a service restart.

The input report lives in the ignored operator directory.  It contains the
test clients' credentials and must never be committed or copied to a server.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import httpx

from verify_node_lab_crypto import decrypt_with


HOMES = [f"https://home-{letter}:8001" for letter in "abcde"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    report: dict[str, Any] = json.loads(Path(args.report).read_text(encoding="utf-8"))
    users = {item["user_id"]: item for item in report["users"]}
    clients = [httpx.Client(base_url=url, verify=args.ca_file, timeout=30) for url in HOMES]
    verified = 0
    try:
        for message in report["messages"]:
            recipient = users[message["recipient_user_id"]]
            client = clients[int(message["recipient_home_index"])]
            deadline = time.monotonic() + 15
            observed = None
            while time.monotonic() < deadline:
                response = client.get(
                    f"/conversations/{message['conversation_id']}/messages?limit=10",
                    headers={"Authorization": f"Bearer {recipient['access_token']}"},
                )
                if response.status_code == 200:
                    observed = next(
                        (item for item in response.json()["items"] if item["id"] == message["message_id"]),
                        None,
                    )
                    if observed is not None:
                        break
                elif response.status_code != 404:
                    raise RuntimeError(
                        f"history after restart: HTTP {response.status_code} {response.text[:400]}"
                    )
                time.sleep(0.15)
            if observed is None:
                raise RuntimeError(f"message {message['message_id']} disappeared after restart")
            plaintext = decrypt_with(
                recipient["e2ee_private_key"],
                message["conversation_id"],
                observed["ciphertext"],
            )
            if plaintext != message["plaintext_marker"]:
                raise RuntimeError(f"message {message['message_id']} failed decrypt after restart")
            verified += 1
    finally:
        for client in clients:
            client.close()
    print(f"Verified {verified} encrypted messages after restart")


if __name__ == "__main__":
    main()
