#!/usr/bin/env python3
"""Minimal local CLI for owner-device pairing and revocation."""

import argparse
import json
import os
from pathlib import Path
from datetime import datetime, timedelta, timezone

from shared.security.keys import load_or_create_signing_key
from shared.security.owner_management_store import OwnerManagementStore


def _store(args) -> OwnerManagementStore:
    return OwnerManagementStore(
        args.state,
        node_root_signing_key=load_or_create_signing_key(args.root_key),
    )


def main() -> int:
    parser = argparse.ArgumentParser(prog="ouoctl")
    parser.add_argument(
        "--root-key",
        default=os.environ.get("NODE_ROOT_KEY_PATH", "/data/node_root_key"),
    )
    parser.add_argument(
        "--state",
        default=os.environ.get(
            "OWNER_MANAGEMENT_STATE_PATH", "/data/owner_management_state.json"
        ),
    )
    commands = parser.add_subparsers(dest="command", required=True)

    pair = commands.add_parser("pair", help="create a one-time phone pairing payload")
    pair.add_argument("--role", choices=("viewer", "operator", "owner"), default="owner")
    pair.add_argument("--expires", type=int, default=5, metavar="MINUTES")
    pair.add_argument(
        "--endpoint",
        action="append",
        default=None,
        help="HTTPS/VPN management endpoint; repeat for fallback endpoints",
    )
    pair.add_argument(
        "--ca-fingerprint",
        default=os.environ.get("MANAGEMENT_CA_FINGERPRINT", ""),
    )

    commands.add_parser("list", help="list paired owner devices")
    revoke = commands.add_parser("revoke", help="revoke one owner device certificate")
    revoke.add_argument("serial")

    args = parser.parse_args()
    store = _store(args)
    now = datetime.now(timezone.utc)
    if args.command == "pair":
        payload = store.create_pairing(
            role=args.role,
            now=now,
            expires_in=timedelta(minutes=args.expires),
        )
        payload["kind"] = "ouo_node_owner_pair"
        payload["version"] = 1
        default_scheme = "https" if Path("/tls/server.crt").is_file() else "http"
        payload["management_endpoints"] = args.endpoint or [
            os.environ.get(
                "MANAGEMENT_PUBLIC_ENDPOINT", f"{default_scheme}://127.0.0.1:9443"
            )
        ]
        fingerprint = args.ca_fingerprint
        fingerprint_file = Path("/tls/fingerprint.txt")
        if not fingerprint and fingerprint_file.is_file():
            fingerprint = fingerprint_file.read_text(encoding="utf-8").strip()
        payload["management_ca_fingerprint"] = fingerprint
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    if args.command == "list":
        print(json.dumps({"devices": store.list_devices(now=now)}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "revoke":
        if not store.revoke_device(args.serial):
            parser.error("owner device not found")
        print(json.dumps({"status": "revoked", "serial": args.serial}))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
