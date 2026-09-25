"""Small shared crypto helpers for the isolated node-lab verifiers."""
from __future__ import annotations

import base64
import json

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def _derive_key(shared_secret: bytes, conversation_id: str) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=("OUO/LAB-E2EE/" + conversation_id).encode(),
    ).derive(shared_secret)


def decrypt_with(private_b64: str, conversation_id: str, envelope_b64: str) -> str:
    envelope = json.loads(base64.b64decode(envelope_b64))
    private = x25519.X25519PrivateKey.from_private_bytes(base64.b64decode(private_b64))
    peer = x25519.X25519PublicKey.from_public_bytes(base64.b64decode(envelope["epk"]))
    plaintext = AESGCM(_derive_key(private.exchange(peer), conversation_id)).decrypt(
        base64.b64decode(envelope["nonce"]),
        base64.b64decode(envelope["ciphertext"]),
        conversation_id.encode(),
    )
    return plaintext.decode()
