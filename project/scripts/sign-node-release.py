#!/usr/bin/env python3
"""Sign node release attestation payload for NODE_RELEASE_SIGNATURE."""
import argparse
import base64
import hashlib
import hmac
import os
from nacl.signing import SigningKey


def _canonical_field(name: str, value: str, *, max_length: int) -> str:
    if (
        not value
        or len(value) > max_length
        or ":" in value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{name} is invalid")
    return value


def _message(node_id: str, build_hash: str, software_version: str) -> bytes:
    return (
        f"{_canonical_field('node_id', node_id, max_length=256)}:"
        f"{_canonical_field('build_hash', build_hash, max_length=256)}:"
        f"{_canonical_field('software_version', software_version, max_length=128)}"
    ).encode()


def sign_hmac(node_id: str, build_hash: str, software_version: str, secret: str) -> str:
    if len(secret.encode("utf-8")) < 32:
        raise ValueError("RELEASE_SIGNING_SECRET must contain at least 32 bytes")
    message = _message(node_id, build_hash, software_version)
    digest = hmac.new(secret.encode(), message, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode()


def sign_ed25519(node_id: str, build_hash: str, software_version: str, private_key_b64: str) -> str:
    message = _message(node_id, build_hash, software_version)
    try:
        key_bytes = base64.b64decode(
            private_key_b64.encode(), altchars=b"-_", validate=True
        )
    except (TypeError, ValueError) as exc:
        raise ValueError("RELEASE_SIGNING_PRIVATE_KEY is not valid base64") from exc
    if len(key_bytes) != 32:
        raise ValueError("RELEASE_SIGNING_PRIVATE_KEY must encode exactly 32 bytes")
    signing_key = SigningKey(key_bytes)
    sig = signing_key.sign(message).signature
    return base64.urlsafe_b64encode(sig).decode()


def generate_ed25519_keypair() -> tuple[str, str]:
    sk = SigningKey.generate()
    vk = sk.verify_key
    return (
        base64.urlsafe_b64encode(bytes(sk)).decode(),
        base64.urlsafe_b64encode(bytes(vk)).decode(),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Sign node release for Discovery attestation")
    parser.add_argument("--node-id", required=True)
    parser.add_argument("--build-hash", required=True)
    parser.add_argument("--software-version", default=os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0"))
    parser.add_argument("--algorithm", choices=["hmac", "ed25519"], default="ed25519")
    parser.add_argument("--secret", default=os.environ.get("RELEASE_SIGNING_SECRET", ""))
    parser.add_argument("--private-key", default=os.environ.get("RELEASE_SIGNING_PRIVATE_KEY", ""))
    parser.add_argument("--generate-ed25519-keypair", action="store_true")
    args = parser.parse_args()
    if args.generate_ed25519_keypair:
        private_key, public_key = generate_ed25519_keypair()
        print(f"private_key={private_key}")
        print(f"public_key={public_key}")
        return
    if args.algorithm == "hmac":
        if not args.secret:
            raise SystemExit("Set RELEASE_SIGNING_SECRET or pass --secret")
        try:
            print(sign_hmac(args.node_id, args.build_hash, args.software_version, args.secret))
        except ValueError as exc:
            raise SystemExit(str(exc)) from exc
        return
    if not args.private_key:
        raise SystemExit("Set RELEASE_SIGNING_PRIVATE_KEY or pass --private-key")
    try:
        print(sign_ed25519(args.node_id, args.build_hash, args.software_version, args.private_key))
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
