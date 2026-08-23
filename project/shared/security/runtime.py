"""Lazy singletons for federation security per service process."""
from datetime import datetime, timedelta, timezone
from functools import lru_cache
import json
from pathlib import Path
from typing import Optional

from nacl.public import PrivateKey
from nacl.signing import SigningKey

from shared.security.audit_log import FederationAuditLog
from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.nonce_store import NonceStore
from shared.security.sealed_sender import curve_public_key_b64, get_or_create_curve_key
from shared.security.trust_cache import TrustCache
from shared.security.node_identity_credentials import node_identity_registration_fields
from shared.security.node_identity_credentials import load_or_renew_operational_certificate
from shared.security.node_identity_credentials import (
    load_or_update_operational_credential_state,
)
from shared.security.config import FEDERATION_NODE_ID_MODE
from shared.security.node_advertisement import issue_node_advertisement
from shared.security.capability_certificate import validate_capability_certificate
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.transport_credentials import load_or_renew_transport_certificate


@lru_cache
def get_signing_key(key_path: str) -> SigningKey:
    return load_or_create_signing_key(key_path)


def signing_public_key_b64(key_path: str) -> str:
    return public_key_b64(get_signing_key(key_path))


class FederationSecurity:
    def __init__(
        self,
        *,
        discovery_url: str,
        node_id: str,
        signing_key_path: str,
        root_key_path: Optional[str] = None,
        operational_certificate_path: Optional[str] = None,
        node_id_mode: str = FEDERATION_NODE_ID_MODE,
        nonce_db_path: Optional[str] = None,
        audit_db_path: Optional[str] = None,
        curve_key_path: Optional[str] = None,
    ):
        if node_id_mode not in {"legacy", "report", "enforce"}:
            raise ValueError("invalid federation NodeID mode")
        self.node_alias = node_id
        self.root_key_path = root_key_path
        self.operational_certificate_path = operational_certificate_path
        self.node_id_mode = node_id_mode
        self.signing_key_path = signing_key_path
        self._curve_key_path = curve_key_path
        self.trust_cache = TrustCache(discovery_url)
        self.nonce_store = NonceStore(nonce_db_path)
        self.audit_log = FederationAuditLog(audit_db_path)

    @property
    def identity_node_id(self) -> Optional[str]:
        if not self.root_key_path or not self.operational_certificate_path:
            if self.node_id_mode == "enforce":
                raise RuntimeError("federation NodeID enforcement requires identity paths")
            return None
        certificate = load_or_renew_operational_certificate(
            root_key_path=self.root_key_path,
            operational_key_path=self.signing_key_path,
            certificate_path=self.operational_certificate_path,
        )
        return certificate["node_id"]

    @property
    def node_id(self) -> str:
        if self.node_id_mode == "enforce":
            identity = self.identity_node_id
            if identity is None:
                raise RuntimeError("self-certifying federation NodeID is unavailable")
            return identity
        return self.node_alias

    @property
    def signing_key(self) -> SigningKey:
        return get_signing_key(self.signing_key_path)

    @property
    def signing_public_key(self) -> str:
        return public_key_b64(self.signing_key)

    @property
    def curve_private_key(self) -> Optional[PrivateKey]:
        """X25519 private key for sealed sender decryption. None if not configured."""
        if not self._curve_key_path:
            return None
        return get_or_create_curve_key(self._curve_key_path)

    @property
    def curve_public_key(self) -> Optional[str]:
        """X25519 public key (base64) to publish in /health for sealed sender."""
        pk = self.curve_private_key
        if pk is None:
            return None
        return curve_public_key_b64(pk)


def federation_registration_fields(
    signing_key_path: str,
    root_key_path: Optional[str] = None,
    certificate_path: Optional[str] = None,
    node_url: Optional[str] = None,
    capability_certificate_path: Optional[str] = None,
    capability_authority_state_path: Optional[str] = None,
    operational_credential_chain_path: Optional[str] = None,
    allow_existing_credential_genesis: bool = False,
    transport_key_path: Optional[str] = None,
    transport_certificate_path: Optional[str] = None,
) -> dict:
    if not signing_key_path:
        return {}
    if root_key_path and certificate_path:
        if operational_credential_chain_path:
            credential_state = load_or_update_operational_credential_state(
                root_key_path=root_key_path,
                operational_key_path=signing_key_path,
                certificate_path=certificate_path,
                credential_chain_path=operational_credential_chain_path,
                allow_existing_certificate_genesis=allow_existing_credential_genesis,
            )
            certificate = credential_state["operational_certificate"]
            fields = {
                "operational_certificate": certificate,
                "signing_public_key": certificate["operational_public_key"],
                "operational_credential_state": credential_state,
            }
        else:
            fields = node_identity_registration_fields(
                root_key_path=root_key_path,
                operational_key_path=signing_key_path,
                certificate_path=certificate_path,
            )
        if node_url:
            now = datetime.now(timezone.utc)
            fields["node_advertisement"] = issue_node_advertisement(
                operational_signing_key=get_signing_key(signing_key_path),
                operational_certificate=fields["operational_certificate"],
                endpoints=[node_url],
                supported_transports=["https"],
                supported_protocols=[
                    "ouo-federation-auth/1",
                    "ouo-federation-envelope/1",
                ],
                epoch=int(now.timestamp() * 1000),
                issued_at=now,
                expires_at=now + timedelta(hours=1),
            )
        if capability_certificate_path:
            raw = Path(capability_certificate_path).read_bytes()
            if len(raw) > 65536:
                raise ValueError("capability certificate exceeds size limit")
            certificate = json.loads(raw)
            if not isinstance(certificate, dict):
                raise ValueError("capability certificate must be an object")
            if not capability_authority_state_path:
                raise ValueError(
                    "capability certificate requires a local authority state"
                )
            authority = load_capability_authority_state(
                capability_authority_state_path
            )
            if authority is None:
                raise ValueError("capability authority state is unavailable")
            validation = validate_capability_certificate(
                certificate,
                now=datetime.now(timezone.utc),
                expected_committee=authority.committee,
                expected_threshold=authority.threshold,
                validator_credentials=authority.validators,
                minimum_epoch=0,
                expected_authority_epoch=authority.epoch,
                expected_subject_node_id=fields["operational_certificate"]["node_id"],
            )
            if not validation.valid:
                raise ValueError(
                    "invalid capability certificate: "
                    f"{validation.reason or 'validation failed'}"
                )
            fields["capability_certificate"] = certificate
        if transport_key_path or transport_certificate_path:
            if not transport_key_path or not transport_certificate_path:
                raise ValueError("both transport credential paths are required")
            fields["transport_certificate"] = load_or_renew_transport_certificate(
                root_key_path=root_key_path,
                transport_key_path=transport_key_path,
                certificate_path=transport_certificate_path,
            )
        return fields
    return {"signing_public_key": signing_public_key_b64(signing_key_path)}
