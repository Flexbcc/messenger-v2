#!/usr/bin/env python3
"""Provision independent strict credentials for the local Docker node lab.

The script is intended to run once in the compose ``provisioner`` service.
It writes only to the mounted node volumes and to an ignored operator output
directory. Validator private keys never enter a runtime node volume.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nacl.signing import SigningKey
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from shared.security.capability_certificate import (
    add_validator_signature,
    build_capability_certificate,
)
from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.node_identity_credentials import (
    load_or_update_operational_credential_state,
    node_identity_registration_fields,
)
from shared.security.runtime import federation_registration_fields


NODES: dict[str, tuple[str, int, str]] = {
    "discovery-d1": ("discovery", 4, "https://discovery-d1:8003"),
    "discovery-d2": ("discovery", 4, "https://discovery-d2:8003"),
    "discovery-d3": ("discovery", 4, "https://discovery-d3:8003"),
    "home-a": ("home", 0, "https://home-a:8001"),
    "home-b": ("home", 0, "https://home-b:8001"),
    "home-c": ("home", 0, "https://home-c:8001"),
    "home-d": ("home", 0, "https://home-d:8001"),
    "home-e": ("home", 0, "https://home-e:8001"),
    "storage-a": ("storage", 4, "https://storage-a:8002"),
    "storage-b": ("storage", 4, "https://storage-b:8002"),
    "relay-a": ("relay", 2, "https://relay-a:8005"),
    "relay-b": ("relay", 2, "https://relay-b:8005"),
    "gateway": ("gateway", 4, "https://gateway:8007"),
    "turn-api": ("turn", 4, "https://turn-api:8006"),
}


def compact_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"


def private_key_b64(key: SigningKey) -> str:
    return base64.urlsafe_b64encode(bytes(key)).decode("ascii").rstrip("=")


def write_private(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)


def load_or_create_discovery_key(path: Path) -> SigningKey:
    """Accept both the legacy base64 seed and Discovery's normalized binary seed."""
    if path.exists():
        raw = path.read_bytes()
        if len(raw) == 32:
            return SigningKey(raw)
        try:
            decoded = base64.b64decode(raw.strip(), altchars=b"-_", validate=True)
        except (TypeError, ValueError) as exc:
            raise RuntimeError(f"malformed Discovery signing key: {path}") from exc
        if len(decoded) != 32:
            raise RuntimeError(f"malformed Discovery signing key: {path}")
        return SigningKey(decoded)
    return load_or_create_signing_key(str(path))


def issue_tls_ca(output_root: Path, now: datetime) -> tuple[object, x509.Certificate]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "OUO local lab CA")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_path = output_root / "offline-authority" / "tls-ca.key"
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    key_path.chmod(0o600)
    (output_root / "tls-ca.crt").write_bytes(
        certificate.public_bytes(serialization.Encoding.PEM)
    )
    return key, certificate


def issue_tls_certificate(
    node_name: str,
    node_dir: Path,
    ca_key: object,
    ca_certificate: x509.Certificate,
    now: datetime,
) -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, node_name)])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(ca_certificate.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=7))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(node_name)]), critical=False
        )
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(ca_key, hashes.SHA256())
    )
    key_path = node_dir / "tls.key"
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    key_path.chmod(0o600)
    (node_dir / "tls.crt").write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    (node_dir / "ca.crt").write_bytes(ca_certificate.public_bytes(serialization.Encoding.PEM))
    return certificate.fingerprint(hashes.SHA256()).hex()


