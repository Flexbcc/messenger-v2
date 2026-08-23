import asyncio
import logging

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.routers import admin_enrollment, enrollment, registry
from app.config import (
    CAPABILITY_CERTIFICATE_MODE,
    ENROLLMENT_MODE,
    NODE_ADVERTISEMENT_MODE,
    NODE_IDENTITY_MODE,
    OPERATIONAL_CREDENTIAL_STATE_MODE,
    OPERATIONAL_CREDENTIAL_REVOCATION_MODE,
    TRUST_LEDGER_MODE,
    TRUST_PROPOSAL_MODE,
    TRUST_DEGRADATION_MODE,
    CHALLENGE_PROPOSAL_SCHEDULER_MODE,
    DISCOVERY_SIGNING_KEY_PATH,
)
from app.attestation import ATTESTATION_MODE, MTLS_MODE
from app.deps import require_admin
from app.health import start_health_monitor
from app.key_rotation import bootstrap_key_from_file, get_all_valid_public_keys, rotate_signing_key, expire_old_keys
from app.record_signer import discovery_public_key_b64
from app.trust_degradation import start_trust_degradation
from app.network_guard import get_network_view_guard
from app.node_identity import discovery_node_identity
from app.config import DISCOVERY_NODE_ALIAS
from app.config import AUTHORITY_GOSSIP_ENABLED, AUTHORITY_GOSSIP_PEERS
from app.authority_gossip import start_authority_gossip
from app.node_advertisement_gossip import start_node_advertisement_gossip
from app.trust_record_gossip import start_trust_record_gossip
from app.trust_record_proposals import start_trust_record_proposals
from app.challenge_assignment_gossip import start_challenge_assignment_gossip
from app.challenge_assignment_ack_gossip import start_challenge_assignment_ack_gossip
from app.challenge_proposal_scheduler import (
    challenge_proposal_status_counts,
    start_challenge_proposal_scheduler,
)
from app.trust_observation_gossip import start_trust_observation_gossip
from app.randomness_checkpoint_gossip import start_randomness_checkpoint_gossip
from app.operational_credential_gossip import start_operational_credential_gossip
from app.operational_credential_revocation_gossip import (
    start_operational_credential_revocation_gossip,
)
from app.rendezvous_gossip import start_rendezvous_gossip
from shared.security.trust_ledger import TrustLedgerStore
from app.config import (
    NODE_ADVERTISEMENT_GOSSIP_ENABLED,
    NODE_ADVERTISEMENT_GOSSIP_PEERS,
    TRUST_RECORD_GOSSIP_ENABLED,
    TRUST_RECORD_GOSSIP_PEERS,
    TRUST_LEDGER_DB_PATH,
    CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED,
    CHALLENGE_ASSIGNMENT_GOSSIP_PEERS,
    RENDEZVOUS_GOSSIP_ENABLED,
    RENDEZVOUS_GOSSIP_PEERS,
)

logger = logging.getLogger(__name__)

KEY_EXPIRE_CHECK_INTERVAL_SECONDS = 3600  # раз в час

app = FastAPI(title="Discovery Node", version="0.2.0")
_background_tasks: set[asyncio.Task] = set()


def _track(task: asyncio.Task | None) -> None:
    if task is not None:
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)


async def _key_expire_loop():
    while True:
        await asyncio.sleep(KEY_EXPIRE_CHECK_INTERVAL_SECONDS)
        try:
            n = expire_old_keys()
            if n:
                logger.info("Key rotation: %d retiring key(s) marked expired", n)
        except Exception as e:
            logger.warning("Key expire check failed (non-fatal): %s", e)


@app.on_event("startup")
async def on_startup():
    init_db()
    discovery_node_identity()
    bootstrap_key_from_file(DISCOVERY_SIGNING_KEY_PATH)
    _track(start_health_monitor())
    _track(start_trust_degradation())
    _track(start_authority_gossip())
    _track(start_node_advertisement_gossip())
    _track(start_trust_record_gossip())
    _track(start_trust_record_proposals())
    _track(start_challenge_assignment_gossip())
    _track(start_challenge_assignment_ack_gossip())
    _track(start_challenge_proposal_scheduler())
    _track(start_trust_observation_gossip())
    _track(start_randomness_checkpoint_gossip())
    _track(start_operational_credential_gossip())
    _track(start_operational_credential_revocation_gossip())
    _track(start_rendezvous_gossip())
    _track(asyncio.create_task(_key_expire_loop()))


