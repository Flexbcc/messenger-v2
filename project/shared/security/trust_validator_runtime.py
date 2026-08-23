"""Independent, opt-in validator runtime for quorum TrustRecord votes."""

from __future__ import annotations

import asyncio
import base64
import logging
import os
from pathlib import Path
from typing import Any

import httpx
from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.trust_ledger import add_trust_record_signature


class TrustValidatorRuntime:
    def __init__(self, *, logger: logging.Logger) -> None:
        self.logger = logger
        self.validator_id = os.environ.get("NODE_VALIDATOR_ID", "").strip()
        self.key_path = os.environ.get("NODE_VALIDATOR_KEY_PATH", "").strip()
        self.origins = tuple(dict.fromkeys(
            item.strip().rstrip("/")
            for item in os.environ.get("FEDERATION_DISCOVERY_URLS", "").split(",")
            if item.strip()
        ))
        self.minimum_sources = int(os.environ.get("NODE_VALIDATOR_MINIMUM_SOURCES", "2"))
        if not self.validator_id or not self.key_path:
            raise RuntimeError("validator ID and separate key path are required")
        if not 2 <= self.minimum_sources <= len(self.origins):
            raise RuntimeError("validator requires at least two Discovery sources")
        self.signing_key = self._load_key(self.key_path)
        self._task: asyncio.Task | None = None
        self._signed: set[str] = set()
        self._last_error: str | None = None

    @staticmethod
    def _load_key(path: str) -> SigningKey:
        try:
            raw = base64.urlsafe_b64decode(Path(path).read_text(encoding="utf-8").strip())
        except (FileNotFoundError, ValueError) as exc:
            raise RuntimeError("provisioned validator key is unavailable") from exc
        if len(raw) != 32:
            raise RuntimeError("validator key must contain a 32-byte Ed25519 seed")
        return SigningKey(raw)

    @staticmethod
    def _evidence_path(action: str, subject: str) -> str:
        if action == "promotion":
            return f"/registry/reliability/{subject}"
        if action == "degradation":
            return "/registry/trust-degradation-candidates?limit=1000"
        if action == "suspension":
            return "/registry/security-reputation-candidates?limit=1000"
        raise ValueError("validator runtime does not automate this Trust action")

    @staticmethod
    def _matching_evidence(payload: Any, proposal: dict[str, Any]) -> dict[str, Any] | None:
        if proposal["action"] == "promotion":
            candidates = [payload]
        else:
            candidates = payload.get("candidates", []) if isinstance(payload, dict) else []
        matches = [
            item for item in candidates
            if isinstance(item, dict)
            and item.get("subject_node_id") == proposal["subject_node_id"]
            and item.get("evidence_commitment") == proposal["metrics_commitment"]
        ]
        if len(matches) != 1:
            return None
        item = matches[0]
        if proposal["action"] == "promotion" and (
            item.get("promotion_decision") != "eligible_for_quorum_review"
            or item.get("current_level") != proposal["previous_level"]
            or item.get("proposed_level") != proposal["new_level"]
        ):
            return None
        if proposal["action"] == "degradation" and (
            item.get("previous_level") != proposal["previous_level"]
            or item.get("proposed_level") != proposal["new_level"]
        ):
            return None
        if proposal["action"] == "suspension" and item.get("decision") != "eligible_for_quorum_security_review":
            return None
        return item

    @staticmethod
    def _evidence_consensus_view(item: dict[str, Any], action: str) -> str:
        fields = {
            "promotion": (
                "subject_node_id", "evidence_commitment", "current_level",
                "proposed_level", "promotion_decision",
            ),
            "degradation": (
                "subject_node_id", "evidence_commitment", "previous_level",
                "proposed_level", "last_heartbeat",
            ),
            "suspension": (
                "subject_node_id", "evidence_commitment", "violation",
                "proof_count", "decision",
            ),
        }[action]
        return canonical_json({field: item.get(field) for field in fields})

    async def cycle(self) -> int:
        async with httpx.AsyncClient(timeout=8.0, follow_redirects=False, trust_env=False) as client:
            proposal_views: list[tuple[str, dict[str, Any]]] = []
            for origin in self.origins:
                try:
                    response = await client.get(f"{origin}/registry/trust-record-proposals?limit=1000")
                    response.raise_for_status()
                    for wrapped in response.json().get("proposals", []):
                        proposal = wrapped.get("proposal") if isinstance(wrapped, dict) else None
                        if isinstance(proposal, dict) and wrapped.get("status") == "unsigned":
                            proposal_views.append((origin, proposal))
                except (httpx.HTTPError, ValueError, AttributeError):
                    continue
            variants: dict[str, set[str]] = {}
            record_variants: dict[str, set[str]] = {}
            for origin, proposal in proposal_views:
                serialized = canonical_json(proposal)
                variants.setdefault(serialized, set()).add(origin)
                record_variants.setdefault(str(proposal.get("record_id")), set()).add(serialized)
            signed = 0
            for serialized, sources in variants.items():
                if len(sources) < self.minimum_sources:
                    continue
                proposal = next(item for _origin, item in proposal_views if canonical_json(item) == serialized)
                record_id = proposal.get("record_id")
                quorum_variants = [
                    item for item in record_variants.get(str(record_id), set())
                    if len(variants[item]) >= self.minimum_sources
                ]
                if len(quorum_variants) != 1:
                    continue
                if record_id in self._signed or self.validator_id not in proposal.get("committee", []):
                    continue
                if proposal.get("action") not in {"promotion", "degradation"}:
                    # Security sanctions require full local validation of both
                    # conflicting signed objects, not candidate-view consensus.
                    continue
                evidence_views: dict[str, set[str]] = {}
                path = self._evidence_path(proposal["action"], proposal["subject_node_id"])
                for origin in self.origins:
                    try:
                        response = await client.get(f"{origin}{path}")
                        response.raise_for_status()
                        evidence = self._matching_evidence(response.json(), proposal)
                        if evidence is not None:
                            view = self._evidence_consensus_view(evidence, proposal["action"])
                            evidence_views.setdefault(view, set()).add(origin)
                    except (httpx.HTTPError, ValueError, AttributeError):
                        continue
                quorum_evidence = [item for item, origins in evidence_views.items() if len(origins) >= self.minimum_sources]
                if len(quorum_evidence) != 1:
                    continue
                voted = add_trust_record_signature(
                    proposal,
                    validator_id=self.validator_id,
                    validator_signing_key=self.signing_key,
                )
                signature = voted["signatures"][0]["signature"]
                accepted = 0
                for origin in self.origins:
                    try:
                        response = await client.post(
                            f"{origin}/registry/trust-record-proposal-votes",
                            json={"proposal": proposal, "validator_id": self.validator_id, "signature": signature},
                        )
                        response.raise_for_status()
                        accepted += 1
                    except httpx.HTTPError:
                        continue
                if accepted >= self.minimum_sources:
                    self._signed.add(record_id)
                    signed += 1
            return signed

    async def _loop(self) -> None:
        while True:
            try:
                await self.cycle()
                self._last_error = None
            except Exception as exc:
                self._last_error = str(exc)
                self.logger.warning("Trust validator cycle failed: %s", exc)
            await asyncio.sleep(max(15, int(os.environ.get("NODE_VALIDATOR_INTERVAL_SECONDS", "60"))))

    def start(self) -> asyncio.Task:
        self._task = asyncio.create_task(self._loop())
        return self._task

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
            self._task = None

    def status(self) -> dict[str, Any]:
        return {"running": self._task is not None and not self._task.done(), "signed": len(self._signed), "last_error": self._last_error}
