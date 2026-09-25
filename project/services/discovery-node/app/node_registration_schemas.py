"""Validated input models for node enrollment and heartbeat."""

import json
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.schema_validation import (
    Capabilities,
    EncodedKey,
    Identifier,
    ServiceUrl,
    ShortText,
)


class BoundedSecurityPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    @model_validator(mode="after")
    def bound_nested_security_material(self):
        total = 0
        for name in (
            "operational_certificate",
            "operational_credential_state",
            "operational_credential_chain",
            "node_advertisement",
            "capability_certificate",
            "transport_certificate",
        ):
            value = getattr(self, name, None)
            if value is None:
                continue
            encoded_size = len(
                json.dumps(
                    value, separators=(",", ":"), ensure_ascii=False
                ).encode("utf-8")
            )
            if encoded_size > 1024 * 1024:
                raise ValueError(f"{name} exceeds 1 MiB")
            total += encoded_size
        if total > 4 * 1024 * 1024:
            raise ValueError("combined security material exceeds 4 MiB")
        return self


class RegisterNodeCapability(BoundedSecurityPayload):
    node_id: Identifier
    node_url: ServiceUrl
    capabilities: Capabilities
    software_version: ShortText = "unknown"
    cluster_id: Identifier = "default"
    build_hash: Optional[ShortText] = None
    tls_cert_fingerprint: Optional[ShortText] = None
    release_signature: Optional[EncodedKey] = None
    signing_public_key: Optional[EncodedKey] = None
    operational_certificate: Optional[Dict[str, Any]] = None
    operational_credential_state: Optional[Dict[str, Any]] = None
    operational_credential_chain: Optional[List[Dict[str, Any]]] = None
    node_advertisement: Optional[Dict[str, Any]] = None
    capability_certificate: Optional[Dict[str, Any]] = None
    transport_certificate: Optional[Dict[str, Any]] = None

    @field_validator("capabilities")
    @classmethod
    def unique_capabilities(cls, capabilities: List[str]) -> List[str]:
        if len(capabilities) != len(set(capabilities)):
            raise ValueError("capabilities must not contain duplicates")
        return capabilities

    @field_validator("operational_credential_chain")
    @classmethod
    def bound_credential_chain(
        cls, chain: Optional[List[Dict[str, Any]]]
    ) -> Optional[List[Dict[str, Any]]]:
        if chain is not None and not 1 <= len(chain) <= 4096:
            raise ValueError("operational credential chain length is invalid")
        return chain


class HeartbeatRequest(BoundedSecurityPayload):
    software_version: Optional[ShortText] = None
    build_hash: Optional[ShortText] = None
    tls_cert_fingerprint: Optional[ShortText] = None
    release_signature: Optional[EncodedKey] = None
    signing_public_key: Optional[EncodedKey] = None
    operational_certificate: Optional[Dict[str, Any]] = None
    operational_credential_state: Optional[Dict[str, Any]] = None
    node_advertisement: Optional[Dict[str, Any]] = None
    capability_certificate: Optional[Dict[str, Any]] = None
    transport_certificate: Optional[Dict[str, Any]] = None
    cpu_load_1m: Optional[float] = Field(default=None, ge=0, le=1_000_000)
    cpu_cores: Optional[int] = Field(default=None, ge=1, le=65_536)
    cpu_percent_est: Optional[int] = Field(default=None, ge=0, le=100)
    ram_total_bytes: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    ram_used_bytes: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    ram_percent: Optional[int] = Field(default=None, ge=0, le=100)
    disk_used_bytes: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    disk_total_bytes: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    disk_percent: Optional[int] = Field(default=None, ge=0, le=100)
    uptime_sec: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    ws_connections: Optional[int] = Field(default=None, ge=0, le=10_000_000)
    messages_24h: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    calls_24h: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)
    error_rate_pct: Optional[float] = Field(default=None, ge=0, le=100)
    messages_total: Optional[int] = Field(default=None, ge=0, le=2**63 - 1)

    @model_validator(mode="after")
    def validate_metric_relationships(self):
        if (
            self.ram_total_bytes is not None
            and self.ram_used_bytes is not None
            and self.ram_used_bytes > self.ram_total_bytes
        ):
            raise ValueError("ram_used_bytes cannot exceed ram_total_bytes")
        if (
            self.disk_total_bytes is not None
            and self.disk_used_bytes is not None
            and self.disk_used_bytes > self.disk_total_bytes
        ):
            raise ValueError("disk_used_bytes cannot exceed disk_total_bytes")
        return self
