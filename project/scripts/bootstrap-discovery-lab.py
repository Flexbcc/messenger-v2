#!/usr/bin/env python3
"""Register the three Discovery identities at every local Discovery origin."""
from __future__ import annotations

import argparse
import json
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--origin", action="append", dest="origins", required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    context = ssl.create_default_context(cafile=str(args.ca_file))
    for origin in args.origins:
        for name in ("discovery-d1", "discovery-d2", "discovery-d3"):
            payload = manifest["nodes"][name]["registration_payload"]
            request = urllib.request.Request(
                f"{origin}/registry/nodes",
                data=json.dumps(payload, separators=(",", ":")).encode(),
                method="POST",
                headers={"Content-Type": "application/json"},
            )
            last_error = None
            for _attempt in range(30):
                try:
                    with urllib.request.urlopen(request, context=context, timeout=10) as response:
                        if response.status != 200:
                            raise RuntimeError(
                                f"{origin}: registration of {name} returned {response.status}"
                            )
                    break
                except urllib.error.HTTPError as exc:
                    detail = exc.read(1000).decode("utf-8", "replace")
                    raise RuntimeError(
                        f"{origin}: registration of {name} returned {exc.code}: {detail}"
                    ) from exc
                except OSError as exc:
                    last_error = exc
                    time.sleep(1)
            else:
                raise RuntimeError(
                    f"{origin}: registration of {name} could not connect: {last_error}"
                )
    print("Registered 3 Discovery identities at 3 Discovery origins")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
