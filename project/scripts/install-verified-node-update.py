#!/usr/bin/env python3
"""Atomically activate a TUF-verified OUO tar release with health rollback."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


def _load_update_policy():
    path = Path(__file__).resolve().parents[1] / "shared/security/update_policy.py"
    spec = importlib.util.spec_from_file_location("ouo_update_policy", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load update policy")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_update_policy = _load_update_policy()
UpdateDecision = _update_policy.UpdateDecision
commit_state = _update_policy.commit_state
load_state = _update_policy.load_state


RECEIPT_FIELDS = {
    "receipt_version", "target", "downloaded_path", "release_version",
    "release_epoch", "protocol_version", "length", "hashes",
}


def _command(value: str | None) -> list[str] | None:
    if value is None:
        return None
    parsed = json.loads(value)
    if not isinstance(parsed, list) or not parsed or not all(isinstance(item, str) and item for item in parsed):
        raise ValueError("command must be a non-empty JSON string array")
    return parsed


def _digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _extract(artifact: Path, destination: Path) -> None:
    total = 0
    with tarfile.open(artifact, "r:*") as archive:
        members = archive.getmembers()
        if not members or len(members) > 100_000:
            raise ValueError("invalid release archive member count")
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                raise ValueError(f"unsafe archive member: {member.name}")
            total += member.size
            if total > 8 * 1024 * 1024 * 1024:
                raise ValueError("release archive exceeds extraction limit")
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"missing archive data: {member.name}")
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)


def _switch(link: Path, target: str) -> None:
    temporary = link.parent / f".{link.name}.{os.getpid()}"
    temporary.symlink_to(target)
    os.replace(temporary, link)
    descriptor = os.open(link.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--install-root", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--restart-command-json")
    parser.add_argument("--health-url", required=True)
    parser.add_argument("--health-timeout", type=float, default=15.0)
    args = parser.parse_args()
    restart = _command(args.restart_command_json)
    health_uri = urlsplit(args.health_url)
    if health_uri.scheme not in {"http", "https"} or not health_uri.hostname or health_uri.username or health_uri.password:
        raise SystemExit("health URL must be absolute HTTP(S) without credentials")
    receipt_path = Path(args.receipt)
    if not receipt_path.is_file() or receipt_path.is_symlink() or receipt_path.stat().st_mode & 0o077:
        raise SystemExit("verified receipt must be a private regular file")
    receipt = json.loads(receipt_path.read_text())
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_FIELDS or receipt.get("receipt_version") != "ouo-verified-update/1":
        raise SystemExit("invalid verified update receipt")
    artifact = Path(receipt["downloaded_path"])
    if not artifact.is_file() or artifact.is_symlink() or artifact.stat().st_size != receipt["length"]:
        raise SystemExit("verified artifact length mismatch")
    for algorithm, expected in receipt["hashes"].items():
        if algorithm not in {"sha256", "sha512"} or _digest(artifact, algorithm) != expected:
            raise SystemExit("verified artifact hash mismatch")
    decision = UpdateDecision(
        target_path=receipt["target"], release_version=receipt["release_version"],
        release_epoch=receipt["release_epoch"], protocol_version=receipt["protocol_version"], eligible=True,
    )
    current_state = load_state(args.state)
    if current_state and decision.release_epoch <= current_state["highest_release_epoch"]:
        raise SystemExit("release rollback/reuse detected")
    if not isinstance(decision.release_version, str) or not decision.release_version.replace(".", "").replace("-", "").isalnum():
        raise SystemExit("unsafe release version")

    install_root = Path(args.install_root).resolve()
    versions = install_root / "versions"
    versions.mkdir(parents=True, exist_ok=True)
    final = versions / f"{decision.release_epoch:020d}-{decision.release_version}"
    if final.exists():
        raise SystemExit("release directory already exists")
    current_link = install_root / "current"
    if current_link.exists() and not current_link.is_symlink():
        raise SystemExit("install current must be a symlink")
    stage = Path(tempfile.mkdtemp(prefix=".install-", dir=versions))
    old_target = os.readlink(current_link) if current_link.is_symlink() else None
    try:
        _extract(artifact, stage)
        os.replace(stage, final)
        _switch(install_root / "current", os.path.relpath(final, install_root))
        if restart:
            subprocess.run(restart, check=True, shell=False)
        with urllib.request.urlopen(args.health_url, timeout=args.health_timeout) as response:
            if not 200 <= response.status < 300:
                raise RuntimeError(f"health returned {response.status}")
        commit_state(args.state, decision)
    except Exception:
        if old_target is not None:
            _switch(install_root / "current", old_target)
            if restart:
                subprocess.run(restart, check=False, shell=False)
        elif (install_root / "current").is_symlink():
            (install_root / "current").unlink()
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"activated {final.name}; previous version retained for rollback")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
