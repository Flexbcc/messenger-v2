#!/usr/bin/env python3
"""Download a TUF-verified node artifact into staging; never install it."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

from tuf.ngclient import Updater


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
evaluate_update = _update_policy.evaluate_update
load_state = _update_policy.load_state


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata-url", required=True)
    parser.add_argument("--targets-url", required=True)
    parser.add_argument("--metadata-dir", required=True)
    parser.add_argument("--targets-dir", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--node-id", required=True)
    parser.add_argument("--current-protocol", required=True, type=int)
    parser.add_argument("--state", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()

    for label, value in (("metadata", args.metadata_url), ("targets", args.targets_url)):
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise SystemExit(f"{label} URL must be absolute HTTPS without credentials")

    metadata_dir = Path(args.metadata_dir)
    trusted_root = metadata_dir / "root.json"
    if not trusted_root.is_file() or trusted_root.is_symlink():
        raise SystemExit("offline-provisioned trusted root.json is required")
    if trusted_root.stat().st_mode & 0o022:
        raise SystemExit("trusted root.json must not be group/world writable")

    updater = Updater(
        metadata_dir=str(metadata_dir),
        metadata_base_url=args.metadata_url.rstrip("/") + "/",
        target_dir=args.targets_dir,
        target_base_url=args.targets_url.rstrip("/") + "/",
    )
    updater.refresh()
    target = updater.get_targetinfo(args.target)
    if target is None:
        raise SystemExit("target is not present in verified TUF metadata")
    decision = evaluate_update(
        target_path=args.target,
        custom=target.custom,
        node_id=args.node_id,
        current_protocol_version=args.current_protocol,
        state=load_state(args.state),
    )
    if not decision.eligible:
        print("node is outside the current signed rollout cohort")
        return 3
    downloaded = updater.download_target(target)

    receipt_path = Path(args.receipt)
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt = {
        "receipt_version": "ouo-verified-update/1",
        "target": decision.target_path,
        "downloaded_path": os.fspath(downloaded),
        "release_version": decision.release_version,
        "release_epoch": decision.release_epoch,
        "protocol_version": decision.protocol_version,
        "length": target.length,
        "hashes": target.hashes,
    }
    descriptor, temporary = tempfile.mkstemp(prefix=".verified-update-", dir=receipt_path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(receipt, handle, sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, receipt_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(os.fspath(downloaded))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
