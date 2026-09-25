#!/usr/bin/env python3
"""Pre-deploy smoke checks for the messenger stack (run against running services)."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

HOME = os.environ.get("HOME_URL", "http://localhost:8001")
DISCOVERY = os.environ.get("DISCOVERY_URL", "http://localhost:8003")
GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8007")
MEDIA = os.environ.get("MEDIA_URL", "http://localhost:8004")
TURN = os.environ.get("TURN_URL", "http://localhost:8006")

failures: list[str] = []


def get(url: str) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read()) if e.read else {}
    except urllib.error.URLError as e:
        return 0, {"error": str(e)}


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"OK   {name}")
    else:
        print(f"FAIL {name}: {detail}", file=sys.stderr)
        failures.append(name)


def main() -> int:
    print(f"=== Module smoke ({HOME}) ===")

    code, body = get(f"{HOME}/health")
    check("home-node /health", code == 200 and body.get("node_role") == "home", str(body))

    code, body = get(f"{DISCOVERY}/health")
    check("discovery-node /health", code == 200 and body.get("node_role") == "discovery", str(body))

    code, body = get(f"{GATEWAY}/health")
    check("gateway-node /health", code == 200 and body.get("node_role") == "gateway", str(body))

    code, body = get(f"{MEDIA}/health")
    check("media-node /health", code == 200 and body.get("node_role") == "media", str(body))

    code, body = get(f"{TURN}/health")
    check("turn-node /health", code == 200, str(body))

    code, body = get(f"{GATEWAY}/gateway/routing?cluster_id=default")
    check("gateway /gateway/routing", code == 200 and "home_nodes" in body, str(body)[:120])

    code, body = get(f"{DISCOVERY}/registry/nodes")
    nodes = body.get("nodes", []) if code == 200 else []
    check("discovery /registry/nodes", code == 200 and len(nodes) > 0, f"{len(nodes)} nodes")

    code, body = get(f"{HOME}/internal/mesh/peers")
    check("home mesh /internal/mesh/peers", code == 200 and "peers" in body, f"{len(body.get('peers', []))} peers")

    if failures:
        print(f"\n{len(failures)} failure(s)", file=sys.stderr)
        return 1
    print("\nAll module smoke checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
