#!/usr/bin/env python3
"""Offline TUF ceremony, signed release builder and atomic publisher for OUO."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from securesystemslib.signer import CryptoSigner, SSlibKey
from tuf.api.metadata import MetaFile, Metadata, Role, Root, Snapshot, TargetFile, Targets, Timestamp


ROOT_COUNT = 5
ROOT_THRESHOLD = 3
TARGETS_COUNT = 3
TARGETS_THRESHOLD = 2
TARGET_CUSTOM_FIELDS = {
    "policy_version", "release_version", "release_epoch", "protocol_version",
    "minimum_protocol_version", "rollout_percent",
}


def _atomic_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _write_metadata(metadata: Metadata, path: Path) -> bytes:
    metadata.to_file(str(path))
    os.chmod(path, 0o644)
    return path.read_bytes()


def _new_signer(path: Path, password: str) -> CryptoSigner:
    signer = CryptoSigner.generate_ed25519()
    private = load_pem_private_key(signer.private_bytes, password=None)
    encrypted = private.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.BestAvailableEncryption(password.encode("utf-8")),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encrypted)
    os.chmod(path, 0o600)
    return signer


def _load_signer(ceremony: Path, name: str) -> CryptoSigner:
    secrets_data = json.loads((ceremony / "ceremony-passphrases.json").read_text())
    public_data = json.loads((ceremony / "public-keys.json").read_text())
    password = secrets_data[name].encode("utf-8")
    private = load_pem_private_key(
        (ceremony / "private" / f"{name}.pem").read_bytes(), password=password
    )
    key_data = public_data[name]
    public = SSlibKey.from_dict(key_data["keyid"], key_data["key"])
    return CryptoSigner(private, public)


def ceremony(args: argparse.Namespace) -> None:
    output = Path(args.output).resolve()
    if output.exists():
        raise SystemExit(f"refusing to overwrite ceremony directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".tuf-ceremony-", dir=output.parent))
    os.chmod(stage, 0o700)
    try:
        signers: dict[str, CryptoSigner] = {}
        passwords: dict[str, str] = {}
        names = (
            [f"root-{index}" for index in range(1, ROOT_COUNT + 1)]
            + [f"targets-{index}" for index in range(1, TARGETS_COUNT + 1)]
            + ["snapshot-1", "timestamp-1"]
        )
        for name in names:
            password = secrets.token_urlsafe(32)
            passwords[name] = password
            signers[name] = _new_signer(stage / "private" / f"{name}.pem", password)

        public = {
            name: {"keyid": signer.public_key.keyid, "key": signer.public_key.to_dict()}
            for name, signer in signers.items()
        }
        _atomic_json(stage / "public-keys.json", public, 0o644)
        _atomic_json(stage / "ceremony-passphrases.json", passwords, 0o600)

        now = datetime.now(timezone.utc)
        root = Root(version=1, expires=now + timedelta(days=365), consistent_snapshot=False)
        role_names = {
            "root": [f"root-{index}" for index in range(1, ROOT_COUNT + 1)],
            "targets": [f"targets-{index}" for index in range(1, TARGETS_COUNT + 1)],
            "snapshot": ["snapshot-1"],
            "timestamp": ["timestamp-1"],
        }
        thresholds = {"root": ROOT_THRESHOLD, "targets": TARGETS_THRESHOLD, "snapshot": 1, "timestamp": 1}
        for role, members in role_names.items():
            root.roles[role] = Role([signers[name].public_key.keyid for name in members], thresholds[role])
            for name in members:
                root.add_key(signers[name].public_key, role)
        root_metadata = Metadata(root)
        for name in role_names["root"]:
            root_metadata.sign(signers[name], append=True)
        (stage / "trusted").mkdir()
        _write_metadata(root_metadata, stage / "trusted" / "root.json")
        (stage / "CEREMONY.txt").write_text(
            "OUO TUF ceremony v1\nroot: 3-of-5\ntargets: 2-of-3\n"
            "Distribute private keys and passphrases to independent offline custodians.\n",
            encoding="utf-8",
        )
        os.chmod(stage / "CEREMONY.txt", 0o644)
        os.replace(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"created TUF root 3-of-5 and targets 2-of-3 ceremony at {output}")


def build_release(args: argparse.Namespace) -> None:
    ceremony_dir = Path(args.ceremony).resolve()
    artifact = Path(args.artifact).resolve()
    output = Path(args.output).resolve()
    if output.exists():
        raise SystemExit(f"refusing to overwrite signed bundle: {output}")
    if not artifact.is_file() or artifact.is_symlink():
        raise SystemExit("artifact must be a regular file")
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,256}", args.target) or ".." in Path(args.target).parts:
        raise SystemExit("unsafe target path")
    custom = {
        "policy_version": "ouo-update-policy/1",
        "release_version": args.release_version,
        "release_epoch": args.release_epoch,
        "protocol_version": args.protocol_version,
        "minimum_protocol_version": args.minimum_protocol_version,
        "rollout_percent": args.rollout_percent,
    }
    if (
        set(custom) != TARGET_CUSTOM_FIELDS
        or args.release_epoch < 1
        or args.protocol_version < 1
        or args.minimum_protocol_version < 1
        or not 1 <= args.rollout_percent <= 100
    ):
        raise SystemExit("invalid critical target metadata")

    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".tuf-release-", dir=output.parent))
    try:
        metadata_dir = stage / "metadata"
        target_path = stage / "targets" / args.target
        metadata_dir.mkdir(parents=True)
        target_path.parent.mkdir(parents=True)
        shutil.copyfile(artifact, target_path)
        os.chmod(target_path, 0o644)
        shutil.copyfile(ceremony_dir / "trusted" / "root.json", metadata_dir / "root.json")

        now = datetime.now(timezone.utc)
        target_file = TargetFile.from_file(args.target, str(target_path), ["sha256"])
        target_file.unrecognized_fields["custom"] = custom
        targets = Metadata(Targets(version=args.release_epoch, expires=now + timedelta(days=90), targets={args.target: target_file}))
        for index in range(1, TARGETS_COUNT + 1):
            targets.sign(_load_signer(ceremony_dir, f"targets-{index}"), append=True)
        targets_bytes = _write_metadata(targets, metadata_dir / "targets.json")

        snapshot = Metadata(Snapshot(version=args.release_epoch, expires=now + timedelta(days=7), meta={
            "targets.json": MetaFile.from_data(args.release_epoch, targets_bytes, ["sha256"])
        }))
        snapshot.sign(_load_signer(ceremony_dir, "snapshot-1"))
        snapshot_bytes = _write_metadata(snapshot, metadata_dir / "snapshot.json")

        timestamp = Metadata(Timestamp(version=args.release_epoch, expires=now + timedelta(days=1), snapshot_meta=MetaFile.from_data(args.release_epoch, snapshot_bytes, ["sha256"])))
        timestamp.sign(_load_signer(ceremony_dir, "timestamp-1"))
        _write_metadata(timestamp, metadata_dir / "timestamp.json")
        _atomic_json(stage / "bundle.json", {"bundle_version": "ouo-tuf-bundle/1", "target": args.target}, 0o644)
        os.replace(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"created signed TUF release bundle at {output}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish(args: argparse.Namespace) -> None:
    bundle = Path(args.bundle).resolve()
    repository = Path(args.repository).resolve()
    descriptor = json.loads((bundle / "bundle.json").read_text())
    if set(descriptor) != {"bundle_version", "target"} or descriptor["bundle_version"] != "ouo-tuf-bundle/1":
        raise SystemExit("invalid signed bundle descriptor")
    target_name = descriptor["target"]
    root = Metadata[Root].from_file(str(bundle / "metadata" / "root.json"))
    targets = Metadata[Targets].from_file(str(bundle / "metadata" / "targets.json"))
    snapshot = Metadata[Snapshot].from_file(str(bundle / "metadata" / "snapshot.json"))
    timestamp = Metadata[Timestamp].from_file(str(bundle / "metadata" / "timestamp.json"))
    root.signed.verify_delegate("root", root.signed_bytes, root.signatures)
    root.signed.verify_delegate("targets", targets.signed_bytes, targets.signatures)
    root.signed.verify_delegate("snapshot", snapshot.signed_bytes, snapshot.signatures)
    root.signed.verify_delegate("timestamp", timestamp.signed_bytes, timestamp.signatures)
    if any(item.signed.is_expired() for item in (root, targets, snapshot, timestamp)):
        raise SystemExit("refusing to publish expired TUF metadata")
    if not (targets.signed.version == snapshot.signed.version == timestamp.signed.version):
        raise SystemExit("metadata versions do not describe one release epoch")
    targets_bytes = (bundle / "metadata" / "targets.json").read_bytes()
    snapshot_bytes = (bundle / "metadata" / "snapshot.json").read_bytes()
    snapshot.signed.meta["targets.json"].verify_length_and_hashes(targets_bytes)
    timestamp.signed.snapshot_meta.verify_length_and_hashes(snapshot_bytes)
    if set(targets.signed.targets) != {target_name}:
        raise SystemExit("bundle must contain exactly the declared target")
    target_path = bundle / "targets" / target_name
    targets.signed.targets[target_name].verify_length_and_hashes(target_path.read_bytes())
    custom = targets.signed.targets[target_name].custom
    if not isinstance(custom, dict) or set(custom) != TARGET_CUSTOM_FIELDS:
        raise SystemExit("invalid critical OUO target metadata")

    release_name = f"{custom['release_epoch']:020d}-{custom['release_version']}"
    if not re.fullmatch(r"[0-9A-Za-z._-]{1,96}", release_name):
        raise SystemExit("unsafe release name")
    releases = repository / "releases"
    destination = releases / release_name
    if destination.exists():
        raise SystemExit(f"release already published: {release_name}")
    releases.mkdir(parents=True, exist_ok=True)
    current = repository / "current"
    if current.exists() and not current.is_symlink():
        raise SystemExit("repository current must be a symlink")
    previous_entry_hash = None
    if current.is_symlink():
        previous_record = current.resolve() / "transparency.json"
        if not previous_record.is_file():
            raise SystemExit("previous release transparency record is missing")
        previous_entry_hash = _sha256(previous_record)
    stage = Path(tempfile.mkdtemp(prefix=".publish-", dir=releases))
    try:
        shutil.copytree(bundle / "metadata", stage / "metadata")
        shutil.copytree(bundle / "targets", stage / "targets")
        _atomic_json(stage / "transparency.json", {
            "log_version": "ouo-release-transparency/1",
            "published_at": datetime.now(timezone.utc).isoformat(),
            "release_epoch": custom["release_epoch"],
            "release_version": custom["release_version"],
            "previous_entry_sha256": previous_entry_hash,
            "target": target_name,
            "target_sha256": _sha256(target_path),
            "metadata_sha256": {name: _sha256(stage / "metadata" / name) for name in ("root.json", "targets.json", "snapshot.json", "timestamp.json")},
        }, 0o644)
        os.replace(stage, destination)
        _fsync_directory(releases)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    temporary_link = repository / f".current-{secrets.token_hex(8)}"
    temporary_link.symlink_to(Path("releases") / release_name)
    os.replace(temporary_link, current)
    _fsync_directory(repository)
    print(f"atomically published {release_name} at {repository / 'current'}")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("ceremony")
    create.add_argument("--output", required=True)
    create.set_defaults(function=ceremony)
    release = sub.add_parser("build-release")
    release.add_argument("--ceremony", required=True)
    release.add_argument("--artifact", required=True)
    release.add_argument("--target", required=True)
    release.add_argument("--release-version", required=True)
    release.add_argument("--release-epoch", required=True, type=int)
    release.add_argument("--protocol-version", required=True, type=int)
    release.add_argument("--minimum-protocol-version", required=True, type=int)
    release.add_argument("--rollout-percent", required=True, type=int)
    release.add_argument("--output", required=True)
    release.set_defaults(function=build_release)
    publisher = sub.add_parser("publish")
    publisher.add_argument("--bundle", required=True)
    publisher.add_argument("--repository", required=True)
    publisher.set_defaults(function=publish)
    args = parser.parse_args()
    args.function(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
