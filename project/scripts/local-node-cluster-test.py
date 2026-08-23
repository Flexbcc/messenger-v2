#!/usr/bin/env python3
"""Run a real six-process node federation test on loopback.

No Docker, external network, Proxmox, or persistent project data is touched.
Service databases and logs are written under ignored test-results/.
"""

from __future__ import annotations

import asyncio
import base64
import json
import hashlib
import os
import socket
import sqlite3
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
from nacl.signing import SigningKey
from websockets.sync.client import connect as websocket_connect
from websockets.exceptions import ConnectionClosed


PROJECT_ROOT = Path(__file__).resolve().parents[1]
os.environ["INTERNAL_SECURITY_MODE"] = "signed"
os.environ["FEDERATION_ENVELOPE_MODE"] = "signed"
sys.path.insert(0, str(PROJECT_ROOT))

from shared.security.federation_auth import sign_federation_request
from shared.security.bootstrap_record import issue_bootstrap_record, validate_bootstrap_record
from shared.security.capability_certificate import (
    add_validator_signature,
    build_capability_certificate,
    capability_certificate_hash,
)
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.authority_checkpoint import (
    add_authority_signature,
    authority_checkpoint_hash,
    authority_state_hash,
    build_authority_checkpoint,
)
from shared.security.keys import load_or_create_signing_key
from shared.security.keys import public_key_b64
from shared.security.node_identity_credentials import (
    node_identity_registration_fields,
    rotate_operational_credentials,
)
from shared.security.node_identity import issue_operational_certificate
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
)
from shared.security.operational_credential_revocation import (
    add_operational_credential_revocation_signature,
    build_operational_credential_revocation,
)
from shared.security.mailbox_capability import generate_mailbox_token
from shared.security.runtime import federation_registration_fields
from shared.security.route_descriptor import (
    issue_route_descriptor,
    route_descriptor_hash,
    validate_route_descriptor,
    validate_route_transition,
)
from shared.security.trust_ledger import (
    add_trust_record_signature,
    build_trust_record,
    trust_record_hash,
)
from shared.security.challenge_assignment import (
    add_assignment_signature,
    issue_assignment_ack,
)
from shared.security.challenge_scheduler import build_challenge_assignment_proposal
from shared.security.randomness_checkpoint import (
    add_randomness_signature,
    build_randomness_checkpoint,
)
from shared.security.observer_auth import issue_observer_request_proof
from shared.security.trust_evidence import issue_reliability_observation
from shared.security.synthetic_challenge import run_synthetic_challenge
from shared.transport.binary_batch import decode_batch, encode_batch
from shared.transport.fixed_cell import open_fixed_cell, seal_fixed_cell
from shared.transport.ws_relay_client import RelayWebSocketClient
from shared.security.payload_builder import (
    build_buffer_payload,
    build_deliver_payload,
    build_delivery_ack_payload,
    build_relay_forward_payload,
)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


@dataclass
class Service:
    name: str
    role: str
    port: int
    env: dict[str, str]
    log_path: Path
    process: subprocess.Popen | None = None
    log_handle: Any = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> None:
        service_root = PROJECT_ROOT / "services" / self.role
        process_env = os.environ.copy()
        process_env.update(self.env)
        process_env["PYTHONPATH"] = f"{service_root}:{PROJECT_ROOT}"
        self.log_handle = self.log_path.open("ab")
        self.process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(self.port),
                "--log-level",
                "info",
            ],
            cwd=PROJECT_ROOT,
            env=process_env,
            stdout=self.log_handle,
            stderr=subprocess.STDOUT,
        )

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log_handle:
            self.log_handle.close()
            self.log_handle = None


