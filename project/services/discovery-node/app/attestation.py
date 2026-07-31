"""Build hash, release signature, and TLS fingerprint checks (ADR-0010)."""
import base64
import hmac
import hashlib
import os
from typing import Optional
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

ATTESTATION_MODE = os.environ.get("ATTESTATION_MODE", "off").lower()
MTLS_MODE = os.environ.get("MTLS_MODE", "off").lower()
RELEASE_SIGNING_SECRET = os.environ.get("RELEASE_SIGNING_SECRET", "")
RELEASE_SIGNING_PUBLIC_KEYS = {
    item.split(":", 1)[0].strip(): item.split(":", 1)[1].strip()
    for item in os.environ.get("RELEASE_SIGNING_PUBLIC_KEYS", "").split(",")
    if ":" in item
}

ALLOWED_BUILD_HASHES = frozenset(
    h.strip()
    for h in os.environ.get("ALLOWED_BUILD_HASHES", "").split(",")
    if h.strip()
)
ALLOWED_TLS_CERT_FINGERPRINTS = frozenset(
    fp.strip().lower()
    for fp in os.environ.get("ALLOWED_TLS_CERT_FINGERPRINTS", "").split(",")
    if fp.strip()
)

ATTESTATION_SKIPPED = "skipped"
ATTESTATION_VERIFIED = "verified"
ATTESTATION_UNVERIFIED = "unverified"
ATTESTATION_REJECTED = "rejected"


def canonical_release_message(node_id: str, build_hash: str, software_version: str) -> bytes:
    return f"{node_id}:{build_hash}:{software_version}".encode()


def _verify_hmac_signature(
    node_id: str,
    build_hash: str,
    software_version: str,
    signature_b64: Optional[str],
) -> bool:
    if not RELEASE_SIGNING_SECRET:
        return True
    if not signature_b64:
        return False
    try:
        provided = base64.urlsafe_b64decode(signature_b64.encode())
    except Exception:
        return False
    expected = hmac.new(
        RELEASE_SIGNING_SECRET.encode(),
        canonical_release_message(node_id, build_hash, software_version),
        hashlib.sha256,
    ).digest()
    return hmac.compare_digest(provided, expected)


def _verify_ed25519_signature(
    node_id: str,
    build_hash: str,
    software_version: str,
    signature_b64: Optional[str],
) -> bool:
    public_key = RELEASE_SIGNING_PUBLIC_KEYS.get(node_id)
    if not public_key:
        return False
    if not signature_b64:
        return False
    try:
        sig_bytes = base64.urlsafe_b64decode(signature_b64.encode())
        key_bytes = base64.urlsafe_b64decode(public_key.encode())
        verify_key = VerifyKey(key_bytes)
        verify_key.verify(canonical_release_message(node_id, build_hash, software_version), sig_bytes)
        return True
    except (BadSignatureError, ValueError):
        return False


def verify_release_signature(
    node_id: str,
    build_hash: str,
    software_version: str,
    signature_b64: Optional[str],
) -> bool:
    # Prefer Ed25519 if a node-specific public key is configured.
    if RELEASE_SIGNING_PUBLIC_KEYS:
        return _verify_ed25519_signature(node_id, build_hash, software_version, signature_b64)
    # Backward-compatible fallback for existing HMAC setup.
    return _verify_hmac_signature(node_id, build_hash, software_version, signature_b64)


def _check_build_hash(build_hash: Optional[str]) -> tuple[bool, Optional[str]]:
    if not ALLOWED_BUILD_HASHES:
        return True, None
    if not build_hash:
        return False, "build_hash required"
    if build_hash not in ALLOWED_BUILD_HASHES:
        return False, f"build_hash not in allowlist"
    return True, None


def _check_tls_fingerprint(tls_cert_fingerprint: Optional[str]) -> tuple[bool, Optional[str]]:
    if MTLS_MODE == "off" or not ALLOWED_TLS_CERT_FINGERPRINTS:
        return True, None
    if not tls_cert_fingerprint:
        return False, "tls_cert_fingerprint required"
    if tls_cert_fingerprint.lower() not in ALLOWED_TLS_CERT_FINGERPRINTS:
        return False, "tls_cert_fingerprint not in allowlist"
    return True, None


def evaluate_attestation(
    *,
    node_id: str,
    software_version: str,
    build_hash: Optional[str],
    tls_cert_fingerprint: Optional[str],
    release_signature: Optional[str],
) -> tuple[str, Optional[str], bool]:
    """
    Returns (attestation_status, detail, should_reject).
    should_reject is True only when mode is enforce and checks fail.
    """
    if ATTESTATION_MODE == "off" and MTLS_MODE == "off" and not RELEASE_SIGNING_SECRET:
        return ATTESTATION_SKIPPED, None, False

    failures: list[str] = []
    ok_hash, hash_detail = _check_build_hash(build_hash)
    if not ok_hash and hash_detail:
        failures.append(hash_detail)

    ok_tls, tls_detail = _check_tls_fingerprint(tls_cert_fingerprint)
    if not ok_tls and tls_detail:
        failures.append(tls_detail)

    if (RELEASE_SIGNING_SECRET or RELEASE_SIGNING_PUBLIC_KEYS) and build_hash:
        if not verify_release_signature(node_id, build_hash, software_version, release_signature):
            failures.append("invalid release_signature")

    if not failures:
        return ATTESTATION_VERIFIED, None, False

    detail = "; ".join(failures)
    enforce = ATTESTATION_MODE == "enforce" or MTLS_MODE == "enforce"
    status = ATTESTATION_REJECTED if enforce else ATTESTATION_UNVERIFIED
    return status, detail, enforce
