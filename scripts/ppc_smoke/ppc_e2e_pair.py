#!/usr/bin/env python3
"""E2E helper: read pairing code from headless storage-app log → POST /ppc/pair.

Headless prints ``storage-app :: pairing-код (TTL 5м): 123456`` — this script
waits for that line, then pairs directly over LAN (no QR payload file needed).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "backend"))

from shared.storage.personal_pc_pairing import (  # noqa: E402
    PairingPayloadError,
    node_peer_pubkey,
    pair_with_storage_app,
)

PAIRING_CODE_RE = re.compile(
    r"pairing-код(?:\s*\([^)]+\))?:\s*(\d{6})",
    re.IGNORECASE,
)


def wait_for_pairing_code(log_path: Path, timeout_s: float) -> str:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if log_path.is_file():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            match = PAIRING_CODE_RE.search(text)
            if match:
                return match.group(1)
        time.sleep(0.25)
    raise PairingPayloadError(
        f"pairing code not found in {log_path} within {timeout_s:.0f}s"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pair with storage-app using pairing code scraped from headless log.",
    )
    parser.add_argument(
        "--log",
        required=True,
        help="Path to headless storage-app stdout/stderr log file",
    )
    parser.add_argument(
        "--lan-hint",
        default="127.0.0.1:7345",
        help="LAN host:port for POST /ppc/pair (default: 127.0.0.1:7345)",
    )
    parser.add_argument(
        "--user-id",
        default="smoke-e2e",
        help="Node/user id sent as peer id (default: smoke-e2e)",
    )
    parser.add_argument(
        "--signing-key",
        required=True,
        dest="signing_key",
        help="Path to node Ed25519 seed file (base64url)",
    )
    parser.add_argument(
        "--name",
        default="home:e2e-smoke",
        help="Peer display name (default: home:e2e-smoke)",
    )
    parser.add_argument(
        "--wait-timeout",
        type=float,
        default=90.0,
        dest="wait_timeout",
        help="Seconds to wait for pairing code in log (default: 90)",
    )
    args = parser.parse_args()

    signing_key = Path(args.signing_key)
    if not signing_key.is_file():
        print(json.dumps({"error": f"signing key not found: {signing_key}"}, indent=2))
        return 1

    try:
        code = wait_for_pairing_code(Path(args.log), args.wait_timeout)
        peer_pubkey = node_peer_pubkey(str(signing_key))
        result = pair_with_storage_app(
            lan_hint=args.lan_hint,
            code=code,
            peer_pubkey=peer_pubkey,
            node_id=args.user_id,
            name=args.name,
        )
        print(json.dumps({"code": code, **result}, indent=2, sort_keys=True))
        return 0
    except PairingPayloadError as e:
        print(json.dumps({"error": str(e)}, indent=2))
        return 1
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}, indent=2))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
