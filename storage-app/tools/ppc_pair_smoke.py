#!/usr/bin/env python3
"""Manual E2E helper: pair a node with storage-app from a QR/pairing payload.

Bypasses the owner panel and calls ``pair_from_qr_payload`` directly.

Usage:
  python storage-app/tools/ppc_pair_smoke.py \\
    --payload '{"kind":"ouo_ppc_pair","code":"123456",...}' \\
    --user-id alice \\
    --signing-key /path/to/node.ed25519.seed

  python storage-app/tools/ppc_pair_smoke.py \\
    --payload /tmp/ppc_pair.json \\
    --user-id alice \\
    --signing-key ./keys/node.seed \\
    --name home:smoke \\
    --caller-node-id home-local
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "backend"))

from shared.storage.personal_pc_pairing import PairingPayloadError, pair_from_qr_payload


def load_payload(raw: str) -> str | dict:
    path = Path(raw)
    if path.is_file():
        return path.read_text(encoding="utf-8")
    return raw


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Smoke-test storage-app pairing from QR JSON (no owner panel).",
    )
    parser.add_argument(
        "--payload",
        required=True,
        help="Pairing JSON string or path to a .json file",
    )
    parser.add_argument(
        "--user-id",
        required=True,
        help="Node/user id sent to storage-app as peer id",
    )
    parser.add_argument(
        "--signing-key",
        required=True,
        dest="signing_key",
        help="Path to node Ed25519 seed file (base64url)",
    )
    parser.add_argument(
        "--name",
        default="home:smoke",
        help="Peer display name (default: home:smoke)",
    )
    parser.add_argument(
        "--caller-node-id",
        default="",
        dest="caller_node_id",
        help="Relay caller node id (optional; defaults to node_id in relay path)",
    )
    args = parser.parse_args()

    signing_key = Path(args.signing_key)
    if not signing_key.is_file():
        print(json.dumps({"error": f"signing key not found: {signing_key}"}, indent=2))
        return 1

    try:
        payload_raw = load_payload(args.payload)
        result = pair_from_qr_payload(
            payload_raw,
            signing_key_path=str(signing_key),
            node_id=args.user_id,
            name=args.name,
            caller_node_id=args.caller_node_id,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except PairingPayloadError as e:
        print(json.dumps({"error": str(e)}, indent=2))
        return 1
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}, indent=2))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
