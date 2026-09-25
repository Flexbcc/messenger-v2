import base64
import os
import tempfile
from pathlib import Path
from typing import Optional

from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey


def _read_key_file(path: str) -> Optional[bytes]:
    p = Path(path)
    if not p.is_file():
        return None
    text = p.read_text(encoding="utf-8").strip()
    if not text:
        raise ValueError(f"signing key file is empty: {p}")
    try:
        raw = base64.b64decode(text, altchars=b"-_", validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError(f"signing key file is not valid base64: {p}") from exc
    if len(raw) != 32:
        raise ValueError(f"signing key file must contain a 32-byte seed: {p}")
    return raw


def _write_key_file(path: str, raw: bytes) -> bool:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    if len(raw) != 32:
        raise ValueError("Ed25519 signing seed must be exactly 32 bytes")
    fd, temporary_path = tempfile.mkstemp(
        dir=p.parent,
        prefix=f".{p.name}.",
        text=True,
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(base64.urlsafe_b64encode(raw).decode("ascii"))
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary_path, p)
        except FileExistsError:
            return False
        return True
    except Exception:
        if fd >= 0:
            os.close(fd)
        raise
    finally:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass


def load_or_create_signing_key(path: str) -> SigningKey:
    seed = _read_key_file(path)
    if seed is None:
        sk = SigningKey.generate()
        if _write_key_file(path, bytes(sk)):
            return sk
        # Another process won first-start initialization. Use its trust root
        # rather than overwriting it with this process's candidate.
        seed = _read_key_file(path)
        if seed is None:  # Defensive: the atomic link above created the file.
            raise RuntimeError("signing key initialization race did not settle")
    return SigningKey(seed)


def public_key_b64(signing_key: SigningKey) -> str:
    return base64.urlsafe_b64encode(bytes(signing_key.verify_key)).decode()


def sign_message(signing_key: SigningKey, message: bytes) -> str:
    sig = signing_key.sign(message).signature
    return base64.urlsafe_b64encode(sig).decode()


def verify_message(public_key_b64: str, message: bytes, signature_b64: str) -> bool:
    if not isinstance(public_key_b64, str) or not isinstance(signature_b64, str):
        return False
    if len(public_key_b64) > 64 or len(signature_b64) > 128:
        return False
    try:
        key_bytes = base64.b64decode(
            public_key_b64,
            altchars=b"-_",
            validate=True,
        )
        sig_bytes = base64.b64decode(
            signature_b64,
            altchars=b"-_",
            validate=True,
        )
        if len(key_bytes) != 32 or len(sig_bytes) != 64:
            return False
        verify_key = VerifyKey(key_bytes)
        verify_key.verify(message, sig_bytes)
        return True
    except (BadSignatureError, ValueError, TypeError):
        return False