def provision(runtime_root: Path, output_root: Path, *, force: bool) -> None:
    marker = output_root / "provisioned.json"
    if marker.exists() and not force:
        raise SystemExit(
            "Lab credentials already exist. Use --force only after intentionally "
            "deleting/replacing every node volume."
        )

    output_root.mkdir(parents=True, exist_ok=True)
    output_root.chmod(0o700)
    validators_dir = output_root / "offline-authority"
    validators_dir.mkdir(parents=True, exist_ok=True)
    validators_dir.chmod(0o700)

    validator_keys = {
        f"validator-{index}": SigningKey.generate() for index in range(1, 8)
    }
    now = datetime.now(timezone.utc)
    ca_key, ca_certificate = issue_tls_ca(output_root, now)
    release_key = SigningKey.generate()
    write_private(validators_dir / "release-signing.key", private_key_b64(release_key))
    valid_until = now + timedelta(days=30)
    authority_state = {
        "epoch": 1,
        "committee": sorted(validator_keys),
        "threshold": 5,
        "validators": {
            validator_id: {
                "public_key": public_key_b64(key),
                "valid_until": valid_until.isoformat().replace("+00:00", "Z"),
                "revoked": False,
            }
            for validator_id, key in validator_keys.items()
        },
    }
    (output_root / "authority-state.json").write_text(
        compact_json(authority_state), encoding="utf-8"
    )
    for validator_id, key in validator_keys.items():
        write_private(validators_dir / f"{validator_id}.key", private_key_b64(key))

    discovery_public_keys: list[str] = []
    discovery_sources: list[dict[str, object]] = []
    release_public_entries: list[str] = []
    tls_fingerprints: list[str] = []
    generated_env: dict[str, str] = {}
    node_manifest: dict[str, dict[str, object]] = {}
    for node_name, (capability, level, public_url) in NODES.items():
        node_dir = runtime_root / node_name
        node_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(output_root / "authority-state.json", node_dir / "authority-state.json")

        root_key = node_dir / "node_root_key"
        operational_key = node_dir / "node_signing_key"
        operational_certificate = node_dir / "node_operational_certificate.json"
        credential_chain = node_dir / "operational_credential_chain.json"
        transport_key = node_dir / "node_transport_key"
        transport_certificate = node_dir / "node_transport_certificate.json"
        capability_certificate = node_dir / "capability-certificate.json"

        identity = node_identity_registration_fields(
            root_key_path=str(root_key),
            operational_key_path=str(operational_key),
            certificate_path=str(operational_certificate),
        )
        load_or_update_operational_credential_state(
            root_key_path=str(root_key),
            operational_key_path=str(operational_key),
            certificate_path=str(operational_certificate),
            credential_chain_path=str(credential_chain),
            allow_existing_certificate_genesis=True,
        )
        node_id = identity["operational_certificate"]["node_id"]
        tls_fingerprint = issue_tls_certificate(
            node_name, node_dir, ca_key, ca_certificate, now
        )
        tls_fingerprints.append(tls_fingerprint)
        certificate = build_capability_certificate(
            subject_node_id=node_id,
            level=level,
            capabilities=[capability],
            quotas={"max_connections": 1000},
            epoch=1,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=7),
            committee=sorted(validator_keys),
            threshold=5,
        )
        for validator_id in sorted(validator_keys)[:5]:
            certificate = add_validator_signature(
                certificate,
                validator_id=validator_id,
                validator_signing_key=validator_keys[validator_id],
            )
        capability_certificate.write_text(compact_json(certificate), encoding="utf-8")

        registration = federation_registration_fields(
            str(operational_key),
            str(root_key),
            str(operational_certificate),
            public_url,
            str(capability_certificate),
            capability_authority_state_path=str(node_dir / "authority-state.json"),
            operational_credential_chain_path=str(credential_chain),
            transport_key_path=str(transport_key),
            transport_certificate_path=str(transport_certificate),
            supported_transports=("https", "wss"),
        )
        for private_path in (root_key, operational_key, transport_key):
            private_path.chmod(0o600)

        if capability == "discovery":
            discovery_key = load_or_create_discovery_key(
                node_dir / "discovery_signing.key"
            )
            (node_dir / "discovery_signing.key").chmod(0o600)
            discovery_public_keys.append(public_key_b64(discovery_key))
            discovery_sources.append(
                {
                    "operational_certificate": identity["operational_certificate"],
                    "capability_certificate": certificate,
                }
            )

        release_message = f"{node_name}:main-local:lab-0.2.0".encode("utf-8")
        release_signature = base64.urlsafe_b64encode(
            release_key.sign(release_message).signature
        ).decode("ascii")
        registration_payload = {
            "node_id": node_name,
            "node_url": public_url,
            "capabilities": [capability],
            "software_version": "lab-0.2.0",
            "cluster_id": "pve2-node-lab",
            "build_hash": "main-local",
            "tls_cert_fingerprint": tls_fingerprint,
            "release_signature": release_signature,
            **registration,
        }
        node_manifest[node_name] = {
            "node_id": node_id,
            "capability": capability,
            "level": level,
            "public_url": public_url,
            "operational_certificate": registration["operational_certificate"],
            "transport_certificate": registration["transport_certificate"],
            "tls_certificate_fingerprint": tls_fingerprint,
            "registration_payload": registration_payload,
        }

        env_prefix = node_name.upper().replace("-", "_")
        # Runtime registration currently uses the operator alias in its
        # top-level node_id field, while the cryptographic NodeID remains
        # bound inside the Operational Certificate. Attestation signs the
        # exact top-level tuple evaluated by Discovery.
        generated_env[f"{env_prefix}_RELEASE_SIGNATURE"] = release_signature
        generated_env[f"{env_prefix}_TLS_FINGERPRINT"] = tls_fingerprint
        release_public_entries.append(f"{node_name}:{public_key_b64(release_key)}")

    (output_root / "discovery-public-keys.env").write_text(
        "DISCOVERY_SIGNING_PUBLIC_KEYS=" + ",".join(discovery_public_keys) + "\n",
        encoding="utf-8",
    )
    generated_env.update(
        {
            "DISCOVERY_SIGNING_PUBLIC_KEYS": ",".join(discovery_public_keys),
            "RELEASE_SIGNING_PUBLIC_KEYS": ",".join(release_public_entries),
            "ALLOWED_BUILD_HASHES": "main-local",
            "ALLOWED_TLS_CERT_FINGERPRINTS": ",".join(tls_fingerprints),
        }
    )
    discovery_source_set = {
        "protocol_version": "ouo-discovery-source-set/1",
        "authority_epoch": 1,
        "sources": discovery_sources,
    }
    for home_name in ("home-a", "home-b", "home-c", "home-d", "home-e"):
        (runtime_root / home_name / "peer-discovery-source-set.json").write_text(
            compact_json(discovery_source_set), encoding="utf-8"
        )
    (output_root / "generated.env").write_text(
        "".join(f"{key}={value}\n" for key, value in sorted(generated_env.items())),
        encoding="utf-8",
    )
    marker.write_text(
        compact_json(
            {
                "schema_version": 5,
                "created_at": now.isoformat().replace("+00:00", "Z"),
                "authority_epoch": 1,
                "threshold": 5,
                "nodes": node_manifest,
            }
        ),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path, default=Path("/nodes"))
    parser.add_argument("--output-root", type=Path, default=Path("/operator"))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    provision(args.runtime_root, args.output_root, force=args.force)
    print(f"Provisioned {len(NODES)} independent strict node identities.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
