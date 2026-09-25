"""Quorum client for replicated opaque Storage mailboxes."""

from __future__ import annotations

import asyncio
import base64
import hashlib
from dataclasses import dataclass
from typing import Any, Sequence

import httpx

from shared.security.http_client import federation_post
from shared.security.keys import SigningKey
from shared.security.mailbox_capability import mailbox_token_bytes
from shared.transport.fixed_cell import CELL_SIZES

MAX_PADDED_POLL_BYTES = 1024 * 1024

@dataclass(frozen=True)
class MailboxReplicaReceipt:
    storage_url: str
    entry_id: str


@dataclass(frozen=True)
class ReplicatedMailboxCell:
    cell_b64: str
    cell_hash: str
    receipts: tuple[MailboxReplicaReceipt, ...]


class OpaqueMailboxClient:
    def __init__(
        self,
        *,
        signing_key: SigningKey,
        node_id: str,
        storage_urls: Sequence[str],
        replication_factor: int,
        write_quorum: int,
        timeout_seconds: float = 10.0,
    ) -> None:
        normalized = tuple(dict.fromkeys(url.rstrip("/") for url in storage_urls if url))
        if not normalized:
            raise ValueError("at least one Storage URL is required")
        if not 1 <= write_quorum <= replication_factor <= len(normalized):
            raise ValueError("invalid mailbox replication policy")
        self.signing_key = signing_key
        self.node_id = node_id
        self.storage_urls = normalized
        self.replication_factor = replication_factor
        self.write_quorum = write_quorum
        self.timeout_seconds = timeout_seconds

    def _validate(self, mailbox_token: str, cell: bytes | None = None) -> None:
        mailbox_token_bytes(mailbox_token)
        if cell is not None and len(cell) not in CELL_SIZES:
            raise ValueError("opaque mailbox cell must use a fixed size class")

    async def _post(self, url: str, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        async with httpx.AsyncClient(
            timeout=self.timeout_seconds, follow_redirects=False, trust_env=False
        ) as client:
            response = await federation_post(
                client,
                f"{url}{path}",
                path=path,
                payload=payload,
                signing_key=self.signing_key,
                node_id=self.node_id,
            )
            response.raise_for_status()
            if response.status_code == 204:
                return {}
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError("Storage response is not an object")
            return result

    async def store(
        self, *, mailbox_token: str, cell: bytes, ttl_seconds: int
    ) -> tuple[MailboxReplicaReceipt, ...]:
        self._validate(mailbox_token, cell)
        payload = {
            "mailbox_token": mailbox_token,
            "cell_b64": base64.urlsafe_b64encode(cell).decode("ascii"),
            "ttl_seconds": ttl_seconds,
        }
        targets = self.storage_urls[: self.replication_factor]
        results = await asyncio.gather(
            *(self._post(url, "/mailbox/store", payload) for url in targets),
            return_exceptions=True,
        )
        receipts = []
        for url, result in zip(targets, results):
            if isinstance(result, Exception):
                continue
            entry_id = result.get("id")
            if isinstance(entry_id, str):
                receipts.append(MailboxReplicaReceipt(url, entry_id))
        if len(receipts) < self.write_quorum:
            raise RuntimeError(
                f"opaque mailbox write quorum failed ({len(receipts)}/{self.write_quorum})"
            )
        return tuple(receipts)

    async def fetch(
        self,
        *,
        mailbox_token: str,
        limit: int = 8,
        padded_cell_size: int | None = None,
    ) -> tuple[ReplicatedMailboxCell, ...]:
        self._validate(mailbox_token)
        if not 1 <= limit <= 32:
            raise ValueError("opaque mailbox fetch limit must be 1-32")
        if padded_cell_size is not None and padded_cell_size not in CELL_SIZES:
            raise ValueError("invalid padded mailbox cell size")
        if (
            padded_cell_size is not None
            and padded_cell_size * limit > MAX_PADDED_POLL_BYTES
        ):
            raise ValueError("padded mailbox poll exceeds response byte budget")
        payload = {
            "mailbox_token": mailbox_token,
            "limit": limit,
            "padded": padded_cell_size is not None,
            "cell_size": padded_cell_size,
        }
        results = await asyncio.gather(
            *(self._post(url, "/mailbox/fetch", payload) for url in self.storage_urls),
            return_exceptions=True,
        )
        merged: dict[str, dict[str, Any]] = {}
        for url, result in zip(self.storage_urls, results):
            if isinstance(result, Exception):
                continue
            cells = result.get("cells")
            if not isinstance(cells, list) or len(cells) > limit:
                continue
            for item in cells:
                if not isinstance(item, dict):
                    continue
                encoded = item.get("cell_b64")
                entry_id = item.get("id")
                if not isinstance(encoded, str) or not isinstance(entry_id, str):
                    continue
                try:
                    raw = base64.b64decode(encoded.encode("ascii"), altchars=b"-_", validate=True)
                except (UnicodeEncodeError, ValueError):
                    continue
                if len(raw) not in CELL_SIZES:
                    continue
                digest = hashlib.sha256(raw).hexdigest()
                slot = merged.setdefault(digest, {"cell_b64": encoded, "receipts": []})
                slot["receipts"].append(MailboxReplicaReceipt(url, entry_id))
        return tuple(
            ReplicatedMailboxCell(
                cell_b64=value["cell_b64"],
                cell_hash=digest,
                receipts=tuple(value["receipts"]),
            )
            for digest, value in merged.items()
        )

    async def acknowledge(
        self, *, mailbox_token: str, receipts: Sequence[MailboxReplicaReceipt]
    ) -> tuple[MailboxReplicaReceipt, ...]:
        self._validate(mailbox_token)
        results = await asyncio.gather(
            *(
                self._post(
                    receipt.storage_url,
                    "/mailbox/ack",
                    {"mailbox_token": mailbox_token, "entry_id": receipt.entry_id},
                )
                for receipt in receipts
            ),
            return_exceptions=True,
        )
        return tuple(
            receipt
            for receipt, result in zip(receipts, results)
            if isinstance(result, Exception)
        )
