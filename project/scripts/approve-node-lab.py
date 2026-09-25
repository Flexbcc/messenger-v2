#!/usr/bin/env python3
"""Approve pre-provisioned local-lab nodes through the audited Admin API."""
from __future__ import annotations

import argparse
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


def load_env(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def request(url: str, secret: str, context: ssl.SSLContext, method: str = "GET") -> dict:
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "X-Discovery-Admin-Secret": secret,
            "X-Operator-Id": "local-lab-provisioner",
        },
    )
    with urllib.request.urlopen(req, context=context, timeout=5) as response:
        return json.load(response)


def approve_origin(
    origin: str, secret: str, context: ssl.SSLContext
) -> tuple[int, int, int]:
    listing = request(f"{origin}/admin/registry/nodes?limit=500", secret, context)
    approved = 0
    for node in listing.get("nodes", []):
        if node.get("trust_status") == "trusted":
            continue
        node_id = urllib.parse.quote(node["node_id"], safe="")
        request(
            f"{origin}/admin/registry/nodes/{node_id}/approve",
            secret,
            context,
            method="POST",
        )
        approved += 1
    verified = request(f"{origin}/admin/registry/nodes?limit=500", secret, context)
    trusted = sum(
        1 for node in verified.get("nodes", []) if node.get("trust_status") == "trusted"
    )
    peer_view = request(
        f"{origin}/registry/node-advertisements/peer-view?minimum_sources=2",
        secret,
        context,
    )
    candidates = peer_view.get("candidates", [])
    peer_count = len(candidates) if isinstance(candidates, list) else 0
    return approved, trusted, peer_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--origin", action="append", dest="origins")
    parser.add_argument("--attempts", type=int, default=30)
    parser.add_argument("--expected", type=int, default=9)
    args = parser.parse_args()
    values = load_env(args.env_file) if args.env_file else {}
    secret = values.get("DISCOVERY_ADMIN_SECRET") or os.environ["DISCOVERY_ADMIN_SECRET"]
    context = ssl.create_default_context(cafile=str(args.ca_file))
    context.check_hostname = False
    origins = args.origins or [
        "https://127.0.0.1:18031",
        "https://127.0.0.1:18032",
        "https://127.0.0.1:18033",
    ]
    last_error: Optional[Exception] = None
    for _ in range(args.attempts):
        try:
            results = [approve_origin(origin, secret, context) for origin in origins]
            trusted = [result[1] for result in results]
            peers = [result[2] for result in results]
            if all(count >= args.expected for count in trusted) and all(
                count >= args.expected for count in peers
            ):
                print(
                    "Trusted peer views converged across Discovery: "
                    + ", ".join(
                        f"{trusted_count}/{peer_count}"
                        for trusted_count, peer_count in zip(trusted, peers)
                    )
                )
                return 0
            last_error = RuntimeError(
                f"waiting for {args.expected} trusted registrations and peer candidates "
                f"per Discovery; got trusted={trusted}, peers={peers}"
            )
            time.sleep(2)
        except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
            last_error = exc
            time.sleep(2)
    raise SystemExit(f"Discovery approval did not converge: {last_error}")


if __name__ == "__main__":
    raise SystemExit(main())
