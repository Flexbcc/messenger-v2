from datetime import datetime, timezone
from typing import Optional
from fastapi import APIRouter, HTTPException, Header
import json

from app.config import (
    CAPABILITY_AUTHORITY_STATE_PATH,
    CAPABILITY_CERTIFICATE_MODE,
    ENROLLMENT_MODE,
    NODE_ADVERTISEMENT_MODE,
    NODE_IDENTITY_MODE,
    OPERATIONAL_CREDENTIAL_STATE_MODE,
    TRANSPORT_CERTIFICATE_MODE,
)
from app.network_guard import require_governance_available
from app.db import get_conn
from app.schemas import (
    RegisterNodeCapability,
    HeartbeatRequest,
    MeshPeerEntry,
    NodeCapabilityResponse,
    NodeCapabilityListResponse,
    RegisterNodeResponse,
)
from app.security import generate_enrollment_secret, hash_value, verify_hash
from app.attestation_flow import apply_attestation
from app.trust import enrollment_required, initial_trust_status_for_register, now_iso
from app.policy import blocked_version_set, get_quarantine_mode, evaluate_version
from app.mesh_notify import schedule_mesh_peer_notify, should_notify_on_register
from app.registry_capabilities import evaluate_registry_capability
from app.trust_record_service import reconcile_registered_subject
from app.registry_credentials import (
    publish_credential_state,
    require_valid_identity,
    validate_credential_state,
)
from app import registry_credentials as _registry_credentials
from app import registry_capabilities as _registry_capabilities
from app import registry_eligibility as _registry_eligibility
from shared.security.node_identity_enrollment import evaluate_node_identity_report
from shared.security.node_advertisement_enrollment import evaluate_node_advertisement_report
from shared.security.jwt_auth import extract_bearer_token
from app.registry_views import (
    cluster_id_from_row as _cluster_id_from_row,
    evaluate_transport_certificate as _evaluate_transport_certificate,
    node_response as _node_response,
    register_response as _register_response,
    row_field as _row_field,
    trust_from_row as _trust_from_row,
)
from app.registry_eligibility import (
    capabilities_from_row,
    row_has_current_advertisement as _row_has_current_advertisement,
    row_has_current_capability as _row_has_current_capability,
    row_is_publicly_eligible,
)
from app.routers.user_registry import router as user_registry_router
from app.routers.routing_registry import router as routing_registry_router
from app.routers.trust_registry import router as trust_registry_router
from app.routers.operational_credentials_registry import (
    router as operational_credentials_registry_router,
)
from app.routers.authority_registry import router as authority_registry_router
from app.routers.node_advertisement_registry import (
    router as node_advertisement_registry_router,
)
from app.routers.challenge_registry import router as challenge_registry_router

# Keep the original Python integration surface while the HTTP routes live in
# focused modules.  External callers use the routers; direct integration tests
# and maintenance scripts historically imported these callables here.
from app.routers.routing_registry import (
    publish_bootstrap_record,
    publish_route_descriptor_record,
    resolve_bootstrap_record,
    resolve_route_descriptors,
)
from app.routers import authority_registry as _authority_registry
from app.routers import challenge_registry as _challenge_registry
from app.routers.trust_registry import (
    get_reliability_snapshot,
    get_trust_observations,
    publish_trust_observation,
    publish_trust_record,
)


def _sync_legacy_router_context(target) -> None:
    """Propagate supported test/maintenance overrides to split route modules."""
    for name in (
        "TRUST_AUTHORITY_STATE_PATH",
        "require_governance_available",
        "get_network_view_guard",
        "discovery_node_identity",
        "schedule_mesh_peer_notify",
    ):
        if name in globals() and hasattr(target, name):
            setattr(target, name, globals()[name])


def publish_authority_checkpoint_record(payload):
    _sync_legacy_router_context(_authority_registry)
    return _authority_registry.publish_authority_checkpoint_record(payload)


