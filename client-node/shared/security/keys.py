import base64
import os
from pathlib import Path
from typing import Optional

from nacl.signing import SigningKey, VerifyKey


def _read_key_file(path: str) -> Optional[bytes]:
    p = Path(path)
    if not p.is_file():
        return None
    text = p.read_text(encoding="utf-8").strip()
    if not text:
        return None
    return base64.urlsafe_b64decode(text.encode())


def _write_key_file(path: str, raw: bytes) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(base64.urlsafe_b64encode(raw).decode(), encoding="utf-8")
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass


def load_or_create_signing_key(path: str) -> SigningKey:
    seed = _read_key_file(path)
    if seed is None:
        sk = SigningKey.generate()
        _write_key_file(path, bytes(sk))
        return sk
    return SigningKey(seed)


def public_key_b64(signing_key: SigningKey) -> str:
    return base64.urlsafe_b64encode(bytes(signing_key.verify_key)).decode()


def sign_message(signing_key: SigningKey, message: bytes) -> str:
    sig = signing_key.sign(message).signature
    return base64.urlsafe_b64encode(sig).decode()


def verify_message(public_key_b64: str, message: bytes, signature_b64: str) -> bool:
    try:
        key_bytes = base64.urlsafe_b64decode(public_key_b64.encode())
        sig_bytes = base64.urlsafe_b64decode(signature_b64.encode())
        verify_key = VerifyKey(key_bytes)
        verify_key.verify(message, sig_bytes)
        return True
    except Exception:
        return False