@app.on_event("shutdown")
async def on_shutdown():
    tasks = list(_background_tasks)
    for task in tasks:
        task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    _background_tasks.clear()


@app.get("/health")
def health():
    with get_conn() as conn:
        nodes_count = conn.execute("SELECT COUNT(*) FROM node_capabilities").fetchone()[0]
        users_count = conn.execute("SELECT COUNT(*) FROM user_records").fetchone()[0]
        bootstrap_records_count = conn.execute(
            "SELECT COUNT(*) FROM bootstrap_records"
        ).fetchone()[0]
        route_descriptors_count = conn.execute(
            "SELECT COUNT(*) FROM route_descriptors"
        ).fetchone()[0]
        trust_observations_count = conn.execute(
            "SELECT COUNT(*) FROM trust_observations"
        ).fetchone()[0]
        trust_observation_events_count = conn.execute(
            "SELECT COUNT(*) FROM trust_observation_events"
        ).fetchone()[0]
        challenge_assignments_count = conn.execute(
            "SELECT COUNT(*) FROM challenge_assignments"
        ).fetchone()[0]
        challenge_proposals_count = conn.execute(
            "SELECT COUNT(*) FROM challenge_assignment_proposals"
        ).fetchone()[0]
        randomness_checkpoints_count = conn.execute(
            "SELECT COUNT(*) FROM randomness_checkpoints"
        ).fetchone()[0]
        operational_credential_states_count = conn.execute(
            "SELECT COUNT(*) FROM operational_credential_states"
        ).fetchone()[0]
        operational_credential_revocations_count = conn.execute(
            "SELECT COUNT(*) FROM operational_credential_revocations"
        ).fetchone()[0]
        pending_challenge_observers = conn.execute(
            """SELECT COUNT(*) FROM challenge_assignment_observers
               WHERE state IN ('pending', 'accepted')"""
        ).fetchone()[0]
        challenge_assignment_acks = conn.execute(
            "SELECT COUNT(*) FROM challenge_assignment_ack_events"
        ).fetchone()[0]
        authority_checkpoint_count = conn.execute(
            "SELECT COUNT(*) FROM authority_checkpoints"
        ).fetchone()[0]
        authority_recovery_count = conn.execute(
            "SELECT COUNT(*) FROM authority_recoveries"
        ).fetchone()[0]
        trust_degradation_candidates = conn.execute(
            "SELECT COUNT(*) FROM trust_degradation_candidates"
        ).fetchone()[0]
        trust_record_proposals_count = conn.execute(
            "SELECT COUNT(*) FROM trust_record_proposals"
        ).fetchone()[0]
    network_view = get_network_view_guard().decision()
    identity = discovery_node_identity()["operational_certificate"]
    trust_record_count = TrustLedgerStore(TRUST_LEDGER_DB_PATH).latest_sequence()
    proposal_status = challenge_proposal_status_counts()
    return {
        "status": "ok",
        "node_role": "discovery",
        "node_id": identity["node_id"],
        "node_alias": DISCOVERY_NODE_ALIAS,
        "load": {
            "registered_nodes": nodes_count,
            "registered_users": users_count,
            "bootstrap_records": bootstrap_records_count,
            "route_descriptors": route_descriptors_count,
            "trust_observations": trust_observations_count,
            "trust_observation_events": trust_observation_events_count,
            "challenge_assignments": challenge_assignments_count,
            "challenge_assignment_proposals": challenge_proposals_count,
            "challenge_proposal_recent_status": proposal_status,
            "randomness_checkpoints": randomness_checkpoints_count,
            "operational_credential_states": operational_credential_states_count,
            "operational_credential_revocations": operational_credential_revocations_count,
            "pending_challenge_observers": pending_challenge_observers,
            "challenge_assignment_acks": challenge_assignment_acks,
            "authority_checkpoints": authority_checkpoint_count,
            "authority_recoveries": authority_recovery_count,
            "authority_gossip_enabled": AUTHORITY_GOSSIP_ENABLED,
            "authority_gossip_peer_count": len(AUTHORITY_GOSSIP_PEERS),
            "node_advertisement_gossip_enabled": NODE_ADVERTISEMENT_GOSSIP_ENABLED,
            "node_advertisement_gossip_peer_count": len(NODE_ADVERTISEMENT_GOSSIP_PEERS),
            "trust_record_gossip_enabled": TRUST_RECORD_GOSSIP_ENABLED,
            "trust_record_gossip_peer_count": len(TRUST_RECORD_GOSSIP_PEERS),
            "rendezvous_gossip_enabled": RENDEZVOUS_GOSSIP_ENABLED,
            "rendezvous_gossip_peer_count": len(RENDEZVOUS_GOSSIP_PEERS),
            "trust_records": trust_record_count,
            "trust_record_proposals": trust_record_proposals_count,
            "trust_proposal_mode": TRUST_PROPOSAL_MODE,
            "challenge_assignment_gossip_enabled": CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED,
            "challenge_assignment_gossip_peer_count": len(CHALLENGE_ASSIGNMENT_GOSSIP_PEERS),
            "challenge_proposal_scheduler_mode": CHALLENGE_PROPOSAL_SCHEDULER_MODE,
            "enrollment_mode": ENROLLMENT_MODE,
            "attestation_mode": ATTESTATION_MODE,
            "mtls_mode": MTLS_MODE,
            "node_identity_mode": NODE_IDENTITY_MODE,
            "operational_credential_state_mode": OPERATIONAL_CREDENTIAL_STATE_MODE,
            "operational_credential_revocation_mode": OPERATIONAL_CREDENTIAL_REVOCATION_MODE,
            "node_advertisement_mode": NODE_ADVERTISEMENT_MODE,
            "capability_certificate_mode": CAPABILITY_CERTIFICATE_MODE,
            "trust_ledger_mode": TRUST_LEDGER_MODE,
            "trust_degradation_mode": TRUST_DEGRADATION_MODE,
            "trust_degradation_candidates": trust_degradation_candidates,
            "governance_allowed": network_view.governance_allowed,
            "control_plane_frozen_reason": network_view.frozen_reason,
        },
        "runtime": {
            "capabilities": ["discovery"],
            "background_tasks": len(_background_tasks),
            "started": bool(_background_tasks),
        },
    }


