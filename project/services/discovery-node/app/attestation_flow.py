"""Discovery Control Plane — attestation evaluation on register/heartbeat."""
from typing import Optional

from app.attestation import evaluate_attestation
from fastapi import HTTPException


def _field_from_row(row, name: str) -> Optional[str]:
    try:
        val = row[name]
        return val if val else None
    except (KeyError, IndexError):
        return None


def apply_attestation(
    *,
    node_id: str,
    software_version: str,
    build_hash: Optional[str],
    tls_cert_fingerprint: Optional[str],
    release_signature: Optional[str],
    existing_row=None,
) -> tuple[str, Optional[str]]:
    """Evaluate attestation; raise 403 in enforce mode on failure."""
    if build_hash is None and existing_row is not None:
        build_hash = _field_from_row(existing_row, "build_hash")
    if tls_cert_fingerprint is None and existing_row is not None:
        tls_cert_fingerprint = _field_from_row(existing_row, "tls_cert_fingerprint")
    if release_signature is None and existing_row is not None:
        release_signature = _field_from_row(existing_row, "release_signature")

    status, detail, reject = evaluate_attestation(
        node_id=node_id,
        software_version=software_version,
        build_hash=build_hash,
        tls_cert_fingerprint=tls_cert_fingerprint,
        release_signature=release_signature,
    )
    if reject:
        raise HTTPException(status_code=403, detail=f"Attestation rejected: {detail}")
    return status, detail