class ClusterRun:
    def __init__(self) -> None:
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{uuid.uuid4().hex[:8]}"
        self.run_dir = PROJECT_ROOT / "test-results" / "local-node-cluster" / run_id
        self.run_dir.mkdir(parents=True)
        self.services: dict[str, Service] = {}
        self.results: list[dict[str, Any]] = []
        self.discovery_url = ""
        self.validator_keys: dict[str, SigningKey] = {}
        self.capability_authority_state_path = self.run_dir / "data" / "authority-state.json"
        self.applied_trust_record: dict[str, Any] | None = None
        self.mesh_notify_secret = uuid.uuid4().hex + uuid.uuid4().hex

    def record(self, name: str, passed: bool, detail: str) -> None:
        self.results.append({"name": name, "passed": passed, "detail": detail})
        print(f"{'PASS' if passed else 'FAIL'} {name}: {detail}", flush=True)
        if not passed:
            raise AssertionError(f"{name}: {detail}")

    def add_service(self, name: str, role: str, env: dict[str, str]) -> Service:
        service = Service(name, role, _free_port(), env, self.run_dir / f"{name}.log")
        self.services[name] = service
        return service

    def common_node_env(self, name: str) -> dict[str, str]:
        data = self.run_dir / "data" / name
        data.mkdir(parents=True)
        return {
            "DISCOVERY_NODE_URL": self.discovery_url,
            "ENROLLMENT_MODE": "legacy",
            "INTERNAL_SECURITY_MODE": "signed",
            "FEDERATION_NODE_ID_MODE": "enforce",
            "FEDERATION_CAPABILITY_MODE": "enforce",
            "FEDERATION_ENVELOPE_MODE": "signed",
            "NODE_SIGNING_KEY_PATH": str(data / "operational.key"),
            "NODE_ROOT_KEY_PATH": str(data / "root.key"),
            "NODE_OPERATIONAL_CERTIFICATE_PATH": str(data / "operational-certificate.json"),
            "NODE_TOKEN_PATH": str(data / "node-token"),
            "ENROLLMENT_SECRET_PATH": str(data / "enrollment-secret"),
            "FEDERATION_NONCE_DB_PATH": str(data / "nonces.db"),
            "FEDERATION_AUDIT_DB_PATH": str(data / "audit.db"),
            "NODE_SOFTWARE_VERSION": "cluster-test",
            "NODE_BUILD_HASH": "cluster-test",
            "CLUSTER_ID": "local-test",
            "MESH_NOTIFY_SECRET": self.mesh_notify_secret,
        }

    def wait_health(self, service: Service, timeout: float = 25) -> None:
        deadline = time.monotonic() + timeout
        last_detail = "not started"
        while time.monotonic() < deadline:
            if service.process and service.process.poll() is not None:
                raise RuntimeError(f"{service.name} exited with {service.process.returncode}")
            try:
                response = httpx.get(f"{service.url}/health", timeout=1)
                if response.status_code == 200:
                    return
                last_detail = f"HTTP {response.status_code}"
            except httpx.HTTPError as exc:
                last_detail = str(exc)
            time.sleep(0.15)
        raise TimeoutError(f"{service.name} health timeout: {last_detail}")

    def signed_request(
        self,
        *,
        method: str,
        url: str,
        path: str,
        node_id: str,
        key_path: Path,
        payload: dict | None = None,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        raw = body if body is not None else (_json_bytes(payload) if payload is not None else b"")
        signing_key = load_or_create_signing_key(str(key_path))
        auth = sign_federation_request(
            signing_key=signing_key,
            node_id=node_id,
            method=method,
            path=path,
            body=raw,
        )
        request_headers = {**auth, **(headers or {})}
        if payload is not None or body is not None:
            request_headers["Content-Type"] = "application/json"
        return httpx.request(method, url, content=raw or None, headers=request_headers, timeout=10)

    def node_key_path(self, name: str) -> Path:
        return self.run_dir / "data" / name / "operational.key"

    def prepare_capability_authority(self) -> None:
        self.capability_authority_state_path.parent.mkdir(parents=True, exist_ok=True)
        self.validator_keys = {
            f"validator-{index}": SigningKey.generate() for index in range(7)
        }
        valid_until = datetime.now(timezone.utc) + timedelta(days=7)
        authority_state = {
            "epoch": 1,
            "committee": sorted(self.validator_keys),
            "threshold": 5,
            "validators": {
                validator_id: {
                    "public_key": public_key_b64(key),
                    "valid_until": valid_until.isoformat().replace("+00:00", "Z"),
                    "revoked": False,
                }
                for validator_id, key in self.validator_keys.items()
            },
        }
        self.capability_authority_state_path.write_text(
            json.dumps(authority_state, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def provision_capability(
        self, name: str, env: dict[str, str], *, capability: str, level: int
    ) -> None:
        identity = node_identity_registration_fields(
            root_key_path=env["NODE_ROOT_KEY_PATH"],
            operational_key_path=env["NODE_SIGNING_KEY_PATH"],
            certificate_path=env["NODE_OPERATIONAL_CERTIFICATE_PATH"],
        )
        now = datetime.now(timezone.utc)
        certificate = build_capability_certificate(
            subject_node_id=identity["operational_certificate"]["node_id"],
            level=level,
            capabilities=[capability],
            quotas={"max_connections": 100},
            epoch=1,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=1),
            committee=sorted(self.validator_keys),
            threshold=5,
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            certificate = add_validator_signature(
                certificate,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        path = self.run_dir / "data" / name / "capability-certificate.json"
        path.write_text(
            json.dumps(certificate, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        env["NODE_CAPABILITY_CERTIFICATE_PATH"] = str(path)

    def deliver_payload(self, origin: str, target_url: str, packet_id: str) -> dict:
        key = load_or_create_signing_key(str(self.node_key_path(origin)))
        conversation_id = str(uuid.uuid4())
        envelope = {
            "packet_id": packet_id,
            "type": "MESSAGE",
            "conversation_id": conversation_id,
            "sender_user_id": f"user-{origin}",
            "ciphertext": f"opaque-{packet_id}",
            "content_type": "text",
            "crypto_version": "test-e2ee-v1",
        }
        conversation_meta = {
            "conversation_id": conversation_id,
            "type": "direct",
            "name": None,
            "participant_user_ids": [f"user-{origin}", "user-recipient"],
        }
        return build_deliver_payload(
            signing_key=key,
            origin_node_id=origin,
            envelope=envelope,
            conversation_meta=conversation_meta,
            target_node_id=target_url,
        )

    def send_direct(self, origin: str, target: Service, packet_id: str) -> httpx.Response:
        payload = self.deliver_payload(origin, target.url, packet_id)
        return self.signed_request(
            method="POST",
            url=f"{target.url}/internal/deliver",
            path="/internal/deliver",
            node_id=origin,
            key_path=self.node_key_path(origin),
            payload=payload,
        )

    def start_cluster(self) -> None:
        self.prepare_capability_authority()
        discovery_data = self.run_dir / "data" / "discovery"
        discovery_data.mkdir(parents=True)
        discovery = self.add_service(
            "discovery",
            "discovery-node",
            {
                "DISCOVERY_DB_PATH": str(discovery_data / "discovery.db"),
                "DISCOVERY_SIGNING_KEY_PATH": str(discovery_data / "signing.key"),
                "ENROLLMENT_MODE": "legacy",
                "NODE_IDENTITY_MODE": "enforce",
                "OPERATIONAL_CREDENTIAL_STATE_MODE": "report",
                "OPERATIONAL_CREDENTIAL_REVOCATION_MODE": "enforce",
                "NODE_ADVERTISEMENT_MODE": "enforce",
                "CAPABILITY_CERTIFICATE_MODE": "enforce",
                "CAPABILITY_AUTHORITY_STATE_PATH": str(
                    self.capability_authority_state_path
                ),
                "TRUST_LEDGER_MODE": "enforce",
                "TRUST_AUTHORITY_STATE_PATH": str(self.capability_authority_state_path),
                "TRUST_LEDGER_DB_PATH": str(discovery_data / "trust-ledger.db"),
                "RANDOMNESS_CHECKPOINT_MODE": "enforce",
                "NETWORK_VIEW_STATE_PATH": str(discovery_data / "network-view.json"),
                "ATTESTATION_MODE": "off",
                # Heartbeats are emitted every 60s; the offline threshold must
                # be larger or healthy nodes flap offline during long chaos runs.
                "DISCOVERY_OFFLINE_THRESHOLD_SECONDS": "120",
                "MESH_NOTIFY_SECRET": self.mesh_notify_secret,
            },
        )
        discovery.env.update(
            {
                "DISCOVERY_NODE_ID": "discovery-d1",
                "DISCOVERY_NODE_PUBLIC_URL": discovery.url,
                "NODE_ROOT_KEY_PATH": str(discovery_data / "root.key"),
                "NODE_SIGNING_KEY_PATH": str(discovery_data / "operational.key"),
                "NODE_OPERATIONAL_CERTIFICATE_PATH": str(
                    discovery_data / "operational-certificate.json"
                ),
            }
        )
        self.discovery_url = discovery.url
        discovery.start()
        self.wait_health(discovery)

        for suffix in ("d2", "d3"):
            replica_data = self.run_dir / "data" / f"discovery-{suffix}"
            replica_data.mkdir(parents=True)
            replica = self.add_service(
                f"discovery-{suffix}",
                "discovery-node",
                {
                    "DISCOVERY_DB_PATH": str(replica_data / "discovery.db"),
                    "DISCOVERY_SIGNING_KEY_PATH": str(replica_data / "signing.key"),
                    "ENROLLMENT_MODE": "legacy",
                    "NODE_IDENTITY_MODE": "enforce",
                    "OPERATIONAL_CREDENTIAL_STATE_MODE": (
                        "enforce" if suffix == "d2" else "report"
                    ),
                    "OPERATIONAL_CREDENTIAL_REVOCATION_MODE": "enforce",
                    "NODE_ADVERTISEMENT_MODE": "enforce",
                    "CAPABILITY_CERTIFICATE_MODE": "off",
                    "TRUST_LEDGER_MODE": "enforce",
                    "TRUST_AUTHORITY_STATE_PATH": str(
                        self.capability_authority_state_path
                    ),
                    "TRUST_LEDGER_DB_PATH": str(replica_data / "trust-ledger.db"),
                    "RANDOMNESS_CHECKPOINT_MODE": "enforce",
                    "NETWORK_VIEW_STATE_PATH": str(replica_data / "network-view.json"),
                    "ATTESTATION_MODE": "off",
                    "MESH_NOTIFY_SECRET": self.mesh_notify_secret,
                },
            )
            replica.env.update(
                {
                    "DISCOVERY_NODE_ID": f"discovery-{suffix}",
                    "DISCOVERY_NODE_PUBLIC_URL": replica.url,
                    "NODE_ROOT_KEY_PATH": str(replica_data / "root.key"),
                    "NODE_SIGNING_KEY_PATH": str(replica_data / "operational.key"),
                    "NODE_OPERATIONAL_CERTIFICATE_PATH": str(
                        replica_data / "operational-certificate.json"
                    ),
                }
            )
            self.provision_capability(
                f"discovery-{suffix}",
                replica.env,
                capability="discovery",
                level=4,
            )
            replica.start()
            self.wait_health(replica)
            registration_fields = federation_registration_fields(
                replica.env["NODE_SIGNING_KEY_PATH"],
                replica.env["NODE_ROOT_KEY_PATH"],
                replica.env["NODE_OPERATIONAL_CERTIFICATE_PATH"],
                replica.url,
                replica.env["NODE_CAPABILITY_CERTIFICATE_PATH"],
            )
            response = httpx.post(
                f"{self.discovery_url}/registry/nodes",
                json={
                    "node_id": f"discovery-{suffix}",
                    "node_url": replica.url,
                    "capabilities": ["discovery"],
                    "software_version": "cluster-test",
                    "cluster_id": "local-test",
                    **registration_fields,
                },
                timeout=5,
            )
            response.raise_for_status()

        # Restart the two replicas with mutual background pull configured.
        # Their DB/identity persists, so this also exercises gossip startup
        # recovery rather than a direct test-side POST into each ledger.
        for name, other in (
            ("discovery-d2", "discovery-d3"),
            ("discovery-d3", "discovery-d2"),
        ):
            replica = self.services[name]
            replica.stop()
            replica.env.update(
                {
                    "TRUST_RECORD_GOSSIP_ENABLED": "true",
                    "TRUST_RECORD_GOSSIP_PEERS": (
                        f"{self.discovery_url},{self.services[other].url}"
                    ),
                    "TRUST_RECORD_GOSSIP_INTERVAL_SECONDS": "5",
                    "TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS": "2",
                    "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED": "true",
                    "CHALLENGE_ASSIGNMENT_GOSSIP_PEERS": (
                        f"{self.discovery_url},{self.services[other].url}"
                    ),
                    "CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS": "5",
                    "CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS": "2",
                }
            )
            replica.start()
            self.wait_health(replica)

        # Complete the mutual D1/D2/D3 pull topology. D1 keeps the same DB and
        # identity across restart; only its bounded gossip peers are enabled.
        discovery.stop()
        discovery.env.update(
            {
                "TRUST_RECORD_GOSSIP_ENABLED": "true",
                "TRUST_RECORD_GOSSIP_PEERS": (
                    f"{self.services['discovery-d2'].url},"
                    f"{self.services['discovery-d3'].url}"
                ),
                "TRUST_RECORD_GOSSIP_INTERVAL_SECONDS": "5",
                "TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS": "2",
                "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED": "true",
                "CHALLENGE_ASSIGNMENT_GOSSIP_PEERS": (
                    f"{self.services['discovery-d2'].url},"
                    f"{self.services['discovery-d3'].url}"
                ),
                "CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS": "5",
                "CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS": "2",
            }
        )
        discovery.start()
        self.wait_health(discovery)

        storage = self.add_service("storage", "storage-node", {})
        storage.env.update(self.common_node_env("storage"))
        storage.env.update(
            {
                "STORAGE_NODE_ID": "storage",
                "STORAGE_NODE_PUBLIC_URL": storage.url,
                "STORAGE_DB_PATH": str(self.run_dir / "data" / "storage" / "storage.db"),
            }
        )
        self.provision_capability("storage", storage.env, capability="storage", level=4)
        relay = self.add_service("relay", "relay-node", {})
        relay.env.update(self.common_node_env("relay"))
        relay.env.update(
            {
                "RELAY_NODE_ID": "relay",
                "RELAY_NODE_PUBLIC_URL": relay.url,
                "RELAY_TARGET_VALIDATION_MODE": "enforce",
                "RELAY_LINK_SEQUENCE_DB_PATH": str(
                    self.run_dir / "data" / "relay" / "link-sequences.db"
                ),
            }
        )
        self.provision_capability("relay", relay.env, capability="relay", level=2)
        for name in ("home-a", "home-b", "home-c"):
            home = self.add_service(name, "home-node", {})
            home.env.update(self.common_node_env(name))
            home.env.update(
                {
                    "HOME_NODE_ID": name,
                    "HOME_NODE_PUBLIC_URL": home.url,
                    "HOME_DB_PATH": str(self.run_dir / "data" / name / "home.db"),
                    "NODE_CURVE_KEY_PATH": str(self.run_dir / "data" / name / "curve.key"),
                    "STORAGE_NODE_URL": storage.url,
                    "JWT_SECRET": "cluster-test-jwt-secret-not-for-production-0001",
                    "NODE_RESOURCE_POLICY": "federated",
                }
            )

        for name in ("storage", "relay", "home-a", "home-b", "home-c"):
            self.services[name].start()
        for name in ("storage", "relay", "home-a", "home-b", "home-c"):
            self.wait_health(self.services[name])

        deadline = time.monotonic() + 25
        nodes = []
        while time.monotonic() < deadline:
            response = httpx.get(f"{self.discovery_url}/registry/nodes", timeout=2)
            nodes = response.json().get("nodes", []) if response.status_code == 200 else []
            if len(nodes) >= 7:
                break
            time.sleep(0.25)
        self.record("registration-heartbeat", len(nodes) >= 7, f"registered={len(nodes)}")
        self.record(
            "node-identity-report",
            all(node.get("node_identity_status") == "valid" for node in nodes),
            ",".join(f"{node['node_id']}={node.get('node_identity_status')}" for node in nodes),
        )
        self.record(
            "node-advertisement-report",
            all(node.get("node_advertisement_status") == "valid" for node in nodes),
            ",".join(
                f"{node['node_id']}={node.get('node_advertisement_status')}"
                for node in nodes
            ),
        )
        node_map = {node["node_id"]: node for node in nodes}
        home_a_env = self.services["home-a"].env
        refreshed_fields = federation_registration_fields(
            home_a_env["NODE_SIGNING_KEY_PATH"],
            home_a_env["NODE_ROOT_KEY_PATH"],
            home_a_env["NODE_OPERATIONAL_CERTIFICATE_PATH"],
            self.services["home-a"].url,
        )
        refresh_response = httpx.post(
            f"{self.discovery_url}/registry/nodes/home-a/heartbeat",
            json=refreshed_fields,
            timeout=5,
        )
        refreshed_epoch = (
            refresh_response.json().get("node_advertisement_epoch")
            if refresh_response.status_code == 200
            else None
        )
        original_epoch = node_map.get("home-a", {}).get("node_advertisement_epoch")
        self.record(
            "node-advertisement-heartbeat-refresh",
            refresh_response.status_code == 200
            and isinstance(refreshed_epoch, int)
            and isinstance(original_epoch, int)
            and refreshed_epoch > original_epoch,
            f"HTTP {refresh_response.status_code} epoch={original_epoch}->{refreshed_epoch}",
        )
        relay_env = self.services["relay"].env
        relay_capability_path = Path(relay_env["NODE_CAPABILITY_CERTIFICATE_PATH"])
        relay_capability_head = json.loads(relay_capability_path.read_text(encoding="utf-8"))
        relay_identity = node_identity_registration_fields(
            root_key_path=relay_env["NODE_ROOT_KEY_PATH"],
            operational_key_path=relay_env["NODE_SIGNING_KEY_PATH"],
            certificate_path=relay_env["NODE_OPERATIONAL_CERTIFICATE_PATH"],
        )
        now = datetime.now(timezone.utc)
        relay_capability_next = build_capability_certificate(
            subject_node_id=relay_identity["operational_certificate"]["node_id"],
            level=2,
            capabilities=["relay"],
            quotas={"max_connections": 100},
            epoch=2,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=1),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=capability_certificate_hash(relay_capability_head),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            relay_capability_next = add_validator_signature(
                relay_capability_next,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        relay_capability_path.write_text(
            json.dumps(relay_capability_next, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        relay_refresh_fields = federation_registration_fields(
            relay_env["NODE_SIGNING_KEY_PATH"],
            relay_env["NODE_ROOT_KEY_PATH"],
            relay_env["NODE_OPERATIONAL_CERTIFICATE_PATH"],
            self.services["relay"].url,
            relay_env["NODE_CAPABILITY_CERTIFICATE_PATH"],
        )
        relay_refresh = httpx.post(
            f"{self.discovery_url}/registry/nodes/relay/heartbeat",
            json=relay_refresh_fields,
            timeout=5,
        )
        relay_refresh_epoch = (
            relay_refresh.json().get("capability_epoch")
            if relay_refresh.status_code == 200
            else None
        )
        self.record(
            "capability-certificate-heartbeat-rotation",
            relay_refresh.status_code == 200 and relay_refresh_epoch == 2,
            f"HTTP {relay_refresh.status_code} epoch=1->{relay_refresh_epoch}",
        )
        health_node_ids = {
            name: httpx.get(f"{self.services[name].url}/health", timeout=5).json().get("node_id")
            for name in ("storage", "relay", "home-a", "home-b", "home-c")
        }
        self.record(
            "federation-self-certifying-node-ids",
            all(
                health_node_ids[name] == node_map.get(name, {}).get("identity_node_id")
                for name in health_node_ids
            ),
            ",".join(f"{name}={value}" for name, value in health_node_ids.items()),
        )
        self.record(
            "capability-certificate-enforcement",
            node_map.get("relay", {}).get("certified_capabilities") == ["relay"]
            and node_map.get("storage", {}).get("certified_capabilities") == ["storage"]
            and all(
                node_map.get(name, {}).get("certified_capabilities") == ["discovery"]
                for name in ("discovery-d2", "discovery-d3")
            )
            and all(
                node_map.get(name, {}).get("certified_capabilities") == []
                for name in ("home-a", "home-b", "home-c")
            ),
            ",".join(
                f"{name}={node_map.get(name, {}).get('certified_capabilities')}"
                for name in (
                    "relay", "storage", "discovery-d2", "discovery-d3",
                    "home-a", "home-b", "home-c"
                )
            ),
        )
        expired_root = SigningKey.generate()
        expired_operational = SigningKey.generate()
        expired_certificate = issue_operational_certificate(
            root_signing_key=expired_root,
            operational_verify_key=expired_operational.verify_key,
            issued_at=datetime.now(timezone.utc) - timedelta(days=2),
            valid_until=datetime.now(timezone.utc) - timedelta(days=1),
        )
        expired_registration = httpx.post(
            f"{self.discovery_url}/registry/nodes",
            json={
                "node_id": "expired-node",
                "node_url": "http://127.0.0.1:9",
                "capabilities": ["home"],
                "software_version": "cluster-test",
                "cluster_id": "local-test",
                "signing_public_key": expired_certificate[
                    "operational_public_key"
                ],
                "operational_certificate": expired_certificate,
            },
            timeout=5,
        )
        self.record(
            "expired-operational-certificate-rejected",
            expired_registration.status_code == 403,
            f"HTTP {expired_registration.status_code}",
        )
        now = datetime.now(timezone.utc)
        trust_record = build_trust_record(
            subject_node_id=node_map["home-a"]["identity_node_id"],
            previous_level=0,
            new_level=1,
            action="promotion",
            epoch=1,
            metrics_commitment=hashlib.sha256(b"cluster-test-external-evidence").hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=None,
            decided_at=now,
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            trust_record = add_trust_record_signature(
                trust_record,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        trust_response = httpx.post(
            f"{self.discovery_url}/registry/trust-records",
            json={"record": trust_record},
            timeout=5,
        )
        self.applied_trust_record = trust_record
        refreshed_nodes = httpx.get(f"{self.discovery_url}/registry/nodes", timeout=5).json()[
            "nodes"
        ]
        refreshed_map = {node["node_id"]: node for node in refreshed_nodes}
        self.record(
            "quorum-trust-record-enforcement",
            trust_response.status_code == 200
            and trust_response.json().get("applied") is True
            and refreshed_map.get("home-a", {}).get("trust_level") == 1,
            f"HTTP {trust_response.status_code} home-a=L{refreshed_map.get('home-a', {}).get('trust_level')}",
        )
        replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("trust_records")
                == 1
                for name in ("discovery-d2", "discovery-d3")
            ]
            if replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-trust-record-replication",
            replicated == [True, True],
            f"background_pull_replicas={replicated}",
        )
        authority_state = load_capability_authority_state(
            str(self.capability_authority_state_path)
        )
        if authority_state is None:
            raise RuntimeError("cluster authority state is unavailable")
        randomness_checkpoint = build_randomness_checkpoint(
            challenge_epoch=1,
            authority_epoch=authority_state.epoch,
            previous_hash=authority_state_hash(authority_state),
            randomness_seed=hashlib.sha256(
                b"cluster-assignment-randomness"
            ).hexdigest(),
            eligible_observers=[
                {
                    "node_id": node_map["home-a"]["identity_node_id"],
                    "diversity_group": "cluster-home-a",
                }
            ],
            observer_count=1,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(hours=1),
            committee=authority_state.committee,
            threshold=authority_state.threshold,
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            randomness_checkpoint = add_randomness_signature(
                randomness_checkpoint,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        randomness_response = httpx.post(
            f"{self.discovery_url}/registry/randomness-checkpoints",
            json={"checkpoint": randomness_checkpoint},
            timeout=5,
        )
        randomness_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            randomness_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("randomness_checkpoints")
                == 1
                for name in ("discovery-d2", "discovery-d3")
            ]
            if randomness_replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-randomness-checkpoint-replication",
            randomness_response.status_code == 200
            and randomness_replicated == [True, True],
            (
                f"publish={randomness_response.status_code} "
                f"background_pull_replicas={randomness_replicated}"
            ),
        )
        assignment = build_challenge_assignment_proposal(
            checkpoint=randomness_checkpoint,
            authority_state=authority_state,
            subject_node_id=node_map["relay"]["identity_node_id"],
            challenge_type="relay_delivery",
            not_before=now - timedelta(minutes=1),
            expires_at=now + timedelta(minutes=30),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            assignment = add_assignment_signature(
                assignment,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        assignment_response = httpx.post(
            f"{self.discovery_url}/registry/challenge-assignments",
            json={"assignment": assignment},
            timeout=5,
        )
        assignment_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            assignment_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("challenge_assignments")
                == 1
                for name in ("discovery-d2", "discovery-d3")
            ]
            if assignment_replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-challenge-assignment-replication",
            assignment_response.status_code == 200
            and assignment_replicated == [True, True],
            (
                f"publish={assignment_response.status_code} "
                f"background_pull_replicas={assignment_replicated}"
            ),
        )
        home_a_certificate = json.loads(
            Path(
                self.services["home-a"].env["NODE_OPERATIONAL_CERTIFICATE_PATH"]
            ).read_text(encoding="utf-8")
        )
        home_a_key = load_or_create_signing_key(str(self.node_key_path("home-a")))
        home_a_root = load_or_create_signing_key(
            self.services["home-a"].env["NODE_ROOT_KEY_PATH"]
        )
        home_a_credential_state = issue_operational_credential_state(
            root_signing_key=home_a_root,
            operational_certificate=home_a_certificate,
            credential_epoch=0,
        )
        credential_response = httpx.post(
            f"{self.discovery_url}/registry/operational-credential-states",
            json={"state": home_a_credential_state},
            timeout=5,
        )
        credential_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            credential_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("operational_credential_states")
                == 1
                for name in ("discovery-d2", "discovery-d3")
            ]
            if credential_replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-operational-credential-replication",
            credential_response.status_code == 200
            and credential_replicated == [True, True],
            (
                f"publish={credential_response.status_code} "
                f"background_pull_replicas={credential_replicated}"
            ),
        )
        proof = issue_observer_request_proof(
            observer_signing_key=home_a_key,
            operational_certificate=home_a_certificate,
            action="challenge_assignment_pull",
            payload={"limit": 20},
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=2),
        )
        portable_pull = httpx.post(
            f"{self.services['discovery-d2'].url}/registry/challenge-assignments/pull",
            json={
                "proof": proof,
                "limit": 20,
                "operational_credential_state": home_a_credential_state,
            },
            timeout=5,
        )
        portable_replay = httpx.post(
            f"{self.services['discovery-d2'].url}/registry/challenge-assignments/pull",
            json={
                "proof": proof,
                "limit": 20,
                "operational_credential_state": home_a_credential_state,
            },
            timeout=5,
        )
        portable_ack_object = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=home_a_certificate["node_id"],
            decision="accepted",
            acknowledged_at=datetime.now(timezone.utc),
            observer_signing_key=home_a_key,
        )
        portable_ack = httpx.post(
            f"{self.services['discovery-d2'].url}/registry/challenge-assignment-acks/portable",
            json={
                "ack": portable_ack_object,
                "operational_certificate": home_a_certificate,
                "operational_credential_state": home_a_credential_state,
            },
            timeout=5,
        )
        self.record(
            "portable-observer-auth-on-discovery-replica",
            portable_pull.status_code == 200
            and len(portable_pull.json().get("assignments", [])) == 1
            and portable_replay.status_code == 409
            and portable_ack.status_code == 200
            and portable_ack.json().get("state") == "accepted",
            (
                f"pull={portable_pull.status_code} replay={portable_replay.status_code} "
                f"ack={portable_ack.status_code}"
            ),
        )
        ack_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            ack_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("challenge_assignment_acks")
                == 1
                for name in ("discovery", "discovery-d3")
            ]
            if ack_replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-challenge-ack-replication",
            portable_ack.status_code == 200 and ack_replicated == [True, True],
            f"background_pull_replicas={ack_replicated}",
        )
        assigned_observation = issue_reliability_observation(
            observer_node_id=home_a_certificate["node_id"],
            subject_node_id=node_map["relay"]["identity_node_id"],
            epoch=assignment["epoch"],
            challenge_type=assignment["challenge_type"],
            challenge_commitment=hashlib.sha256(
                b"cluster-assigned-relay-probe"
            ).hexdigest(),
            result="success",
            latency_bucket="20_50ms",
            observed_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            observer_signing_key=home_a_key,
        )
        portable_observation = httpx.post(
            f"{self.services['discovery-d2'].url}/registry/trust-observations/portable",
            json={
                "observation": assigned_observation,
                "assignment_id": assignment["assignment_id"],
                "operational_certificate": home_a_certificate,
                "operational_credential_state": home_a_credential_state,
            },
            timeout=5,
        )
        completion_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            completion_replicated = []
            for name in ("discovery", "discovery-d3"):
                load = httpx.get(
                    f"{self.services[name].url}/health", timeout=5
                ).json().get("load", {})
                completion_replicated.append(
                    load.get("trust_observation_events") == 1
                    and load.get("pending_challenge_observers") == 0
                )
            if completion_replicated == [True, True]:
                break
            time.sleep(0.25)
        self.record(
            "three-discovery-challenge-completion-replication",
            portable_observation.status_code == 200
            and completion_replicated == [True, True],
            (
                f"publish={portable_observation.status_code} "
                f"background_pull_replicas={completion_replicated}"
            ),
        )

    def run_checks(self) -> None:
        home_a = self.services["home-a"]
        home_b = self.services["home-b"]
        home_c = self.services["home-c"]
        relay = self.services["relay"]
        storage = self.services["storage"]

        home_a_node_id = httpx.get(f"{home_a.url}/health", timeout=5).json()["node_id"]
        oversized_body = b"x" * (1024 * 1024 + 1)
        oversized_response = self.signed_request(
            method="POST",
            url=f"{home_b.url}/internal/deliver",
            path="/internal/deliver",
            node_id=home_a_node_id,
            key_path=self.node_key_path("home-a"),
            body=oversized_body,
        )
        self.record(
            "oversized-federation-body-rejected",
            oversized_response.status_code == 413,
            f"HTTP {oversized_response.status_code}",
        )

        identity_key = SigningKey.generate()
        now = datetime.now(timezone.utc)
        bootstrap_record = issue_bootstrap_record(
            identity_signing_key=identity_key,
            identity_version=1,
            ingress_endpoints=["https://ingress-a.local", "wss://ingress-b.local/ws"],
            record_version=1,
            issued_at=now - timedelta(seconds=5),
            expires_at=now + timedelta(hours=1),
        )
        discovery_services = [
            self.services["discovery"],
            self.services["discovery-d2"],
            self.services["discovery-d3"],
        ]
        publish_codes = []
        for discovery_service in discovery_services:
            response = httpx.post(
                f"{discovery_service.url}/registry/bootstrap-records",
                json={"record": bootstrap_record},
                timeout=5,
            )
            publish_codes.append(response.status_code)
        self.record(
            "three-discovery-bootstrap-publish",
            publish_codes == [200, 200, 200],
            f"HTTP={publish_codes}",
        )
        retrieved = []
        for discovery_service in discovery_services:
            response = httpx.get(
                f"{discovery_service.url}/registry/bootstrap-records/{bootstrap_record['user_id']}",
                timeout=5,
            )
            record = response.json().get("record", {}) if response.status_code == 200 else {}
            retrieved.append(
                response.status_code == 200
                and validate_bootstrap_record(record, now=datetime.now(timezone.utc)).valid
            )
        self.record(
            "three-discovery-independent-verification",
            retrieved == [True, True, True],
            f"valid={retrieved}",
        )

        ingress_set = [
            {
                "node_id": "ingress-a",
                "endpoint": "https://ingress-a.local",
                "transport": "https",
            },
            {
                "node_id": "ingress-b",
                "endpoint": "wss://ingress-b.local/ws",
                "transport": "wss",
            },
        ]
        route_chain = []
        for route_epoch in (100, 101, 102):
            descriptor = issue_route_descriptor(
                identity_signing_key=identity_key,
                identity_version=1,
                route_epoch=route_epoch,
                ingress_set=ingress_set,
                valid_from=now - timedelta(minutes=1),
                valid_until=now + timedelta(hours=2),
                previous_hash=(
                    route_descriptor_hash(route_chain[-1]) if route_chain else None
                ),
            )
            route_chain.append(descriptor)
        route_publish_codes = []
        for discovery_service in discovery_services:
            for descriptor in route_chain:
                response = httpx.post(
                    f"{discovery_service.url}/registry/route-descriptors",
                    json={"descriptor": descriptor},
                    timeout=5,
                )
                route_publish_codes.append(response.status_code)
        self.record(
            "three-discovery-route-chain-publish",
            route_publish_codes == [200] * 9,
            f"HTTP={route_publish_codes}",
        )
        route_views = []
        for discovery_service in discovery_services:
            response = httpx.get(
                f"{discovery_service.url}/registry/route-descriptors/{bootstrap_record['user_id']}",
                timeout=5,
            )
            descriptors = (
                response.json().get("descriptors", [])
                if response.status_code == 200
                else []
            )
            valid_chain = len(descriptors) == 3 and all(
                validate_route_descriptor(
                    descriptor,
                    identity_public_key=bootstrap_record["identity_public_key"],
                    expected_user_id=bootstrap_record["user_id"],
                    now=datetime.now(timezone.utc),
                    minimum_route_epoch=100,
                    allow_future=True,
                ).valid
                for descriptor in descriptors
            )
            valid_chain = valid_chain and all(
                validate_route_transition(descriptors[index - 1], descriptors[index]).valid
                for index in range(1, len(descriptors))
            )
            route_views.append(valid_chain)
        rollback_descriptor = issue_route_descriptor(
            identity_signing_key=identity_key,
            identity_version=1,
            route_epoch=99,
            ingress_set=ingress_set,
            valid_from=now - timedelta(minutes=1),
            valid_until=now + timedelta(hours=2),
        )
        rollback_codes = [
            httpx.post(
                f"{service.url}/registry/route-descriptors",
                json={"descriptor": rollback_descriptor},
                timeout=5,
            ).status_code
            for service in discovery_services
        ]
        self.record(
            "three-discovery-route-anti-rollback",
            route_views == [True, True, True] and rollback_codes == [400, 400, 400],
            f"valid={route_views} rollback={rollback_codes}",
        )

        direct_id = str(uuid.uuid4())
        direct_payload = self.deliver_payload("home-a", home_b.url, direct_id)
        direct_body = _json_bytes(direct_payload)
        direct = self.signed_request(
            method="POST",
            url=f"{home_b.url}/internal/deliver",
            path="/internal/deliver",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            body=direct_body,
        )
        self.record("direct-home-delivery", direct.status_code == 200, f"HTTP {direct.status_code}")

        # Replay an otherwise fresh exact outer request by reusing headers once.
        # The first request must pass; the second must be rejected by the nonce DB.
        signing_key = load_or_create_signing_key(str(self.node_key_path("home-a")))
        replay_payload = self.deliver_payload("home-a", home_b.url, str(uuid.uuid4()))
        replay_body = _json_bytes(replay_payload)
        replay_headers = sign_federation_request(
            signing_key=signing_key,
            node_id="home-a",
            method="POST",
            path="/internal/deliver",
            body=replay_body,
        )
        replay_headers["Content-Type"] = "application/json"
        first = httpx.post(f"{home_b.url}/internal/deliver", content=replay_body, headers=replay_headers)
        second = httpx.post(f"{home_b.url}/internal/deliver", content=replay_body, headers=replay_headers)
        self.record(
            "outer-request-replay-rejected",
            first.status_code == 200 and second.status_code == 403,
            f"first={first.status_code} second={second.status_code}",
        )

        relay_packet = str(uuid.uuid4())
        relay_direct = self.deliver_payload("home-a", home_b.url, relay_packet)
        relay_payload = build_relay_forward_payload(
            signing_key=signing_key,
            origin_node_id="home-a",
            envelope=relay_direct["envelope"],
            conversation_meta=relay_direct["conversation_meta"],
            target_home_node_url=home_b.url,
        )
        relay_response = self.signed_request(
            method="POST",
            url=f"{relay.url}/relay/forward",
            path="/relay/forward",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload=relay_payload,
        )
        self.record(
            "relay-forward-signed",
            relay_response.status_code == 200,
            f"HTTP {relay_response.status_code} {relay_response.text[:160]}",
        )

        websocket_headers = sign_federation_request(
            signing_key=signing_key,
            node_id="home-a",
            method="GET",
            path="/relay/ws",
            body=b"",
        )
        websocket_results = []
        websocket_replay_code = None
        with websocket_connect(
            f"ws://127.0.0.1:{relay.port}/relay/ws",
            additional_headers=websocket_headers,
            open_timeout=5,
            close_timeout=2,
        ) as websocket:
            for sequence in (1, 2):
                ws_direct = self.deliver_payload(
                    "home-a", home_b.url, str(uuid.uuid4())
                )
                ws_payload = build_relay_forward_payload(
                    signing_key=signing_key,
                    origin_node_id="home-a",
                    envelope=ws_direct["envelope"],
                    conversation_meta=ws_direct["conversation_meta"],
                    target_home_node_url=home_b.url,
                )
                websocket.send(
                    encode_batch(sequence=sequence, cells=[_json_bytes(ws_payload)])
                )
                reply = decode_batch(websocket.recv(timeout=10))
                result = json.loads(reply.cells[0])
                websocket_results.append(
                    reply.sequence == sequence
                    and result.get("ok") is True
                    and result.get("result", {}).get("status") == "forwarded"
                )
            websocket.send(
                encode_batch(sequence=2, cells=[_json_bytes(ws_payload)])
            )
            try:
                websocket.recv(timeout=5)
            except ConnectionClosed as exc:
                websocket_replay_code = exc.code
        self.record(
            "persistent-websocket-binary-relay",
            websocket_results == [True, True] and websocket_replay_code == 4403,
            f"batches={websocket_results} replay_close={websocket_replay_code}",
        )
        quota_headers = sign_federation_request(
            signing_key=signing_key,
            node_id="home-a",
            method="GET",
            path="/relay/ws",
            body=b"",
        )
        websocket_quota_code = None
        with websocket_connect(
            f"ws://127.0.0.1:{relay.port}/relay/ws",
            additional_headers=quota_headers,
            open_timeout=5,
            close_timeout=2,
        ) as websocket:
            websocket.send(
                encode_batch(sequence=1, cells=[_json_bytes(ws_payload)] * 33)
            )
            try:
                websocket.recv(timeout=5)
            except ConnectionClosed as exc:
                websocket_quota_code = exc.code
        self.record(
            "websocket-batch-cell-quota",
            websocket_quota_code == 4408,
            f"close={websocket_quota_code}",
        )

        async def probe_home_adapter():
            adapter = RelayWebSocketClient(
                signing_key=signing_key,
                node_id="home-a",
                timeout_seconds=5,
            )
            results = []
            try:
                for _ in range(2):
                    adapter_direct = self.deliver_payload(
                        "home-a", home_b.url, str(uuid.uuid4())
                    )
                    adapter_payload = build_relay_forward_payload(
                        signing_key=signing_key,
                        origin_node_id="home-a",
                        envelope=adapter_direct["envelope"],
                        conversation_meta=adapter_direct["conversation_meta"],
                        target_home_node_url=home_b.url,
                    )
                    results.append(await adapter.forward(relay.url, adapter_payload))
            finally:
                await adapter.close()
            return results

        adapter_results = asyncio.run(probe_home_adapter())
        self.record(
            "home-persistent-websocket-adapter",
            len(adapter_results) == 2
            and all(result.get("status") == "forwarded" for result in adapter_results),
            f"batches={len(adapter_results)}",
        )

        buffer_packet = str(uuid.uuid4())
        buffer_envelope = {
            "packet_id": buffer_packet,
            "sender_user_id": "user-home-a",
            "ciphertext": "opaque-offline-cell",
        }
        buffer_payload = build_buffer_payload(
            signing_key=signing_key,
            origin_node_id="home-a",
            recipient_device_id="offline-device",
            envelope=buffer_envelope,
            ttl_seconds=3600,
        )
        buffered_first = self.signed_request(
            method="POST",
            url=f"{storage.url}/buffer",
            path="/buffer",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload=buffer_payload,
        )
        buffer_payload_retry = build_buffer_payload(
            signing_key=signing_key,
            origin_node_id="home-a",
            recipient_device_id="offline-device",
            envelope=buffer_envelope,
            ttl_seconds=3600,
        )
        buffered_second = self.signed_request(
            method="POST",
            url=f"{storage.url}/buffer",
            path="/buffer",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload=buffer_payload_retry,
        )
        first_json = buffered_first.json() if buffered_first.status_code == 200 else {}
        second_json = buffered_second.json() if buffered_second.status_code == 200 else {}
        self.record(
            "storage-idempotent-buffer",
            buffered_first.status_code == 200
            and buffered_second.status_code == 200
            and first_json.get("id") == second_json.get("id"),
            f"first={buffered_first.status_code} second={buffered_second.status_code}",
        )
        storage.stop()
        storage.start()
        self.wait_health(storage)
        fetched_after_restart = self.signed_request(
            method="GET",
            url=f"{storage.url}/buffer/offline-device",
            path="/buffer/offline-device",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
        )
        fetched_json = (
            fetched_after_restart.json() if fetched_after_restart.status_code == 200 else {}
        )
        stored_entries = fetched_json.get("envelopes", [])
        self.record(
            "storage-restart-persistence",
            fetched_after_restart.status_code == 200
            and len(stored_entries) == 1
            and stored_entries[0].get("id") == first_json.get("id"),
            f"HTTP {fetched_after_restart.status_code} entries={len(stored_entries)}",
        )
        ack_buffered = self.signed_request(
            method="DELETE",
            url=f"{storage.url}/buffer/{first_json.get('id')}",
            path=f"/buffer/{first_json.get('id')}",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
        )
        fetched_after_ack = self.signed_request(
            method="GET",
            url=f"{storage.url}/buffer/offline-device",
            path="/buffer/offline-device",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
        )
        after_ack_entries = (
            fetched_after_ack.json().get("envelopes", [])
            if fetched_after_ack.status_code == 200
            else ["fetch-failed"]
        )
        self.record(
            "storage-ack-removes-buffered-cell",
            ack_buffered.status_code == 204 and after_ack_entries == [],
            f"ack={ack_buffered.status_code} remaining={len(after_ack_entries)}",
        )

        mailbox_token = generate_mailbox_token()
        mailbox_key = b"local-mailbox-test-key-32-bytes!"
        opaque_payload = b"endpoint-only offline payload"
        opaque_cell = seal_fixed_cell(
            payload=opaque_payload, key=mailbox_key, cell_size=4 * 1024
        )
        mailbox_store = self.signed_request(
            method="POST",
            url=f"{storage.url}/mailbox/store",
            path="/mailbox/store",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload={
                "mailbox_token": mailbox_token,
                "cell_b64": base64.urlsafe_b64encode(opaque_cell).decode("ascii"),
                "ttl_seconds": 3600,
            },
        )
        mailbox_fetch = self.signed_request(
            method="POST",
            url=f"{storage.url}/mailbox/fetch",
            path="/mailbox/fetch",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload={"mailbox_token": mailbox_token},
        )
        fetched_cells = (
            mailbox_fetch.json().get("cells", [])
            if mailbox_fetch.status_code == 200
            else []
        )
        opened_payload = None
        if len(fetched_cells) == 1:
            fetched_cell = base64.urlsafe_b64decode(fetched_cells[0]["cell_b64"])
            opened_payload = open_fixed_cell(
                cell=fetched_cell, key=mailbox_key
            ).payload
        mailbox_ack = self.signed_request(
            method="POST",
            url=f"{storage.url}/mailbox/ack",
            path="/mailbox/ack",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload={
                "mailbox_token": mailbox_token,
                "entry_id": (
                    fetched_cells[0]["id"]
                    if fetched_cells
                    else "00000000-0000-0000-0000-000000000000"
                ),
            },
        )
        self.record(
            "opaque-fixed-cell-mailbox",
            mailbox_store.status_code == 200
            and mailbox_fetch.status_code == 200
            and opened_payload == opaque_payload
            and mailbox_ack.status_code == 204,
            (
                f"store={mailbox_store.status_code} fetch={mailbox_fetch.status_code} "
                f"cells={len(fetched_cells)} ack={mailbox_ack.status_code}"
            ),
        )

        # External synthetic challenges exercise the real data-plane operations,
        # then publish only privacy-minimized signed observations to Discovery.
        home_a_identity = json.loads(
            (self.run_dir / "data" / "home-a" / "operational-certificate.json").read_text()
        )["node_id"]
        relay_identity = json.loads(
            (self.run_dir / "data" / "relay" / "operational-certificate.json").read_text()
        )["node_id"]
        storage_identity = json.loads(
            (self.run_dir / "data" / "storage" / "operational-certificate.json").read_text()
        )["node_id"]
        discovery_d2_identity = httpx.get(
            f"{self.services['discovery-d2'].url}/health", timeout=5
        ).json()["node_id"]

        def relay_challenge(context):
            challenge_direct = self.deliver_payload(
                "home-a", home_b.url, context.challenge_id
            )
            challenge_payload = build_relay_forward_payload(
                signing_key=signing_key,
                origin_node_id="home-a",
                envelope=challenge_direct["envelope"],
                conversation_meta=challenge_direct["conversation_meta"],
                target_home_node_url=home_b.url,
            )
            for attempt in range(3):
                response = self.signed_request(
                    method="POST",
                    url=f"{relay.url}/relay/forward",
                    path="/relay/forward",
                    node_id="home-a",
                    key_path=self.node_key_path("home-a"),
                    payload=challenge_payload,
                )
                if (
                    response.status_code == 200
                    and response.json().get("status") == "forwarded"
                ):
                    return True
                if attempt < 2:
                    time.sleep(0.25)
            return False

        def storage_challenge(context):
            mailbox = uuid.UUID(bytes=context.secret[:16]).hex
            challenge_envelope = {
                "packet_id": context.challenge_id,
                "sender_user_id": "user-home-a",
                "ciphertext": context.secret.hex(),
            }
            payload = build_buffer_payload(
                signing_key=signing_key,
                origin_node_id="home-a",
                recipient_device_id=mailbox,
                envelope=challenge_envelope,
                ttl_seconds=300,
            )
            stored = self.signed_request(
                method="POST",
                url=f"{storage.url}/buffer",
                path="/buffer",
                node_id="home-a",
                key_path=self.node_key_path("home-a"),
                payload=payload,
            )
            if stored.status_code != 200:
                return False
            entry_id = stored.json().get("id")
            fetched = self.signed_request(
                method="GET",
                url=f"{storage.url}/buffer/{mailbox}",
                path=f"/buffer/{mailbox}",
                node_id="home-a",
                key_path=self.node_key_path("home-a"),
            )
            entries = fetched.json().get("envelopes", []) if fetched.status_code == 200 else []
            verified = any(
                entry.get("id") == entry_id
                and entry.get("envelope", {}).get("packet_id") == context.challenge_id
                and entry.get("envelope", {}).get("ciphertext") == context.secret.hex()
                for entry in entries
            )
            if entry_id:
                self.signed_request(
                    method="DELETE",
                    url=f"{storage.url}/buffer/{entry_id}",
                    path=f"/buffer/{entry_id}",
                    node_id="home-a",
                    key_path=self.node_key_path("home-a"),
                )
            return verified

        def discovery_challenge(_context):
            response = httpx.get(
                (
                    f"{self.services['discovery-d2'].url}/registry/bootstrap-records/"
                    f"{bootstrap_record['user_id']}"
                ),
                timeout=5,
            )
            if response.status_code != 200:
                return False
            record = response.json().get("record", {})
            return validate_bootstrap_record(
                record, now=datetime.now(timezone.utc)
            ).valid

        relay_observation = asyncio.run(
            run_synthetic_challenge(
                observer_node_id=home_a_identity,
                subject_node_id=relay_identity,
                epoch=1,
                challenge_type="relay_delivery",
                observer_signing_key=signing_key,
                action=relay_challenge,
            )
        ).observation
        storage_observation = asyncio.run(
            run_synthetic_challenge(
                observer_node_id=home_a_identity,
                subject_node_id=storage_identity,
                epoch=1,
                challenge_type="storage_store_get",
                observer_signing_key=signing_key,
                action=storage_challenge,
            )
        ).observation
        discovery_observation = asyncio.run(
            run_synthetic_challenge(
                observer_node_id=home_a_identity,
                subject_node_id=discovery_d2_identity,
                epoch=1,
                challenge_type="discovery_lookup",
                observer_signing_key=signing_key,
                action=discovery_challenge,
            )
        ).observation
        published_observations = [
            httpx.post(
                f"{self.discovery_url}/registry/trust-observations",
                json={"observation": observation},
                timeout=5,
            )
            for observation in (
                relay_observation,
                storage_observation,
                discovery_observation,
            )
        ]
        relay_evidence = httpx.get(
            f"{self.discovery_url}/registry/trust-observations/{relay_identity}", timeout=5
        )
        storage_evidence = httpx.get(
            f"{self.discovery_url}/registry/trust-observations/{storage_identity}", timeout=5
        )
        discovery_evidence = httpx.get(
            f"{self.discovery_url}/registry/trust-observations/{discovery_d2_identity}",
            timeout=5,
        )
        observations_ok = (
            all(response.status_code == 200 and response.json().get("accepted") for response in published_observations)
            and relay_observation["result"] == "success"
            and storage_observation["result"] == "success"
            and discovery_observation["result"] == "success"
            # One assignment-bound observation already converged from D2.
            and len(relay_evidence.json().get("observations", [])) == 2
            and len(storage_evidence.json().get("observations", [])) == 1
            and len(discovery_evidence.json().get("observations", [])) == 1
        )
        self.record(
            "external-synthetic-challenge-evidence",
            observations_ok,
            (
                f"publish={[response.status_code for response in published_observations]} "
                f"results={[relay_observation['result'], storage_observation['result'], discovery_observation['result']]}"
            ),
        )
        reliability_snapshots = [
            httpx.get(
                f"{self.discovery_url}/registry/reliability/{subject}", timeout=5
            ).json()
            for subject in (relay_identity, storage_identity, discovery_d2_identity)
        ]
        self.record(
            "bounded-reliability-aggregation",
            all(
                snapshot.get("effective_observations") == 1
                and snapshot.get("observer_count") == 1
                and snapshot.get("success_rate_bps") == 10_000
                and snapshot.get("promotion_decision") == "not_evaluated"
                for snapshot in reliability_snapshots
            ),
            f"effective={[snapshot.get('effective_observations') for snapshot in reliability_snapshots]}",
        )

        # Network path for semantic ACK while both peer trust records are
        # available. Persistence/idempotency is covered by Home's unit suite.
        ack_source_packet = str(uuid.uuid4())
        to_a = self.send_direct("home-b", home_a, ack_source_packet)
        self.record("ack-source-message", to_a.status_code == 200, f"HTTP {to_a.status_code}")
        home_b_key = load_or_create_signing_key(str(self.node_key_path("home-b")))
        ack_payload = build_delivery_ack_payload(
            signing_key=home_b_key,
            origin_node_id="home-b",
            packet_id=ack_source_packet,
            conversation_id=str(uuid.uuid4()),
            from_user_id="user-home-b",
            acked_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            target_node_id=home_a.url,
        )
        ack_response = self.signed_request(
            method="POST",
            url=f"{home_a.url}/internal/delivery-ack",
            path="/internal/delivery-ack",
            node_id="home-b",
            key_path=self.node_key_path("home-b"),
            payload=ack_payload,
        )
        self.record("delivery-ack-network-path", ack_response.status_code == 200, f"HTTP {ack_response.status_code}")

        # Warm trust cache, then prove existing data plane survives Discovery outage.
        warm = self.send_direct("home-a", home_c, str(uuid.uuid4()))
        self.record("home-c-trust-cache-warm", warm.status_code == 200, f"HTTP {warm.status_code}")
        self.services["discovery"].stop()
        replica_results = []
        for name in ("discovery-d2", "discovery-d3"):
            response = httpx.get(
                f"{self.services[name].url}/registry/bootstrap-records/{bootstrap_record['user_id']}",
                timeout=5,
            )
            replica_results.append(response.status_code == 200)
        self.record(
            "bootstrap-available-with-d1-down",
            replica_results == [True, True],
            f"D2/D3={replica_results}",
        )
        after_discovery_outage = self.send_direct("home-a", home_c, str(uuid.uuid4()))
        self.record(
            "direct-data-plane-with-discovery-down",
            after_discovery_outage.status_code == 200,
            f"HTTP {after_discovery_outage.status_code}",
        )
        unverified_relay_direct = self.deliver_payload("home-a", home_b.url, str(uuid.uuid4()))
        relay_during_discovery_outage = self.signed_request(
            method="POST",
            url=f"{relay.url}/relay/forward",
            path="/relay/forward",
            node_id="home-a",
            key_path=self.node_key_path("home-a"),
            payload=build_relay_forward_payload(
                signing_key=signing_key,
                origin_node_id="home-a",
                envelope=unverified_relay_direct["envelope"],
                conversation_meta=unverified_relay_direct["conversation_meta"],
                target_home_node_url=home_b.url,
            ),
        )
        self.record(
            "relay-freezes-unverified-target-with-discovery-down",
            relay_during_discovery_outage.status_code == 403,
            f"HTTP {relay_during_discovery_outage.status_code}",
        )

        # Bring the local control plane back before restarting a process with
        # an empty in-memory trust cache. The persisted registry survives.
        self.services["discovery"].start()
        self.wait_health(self.services["discovery"])
        rejoined_bootstrap = httpx.get(
            f"{self.discovery_url}/registry/bootstrap-records/{bootstrap_record['user_id']}",
            timeout=5,
        )
        rejoined_nodes = httpx.get(
            f"{self.discovery_url}/registry/nodes", timeout=5
        )
        rejoined_node_count = (
            len(rejoined_nodes.json().get("nodes", []))
            if rejoined_nodes.status_code == 200
            else 0
        )
        self.record(
            "discovery-control-plane-rejoin",
            rejoined_bootstrap.status_code == 200
            and rejoined_node_count >= 7,
            (
                f"bootstrap={rejoined_bootstrap.status_code} "
                f"registered={rejoined_node_count}"
            ),
        )

        # Restart Relay to discard its in-memory target trust cache. A
        # successful forward now proves a cold data-plane process can resolve
        # the restored control plane after the outage.
        relay.stop()
        relay.start()
        self.wait_health(relay)
        cold_relay_payload = self.deliver_payload(
            "home-a", home_b.url, str(uuid.uuid4())
        )
        cold_relay_forward = build_relay_forward_payload(
            signing_key=signing_key,
            origin_node_id="home-a",
            envelope=cold_relay_payload["envelope"],
            conversation_meta=cold_relay_payload["conversation_meta"],
            target_home_node_url=home_b.url,
        )
        deadline = time.monotonic() + 5
        while True:
            cold_relay_response = self.signed_request(
                method="POST",
                url=f"{relay.url}/relay/forward",
                path="/relay/forward",
                node_id="home-a",
                key_path=self.node_key_path("home-a"),
                payload=cold_relay_forward,
            )
            if cold_relay_response.status_code == 200 or time.monotonic() >= deadline:
                break
            time.sleep(0.25)
        self.record(
            "relay-cold-cache-after-discovery-rejoin",
            cold_relay_response.status_code == 200,
            f"HTTP {cold_relay_response.status_code}",
        )

        home_b_db = self.run_dir / "data" / "home-b" / "home.db"
        with sqlite3.connect(home_b_db) as conn:
            before_restart = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        home_b.stop()
        home_b.start()
        self.wait_health(home_b)
        with sqlite3.connect(home_b_db) as conn:
            after_restart = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        self.record(
            "home-restart-persistence",
            before_restart >= 2 and after_restart == before_restart,
            f"before={before_restart} after={after_restart}",
        )

        home_b_certificate_path = (
            self.run_dir / "data" / "home-b" / "operational-certificate.json"
        )
        old_home_b_certificate = json.loads(home_b_certificate_path.read_text())
        with sqlite3.connect(
            self.services["discovery"].env["DISCOVERY_DB_PATH"]
        ) as conn:
            old_home_b_advertisement = json.loads(
                conn.execute(
                    "SELECT node_advertisement FROM node_capabilities WHERE node_id = ?",
                    ("home-b",),
                ).fetchone()[0]
            )
        home_b.stop()
        new_home_b_certificate = rotate_operational_credentials(
            root_key_path=str(self.run_dir / "data" / "home-b" / "root.key"),
            operational_key_path=str(self.node_key_path("home-b")),
            certificate_path=str(home_b_certificate_path),
        )
        home_b.start()
        self.wait_health(home_b)
        rotation_deadline = time.monotonic() + 15
        discovery_home_b = {}
        while time.monotonic() < rotation_deadline:
            node_list = httpx.get(f"{self.discovery_url}/registry/nodes", timeout=5).json()[
                "nodes"
            ]
            discovery_home_b = next(
                (node for node in node_list if node["node_id"] == "home-b"), {}
            )
            if (
                discovery_home_b.get("signing_public_key")
                == new_home_b_certificate["operational_public_key"]
            ):
                break
            time.sleep(0.2)
        # Home A may still cache Home B's previous operational key. Restarting
        # here exercises the documented cache refresh procedure without waiting
        # for a production TTL.
        home_a.stop()
        home_a.start()
        self.wait_health(home_a)
        rotated_delivery = self.send_direct("home-b", home_a, str(uuid.uuid4()))
        self.record(
            "operational-key-rotation-preserves-node-id",
            old_home_b_certificate["node_id"] == new_home_b_certificate["node_id"]
            and old_home_b_certificate["operational_public_key"]
            != new_home_b_certificate["operational_public_key"]
            and discovery_home_b.get("signing_public_key")
            == new_home_b_certificate["operational_public_key"]
            and rotated_delivery.status_code == 200,
            (
                f"same_node_id={old_home_b_certificate['node_id'] == new_home_b_certificate['node_id']} "
                f"key_changed={old_home_b_certificate['operational_public_key'] != new_home_b_certificate['operational_public_key']} "
                f"delivery={rotated_delivery.status_code}"
            ),
        )
        rollback_registration = httpx.post(
            f"{self.discovery_url}/registry/nodes",
            json={
                "node_id": "home-b",
                "node_url": home_b.url,
                "capabilities": ["home"],
                "software_version": "cluster-test",
                "cluster_id": "local-test",
                "signing_public_key": old_home_b_certificate[
                    "operational_public_key"
                ],
                "operational_certificate": old_home_b_certificate,
                "node_advertisement": old_home_b_advertisement,
            },
            timeout=5,
        )
        node_list_after_rollback = httpx.get(
            f"{self.discovery_url}/registry/nodes", timeout=5
        ).json()["nodes"]
        home_b_after_rollback = next(
            node for node in node_list_after_rollback if node["node_id"] == "home-b"
        )
        self.record(
            "operational-certificate-rollback-rejected",
            rollback_registration.status_code == 403
            and home_b_after_rollback.get("signing_public_key")
            == new_home_b_certificate["operational_public_key"],
            (
                f"HTTP {rollback_registration.status_code} "
                f"new_key_preserved={home_b_after_rollback.get('signing_public_key') == new_home_b_certificate['operational_public_key']}"
            ),
        )

        home_a_certificate = json.loads(
            Path(
                self.services["home-a"].env["NODE_OPERATIONAL_CERTIFICATE_PATH"]
            ).read_text(encoding="utf-8")
        )
        home_a_key = load_or_create_signing_key(str(self.node_key_path("home-a")))
        home_a_root = load_or_create_signing_key(
            self.services["home-a"].env["NODE_ROOT_KEY_PATH"]
        )
        home_a_credential_state = issue_operational_credential_state(
            root_signing_key=home_a_root,
            operational_certificate=home_a_certificate,
            credential_epoch=0,
        )
        revocation_time = datetime.now(timezone.utc)
        credential_revocation = build_operational_credential_revocation(
            operational_certificate=home_a_certificate,
            credential_epoch=0,
            revocation_epoch=0,
            authority_epoch=1,
            reason_commitment=hashlib.sha256(
                b"cluster-test-compromised-operational-key"
            ).hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            decided_at=revocation_time,
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            credential_revocation = (
                add_operational_credential_revocation_signature(
                    credential_revocation,
                    validator_id=validator_id,
                    validator_signing_key=self.validator_keys[validator_id],
                )
            )
        revocation_response = httpx.post(
            f"{self.discovery_url}/registry/operational-credential-revocations",
            json={"revocation": credential_revocation},
            timeout=5,
        )
        revocation_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            revocation_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("operational_credential_revocations")
                == 1
                for name in ("discovery-d2", "discovery-d3")
            ]
            if revocation_replicated == [True, True]:
                break
            time.sleep(0.25)
        revoked_proof = issue_observer_request_proof(
            observer_signing_key=home_a_key,
            operational_certificate=home_a_certificate,
            action="challenge_assignment_pull",
            payload={"limit": 20},
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=2),
        )
        revoked_live_pull = httpx.post(
            f"{self.services['discovery-d2'].url}/registry/challenge-assignments/pull",
            json={
                "proof": revoked_proof,
                "limit": 20,
                "operational_credential_state": home_a_credential_state,
            },
            timeout=5,
        )
        historical_counts = [
            httpx.get(f"{self.services[name].url}/health", timeout=5)
            .json()
            .get("load", {})
            for name in ("discovery", "discovery-d2", "discovery-d3")
        ]
        self.record(
            "quorum-operational-credential-revocation",
            revocation_response.status_code == 200
            and revocation_replicated == [True, True]
            and revoked_live_pull.status_code == 403
            and all(
                load.get("challenge_assignment_acks") == 1
                and load.get("trust_observation_events") == 1
                for load in historical_counts
            ),
            (
                f"publish={revocation_response.status_code} "
                f"replicas={revocation_replicated} "
                f"live_old_key={revoked_live_pull.status_code} "
                f"history={[(load.get('challenge_assignment_acks'), load.get('trust_observation_events')) for load in historical_counts]}"
            ),
        )

        home_c_certificate = json.loads(
            Path(
                self.services["home-c"].env["NODE_OPERATIONAL_CERTIFICATE_PATH"]
            ).read_text(encoding="utf-8")
        )
        with sqlite3.connect(
            self.services["discovery"].env["DISCOVERY_DB_PATH"]
        ) as conn:
            home_c_advertisement = json.loads(
                conn.execute(
                    "SELECT node_advertisement FROM node_capabilities WHERE node_id = ?",
                    ("home-c",),
                ).fetchone()[0]
            )
        node_revocation = build_trust_record(
            subject_node_id=home_c_certificate["node_id"],
            previous_level=0,
            new_level=0,
            action="revocation",
            epoch=1,
            metrics_commitment=hashlib.sha256(
                b"cluster-test-node-wide-security-evidence"
            ).hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=None,
            decided_at=datetime.now(timezone.utc),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            node_revocation = add_trust_record_signature(
                node_revocation,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        node_revocation_response = httpx.post(
            f"{self.discovery_url}/registry/trust-records",
            json={"record": node_revocation},
            timeout=5,
        )
        node_revocation_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            node_revocation_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("trust_records")
                == 2
                for name in ("discovery-d2", "discovery-d3")
            ]
            if node_revocation_replicated == [True, True]:
                break
            time.sleep(0.25)
        revoked_node_registration = httpx.post(
            f"{self.discovery_url}/registry/nodes",
            json={
                "node_id": "home-c",
                "node_url": self.services["home-c"].url,
                "capabilities": ["home"],
                "software_version": "cluster-test",
                "cluster_id": "local-test",
                "signing_public_key": home_c_certificate[
                    "operational_public_key"
                ],
                "operational_certificate": home_c_certificate,
                "node_advertisement": home_c_advertisement,
            },
            timeout=5,
        )
        listed_after_node_revocation = {
            node["node_id"]
            for node in httpx.get(
                f"{self.discovery_url}/registry/nodes", timeout=5
            ).json()["nodes"]
        }
        with sqlite3.connect(
            self.services["discovery"].env["DISCOVERY_DB_PATH"]
        ) as conn:
            home_c_trust_status = conn.execute(
                "SELECT trust_status FROM node_capabilities WHERE node_id = ?",
                ("home-c",),
            ).fetchone()[0]
        self.record(
            "node-wide-trust-revocation-control-plane",
            node_revocation_response.status_code == 200
            and node_revocation_response.json().get("applied") is True
            and node_revocation_replicated == [True, True]
            and revoked_node_registration.status_code == 403
            and "home-c" not in listed_after_node_revocation
            and home_c_trust_status == "compromised",
            (
                f"publish={node_revocation_response.status_code} "
                f"replicas={node_revocation_replicated} "
                f"registration={revoked_node_registration.status_code} "
                f"listed={'home-c' in listed_after_node_revocation} "
                f"status={home_c_trust_status}"
            ),
        )

        authority_state = load_capability_authority_state(
            str(self.capability_authority_state_path)
        )
        if authority_state is None:
            raise RuntimeError("cluster authority state is unavailable")
        authority_now = datetime.now(timezone.utc)
        checkpoint_2 = build_authority_checkpoint(
            authority_epoch=2,
            previous_hash=authority_state_hash(authority_state),
            committee=authority_state.committee,
            threshold=authority_state.threshold,
            validators=authority_state.validators,
            issued_at=authority_now - timedelta(minutes=2),
            valid_until=authority_now + timedelta(days=1),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            checkpoint_2 = add_authority_signature(
                checkpoint_2,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        checkpoint_3 = build_authority_checkpoint(
            authority_epoch=3,
            previous_hash=authority_checkpoint_hash(checkpoint_2),
            committee=authority_state.committee,
            threshold=authority_state.threshold,
            validators=authority_state.validators,
            issued_at=authority_now - timedelta(minutes=1),
            valid_until=authority_now + timedelta(days=1),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            checkpoint_3 = add_authority_signature(
                checkpoint_3,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        authority_publish_codes = []
        for checkpoint in (checkpoint_2, checkpoint_3):
            for name in ("discovery", "discovery-d2", "discovery-d3"):
                response = httpx.post(
                    f"{self.services[name].url}/registry/authority-checkpoints",
                    json={"checkpoint": checkpoint},
                    timeout=5,
                )
                authority_publish_codes.append(response.status_code)

        home_b_subject = new_home_b_certificate["node_id"]
        suspension_time = datetime.now(timezone.utc)
        suspension = build_trust_record(
            subject_node_id=home_b_subject,
            previous_level=0,
            new_level=0,
            action="suspension",
            epoch=2,
            metrics_commitment=hashlib.sha256(
                b"cluster-test-temporary-suspension"
            ).hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=None,
            decided_at=suspension_time,
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            suspension = add_trust_record_signature(
                suspension,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        suspension_response = httpx.post(
            f"{self.discovery_url}/registry/trust-records",
            json={"record": suspension},
            timeout=5,
        )
        reinstatement = build_trust_record(
            subject_node_id=home_b_subject,
            previous_level=0,
            new_level=0,
            action="reinstatement",
            epoch=3,
            metrics_commitment=hashlib.sha256(
                b"cluster-test-reinstatement-evidence"
            ).hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=trust_record_hash(suspension),
            decided_at=datetime.now(timezone.utc),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            reinstatement = add_trust_record_signature(
                reinstatement,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        reinstatement_response = httpx.post(
            f"{self.discovery_url}/registry/trust-records",
            json={"record": reinstatement},
            timeout=5,
        )
        reinstatement_replicated = []
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            reinstatement_replicated = [
                httpx.get(f"{self.services[name].url}/health", timeout=5)
                .json()
                .get("load", {})
                .get("trust_records")
                == 4
                for name in ("discovery-d2", "discovery-d3")
            ]
            if reinstatement_replicated == [True, True]:
                break
            time.sleep(0.25)
        restored_home_b = next(
            node
            for node in httpx.get(
                f"{self.discovery_url}/registry/nodes", timeout=5
            ).json()["nodes"]
            if node["node_id"] == "home-b"
        )
        self.record(
            "quorum-suspension-reinstatement",
            authority_publish_codes == [200] * 6
            and suspension_response.status_code == 200
            and suspension_response.json().get("applied") is True
            and reinstatement_response.status_code == 200
            and reinstatement_response.json().get("applied") is True
            and reinstatement_replicated == [True, True]
            and restored_home_b.get("trust_status") == "trusted",
            (
                f"authority={authority_publish_codes} "
                f"suspend={suspension_response.status_code} "
                f"reinstate={reinstatement_response.status_code} "
                f"replicas={reinstatement_replicated} "
                f"status={restored_home_b.get('trust_status')}"
            ),
        )

        relay.stop()
        direct_without_relay = self.send_direct("home-a", home_b, str(uuid.uuid4()))
        self.record(
            "direct-delivery-with-relay-down",
            direct_without_relay.status_code == 200,
            f"HTTP {direct_without_relay.status_code}",
        )

        # A second, separately quorum-signed decision for the same subject and
        # epoch is equivocation evidence. Governance freezes; cached data plane
        # remains available.
        if self.applied_trust_record is None:
            raise RuntimeError("applied TrustRecord is unavailable")
        conflicting_record = build_trust_record(
            subject_node_id=self.applied_trust_record["subject_node_id"],
            previous_level=0,
            new_level=1,
            action="promotion",
            epoch=1,
            metrics_commitment=hashlib.sha256(b"conflicting-evidence-set").hexdigest(),
            committee=sorted(self.validator_keys),
            threshold=5,
            previous_hash=None,
            decided_at=datetime.now(timezone.utc),
        )
        for validator_id in sorted(self.validator_keys)[:5]:
            conflicting_record = add_trust_record_signature(
                conflicting_record,
                validator_id=validator_id,
                validator_signing_key=self.validator_keys[validator_id],
            )
        conflict_response = httpx.post(
            f"{self.discovery_url}/registry/trust-records",
            json={"record": conflicting_record},
            timeout=5,
        )
        discovery_health = httpx.get(f"{self.discovery_url}/health", timeout=5).json()
        data_after_freeze = self.send_direct("home-a", home_c, str(uuid.uuid4()))
        self.record(
            "equivocation-freezes-control-not-data-plane",
            conflict_response.status_code == 409
            and discovery_health.get("load", {}).get("governance_allowed") is False
            and data_after_freeze.status_code == 200,
            (
                f"conflict={conflict_response.status_code} "
                f"governance={discovery_health.get('load', {}).get('governance_allowed')} "
                f"data={data_after_freeze.status_code}"
            ),
        )

    def finish(self, error: str | None = None) -> None:
        for service in reversed(list(self.services.values())):
            service.stop()
        summary = {
            "run_dir": str(self.run_dir),
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "passed": error is None and all(result["passed"] for result in self.results),
            "error": error,
            "results": self.results,
            "logs": {name: str(service.log_path) for name, service in self.services.items()},
        }
        (self.run_dir / "summary.json").write_text(
            json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        print(f"RESULTS {self.run_dir}", flush=True)


def main() -> int:
    cluster = ClusterRun()
    error = None
    try:
        cluster.start_cluster()
        cluster.run_checks()
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        print(f"CLUSTER TEST FAILED: {error}", file=sys.stderr, flush=True)
    finally:
        cluster.finish(error)
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
