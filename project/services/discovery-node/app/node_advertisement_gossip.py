"""Authenticated NodeAdvertisement observation exchange between Discovery nodes."""

from __future__ import annotations

import asyncio
import json
import logging
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.authority_checkpoint_store import load_effective_authority_state
from app.config import (
    DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
    NODE_ADVERTISEMENT_GOSSIP_ENABLED,
    NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS,
    NODE_ADVERTISEMENT_GOSSIP_PEERS,
    NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.db import get_conn
from app.node_identity import discovery_node_identity
from app.operational_credential_revocation_store import (
    require_operational_credential_not_revoked,
)
from app.trust_admission import require_node_trust_active
from shared.security.canonical import canonical_json
from shared.security.capability_certificate import (
    ValidatorCredential,
    capability_certificate_hash,
    validate_capability_certificate,
)
from shared.security.capability_enrollment import (
    CapabilityAuthorityState,
    load_capability_authority_state,
)
from shared.security.keys import load_or_create_signing_key
from shared.security.discovery_peer_view import aggregate_discovery_peer_view
from shared.security.node_advertisement import (
    node_advertisement_hash,
    validate_node_advertisement,
)
from shared.security.node_advertisement_observation import (
    issue_advertisement_observation,
    validate_advertisement_observation,
)
from shared.security.transport_certificate import validate_transport_certificate


MAX_GOSSIP_OBJECT_BYTES = 196608
MAX_ACTIVE_OBSERVATIONS_PER_SOURCE = 500
OBSERVATION_RETENTION = timedelta(hours=1)
GOSSIP_PATH = "/registry/node-advertisements/gossip"
logger = logging.getLogger(__name__)


class AdvertisementObservationConflict(ValueError):
    pass


class CapabilityCertificateConflict(ValueError):
    pass


def _advance_capability_head(
    conn,
    capability: Mapping[str, Any],
    *,
    stored_at: str,
) -> bool:
    subject = capability["subject_node_id"]
    epoch = capability["epoch"]
    digest = capability_certificate_hash(capability)
    serialized = canonical_json(dict(capability))
    existing = conn.execute(
        """SELECT capability_epoch, certificate_hash, certificate_json
           FROM capability_certificate_heads WHERE subject_node_id = ?""",
        (subject,),
    ).fetchone()
    if existing is None:
        conn.execute(
            """INSERT INTO capability_certificate_heads (
                   subject_node_id, capability_epoch, certificate_hash,
                   certificate_json, stored_at
               ) VALUES (?, ?, ?, ?, ?)""",
            (subject, epoch, digest, serialized, stored_at),
        )
        return True
    if epoch < existing["capability_epoch"]:
        raise HTTPException(status_code=409, detail="capability certificate rollback detected")
    if epoch == existing["capability_epoch"]:
        if digest == existing["certificate_hash"]:
            return False
        conn.execute(
            """INSERT INTO capability_certificate_conflicts (
                   subject_node_id, capability_epoch, existing_hash,
                   conflicting_hash, conflicting_json, detected_at
               ) VALUES (?, ?, ?, ?, ?, ?)""",
            (subject, epoch, existing["certificate_hash"], digest, serialized, stored_at),
        )
        conn.commit()
        raise CapabilityCertificateConflict(
            "conflicting quorum CapabilityCertificates for subject epoch"
        )
    if epoch != existing["capability_epoch"] + 1:
        raise HTTPException(
            status_code=409,
            detail="CapabilityCertificate subject epoch must be consecutive",
        )
    if capability.get("previous_hash") != existing["certificate_hash"]:
        raise HTTPException(
            status_code=409,
            detail="CapabilityCertificate previous_hash does not match distributed head",
        )
    conn.execute(
        """UPDATE capability_certificate_heads
           SET capability_epoch = ?, certificate_hash = ?, certificate_json = ?, stored_at = ?
           WHERE subject_node_id = ?""",
        (epoch, digest, serialized, stored_at, subject),
    )
    return True


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)