def get_latest_authority_checkpoint():
    _sync_legacy_router_context(_authority_registry)
    return _authority_registry.get_latest_authority_checkpoint()


def publish_challenge_assignment(payload):
    _sync_legacy_router_context(_challenge_registry)
    return _challenge_registry.publish_challenge_assignment(payload)


def get_challenge_assignments(*args, **kwargs):
    _sync_legacy_router_context(_challenge_registry)
    return _challenge_registry.get_challenge_assignments(*args, **kwargs)


def publish_challenge_assignment_ack(*args, **kwargs):
    _sync_legacy_router_context(_challenge_registry)
    return _challenge_registry.publish_challenge_assignment_ack(*args, **kwargs)

router = APIRouter()
router.include_router(user_registry_router)
router.include_router(routing_registry_router)
router.include_router(trust_registry_router)
router.include_router(operational_credentials_registry_router)
router.include_router(authority_registry_router)
router.include_router(node_advertisement_registry_router)
router.include_router(challenge_registry_router)

MAX_HEARTBEAT_PEERS = 1000
MAX_PUBLIC_NODES = 10000


def _sync_registry_policy_modules() -> None:
    _registry_credentials.NODE_IDENTITY_MODE = NODE_IDENTITY_MODE
    _registry_credentials.OPERATIONAL_CREDENTIAL_STATE_MODE = (
        OPERATIONAL_CREDENTIAL_STATE_MODE
    )
    _registry_capabilities.CAPABILITY_CERTIFICATE_MODE = CAPABILITY_CERTIFICATE_MODE
    _registry_capabilities.CAPABILITY_AUTHORITY_STATE_PATH = (
        globals().get(
            "CAPABILITY_AUTHORITY_STATE_PATH",
            _registry_capabilities.CAPABILITY_AUTHORITY_STATE_PATH,
        )
    )
    _registry_capabilities.require_governance_available = (
        require_governance_available
    )
    if "load_capability_authority_state" in globals():
        _registry_capabilities.load_capability_authority_state = globals()[
            "load_capability_authority_state"
        ]
    _registry_eligibility.CAPABILITY_CERTIFICATE_MODE = CAPABILITY_CERTIFICATE_MODE
    _registry_eligibility.NODE_ADVERTISEMENT_MODE = NODE_ADVERTISEMENT_MODE

