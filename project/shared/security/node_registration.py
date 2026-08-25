"""Shared Discovery registration lifecycle for every OUO node service.

The service-specific modules provide configuration and optional telemetry hooks;
identity construction, enrollment secret handling, retries and heartbeat state
transitions live here so all node roles follow the same security contract.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import os
import tempfile
from pathlib import Path
from typing import Any, Awaitable, Callable, Mapping, Protocol

import httpx

from shared.security.runtime import federation_registration_fields
from shared.security.node_identity_credentials import node_identity_registration_fields
from shared.security.challenge_observer_runtime import ChallengeObserverRuntime
from shared.security.trust_validator_runtime import TrustValidatorRuntime


HEARTBEAT_INTERVAL_SECONDS = 60
ENROLLMENT_POLL_INTERVAL_SECONDS = 30
REGISTER_RETRY_INITIAL_SECONDS = 2
REGISTER_RETRY_MAX_SECONDS = 30

PayloadFactory = Callable[[], Mapping[str, Any] | Awaitable[Mapping[str, Any]]]
ResponseHook = Callable[[Mapping[str, Any]], None | Awaitable[None]]


class NodeRegistrationSettings(Protocol):
    node_id: str
    public_url: str
    discovery_url: str
    capabilities: list[str]
    software_version: str
    cluster_id: str
    enrollment_mode: str
    node_token_path: str
    enrollment_secret_path: str
    build_hash: str
    tls_cert_fingerprint: str
    release_signature: str
    signing_key_path: str
    root_key_path: str
    operational_certificate_path: str
    operational_credential_chain_path: str
    capability_certificate_path: str
    transport_key_path: str
    transport_certificate_path: str


def _read_secret_file(path: str) -> str | None:
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    return value or None


def _write_secret_file_atomic(path: str, value: str) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(value.strip())
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, destination)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


class NodeRegistrationClient:
    def __init__(
        self,
        settings: NodeRegistrationSettings,
        *,
        logger: logging.Logger,
        heartbeat_payload_factory: PayloadFactory | None = None,
        heartbeat_response_hook: ResponseHook | None = None,
    ) -> None:
        if settings.enrollment_mode not in {"legacy", "hybrid", "strict"}:
            raise ValueError("unsupported enrollment mode")
        if (
            settings.enrollment_mode != "legacy"
            and not settings.operational_credential_chain_path
        ):
            raise ValueError(
                "secure enrollment requires NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH"
            )
        self.settings = settings
        self.logger = logger
        self.heartbeat_payload_factory = heartbeat_payload_factory
        self.heartbeat_response_hook = heartbeat_response_hook
        self._tasks: set[asyncio.Task] = set()
        self._started = False
        self._last_error: str | None = None
        self._observer_runtime: ChallengeObserverRuntime | None = None
        self._validator_runtime: TrustValidatorRuntime | None = None

    def load_node_token(self) -> str | None:
        return _read_secret_file(self.settings.node_token_path)

    def load_enrollment_secret(self) -> str | None:
        return _read_secret_file(self.settings.enrollment_secret_path)

    def save_enrollment_secret(self, secret: str) -> None:
        _write_secret_file_atomic(self.settings.enrollment_secret_path, secret)
        self.logger.info("Enrollment secret saved")

    def save_node_token(self, token: str) -> None:
        _write_secret_file_atomic(self.settings.node_token_path, token)
        self.logger.info("Node token saved")

    def auth_headers(self) -> dict[str, str]:
        token = self.load_node_token()
        return {"Authorization": f"Bearer {token}"} if token else {}

    def enrollment_active(self) -> bool:
        return (
            self.settings.enrollment_mode != "legacy"
            and self.load_enrollment_secret() is not None
            and self.load_node_token() is None
        )

    def attestation_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if self.settings.build_hash:
            payload["build_hash"] = self.settings.build_hash
        if self.settings.tls_cert_fingerprint:
            payload["tls_cert_fingerprint"] = self.settings.tls_cert_fingerprint
        if self.settings.release_signature:
            payload["release_signature"] = self.settings.release_signature
        payload.update(
            federation_registration_fields(
                self.settings.signing_key_path,
                self.settings.root_key_path,
                self.settings.operational_certificate_path,
                self.settings.public_url,
                self.settings.capability_certificate_path,
                capability_authority_state_path=getattr(
                    self.settings, "capability_authority_state_path", ""
                ) or None,
                operational_credential_chain_path=(
                    self.settings.operational_credential_chain_path or None
                ),
                transport_key_path=(
                    getattr(self.settings, "transport_key_path", "") or None
                ),
                transport_certificate_path=(
                    getattr(self.settings, "transport_certificate_path", "") or None
                ),
                supported_transports=getattr(
                    self.settings, "supported_transports", ("https",)
                ),
            )
        )
        return payload

    async def heartbeat_payload(self) -> dict[str, Any]:
        payload = self.attestation_payload()
        if self.heartbeat_payload_factory is None:
            return payload
        extra = self.heartbeat_payload_factory()
        if inspect.isawaitable(extra):
            extra = await extra
        payload.update(dict(extra))
        return payload

    async def register_once(self) -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                f"{self.settings.discovery_url}/registry/nodes",
                json={
                    "node_id": self.settings.node_id,
                    "node_url": self.settings.public_url,
                    "capabilities": self.settings.capabilities,
                    "software_version": self.settings.software_version,
                    "cluster_id": self.settings.cluster_id,
                    **self.attestation_payload(),
                },
            )
            response.raise_for_status()
            data = response.json()
        if not isinstance(data, dict):
            raise ValueError("Discovery registration response must be an object")
        secret = data.get("enrollment_secret")
        if secret:
            self.save_enrollment_secret(secret)
        if data.get("trust_status") == "pending":
            self.logger.info("Enrollment pending for node_id=%s", self.settings.node_id)
        return data

    async def enrollment_poll_once(self) -> str | None:
        secret = self.load_enrollment_secret()
        if not secret:
            return None
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                f"{self.settings.discovery_url}/registry/enrollment/status",
                json={"node_id": self.settings.node_id, "enrollment_secret": secret},
            )
        if response.status_code in (403, 404):
            return None
        response.raise_for_status()
        data = response.json()
        if not isinstance(data, dict):
            raise ValueError("Discovery enrollment response must be an object")
        token = data.get("node_token")
        if token:
            self.save_node_token(token)
            return token
        if data.get("trust_status") != "pending":
            self.logger.warning("Enrollment status=%s", data.get("trust_status"))
        return None

    async def heartbeat_once(self) -> None:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                f"{self.settings.discovery_url}/registry/nodes/"
                f"{self.settings.node_id}/heartbeat",
                json=await self.heartbeat_payload(),
                headers=self.auth_headers(),
            )
        if response.status_code == 404:
            await self.register_once()
            return
        if response.status_code == 403:
            await self.enrollment_poll_once()
            return
        if response.status_code == 401:
            self.logger.warning("Heartbeat rejected: invalid or missing node token")
            return
        response.raise_for_status()
        if self.heartbeat_response_hook is not None:
            data = response.json()
            if not isinstance(data, dict):
                raise ValueError("Discovery heartbeat response must be an object")
            result = self.heartbeat_response_hook(data)
            if inspect.isawaitable(result):
                await result

    async def _register_with_retry(self) -> None:
        delay = REGISTER_RETRY_INITIAL_SECONDS
        while True:
            try:
                await self.register_once()
                return
            except Exception as exc:
                self.logger.warning(
                    "Registration failed; retrying in %ss: %s", delay, exc
                )
                await asyncio.sleep(delay)
                delay = min(delay * 2, REGISTER_RETRY_MAX_SECONDS)

    async def _enrollment_poll_loop(self) -> None:
        while self.enrollment_active():
            try:
                await self.enrollment_poll_once()
            except Exception as exc:
                self.logger.warning("Enrollment poll failed: %s", exc)
            if self.enrollment_active():
                await asyncio.sleep(ENROLLMENT_POLL_INTERVAL_SECONDS)

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)
            try:
                await self.heartbeat_once()
            except Exception as exc:
                self.logger.warning("Heartbeat failed: %s", exc)

    def _spawn(self, coroutine) -> asyncio.Task:
        task = asyncio.create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def status(self) -> dict[str, Any]:
        result = {
            "started": self._started,
            "task_count": len(self._tasks),
            "enrollment_active": self.enrollment_active(),
            "has_node_token": self.load_node_token() is not None,
            "last_error": self._last_error,
        }
        if self._observer_runtime is not None:
            result["challenge_observer"] = self._observer_runtime.status()
        if self._validator_runtime is not None:
            result["trust_validator"] = self._validator_runtime.status()
        return result

    def identity_node_id(self) -> str:
        fields = node_identity_registration_fields(
            root_key_path=self.settings.root_key_path,
            operational_key_path=self.settings.signing_key_path,
            certificate_path=self.settings.operational_certificate_path,
        )
        certificate = fields.get("operational_certificate")
        if isinstance(certificate, Mapping) and isinstance(certificate.get("node_id"), str):
            return certificate["node_id"]
        return self.settings.node_id

    def start(self) -> asyncio.Task:
        if self._started:
            raise RuntimeError("node registration lifecycle is already started")
        self._started = True

        async def initialize() -> None:
            try:
                await self._register_with_retry()
                if self.enrollment_active():
                    self._spawn(self._enrollment_poll_loop())
                self._spawn(self._heartbeat_loop())
                if os.environ.get(
                    "NODE_CHALLENGE_OBSERVER_ENABLED", "false"
                ).lower() in {"1", "true", "yes", "on"}:
                    def credential_state():
                        return self.attestation_payload().get(
                            "operational_credential_state"
                        )

                    self._observer_runtime = ChallengeObserverRuntime(
                        self.settings,
                        logger=self.logger,
                        interval_seconds=max(
                            10,
                            int(
                                os.environ.get(
                                    "NODE_CHALLENGE_OBSERVER_INTERVAL_SECONDS", "30"
                                )
                            ),
                        ),
                        credential_state_factory=credential_state,
                    )
                    self._observer_runtime.start()
                if os.environ.get("NODE_VALIDATOR_ENABLED", "false").lower() in {
                    "1", "true", "yes", "on"
                }:
                    self._validator_runtime = TrustValidatorRuntime(logger=self.logger)
                    self._validator_runtime.start()
            except Exception as exc:
                self._last_error = str(exc)
                raise

        return self._spawn(initialize())

    async def stop(self) -> None:
        self._started = False
        if self._observer_runtime is not None:
            await self._observer_runtime.stop()
            self._observer_runtime = None
        if self._validator_runtime is not None:
            await self._validator_runtime.stop()
            self._validator_runtime = None
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._tasks.clear()