def _validated_peer_url(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("advertisement gossip peer must be an http(s) origin without credentials")
    return value.rstrip("/")


def _authority_state() -> CapabilityAuthorityState:
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    try:
        authority = load_effective_authority_state(
            TRUST_AUTHORITY_STATE_PATH,
            bootstrap_state=bootstrap,
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid authority state: {exc}")
    if authority is None:
        raise HTTPException(status_code=503, detail="authority state is unavailable")
    return authority


def _validated_capability(
    certificate: Mapping[str, Any],
    *,
    subject_node_id: str,
    authority: CapabilityAuthorityState,
    now: datetime,
    required_capability: str | None = None,
) -> None:
    validation = validate_capability_certificate(
        certificate,
        now=now,
        expected_committee=authority.committee,
        expected_threshold=authority.threshold,
        validator_credentials=authority.validators,
        minimum_epoch=0,
        expected_authority_epoch=authority.epoch,
        expected_subject_node_id=subject_node_id,
    )
    if not validation.valid:
        raise HTTPException(status_code=403, detail=validation.reason or "invalid capability")
    if required_capability and required_capability not in certificate["capabilities"]:
        raise HTTPException(
            status_code=403,
            detail=f"source lacks a currently valid {required_capability} capability",
        )


def _source_credential(
    source_node_id: str,
    *,
    authority: CapabilityAuthorityState,
    now: datetime,
) -> ValidatorCredential:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
            (source_node_id,),
        ).fetchone()
    if row is None or row["node_identity_status"] != "valid":
        raise HTTPException(status_code=403, detail="unknown observation source Node Identity")
    if (row["trust_status"] or "unknown") != "trusted":
        raise HTTPException(status_code=403, detail="observation source is not trusted")
    if row["capability_certificate_status"] != "valid":
        raise HTTPException(status_code=403, detail="observation source capability is not valid")
    try:
        capability = json.loads(row["capability_certificate"])
        operational = json.loads(row["operational_certificate"])
        credential = ValidatorCredential(
            public_key=row["signing_public_key"],
            valid_until=_parse_time(operational["valid_until"]),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=403, detail="invalid observation source credential") from exc
    _validated_capability(
        capability,
        subject_node_id=source_node_id,
        authority=authority,
        now=now,
        required_capability="discovery",
    )
    require_operational_credential_not_revoked(operational, at_time=now)
    require_node_trust_active(source_node_id, at_time=now)
    return credential


def build_local_gossip_items(
    *,
    after_node_id: str = "",
    limit: int = 100,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    if not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    authority = _authority_state()
    identity = discovery_node_identity()["operational_certificate"]
    require_operational_credential_not_revoked(identity, at_time=current_time)
    require_node_trust_active(identity["node_id"], at_time=current_time)
    signing_key = load_or_create_signing_key(DISCOVERY_NODE_OPERATIONAL_KEY_PATH)
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT identity_node_id, node_advertisement, capability_certificate,
                      transport_certificate
               FROM node_capabilities
               WHERE identity_node_id > ?
                 AND trust_status = 'trusted'
                 AND node_identity_status = 'valid'
                 AND node_advertisement_status = 'valid'
                 AND capability_certificate_status = 'valid'
                 AND transport_certificate_status = 'valid'
               ORDER BY identity_node_id ASC LIMIT ?""",
            (after_node_id, limit),
        ).fetchall()
    result = []
    for row in rows:
        try:
            advertisement = json.loads(row["node_advertisement"])
            capability = json.loads(row["capability_certificate"])
            transport = json.loads(row["transport_certificate"])
        except (TypeError, json.JSONDecodeError):
            continue
        ad_validation = validate_node_advertisement(advertisement, now=current_time)
        if not ad_validation.valid:
            continue
        transport_validation = validate_transport_certificate(
            transport, now=current_time, expected_node_id=advertisement["node_id"]
        )
        if not transport_validation.valid:
            continue
        try:
            require_operational_credential_not_revoked(
                advertisement["operational_certificate"], at_time=current_time
            )
            require_node_trust_active(
                advertisement["node_id"], at_time=current_time
            )
        except HTTPException:
            continue
        try:
            _validated_capability(
                capability,
                subject_node_id=advertisement["node_id"],
                authority=authority,
                now=current_time,
            )
        except HTTPException:
            continue
        digest = node_advertisement_hash(advertisement)
        result.append(
            {
                "advertisement": advertisement,
                "capability_certificate": capability,
                "transport_certificate": transport,
                "observation": issue_advertisement_observation(
                    source_node_id=identity["node_id"],
                    subject_node_id=advertisement["node_id"],
                    advertisement_epoch=advertisement["epoch"],
                    advertisement_hash=digest,
                    observed_at=current_time,
                    expires_at=current_time + timedelta(minutes=5),
                    source_signing_key=signing_key,
                ),
            }
        )
    return result


def ingest_advertisement_gossip(
    item: Mapping[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "advertisement",
        "capability_certificate",
        "transport_certificate",
        "observation",
    }:
        raise HTTPException(status_code=400, detail="invalid advertisement gossip item")
    try:
        serialized = canonical_json(dict(item))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="gossip item is not valid JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_GOSSIP_OBJECT_BYTES:
        raise HTTPException(status_code=413, detail="advertisement gossip item exceeds size limit")
    advertisement = item["advertisement"]
    capability = item["capability_certificate"]
    transport = item["transport_certificate"]
    observation = item["observation"]
    if not all(
        isinstance(value, Mapping)
        for value in (advertisement, capability, transport, observation)
    ):
        raise HTTPException(status_code=400, detail="invalid advertisement gossip object")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    authority = _authority_state()
    ad_validation = validate_node_advertisement(advertisement, now=current_time)
    if not ad_validation.valid:
        raise HTTPException(status_code=400, detail=ad_validation.reason or "invalid advertisement")
    transport_validation = validate_transport_certificate(
        transport, now=current_time, expected_node_id=advertisement["node_id"]
    )
    if not transport_validation.valid:
        raise HTTPException(
            status_code=400,
            detail=transport_validation.reason or "invalid transport certificate",
        )
    require_operational_credential_not_revoked(
        advertisement["operational_certificate"], at_time=current_time
    )
    require_node_trust_active(advertisement["node_id"], at_time=current_time)
    _validated_capability(
        capability,
        subject_node_id=advertisement["node_id"],
        authority=authority,
        now=current_time,
    )
    source_node_id = observation.get("source_node_id")
    credential = _source_credential(
        source_node_id,
        authority=authority,
        now=current_time,
    )
    digest = node_advertisement_hash(advertisement)
    observation_validation = validate_advertisement_observation(
        observation,
        now=current_time,
        expected_subject_node_id=advertisement["node_id"],
        expected_advertisement_epoch=advertisement["epoch"],
        expected_advertisement_hash=digest,
        source_credential=credential,
    )
    if not observation_validation.valid:
        raise HTTPException(
            status_code=400,
            detail=observation_validation.reason or "invalid advertisement observation",
        )

    stored_at = _iso(current_time)
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM node_advertisement_observations WHERE expires_at < ?",
            (_iso(current_time - OBSERVATION_RETENTION),),
        )
        existing = conn.execute(
            """SELECT advertisement_hash, observation_id
               FROM node_advertisement_observations
               WHERE source_node_id = ? AND subject_node_id = ? AND advertisement_epoch = ?""",
            (source_node_id, advertisement["node_id"], advertisement["epoch"]),
        ).fetchone()
        if existing is not None and existing["advertisement_hash"] != digest:
            raise AdvertisementObservationConflict(
                "Discovery source equivocated for subject advertisement epoch"
            )
        _advance_capability_head(conn, capability, stored_at=stored_at)
        active = conn.execute(
            """SELECT COUNT(*) FROM node_advertisement_observations
               WHERE source_node_id = ? AND expires_at >= ?""",
            (source_node_id, _iso(current_time)),
        ).fetchone()[0]
        if existing is None and active >= MAX_ACTIVE_OBSERVATIONS_PER_SOURCE:
            raise HTTPException(status_code=429, detail="observation source quota exceeded")
        try:
            if existing is None:
                conn.execute(
                    """INSERT INTO node_advertisement_observations (
                           observation_id, source_node_id, subject_node_id,
                           advertisement_epoch, advertisement_hash,
                           advertisement_json, capability_certificate_json,
                           transport_certificate_json, observation_json,
                           expires_at, stored_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        observation["observation_id"],
                        source_node_id,
                        advertisement["node_id"],
                        advertisement["epoch"],
                        digest,
                        canonical_json(dict(advertisement)),
                        canonical_json(dict(capability)),
                        canonical_json(dict(transport)),
                        canonical_json(dict(observation)),
                        observation["expires_at"],
                        stored_at,
                    ),
                )
                accepted = True
            else:
                conn.execute(
                    """UPDATE node_advertisement_observations
                       SET observation_id = ?, advertisement_json = ?,
                           capability_certificate_json = ?,
                           transport_certificate_json = ?, observation_json = ?,
                           expires_at = ?, stored_at = ?
                       WHERE source_node_id = ? AND subject_node_id = ?
                         AND advertisement_epoch = ?""",
                    (
                        observation["observation_id"],
                        canonical_json(dict(advertisement)),
                        canonical_json(dict(capability)),
                        canonical_json(dict(transport)),
                        canonical_json(dict(observation)),
                        observation["expires_at"],
                        stored_at,
                        source_node_id,
                        advertisement["node_id"],
                        advertisement["epoch"],
                    ),
                )
                accepted = False
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AdvertisementObservationConflict("observation identity conflict") from exc
    return {
        "source_node_id": source_node_id,
        "subject_node_id": advertisement["node_id"],
        "advertisement_epoch": advertisement["epoch"],
        "advertisement_hash": digest,
        "accepted": accepted,
    }


def list_stored_observations(
    *,
    subject_node_id: str | None = None,
    limit: int = 100,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    if not 1 <= limit <= 1000:
        raise ValueError("limit must be between 1 and 1000")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    query = (
        """SELECT advertisement_json, capability_certificate_json,
                  transport_certificate_json, observation_json
           FROM node_advertisement_observations
           WHERE expires_at >= ? AND transport_certificate_json IS NOT NULL"""
    )
    params: list[Any] = [_iso(current_time)]
    if subject_node_id:
        query += " AND subject_node_id = ?"
        params.append(subject_node_id)
    query += " ORDER BY subject_node_id, source_node_id LIMIT ?"
    params.append(limit)
    with get_conn() as conn:
        rows = conn.execute(query, tuple(params)).fetchall()
    return [
        {
            "advertisement": json.loads(row["advertisement_json"]),
            "capability_certificate": json.loads(row["capability_certificate_json"]),
            "transport_certificate": json.loads(row["transport_certificate_json"]),
            "observation": json.loads(row["observation_json"]),
        }
        for row in rows
    ]


def build_peer_view(
    *,
    capability: str | None = None,
    minimum_sources: int = 2,
    now: datetime | None = None,
) -> dict[str, Any]:
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    authority = _authority_state()
    items = list_stored_observations(limit=1000, now=current_time)
    with get_conn() as conn:
        heads = {
            row["subject_node_id"]: row["certificate_hash"]
            for row in conn.execute(
                "SELECT subject_node_id, certificate_hash FROM capability_certificate_heads"
            ).fetchall()
        }
    items = [
        item
        for item in items
        if capability_certificate_hash(item["capability_certificate"])
        == heads.get(item["advertisement"]["node_id"])
    ]
    source_ids = sorted(
        {
            item["observation"]["source_node_id"]
            for item in items
            if isinstance(item.get("observation"), Mapping)
            and isinstance(item["observation"].get("source_node_id"), str)
        }
    )
    credentials = {}
    for source_node_id in source_ids:
        try:
            credentials[source_node_id] = _source_credential(
                source_node_id,
                authority=authority,
                now=current_time,
            )
        except HTTPException:
            continue
    view = aggregate_discovery_peer_view(
        [
            {
                "advertisement": item["advertisement"],
                "capability_certificate": item["capability_certificate"],
                "observation": item["observation"],
            }
            for item in items
        ],
        now=current_time,
        authority_state=authority,
        trusted_discovery_sources=credentials,
        minimum_sources=minimum_sources,
    )
    candidates = []
    transport_conflicts: set[str] = set()
    for candidate in view.candidates:
        subject = candidate["node_id"]
        epoch = candidate["advertisement_epoch"]
        matching = [
            item
            for item in items
            if item["advertisement"]["node_id"] == subject
            and item["advertisement"]["epoch"] == epoch
        ]
        variants: dict[str, list[dict[str, Any]]] = {}
        for item in matching:
            encoded = canonical_json(dict(item["transport_certificate"]))
            variants.setdefault(encoded, []).append(item)
        if len(variants) != 1:
            transport_conflicts.add(subject)
            continue
        observations = next(iter(variants.values()))
        sources = {
            item["observation"]["source_node_id"] for item in observations
        }
        if len(sources) < minimum_sources:
            continue
        transport = observations[0]["transport_certificate"]
        validation = validate_transport_certificate(
            transport, now=current_time, expected_node_id=subject
        )
        if not validation.valid:
            continue
        enriched = dict(candidate)
        enriched["transport_certificate"] = transport
        enriched["transport_observed_by"] = sorted(sources)
        candidates.append(enriched)
    if capability:
        candidates = [
            candidate
            for candidate in candidates
            if capability in candidate["capabilities"]
        ]
    return {
        "candidates": candidates,
        "conflicts": sorted(set(view.conflicts) | transport_conflicts),
        "rejected_count": view.rejected_count,
        "trusted_source_count": len(credentials),
    }


async def poll_advertisement_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured = tuple(
        _validated_peer_url(peer) for peer in (peers or NODE_ADVERTISEMENT_GOSSIP_PEERS)
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(
            timeout=NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False,
        )
    fetched = accepted = failed = 0
    try:
        for peer in configured:
            try:
                cursor = ""
                for _page in range(10):
                    response = await client.get(
                        f"{peer}{GOSSIP_PATH}",
                        params={"after_node_id": cursor, "limit": 100},
                    )
                    response.raise_for_status()
                    payload = response.json()
                    observations = payload.get("observations")
                    if not isinstance(observations, list) or len(observations) > 100:
                        raise ValueError("invalid advertisement gossip response")
                    if not observations:
                        break
                    page_subjects = []
                    for item in observations:
                        fetched += 1
                        result = ingest_advertisement_gossip(item)
                        if result["accepted"]:
                            accepted += 1
                        page_subjects.append(result["subject_node_id"])
                    next_cursor = max(page_subjects)
                    if len(observations) < 100:
                        break
                    if next_cursor <= cursor:
                        raise ValueError("advertisement gossip cursor did not advance")
                    cursor = next_cursor
            except Exception as exc:
                failed += 1
                logger.warning("Advertisement gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_advertisement_peers_once()
        except Exception as exc:
            logger.warning("Advertisement gossip cycle failed: %s", exc)
        await asyncio.sleep(NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS)


def start_node_advertisement_gossip() -> asyncio.Task | None:
    if not NODE_ADVERTISEMENT_GOSSIP_ENABLED or not NODE_ADVERTISEMENT_GOSSIP_PEERS:
        return None
    for peer in NODE_ADVERTISEMENT_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
