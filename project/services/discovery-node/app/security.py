"""Enrollment secrets and node tokens — hashed at rest (ADR-0009)."""
import hashlib
import secrets


def generate_enrollment_secret() -> str:
    return secrets.token_urlsafe(32)


def generate_node_token() -> str:
    return secrets.token_urlsafe(32)


def hash_value(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def verify_hash(value: str, stored_hash: str | None) -> bool:
    if not stored_hash:
        return False
    return secrets.compare_digest(hash_value(value), stored_hash)