@app.get("/discovery-pubkey")
def discovery_pubkey():
    """
    Ed25519 public key текущего активного ключа.
    Home-nodes используют для верификации подписей user records.
    """
    return {
        "public_key": discovery_public_key_b64(),
        "algorithm": "Ed25519",
        "encoding": "base64url",
        "usage": "verify user record signatures (user_id|home_node_url|updated_at)",
    }


@app.get("/discovery-pubkeys")
def discovery_pubkeys():
    """
    Все валидные публичные ключи (active + retiring в grace period).
    Home-nodes должны принимать подписи от любого из этих ключей.
    Используется при ротации ключей без даунтайма.
    """
    keys = get_all_valid_public_keys()
    return {
        "keys": [
            {
                "key_id": k["key_id"],
                "public_key": k["public_key"],
                "status": k["status"],
                "created_at": k["created_at"],
                "expires_at": k.get("expires_at"),
            }
            for k in keys
        ],
        "algorithm": "Ed25519",
        "encoding": "base64url",
    }


@app.post("/admin/discovery/rotate-key", dependencies=[Depends(require_admin)])
def rotate_discovery_key():
    """
    Ротация signing key без даунтайма:
      1. Новый ключ становится активным (подписывает новые записи).
      2. Старый переходит в retiring — ещё действителен KEY_ROTATION_GRACE_DAYS дней.
      3. После grace period старый ключ автоматически маркируется expired.

    Home-nodes получат новый ключ при следующем вызове /discovery-pubkeys.
    """
    result = rotate_signing_key()
    logger.info("Discovery signing key rotated: new key_id=%s", result["key_id"])
    return result


app.include_router(registry.router)
app.include_router(enrollment.router)
app.include_router(admin_enrollment.router)
