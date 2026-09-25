#!/usr/bin/env python3
"""Create missing local-only Compose secrets without printing their values."""

from __future__ import annotations

import os
import secrets
import tempfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = PROJECT_ROOT / ".env"
REQUIRED = ("GATEWAY_INVITE_SECRET",)


def parse(lines: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def main() -> int:
    lines = ENV_PATH.read_text(encoding="utf-8").splitlines() if ENV_PATH.exists() else []
    configured = parse(lines)
    created: list[str] = []
    for key in REQUIRED:
        if configured.get(key):
            continue
        lines.append(f"{key}={secrets.token_urlsafe(48)}")
        created.append(key)
    if not created:
        print("local secrets already configured")
        return 0

    fd, temporary = tempfile.mkstemp(dir=PROJECT_ROOT, prefix=".env.", text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines).rstrip() + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, ENV_PATH)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    print("created local secrets: " + ", ".join(created))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
