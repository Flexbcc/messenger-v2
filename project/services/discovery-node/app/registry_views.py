import json
from datetime import datetime, timezone
from typing import Optional

from app.config import TRANSPORT_CERTIFICATE_MODE
from app.schemas import (
    NodeCapabilityResponse,
    NodeMetrics,
    RegisterNodeResponse,
)
from app.trust import reachability_for
from shared.security.transport_certificate import validate_transport_certificate


def row_field(row, name, default=None):
    try:
        value = row[name]
        return value if value is not None else default
    except (KeyError, IndexError):
        return default


def trust_from_row(row) -> str:
    return row_field(row, "trust_status", "unknown")


def cluster_id_from_row(row) -> str:
    return row_field(row, "cluster_id", "default")


def _attestation_from_row(row) -> dict:
    return {
        "build_hash": row_field(row, "build_hash"),
        "tls_cert_fingerprint": row_field(row, "tls_cert_fingerprint"),
        "attestation_status": row_field(row, "attestation_status", "skipped"),
        "attestation_detail": row_field(row, "attestation_detail"),
        "signing_public_key": row_field(row, "signing_public_key"),
    }


def _identity_from_row(row) -> dict:
    return {
        "identity_node_id": row_field(row, "identity_node_id"),
        "node_identity_status": row_field(row, "node_identity_status", "absent"),
        "node_identity_detail": row_field(row, "node_identity_detail"),
    }


def _json_list_from_row(row, name) -> list[str]:
    raw = row_field(row, name)
    try:
        value = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def _advertisement_from_row(row) -> dict:
    return {
        "node_advertisement_status": row_field(
            row, "node_advertisement_status", "absent"
        ),
        "node_advertisement_detail": row_field(row, "node_advertisement_detail"),
        "node_advertisement_epoch": row_field(row, "node_advertisement_epoch"),
        "advertised_endpoints": _json_list_from_row(row, "advertised_endpoints"),
        "advertised_transports": _json_list_from_row(row, "advertised_transports"),
        "advertised_protocols": _json_list_from_row(row, "advertised_protocols"),
    }


def _capability_from_row(row) -> dict:
    raw = row_field(row, "certified_capabilities")
    try:
        certified = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        certified = []
    quotas = {}
    if row_field(row, "capability_certificate_status", "absent") == "valid":
        certificate_raw = row_field(row, "capability_certificate")
        try:
            certificate = json.loads(certificate_raw) if certificate_raw else {}
            candidate_quotas = certificate.get("quotas", {})
            if isinstance(candidate_quotas, dict):
                quotas = candidate_quotas
        except (TypeError, ValueError):
            quotas = {}
    return {
        "certified_capabilities": certified,
        "certified_quotas": quotas,
        "certified_level": row_field(row, "certified_level"),
        "capability_certificate_status": row_field(
            row, "capability_certificate_status", "absent"
        ),
        "capability_certificate_detail": row_field(
            row, "capability_certificate_detail"
        ),
        "capability_epoch": row_field(row, "capability_epoch"),
    }


def _transport_from_row(row) -> dict:
    raw = row_field(row, "transport_certificate")
    certificate = None
    if raw:
        try:
            candidate = json.loads(raw)
            certificate = candidate if isinstance(candidate, dict) else None
        except (TypeError, ValueError):
            certificate = None
    return {
        "transport_certificate": certificate,
        "transport_certificate_status": row_field(
            row, "transport_certificate_status", "absent"
        ),
        "transport_certificate_detail": row_field(
            row, "transport_certificate_detail"
        ),
    }


def evaluate_transport_certificate(certificate, *, identity_node_id: str | None):
    if certificate is None:
        return "absent", "transport certificate not supplied", None
    if TRANSPORT_CERTIFICATE_MODE == "off":
        return "ignored", "transport certificate validation disabled", None
    validation = validate_transport_certificate(
        certificate,
        now=datetime.now(timezone.utc),
        expected_node_id=identity_node_id,
    )
    if not validation.valid:
        return "invalid", validation.reason, None
    return "valid", None, json.dumps(
        certificate, sort_keys=True, separators=(",", ":")
    )


def _metrics_from_row(row) -> Optional[NodeMetrics]:
    fields = (
        "cpu_load_1m", "cpu_cores", "cpu_percent_est",
        "ram_total_bytes", "ram_used_bytes", "ram_percent",
        "disk_used_bytes", "disk_total_bytes", "disk_percent",
        "uptime_sec", "ws_connections", "messages_24h", "calls_24h",
        "error_rate_pct", "messages_total", "latency_ms",
    )
    data = {field: row_field(row, field) for field in fields}
    if all(value is None for value in data.values()):
        return None
    return NodeMetrics(**data)


def node_response(row, *, last_heartbeat: str) -> NodeCapabilityResponse:
    reachability = reachability_for(last_heartbeat)
    return NodeCapabilityResponse(
        node_id=row["node_id"],
        node_url=row["node_url"],
        capabilities=json.loads(row["capabilities"]),
        software_version=row["software_version"],
        cluster_id=cluster_id_from_row(row),
        trust_status=trust_from_row(row),
        trust_level=row_field(row, "trust_level", 0),
        reachability=reachability,
        last_heartbeat=last_heartbeat,
        status=reachability,
        health_status=row_field(row, "health_status"),
        last_health_check=row_field(row, "last_health_check"),
        version_status=row_field(row, "version_status", "ok"),
        quarantine_action=row_field(row, "quarantine_action", "off"),
        metrics=_metrics_from_row(row),
        **_attestation_from_row(row),
        **_identity_from_row(row),
        **_advertisement_from_row(row),
        **_capability_from_row(row),
        **_transport_from_row(row),
    )


def register_response(
    row,
    *,
    last_heartbeat: str,
    enrollment_secret: Optional[str] = None,
) -> RegisterNodeResponse:
    base = node_response(row, last_heartbeat=last_heartbeat)
    return RegisterNodeResponse(
        **base.model_dump(),
        enrollment_secret=enrollment_secret,
    )
