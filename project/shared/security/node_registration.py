"""Shared Discovery registration lifecycle for every OUO node service.

The service-specific modules provide configuration and optional telemetry hooks;
identity construction, enrollment secret handling, retries and heartbeat state
transitions live here so all node roles follow the same security contract.
"""

from __future__ import annotations

import asyncio
import hashlib
import inspect
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Awaitable, Callable, Mapping, Protocol

import httpx

from shared.security.runtime import federation_registration_fields
from shared.security.node_identity_credentials import node_identity_registration_fields
from shared.security.node_identity_credentials import load_operational_credential_chain
from shared.security.challenge_observer_runtime import ChallengeObserverRuntime
from shared.security.trust_validator_runtime import TrustValidatorRuntime
from shared.security.outbound_tls import outbound_tls_verify, validated_service_origin
from shared.security.http_response import parse_bounded_json_response


HEARTBEAT_INTERVAL_SECONDS = 60
ENROLLMENT_POLL_INTERVAL_SECONDS = 30
REGISTER_RETRY_INITIAL_SECONDS = 2
REGISTER_RETRY_MAX_SECONDS = 30
ATTESTATION_CACHE_SECONDS = 300


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be a boolean")


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


NODE_CHALLENGE_OBSERVER_ENABLED = _env_bool(
    "NODE_CHALLENGE_OBSERVER_ENABLED", False
)
NODE_CHALLENGE_OBSERVER_INTERVAL_SECONDS = _env_int(
    "NODE_CHALLENGE_OBSERVER_INTERVAL_SECONDS", 30, 10, 3600
)
NODE_VALIDATOR_ENABLED = _env_bool("NODE_VALIDATOR_ENABLED", False)

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