def _build_peer_list(exclude_node_id: str) -> list[MeshPeerEntry]:
    """Возвращает компактный список trusted+online нод (кроме самой себя) для
    включения в heartbeat-ответ. Ноды используют его для обновления mesh-кэша
    без отдельного запроса к Discovery (Фаза 3.3)."""
    from app.config import OFFLINE_THRESHOLD_SECONDS
    from datetime import datetime, timedelta, timezone

    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=OFFLINE_THRESHOLD_SECONDS)).isoformat()
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT * FROM node_capabilities
               WHERE trust_status = 'trusted'
                 AND last_heartbeat >= ?
                 AND node_id != ?
               ORDER BY last_heartbeat DESC
               LIMIT ?""",
            (cutoff, exclude_node_id, MAX_HEARTBEAT_PEERS),
        ).fetchall()

    peers = []
    for r in rows:
        if NODE_ADVERTISEMENT_MODE == "enforce" and not _row_has_current_advertisement(r):
            continue
        if CAPABILITY_CERTIFICATE_MODE == "enforce" and not _row_has_current_capability(r):
            continue
        parsed_caps = capabilities_from_row(r)
        if parsed_caps is None:
            continue
        caps = list(parsed_caps)
        peers.append(MeshPeerEntry(
            node_id=r["node_id"],
            node_url=r["node_url"],
            capabilities=caps,
            cluster_id=r["cluster_id"] or "default",
            trust_level=r["trust_level"] or 0,
        ))
    return peers


def _apply_version_policy(
    conn,
    node_id: str,
    software_version: str,
    *,
    blocked_versions: set[str] | None = None,
    quarantine_mode: str | None = None,
) -> None:
    """Recompute version_status/quarantine_action for a node against blocked_versions."""
    version_status, quarantine_action = evaluate_version(
        software_version,
        blocked_version_set() if blocked_versions is None else blocked_versions,
        get_quarantine_mode() if quarantine_mode is None else quarantine_mode,
    )
    conn.execute(
        "UPDATE node_capabilities SET version_status = ?, quarantine_action = ? WHERE node_id = ?",
        (version_status, quarantine_action, node_id),
    )


@router.post("/registry/nodes", response_model=RegisterNodeResponse)
def register_node_capability(payload: RegisterNodeCapability):
    _sync_registry_policy_modules()
    now = now_iso()
    caps_json = json.dumps(payload.capabilities)
    enrollment_secret_plain: Optional[str] = None

    with get_conn() as conn:
        existing = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
        existing_trust = existing["trust_status"] if existing else None
        trust_status = initial_trust_status_for_register(existing_trust)

        secret_hash = existing["enrollment_secret_hash"] if existing else None
        if trust_status == "pending" and enrollment_required():
            if not secret_hash:
                enrollment_secret_plain = generate_enrollment_secret()
                secret_hash = hash_value(enrollment_secret_plain)

        att_status, att_detail = apply_attestation(
            node_id=payload.node_id,
            software_version=payload.software_version,
            build_hash=payload.build_hash,
            tls_cert_fingerprint=payload.tls_cert_fingerprint,
            release_signature=payload.release_signature,
            existing_row=existing,
        )
        identity_report = evaluate_node_identity_report(
            payload.operational_certificate,
            mode=NODE_IDENTITY_MODE,
            now=datetime.now(timezone.utc),
            existing_identity_node_id=_row_field(existing, "identity_node_id") if existing else None,
            existing_operational_certificate_json=(
                _row_field(existing, "operational_certificate") if existing else None
            ),
            advertised_signing_public_key=payload.signing_public_key,
        )
        require_valid_identity(
            identity_report,
            payload.operational_certificate,
            context="registration",
        )
        credential_state = validate_credential_state(
            payload.operational_credential_state,
            payload.operational_certificate,
            expected_node_id=identity_report.identity_node_id,
            context="registration",
        )
        effective_signing_public_key = payload.signing_public_key
        if identity_report.status == "valid":
            effective_signing_public_key = identity_report.operational_public_key
        elif existing is not None:
            effective_signing_public_key = _row_field(existing, "signing_public_key")
        bound_identity = identity_report.identity_node_id or (
            _row_field(existing, "identity_node_id") if existing else None
        )
        advertisement_report = evaluate_node_advertisement_report(
            payload.node_advertisement,
            mode=NODE_ADVERTISEMENT_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=bound_identity if identity_report.status == "valid" else None,
            advertised_node_url=payload.node_url,
            minimum_epoch=_row_field(existing, "node_advertisement_epoch", 0)
            if existing else 0,
            existing_advertisement_json=(
                _row_field(existing, "node_advertisement") if existing else None
            ),
        )
        if NODE_ADVERTISEMENT_MODE == "enforce" and advertisement_report.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid NodeAdvertisement required: "
                    f"{advertisement_report.detail or advertisement_report.status}"
                ),
            )
        capability_report = evaluate_registry_capability(
            payload.capability_certificate,
            identity_node_id=bound_identity,
            minimum_epoch=_row_field(existing, "capability_epoch", 0) if existing else 0,
            existing_certificate_json=(
                _row_field(existing, "capability_certificate") if existing else None
            ),
            advertised_capabilities=payload.capabilities,
            context="registration",
        )

        transport_status, transport_detail, transport_json = (
            _evaluate_transport_certificate(
                payload.transport_certificate,
                identity_node_id=bound_identity,
            )
        )
        if TRANSPORT_CERTIFICATE_MODE == "enforce" and transport_status != "valid":
            raise HTTPException(
                status_code=403,
                detail=f"valid Transport Certificate required: {transport_detail}",
            )

        conn.execute(
            """
            INSERT INTO node_capabilities (
                node_id, node_url, capabilities, software_version, cluster_id,
                last_heartbeat, trust_status, registered_at, enrollment_secret_hash,
                build_hash, tls_cert_fingerprint, release_signature,
                attestation_status, attestation_detail, signing_public_key,
                identity_node_id, operational_certificate,
                node_identity_status, node_identity_detail,
                node_advertisement, node_advertisement_status,
                node_advertisement_detail, node_advertisement_epoch,
                advertised_endpoints, advertised_transports, advertised_protocols,
                capability_certificate, capability_certificate_status,
                capability_certificate_detail, certified_capabilities,
                certified_level, capability_epoch
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(node_id) DO UPDATE SET
                node_url=excluded.node_url,
                capabilities=excluded.capabilities,
                software_version=excluded.software_version,
                cluster_id=excluded.cluster_id,
                last_heartbeat=excluded.last_heartbeat,
                enrollment_secret_hash=COALESCE(excluded.enrollment_secret_hash, node_capabilities.enrollment_secret_hash),
                build_hash=COALESCE(excluded.build_hash, node_capabilities.build_hash),
                tls_cert_fingerprint=COALESCE(excluded.tls_cert_fingerprint, node_capabilities.tls_cert_fingerprint),
                release_signature=COALESCE(excluded.release_signature, node_capabilities.release_signature),
                attestation_status=excluded.attestation_status,
                attestation_detail=excluded.attestation_detail,
                signing_public_key=COALESCE(excluded.signing_public_key, node_capabilities.signing_public_key),
                identity_node_id=COALESCE(excluded.identity_node_id, node_capabilities.identity_node_id),
                operational_certificate=COALESCE(excluded.operational_certificate, node_capabilities.operational_certificate),
                node_identity_status=excluded.node_identity_status,
                node_identity_detail=excluded.node_identity_detail,
                node_advertisement=COALESCE(excluded.node_advertisement, node_capabilities.node_advertisement),
                node_advertisement_status=excluded.node_advertisement_status,
                node_advertisement_detail=excluded.node_advertisement_detail,
                node_advertisement_epoch=COALESCE(excluded.node_advertisement_epoch, node_capabilities.node_advertisement_epoch),
                advertised_endpoints=COALESCE(excluded.advertised_endpoints, node_capabilities.advertised_endpoints),
                advertised_transports=COALESCE(excluded.advertised_transports, node_capabilities.advertised_transports),
                advertised_protocols=COALESCE(excluded.advertised_protocols, node_capabilities.advertised_protocols),
                capability_certificate=COALESCE(excluded.capability_certificate, node_capabilities.capability_certificate),
                capability_certificate_status=excluded.capability_certificate_status,
                capability_certificate_detail=excluded.capability_certificate_detail,
                certified_capabilities=COALESCE(excluded.certified_capabilities, node_capabilities.certified_capabilities),
                certified_level=COALESCE(excluded.certified_level, node_capabilities.certified_level),
                capability_epoch=COALESCE(excluded.capability_epoch, node_capabilities.capability_epoch),
                trust_status=CASE
                    WHEN node_capabilities.trust_status IN ('suspended', 'compromised')
                    THEN node_capabilities.trust_status
                    WHEN node_capabilities.trust_status = 'trusted'
                    THEN node_capabilities.trust_status
                    ELSE excluded.trust_status
                END,
                registered_at=COALESCE(node_capabilities.registered_at, excluded.registered_at)
            """,
            (
                payload.node_id,
                payload.node_url,
                caps_json,
                payload.software_version,
                payload.cluster_id,
                now,
                trust_status,
                now,
                secret_hash,
                payload.build_hash,
                payload.tls_cert_fingerprint,
                payload.release_signature,
                att_status,
                att_detail,
                effective_signing_public_key,
                identity_report.identity_node_id,
                identity_report.operational_certificate_json,
                identity_report.status,
                identity_report.detail,
                advertisement_report.advertisement_json,
                advertisement_report.status,
                advertisement_report.detail,
                advertisement_report.epoch,
                json.dumps(advertisement_report.endpoints)
                if advertisement_report.status == "valid" else None,
                json.dumps(advertisement_report.supported_transports)
                if advertisement_report.status == "valid" else None,
                json.dumps(advertisement_report.supported_protocols)
                if advertisement_report.status == "valid" else None,
                capability_report.certificate_json,
                capability_report.status,
                capability_report.detail,
                json.dumps(capability_report.certified_capabilities)
                if capability_report.status == "valid" else None,
                capability_report.certified_level,
                capability_report.epoch,
            ),
        )
        conn.execute(
            """UPDATE node_capabilities SET
                   transport_certificate = COALESCE(?, transport_certificate),
                   transport_certificate_status = ?,
                   transport_certificate_detail = ?
               WHERE node_id = ?""",
            (
                transport_json,
                transport_status,
                transport_detail,
                payload.node_id,
            ),
        )
        _apply_version_policy(conn, payload.node_id, payload.software_version)
        for historical_state in payload.operational_credential_chain or []:
            publish_credential_state(historical_state, connection=conn)
        publish_credential_state(credential_state, connection=conn)
        row = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
        notify = should_notify_on_register(existing, payload, _trust_from_row(row))
        conn.commit()

    if bound_identity:
        reconcile_registered_subject(bound_identity)
        with get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
            ).fetchone()

    if notify and row:
        schedule_mesh_peer_notify(dict(row), reason="register")

    return _register_response(row, last_heartbeat=now, enrollment_secret=enrollment_secret_plain)


@router.post("/registry/nodes/{node_id}/heartbeat", response_model=NodeCapabilityResponse)
def heartbeat(
    node_id: str,
    payload: HeartbeatRequest = HeartbeatRequest(),
    authorization: Optional[str] = Header(None),
):
    _sync_registry_policy_modules()
    now = now_iso()
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Unknown node_id — register first via POST /registry/nodes")

        trust = _trust_from_row(row)
        if trust == "pending":
            raise HTTPException(status_code=403, detail="Node enrollment pending approval")
        if trust in ("suspended", "compromised"):
            raise HTTPException(status_code=403, detail=f"Node trust_status is {trust}")

        if row["node_token_hash"] and enrollment_required():
            token = extract_bearer_token(authorization)
            if not verify_hash(token or "", row["node_token_hash"]):
                raise HTTPException(status_code=401, detail="Invalid or missing node_token")

        heartbeat_identity = evaluate_node_identity_report(
            payload.operational_certificate,
            mode=NODE_IDENTITY_MODE,
            now=datetime.now(timezone.utc),
            existing_identity_node_id=_row_field(row, "identity_node_id"),
            existing_operational_certificate_json=_row_field(
                row, "operational_certificate"
            ),
            advertised_signing_public_key=payload.signing_public_key,
        )
        require_valid_identity(
            heartbeat_identity,
            payload.operational_certificate,
            context="heartbeat",
        )
        heartbeat_advertisement = evaluate_node_advertisement_report(
            payload.node_advertisement,
            mode=NODE_ADVERTISEMENT_MODE,
            now=datetime.now(timezone.utc),
            identity_node_id=(
                heartbeat_identity.identity_node_id
                if heartbeat_identity.status == "valid"
                else None
            ),
            advertised_node_url=row["node_url"],
            minimum_epoch=_row_field(row, "node_advertisement_epoch", 0),
            existing_advertisement_json=_row_field(row, "node_advertisement"),
        )
        if NODE_ADVERTISEMENT_MODE == "enforce" and heartbeat_advertisement.status != "valid":
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid NodeAdvertisement required for heartbeat: "
                    f"{heartbeat_advertisement.detail or heartbeat_advertisement.status}"
                ),
            )
        heartbeat_capability = evaluate_registry_capability(
            payload.capability_certificate,
            identity_node_id=(
                heartbeat_identity.identity_node_id
                if heartbeat_identity.status == "valid"
                else None
            ),
            minimum_epoch=_row_field(row, "capability_epoch", 0),
            existing_certificate_json=_row_field(row, "capability_certificate"),
            advertised_capabilities=json.loads(row["capabilities"]),
            context="heartbeat",
        )
        heartbeat_transport_status, heartbeat_transport_detail, heartbeat_transport_json = (
            _evaluate_transport_certificate(
                payload.transport_certificate,
                identity_node_id=_row_field(row, "identity_node_id"),
            )
        )
        if (
            TRANSPORT_CERTIFICATE_MODE == "enforce"
            and heartbeat_transport_status != "valid"
        ):
            raise HTTPException(
                status_code=403,
                detail=(
                    "valid Transport Certificate required for heartbeat: "
                    f"{heartbeat_transport_detail}"
                ),
            )
        heartbeat_state = validate_credential_state(
            payload.operational_credential_state,
            payload.operational_certificate,
            expected_node_id=_row_field(row, "identity_node_id"),
            context="heartbeat",
        )
        publish_credential_state(heartbeat_state, connection=conn)

        effective_heartbeat_signing_key = None
        effective_heartbeat_certificate = None
        if heartbeat_identity.status == "valid":
            effective_heartbeat_signing_key = heartbeat_identity.operational_public_key
            effective_heartbeat_certificate = heartbeat_identity.operational_certificate_json

        version = payload.software_version or row["software_version"]
        att_status, att_detail = apply_attestation(
            node_id=node_id,
            software_version=version,
            build_hash=payload.build_hash,
            tls_cert_fingerprint=payload.tls_cert_fingerprint,
            release_signature=payload.release_signature,
            existing_row=row,
        )
        # Accumulate messages_total: add delta from 24h counter if provided
        # and the counter increased since last heartbeat (simple monotonic check).
        msg_total_expr = "messages_total"
        msg_total_params: list = []
        if payload.messages_24h is not None:
            prev_24h = _row_field(row, "messages_24h") or 0
            delta = max(0, payload.messages_24h - prev_24h)
            if delta > 0:
                msg_total_expr = "messages_total + ?"
                msg_total_params = [delta]

        conn.execute(
            f"""
            UPDATE node_capabilities SET
                last_heartbeat = ?,
                software_version = ?,
                build_hash = COALESCE(?, build_hash),
                tls_cert_fingerprint = COALESCE(?, tls_cert_fingerprint),
                release_signature = COALESCE(?, release_signature),
                attestation_status = ?,
                attestation_detail = ?,
                signing_public_key = COALESCE(?, signing_public_key),
                operational_certificate = COALESCE(?, operational_certificate),
                node_advertisement = COALESCE(?, node_advertisement),
                node_advertisement_status = ?,
                node_advertisement_detail = ?,
                node_advertisement_epoch = COALESCE(?, node_advertisement_epoch),
                advertised_endpoints = COALESCE(?, advertised_endpoints),
                advertised_transports = COALESCE(?, advertised_transports),
                advertised_protocols = COALESCE(?, advertised_protocols),
                capability_certificate = COALESCE(?, capability_certificate),
                capability_certificate_status = ?,
                capability_certificate_detail = ?,
                certified_capabilities = COALESCE(?, certified_capabilities),
                certified_level = COALESCE(?, certified_level),
                capability_epoch = COALESCE(?, capability_epoch),
                cpu_load_1m       = COALESCE(?, cpu_load_1m),
                cpu_cores         = COALESCE(?, cpu_cores),
                cpu_percent_est   = COALESCE(?, cpu_percent_est),
                ram_total_bytes   = COALESCE(?, ram_total_bytes),
                ram_used_bytes    = COALESCE(?, ram_used_bytes),
                ram_percent       = COALESCE(?, ram_percent),
                disk_used_bytes   = COALESCE(?, disk_used_bytes),
                disk_total_bytes  = COALESCE(?, disk_total_bytes),
                disk_percent      = COALESCE(?, disk_percent),
                uptime_sec        = COALESCE(?, uptime_sec),
                ws_connections    = COALESCE(?, ws_connections),
                messages_24h      = COALESCE(?, messages_24h),
                calls_24h         = COALESCE(?, calls_24h),
                error_rate_pct    = COALESCE(?, error_rate_pct),
                messages_total    = {msg_total_expr}
            WHERE node_id = ?
            """,
            (
                now,
                version,
                payload.build_hash,
                payload.tls_cert_fingerprint,
                payload.release_signature,
                att_status,
                att_detail,
                effective_heartbeat_signing_key,
                effective_heartbeat_certificate,
                heartbeat_advertisement.advertisement_json,
                heartbeat_advertisement.status,
                heartbeat_advertisement.detail,
                heartbeat_advertisement.epoch,
                json.dumps(heartbeat_advertisement.endpoints)
                if heartbeat_advertisement.status == "valid" else None,
                json.dumps(heartbeat_advertisement.supported_transports)
                if heartbeat_advertisement.status == "valid" else None,
                json.dumps(heartbeat_advertisement.supported_protocols)
                if heartbeat_advertisement.status == "valid" else None,
                heartbeat_capability.certificate_json,
                heartbeat_capability.status,
                heartbeat_capability.detail,
                json.dumps(heartbeat_capability.certified_capabilities)
                if heartbeat_capability.status == "valid" else None,
                heartbeat_capability.certified_level,
                heartbeat_capability.epoch,
                payload.cpu_load_1m,
                payload.cpu_cores,
                payload.cpu_percent_est,
                payload.ram_total_bytes,
                payload.ram_used_bytes,
                payload.ram_percent,
                payload.disk_used_bytes,
                payload.disk_total_bytes,
                payload.disk_percent,
                payload.uptime_sec,
                payload.ws_connections,
                payload.messages_24h,
                payload.calls_24h,
                payload.error_rate_pct,
                *msg_total_params,
                node_id,
            ),
        )
        conn.execute(
            """UPDATE node_capabilities SET
                   transport_certificate = COALESCE(?, transport_certificate),
                   transport_certificate_status = ?,
                   transport_certificate_detail = ?
               WHERE node_id = ?""",
            (
                heartbeat_transport_json,
                heartbeat_transport_status,
                heartbeat_transport_detail,
                node_id,
            ),
        )
        _apply_version_policy(conn, node_id, version)
        conn.commit()
        row = conn.execute("SELECT * FROM node_capabilities WHERE node_id = ?", (node_id,)).fetchone()

    response = _node_response(row, last_heartbeat=now)
    # Фаза 3.3: включаем актуальный peer-список в heartbeat-ответ.
    # Нода обновит свой mesh-кэш из этого списка — меньше запросов к Discovery.
    response.peers = _build_peer_list(exclude_node_id=node_id)
    return response


@router.get("/registry/nodes", response_model=NodeCapabilityListResponse)
def list_nodes(
    capability: Optional[str] = None,
    cluster_id: Optional[str] = None,
):
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM node_capabilities ORDER BY last_heartbeat DESC LIMIT ?",
            (MAX_PUBLIC_NODES,),
        ).fetchall()
    nodes = []
    for row in rows:
        trust = _trust_from_row(row)
        if trust != "trusted":
            continue
        if not row_is_publicly_eligible(row):
            continue
        caps = capabilities_from_row(row)
        if caps is None:
            continue
        if capability and capability not in caps:
            continue
        if cluster_id and _cluster_id_from_row(row) != cluster_id:
            continue
        nodes.append(_node_response(row, last_heartbeat=row["last_heartbeat"]))
    return NodeCapabilityListResponse(nodes=nodes)
