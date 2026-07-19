#!/usr/bin/env python3
"""Manual E2E helper: PUT/GET a blob via media-node PersonalPCBackend.

Assumes pairing is already done (peer must exist on storage-app).

Usage (LAN-direct):
  python storage-app/tools/ppc_blob_smoke.py \\
    --user-id alice \\
    --signing-key /path/to/node.ed25519.seed \\
    --lan-hint 192.168.1.42:7345

Usage (relay-fallback):
  python storage-app/tools/ppc_blob_smoke.py \\
    --user-id alice \\
    --signing-key ./keys/node.seed \\
    --relay-url https://relay.example.org \\
    --storage-node-id storage-home-pc \\
    --node-id media-smoke

On success prints JSON: {"status": "ok", "key": "...", "size": N, "transport": "lan"|"relay"}.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "backend" / "services" / "media-node"))
sys.path.insert(0, str(REPO_ROOT / "backend"))

from app.backends.personal_pc import (  # noqa: E402
    PersonalPCBackend,
    PersonalPCError,
    PersonalPCSettings,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Smoke-test PUT/GET blob via PersonalPCBackend (LAN or relay).",
    )
    parser.add_argument("--user-id", required=True, help="PPC user namespace on storage-app")
    parser.add_argument(
        "--signing-key",
        required=True,
        dest="signing_key",
        help="Path to node Ed25519 seed file (base64url)",
    )
    parser.add_argument(
        "--lan-hint",
        default="",
        help="LAN host:port for direct HTTP (e.g. 192.168.1.42:7345)",
    )
    parser.add_argument(
        "--relay-url",
        default="",
        help="Relay base URL for relay-fallback transport",
    )
    parser.add_argument(
        "--storage-node-id",
        default="",
        dest="storage_node_id",
        help="Storage-app node id registered on relay",
    )
    parser.add_argument(
        "--data",
        default="hello-ppc-smoke",
        help='Blob payload string (default: "hello-ppc-smoke")',
    )
    parser.add_argument(
        "--node-id",
        default="",
        help="X-PPC-Node-Id header (default: $MEDIA_NODE_ID or media-smoke)",
    )
    args = parser.parse_args()

    has_lan = bool(args.lan_hint.strip())
    has_relay = bool(args.relay_url.strip()) and bool(args.storage_node_id.strip())
    if not has_lan and not has_relay:
        print(
            json.dumps(
                {
                    "error": "provide --lan-hint or both --relay-url and --storage-node-id",
                },
                indent=2,
            )
        )
        return 1

    signing_key = Path(args.signing_key)
    if not signing_key.is_file():
        print(json.dumps({"error": f"signing key not found: {signing_key}"}, indent=2))
        return 1

    node_id = args.node_id.strip() or os.getenv("MEDIA_NODE_ID", "media-smoke")
    os.environ["MEDIA_NODE_ID"] = node_id

    transport = "lan" if has_lan else "relay"
    cfg = PersonalPCSettings(
        user_id=args.user_id,
        peer_pubkey="",
        lan_hint=args.lan_hint.strip(),
        relay_url=args.relay_url.strip(),
        storage_node_id=args.storage_node_id.strip(),
    )

    data = args.data.encode("utf-8")
    key = hashlib.sha256(data).hexdigest()

    backend = PersonalPCBackend(cfg, node_signing_key_path=str(signing_key))
    try:
        backend.put(key, data)
        got = backend.get(key)
        if got != data:
            print(
                json.dumps(
                    {
                        "error": "round-trip mismatch",
                        "key": key,
                        "expected_size": len(data),
                        "got_size": len(got) if got is not None else None,
                    },
                    indent=2,
                )
            )
            return 1
        print(
            json.dumps(
                {
                    "status": "ok",
                    "key": key,
                    "size": len(data),
                    "transport": transport,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    except PersonalPCError as e:
        print(json.dumps({"error": str(e), "key": key, "transport": transport}, indent=2))
        return 1
    except Exception as e:
        print(
            json.dumps(
                {
                    "error": f"{type(e).__name__}: {e}",
                    "key": key,
                    "transport": transport,
                },
                indent=2,
            )
        )
        return 1
    finally:
        backend.close()


if __name__ == "__main__":
    raise SystemExit(main())
