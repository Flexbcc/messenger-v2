#!/usr/bin/env python3
"""Sign node release attestation payload for NODE_RELEASE_SIGNATURE."""
import argparse
import base64
import hashlib
import hmac
import os
from nacl.signing import SigningKey


def sign_hmac(node_id: str, build_hash: str, software_version: str, secret: str) -> str:
    message = f"{node_id}:{build_hash}:{software_version}".encode()
    digest = hmac.new(secret.encode(), message, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode()


def sign_ed25519(node_id: str, build_hash: str, software_version: str, private_key_b64: str) -> str:
    message = f"{node_id}:{build_hash}:{software_version}".encode()
    key_bytes = base64.urlsafe_b64decode(private_key_b64.encode())
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
    parser.add_argument("--algorithm", choices=["hmac", "ed25519"], default="hmac")
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
        print(sign_hmac(args.node_id, args.build_hash, args.software_version, args.secret))
        return
    if not args.private_key:
        raise SystemExit("Set RELEASE_SIGNING_PRIVATE_KEY or pass --private-key")
    print(sign_ed25519(args.node_id, args.build_hash, args.software_version, args.private_key))


if __name__ == "__main__":
    main()
