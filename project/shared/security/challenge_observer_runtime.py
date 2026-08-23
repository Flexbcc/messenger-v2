"""Portable node-side executor for assigned synthetic availability checks."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import logging
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import urlsplit, urlunsplit

import httpx

from shared.security.challenge_assignment import issue_assignment_ack
from shared.security.http_client import federation_get, federation_post
from shared.security.keys import load_or_create_signing_key
from shared.security.node_identity_credentials import node_identity_registration_fields
from shared.security.observer_auth import issue_observer_request_proof
from shared.security.relay_challenge_receipt import validate_relay_challenge_receipt
from shared.security.synthetic_challenge import run_synthetic_challenge
from shared.security.trust_cache import TrustCache


class ObserverSettings(Protocol):
    discovery_url: str
    signing_key_path: str
    root_key_path: str
    operational_certificate_path: str
    operational_credential_chain_path: str


class ChallengeObserverRuntime:
    def __init__(
        self,
        settings: ObserverSettings,
        *,
        logger: logging.Logger,
        interval_seconds: int = 30,
        credential_state_factory: Callable[[], Mapping[str, Any] | None] | None = None,
    ) -> None:
        self.settings = settings
        self.logger = logger
        self.interval_seconds = max(10, min(300, interval_seconds))
        self.trust_cache = TrustCache(settings.discovery_url)
        configured = tuple(
            dict.fromkeys(
                value.strip().rstrip("/")
                for value in os.environ.get("FEDERATION_DISCOVERY_URLS", "").split(",")
                if value.strip()
            )
        )
        self.discovery_origins = configured or (settings.discovery_url.rstrip("/"),)
        for origin in self.discovery_origins:
            parsed = urlsplit(origin)
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.username
                or parsed.password
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
            ):
                raise ValueError("Challenge Discovery URL must be an http(s) origin")
        self.credential_state_factory = credential_state_factory
        self._task: asyncio.Task | None = None
        self._last_error: str | None = None
        self._completed = 0
        self._declined = 0

    def _credentials(self):
        signing_key = load_or_create_signing_key(self.settings.signing_key_path)
        certificate = node_identity_registration_fields(
            root_key_path=self.settings.root_key_path,
            operational_key_path=self.settings.signing_key_path,
            certificate_path=self.settings.operational_certificate_path,
        )["operational_certificate"]
        return signing_key, certificate

    def _credential_state(self) -> Mapping[str, Any] | None:
        return self.credential_state_factory() if self.credential_state_factory else None

    async def _post(self, path: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        last_error: Exception | None = None
        async with httpx.AsyncClient(
            timeout=10.0, follow_redirects=False, trust_env=False
        ) as client:
            for origin in self.discovery_origins:
                try:
                    response = await client.post(
                        f"{origin}{path}", json=dict(payload)
                    )
                    response.raise_for_status()
                    result = response.json()
                    if not isinstance(result, dict):
                        raise ValueError("Discovery challenge response must be an object")
                    return result
                except (httpx.HTTPError, ValueError) as exc:
                    last_error = exc
        raise RuntimeError("all Challenge Discovery origins failed") from last_error

    async def pull_once(self) -> int:
        signing_key, certificate = self._credentials()
        now = datetime.now(timezone.utc)
        pull_payload = {"limit": 20}
        proof = issue_observer_request_proof(
            observer_signing_key=signing_key,
            operational_certificate=certificate,
            action="challenge_assignment_pull",
            payload=pull_payload,
            issued_at=now,
            expires_at=now + timedelta(minutes=2),
        )
        response = await self._post(
            "/registry/challenge-assignments/pull",
            {
                "proof": proof,
                "limit": 20,
                "operational_credential_state": self._credential_state(),
            },
        )
        assignments = response.get("assignments")
        if not isinstance(assignments, list) or len(assignments) > 20:
            raise ValueError("invalid challenge assignment list")
        handled = 0
        for item in assignments:
            if not isinstance(item, dict) or not isinstance(item.get("assignment"), dict):
                continue
            assignment = item["assignment"]
            state = item.get("state")
            if state in {"completed", "declined", "expired"}:
                continue
            if assignment.get("challenge_type") not in {
                "availability",
                "storage_store_get",
                "discovery_lookup",
                "relay_delivery",
            }:
                if state == "pending":
                    await self._ack(assignment, "declined", signing_key, certificate)
                    self._declined += 1
                continue
            if state == "pending":
                await self._ack(assignment, "accepted", signing_key, certificate)
            await self._execute(assignment, signing_key, certificate)
            self._completed += 1
            handled += 1
        return handled

    async def _ack(self, assignment, decision, signing_key, certificate) -> None:
        ack = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=certificate["node_id"],
            decision=decision,
            acknowledged_at=datetime.now(timezone.utc),
            observer_signing_key=signing_key,
        )
        await self._post(
            "/registry/challenge-assignment-acks/portable",
            {
                "ack": ack,
                "operational_certificate": certificate,
                "operational_credential_state": self._credential_state(),
            },
        )

    async def _https_endpoint(self, subject_node_id: str) -> str | None:
        node = await self.trust_cache.get_node(subject_node_id)
        endpoint = node.get("node_url") if node else None
        if not isinstance(endpoint, str):
            return None
        parsed = urlsplit(endpoint)
        allowed_schemes = {"https", "wss"}
        if os.environ.get("NODE_CHALLENGE_ALLOW_HTTP", "false").lower() in {
            "1", "true", "yes", "on"
        }:
            allowed_schemes.add("http")
        if parsed.scheme not in allowed_schemes or not parsed.hostname:
            return None
        path = parsed.path.rstrip("/")
        for suffix in ("/relay/ws", "/mix/ingress"):
            if path.endswith(suffix):
                path = path[: -len(suffix)]
        scheme = "http" if parsed.scheme == "http" else "https"
        return urlunsplit((scheme, parsed.netloc, path, "", "")).rstrip("/")

    async def _execute(self, assignment, signing_key, certificate) -> None:
        subject_node_id = assignment["subject_node_id"]
        challenge_type = assignment["challenge_type"]

        async def action(_context) -> bool:
            endpoint = await self._https_endpoint(subject_node_id)
            if endpoint is None:
                return False
            if challenge_type == "relay_delivery":
                own_node_id = certificate["node_id"]
                destinations = sorted(
                    {
                        item
                        for item in assignment.get("observer_node_ids", [])
                        if isinstance(item, str)
                        and item not in {own_node_id, subject_node_id}
                    }
                )
                if not destinations:
                    return False
                destination_node_id = destinations[0]
                destination = await self.trust_cache.get_node(destination_node_id)
                receiver_public_key = (
                    destination.get("signing_public_key") if destination else None
                )
                if not isinstance(receiver_public_key, str):
                    return False
                cell = secrets.token_bytes(4096)
                digest = hashlib.sha256(cell).hexdigest()
                expires_at = datetime.now(timezone.utc) + timedelta(minutes=2)
                path = "/internal/challenge/relay/deliver"
                payload = {
                    "challenge_id": _context.challenge_id,
                    "destination_node_id": destination_node_id,
                    "cell_b64": base64.urlsafe_b64encode(cell).decode("ascii"),
                    "expected_hash": digest,
                    "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
                }
                async with httpx.AsyncClient(
                    timeout=7.0, follow_redirects=False, trust_env=False
                ) as client:
                    response = await federation_post(
                        client,
                        f"{endpoint}{path}",
                        path=path,
                        payload=payload,
                        signing_key=signing_key,
                        node_id=own_node_id,
                    )
                    response.raise_for_status()
                    result = response.json()
                receipt = result.get("receipt") if isinstance(result, dict) else None
                return validate_relay_challenge_receipt(
                    receipt,
                    expected_challenge_id=_context.challenge_id,
                    expected_receiver_node_id=destination_node_id,
                    expected_cell_hash=digest,
                    receiver_public_key=receiver_public_key,
                    now=datetime.now(timezone.utc),
                )
            if challenge_type == "storage_store_get":
                cell = secrets.token_bytes(4096)
                digest = hashlib.sha256(cell).hexdigest()
                encoded = base64.urlsafe_b64encode(cell).decode("ascii")
                store_path = "/internal/challenge/storage/store"
                async with httpx.AsyncClient(
                    timeout=5.0, follow_redirects=False, trust_env=False
                ) as client:
                    stored = await federation_post(
                        client,
                        f"{endpoint}{store_path}",
                        path=store_path,
                        payload={"cell_b64": encoded, "expected_hash": digest},
                        signing_key=signing_key,
                        node_id=certificate["node_id"],
                    )
                    stored.raise_for_status()
                    receipt = stored.json()
                    token = receipt.get("token") if isinstance(receipt, dict) else None
                    if not isinstance(token, str) or receipt.get("cell_hash") != digest:
                        return False
                    get_path = f"/internal/challenge/storage/get/{token}"
                    fetched = await federation_get(
                        client,
                        f"{endpoint}{get_path}",
                        path=get_path,
                        signing_key=signing_key,
                        node_id=certificate["node_id"],
                    )
                    fetched.raise_for_status()
                    result = fetched.json()
                if not isinstance(result, dict):
                    return False
                try:
                    returned = base64.b64decode(
                        result.get("cell_b64", ""), altchars=b"-_", validate=True
                    )
                except ValueError:
                    return False
                return (
                    len(returned) == 4096
                    and secrets.compare_digest(result.get("cell_hash", ""), digest)
                    and secrets.compare_digest(hashlib.sha256(returned).hexdigest(), digest)
                    and secrets.compare_digest(returned, cell)
                )
            if challenge_type == "discovery_lookup":
                own_node_id = certificate["node_id"]
                expected = await self.trust_cache.get_node(own_node_id)
                expected_endpoint = expected.get("node_url") if expected else None
                async with httpx.AsyncClient(
                    timeout=5.0, follow_redirects=False, trust_env=False
                ) as client:
                    response = await client.get(
                        f"{endpoint}/registry/node-advertisements/peer-view",
                        params={"minimum_sources": 2},
                    )
                    response.raise_for_status()
                    result = response.json()
                candidates = result.get("candidates") if isinstance(result, dict) else None
                if not isinstance(candidates, list) or len(candidates) > 1000:
                    return False
                matches = [
                    item for item in candidates
                    if isinstance(item, dict) and item.get("node_id") == own_node_id
                ]
                return (
                    len(matches) == 1
                    and isinstance(expected_endpoint, str)
                    and matches[0].get("endpoint") == expected_endpoint
                )
            async with httpx.AsyncClient(
                timeout=5.0, follow_redirects=False, trust_env=False
            ) as client:
                response = await client.get(f"{endpoint}/health")
                response.raise_for_status()
                health = response.json()
            return (
                isinstance(health, dict)
                and health.get("status") == "ok"
                and health.get("node_id") == subject_node_id
            )

        execution = await run_synthetic_challenge(
            observer_node_id=certificate["node_id"],
            subject_node_id=subject_node_id,
            epoch=assignment["epoch"],
            challenge_type=challenge_type,
            observer_signing_key=signing_key,
            action=action,
        )
        await self._post(
            "/registry/trust-observations/portable",
            {
                "observation": execution.observation,
                "assignment_id": assignment["assignment_id"],
                "operational_certificate": certificate,
                "operational_credential_state": self._credential_state(),
            },
        )

    async def _loop(self) -> None:
        while True:
            try:
                await self.pull_once()
                self._last_error = None
            except Exception as exc:
                self._last_error = str(exc)
                self.logger.warning("challenge observer cycle failed: %s", exc)
            await asyncio.sleep(self.interval_seconds)

    def start(self) -> asyncio.Task:
        if self._task is not None and not self._task.done():
            raise RuntimeError("challenge observer runtime already started")
        self._task = asyncio.create_task(self._loop())
        return self._task

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        await asyncio.gather(self._task, return_exceptions=True)
        self._task = None

    def status(self) -> dict[str, Any]:
        return {
            "running": self._task is not None and not self._task.done(),
            "completed": self._completed,
            "declined_unsupported": self._declined,
            "last_error": self._last_error,
        }