def _validate_credential(value: object, name: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) < 32
        or len(value) > 4096
        or value != value.strip()
        or any(ord(character) < 33 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{name} is malformed")
    return value


def _read_secret_file(path: str, name: str) -> str | None:
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    if not value:
        return None
    return _validate_credential(value, name)


def _write_secret_file_atomic(path: str, value: str, name: str) -> None:
    value = _validate_credential(value, name)
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
        self._last_error_by_discovery: dict[str, str | None] = {}
        self._registered_discoveries: set[str] = set()
        self._observer_runtime: ChallengeObserverRuntime | None = None
        self._validator_runtime: TrustValidatorRuntime | None = None
        self._attestation_cache: dict[str, Any] | None = None
        self._attestation_cache_deadline = 0.0

        configured_urls = [settings.discovery_url]
        configured_urls.extend(
            item.strip().rstrip("/")
            for item in os.environ.get(
                "NODE_REGISTRATION_DISCOVERY_URLS", ""
            ).split(",")
            if item.strip()
        )
        self.discovery_urls = tuple(
            dict.fromkeys(
                validated_service_origin(url, "node registration Discovery URL")
                for url in configured_urls
            )
        )

    def _credential_paths(self, discovery_url: str) -> tuple[str, str]:
        """Use legacy paths for D1 and isolated files for every extra Discovery."""
        if discovery_url == self.settings.discovery_url.rstrip("/"):
            return self.settings.node_token_path, self.settings.enrollment_secret_path
        digest = hashlib.sha256(discovery_url.encode("utf-8")).hexdigest()[:16]
        base = Path(
            os.environ.get("NODE_REGISTRATION_CREDENTIALS_DIR", "")
            or Path(self.settings.node_token_path).parent
        )
        return (
            str(base / f"discovery-{digest}.token"),
            str(base / f"discovery-{digest}.enrollment"),
        )

    def load_node_token(self, discovery_url: str | None = None) -> str | None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        token_path, _ = self._credential_paths(target)
        return _read_secret_file(token_path, "node_token")

    def load_enrollment_secret(self, discovery_url: str | None = None) -> str | None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        _, secret_path = self._credential_paths(target)
        return _read_secret_file(
            secret_path,
            "enrollment_secret",
        )

    def save_enrollment_secret(self, secret: str, discovery_url: str | None = None) -> None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        _, secret_path = self._credential_paths(target)
        _write_secret_file_atomic(
            secret_path,
            secret,
            "enrollment_secret",
        )
        self.logger.info("Enrollment secret saved for %s", target)

    def save_node_token(self, token: str, discovery_url: str | None = None) -> None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        token_path, _ = self._credential_paths(target)
        _write_secret_file_atomic(
            token_path,
            token,
            "node_token",
        )
        self.logger.info("Node token saved for %s", target)

    def auth_headers(self, discovery_url: str | None = None) -> dict[str, str]:
        token = self.load_node_token(discovery_url)
        return {"Authorization": f"Bearer {token}"} if token else {}

    def enrollment_active(self, discovery_url: str | None = None) -> bool:
        if discovery_url is None and len(self.discovery_urls) > 1:
            return any(self.enrollment_active(url) for url in self.discovery_urls)
        return (
            self.settings.enrollment_mode != "legacy"
            and self.load_enrollment_secret(discovery_url) is not None
            and self.load_node_token(discovery_url) is None
        )

    def attestation_payload(self) -> dict[str, Any]:
        now = time.monotonic()
        if (
            self._attestation_cache is not None
            and now < self._attestation_cache_deadline
        ):
            return dict(self._attestation_cache)
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
        self._attestation_cache = dict(payload)
        self._attestation_cache_deadline = now + ATTESTATION_CACHE_SECONDS
        return dict(payload)

    async def heartbeat_payload(self) -> dict[str, Any]:
        payload = self.attestation_payload()
        if self.heartbeat_payload_factory is None:
            return payload
        extra = self.heartbeat_payload_factory()
        if inspect.isawaitable(extra):
            extra = await extra
        payload.update(dict(extra))
        return payload

    async def register_once(self, discovery_url: str | None = None) -> dict[str, Any]:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        registration_payload = {
            "node_id": self.settings.node_id,
            "node_url": self.settings.public_url,
            "capabilities": self.settings.capabilities,
            "software_version": self.settings.software_version,
            "cluster_id": self.settings.cluster_id,
            **self.attestation_payload(),
        }
        if self.settings.operational_credential_chain_path:
            chain = load_operational_credential_chain(
                self.settings.operational_credential_chain_path
            )
            if chain:
                registration_payload["operational_credential_chain"] = chain
        async with httpx.AsyncClient(
            timeout=5.0,
            follow_redirects=False,
            trust_env=False,
            verify=outbound_tls_verify(),
        ) as client:
            response = await client.post(
                f"{target}/registry/nodes",
                json=registration_payload,
            )
            response.raise_for_status()
            data = parse_bounded_json_response(response, max_bytes=256 * 1024)
        self._registered_discoveries.add(target)
        if not isinstance(data, dict):
            raise ValueError("Discovery registration response must be an object")
        secret = data.get("enrollment_secret")
        if secret:
            self.save_enrollment_secret(secret, target)
        if data.get("trust_status") == "pending":
            self.logger.info(
                "Enrollment pending for node_id=%s at %s",
                self.settings.node_id,
                target,
            )
        return data

    async def enrollment_poll_once(self, discovery_url: str | None = None) -> str | None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        secret = self.load_enrollment_secret(target)
        if not secret:
            return None
        async with httpx.AsyncClient(
            timeout=5.0,
            follow_redirects=False,
            trust_env=False,
            verify=outbound_tls_verify(),
        ) as client:
            response = await client.post(
                f"{target}/registry/enrollment/status",
                json={"node_id": self.settings.node_id, "enrollment_secret": secret},
            )
        if response.status_code in (403, 404):
            return None
        response.raise_for_status()
        data = parse_bounded_json_response(response, max_bytes=256 * 1024)
        if not isinstance(data, dict):
            raise ValueError("Discovery enrollment response must be an object")
        token = data.get("node_token")
        if token:
            self.save_node_token(token, target)
            return token
        if data.get("trust_status") != "pending":
            self.logger.warning("Enrollment status=%s", data.get("trust_status"))
        return None

    async def heartbeat_once(self, discovery_url: str | None = None) -> None:
        target = (discovery_url or self.settings.discovery_url).rstrip("/")
        async with httpx.AsyncClient(
            timeout=5.0,
            follow_redirects=False,
            trust_env=False,
            verify=outbound_tls_verify(),
        ) as client:
            response = await client.post(
                f"{target}/registry/nodes/"
                f"{self.settings.node_id}/heartbeat",
                json=await self.heartbeat_payload(),
                headers=self.auth_headers(target),
            )
        if response.status_code == 404:
            await self.register_once(target)
            return
        if response.status_code == 403:
            await self.enrollment_poll_once(target)
            return
        if response.status_code == 401:
            self.logger.warning("Heartbeat rejected: invalid or missing node token")
            return
        response.raise_for_status()
        self._registered_discoveries.add(target)
        if self.heartbeat_response_hook is not None:
            data = parse_bounded_json_response(response, max_bytes=256 * 1024)
            if not isinstance(data, dict):
                raise ValueError("Discovery heartbeat response must be an object")
            result = self.heartbeat_response_hook(data)
            if inspect.isawaitable(result):
                await result

    async def _register_with_retry(self, discovery_url: str) -> None:
        delay = REGISTER_RETRY_INITIAL_SECONDS
        while True:
            try:
                await self.register_once(discovery_url)
                self._last_error_by_discovery[discovery_url] = None
                return
            except Exception as exc:
                self._last_error_by_discovery[discovery_url] = str(exc)
                self.logger.warning(
                    "Registration at %s failed; retrying in %ss: %s",
                    discovery_url,
                    delay,
                    exc,
                )
                await asyncio.sleep(delay)
                delay = min(delay * 2, REGISTER_RETRY_MAX_SECONDS)

    async def _enrollment_poll_loop(self, discovery_url: str) -> None:
        while self.enrollment_active(discovery_url):
            try:
                await self.enrollment_poll_once(discovery_url)
            except Exception as exc:
                self.logger.warning("Enrollment poll failed: %s", exc)
            if self.enrollment_active(discovery_url):
                await asyncio.sleep(ENROLLMENT_POLL_INTERVAL_SECONDS)

    async def _heartbeat_loop(self, discovery_url: str) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)
            try:
                await self.heartbeat_once(discovery_url)
                self._last_error_by_discovery[discovery_url] = None
            except Exception as exc:
                self._last_error_by_discovery[discovery_url] = str(exc)
                self.logger.warning("Heartbeat to %s failed: %s", discovery_url, exc)

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
            "discovery_targets": [
                {
                    "url": url,
                    "primary": url == self.settings.discovery_url.rstrip("/"),
                    "registered": url in self._registered_discoveries,
                    "enrollment_active": self.enrollment_active(url),
                    "has_node_token": self.load_node_token(url) is not None,
                    "last_error": self._last_error_by_discovery.get(url),
                }
                for url in self.discovery_urls
            ],
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
                for discovery_url in self.discovery_urls:
                    async def registration_lifecycle(url: str = discovery_url) -> None:
                        await self._register_with_retry(url)
                        if self.enrollment_active(url):
                            self._spawn(self._enrollment_poll_loop(url))
                        self._spawn(self._heartbeat_loop(url))

                    self._spawn(registration_lifecycle())
                if NODE_CHALLENGE_OBSERVER_ENABLED:
                    def credential_state():
                        return self.attestation_payload().get(
                            "operational_credential_state"
                        )

                    self._observer_runtime = ChallengeObserverRuntime(
                        self.settings,
                        logger=self.logger,
                        interval_seconds=NODE_CHALLENGE_OBSERVER_INTERVAL_SECONDS,
                        credential_state_factory=credential_state,
                    )
                    self._observer_runtime.start()
                if NODE_VALIDATOR_ENABLED:
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
