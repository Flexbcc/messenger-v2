"""Discovery-side validation policy for OUO Node Identity migration."""

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping, Optional

from shared.security.canonical import canonical_json
from shared.security.node_identity import validate_operational_certificate


MAX_CERTIFICATE_JSON_BYTES = 8192
SUPPORTED_MODES = frozenset({"off", "report", "enforce"})


@dataclass(frozen=True)
class NodeIdentityReport:
    status: str
    detail: Optional[str]
    identity_node_id: Optional[str]
    operational_certificate_json: Optional[str]
    operational_public_key: Optional[str]


def evaluate_node_identity_report(
    certificate: Optional[Mapping[str, Any]],
    *,
    mode: str,
    now: datetime,
    existing_identity_node_id: Optional[str] = None,
    existing_operational_certificate_json: Optional[str] = None,
    advertised_signing_public_key: Optional[str] = None,
) -> NodeIdentityReport:
    """Evaluate a certificate without changing enrollment/trust decisions.

    `report` is intentionally non-blocking during migration.  A previously
    bound root identity is never replaced by a conflicting certificate.
    """
    if mode not in SUPPORTED_MODES:
        raise ValueError(f"unsupported NODE_IDENTITY_MODE: {mode}")
    if mode == "off":
        return NodeIdentityReport("skipped", None, None, None, None)
    if certificate is None:
        return NodeIdentityReport("absent", "operational certificate not provided", None, None, None)
    if not isinstance(certificate, Mapping):
        return NodeIdentityReport("invalid", "certificate must be an object", None, None, None)

    try:
        serialized = canonical_json(dict(certificate))
    except (TypeError, ValueError):
        return NodeIdentityReport("invalid", "certificate is not valid JSON", None, None, None)
    if len(serialized.encode("utf-8")) > MAX_CERTIFICATE_JSON_BYTES:
        return NodeIdentityReport("invalid", "certificate exceeds size limit", None, None, None)

    validation = validate_operational_certificate(certificate, now=now)
    if not validation.valid:
        return NodeIdentityReport("invalid", validation.reason, None, None, None)

    identity_node_id = str(certificate["node_id"])
    operational_public_key = str(certificate["operational_public_key"])
    if existing_identity_node_id and existing_identity_node_id != identity_node_id:
        return NodeIdentityReport(
            "conflict",
            "legacy node alias is already bound to a different Node Root",
            existing_identity_node_id,
            None,
            None,
        )
    if existing_operational_certificate_json:
        try:
            existing_certificate = json.loads(existing_operational_certificate_json)
            existing_serialized = canonical_json(existing_certificate)
            existing_issued_at = datetime.fromisoformat(
                existing_certificate["issued_at"][:-1] + "+00:00"
                if existing_certificate["issued_at"].endswith("Z")
                else existing_certificate["issued_at"]
            ).astimezone(timezone.utc)
            new_issued_at = datetime.fromisoformat(
                certificate["issued_at"][:-1] + "+00:00"
                if certificate["issued_at"].endswith("Z")
                else certificate["issued_at"]
            ).astimezone(timezone.utc)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return NodeIdentityReport(
                "conflict",
                "stored Operational Certificate is invalid",
                existing_identity_node_id,
                None,
                None,
            )
        if serialized != existing_serialized and new_issued_at <= existing_issued_at:
            return NodeIdentityReport(
                "rollback",
                "Operational Certificate is not newer than highest accepted certificate",
                identity_node_id,
                None,
                None,
            )
    if advertised_signing_public_key and advertised_signing_public_key != operational_public_key:
        return NodeIdentityReport(
            "key_mismatch",
            "signing_public_key does not match certified operational key",
            identity_node_id,
            serialized,
            operational_public_key,
        )
    return NodeIdentityReport(
        "valid",
        None,
        identity_node_id,
        serialized,
        operational_public_key,
    )
