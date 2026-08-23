"""
Durable federation outbox — Post-R5. Closes the gap documented in
docs/reality/R3-message-lifecycle.md ("Нет outbox на federation fail: Тихая
потеря remote delivery") and spec/0202_DELIVERY.md's queue policy note
("Durable outbox на Local Home при fail federation (backoff), не только log").

Scope is intentionally minimal: a server-side federation DLQ with retry +
backoff. Removing an outbox row means the remote Home Node or Relay accepted
the packet; end-to-end delivery acknowledgement is tracked separately in
``message_delivery_acks`` and is not conflated with transport acceptance.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession
    from app.models import MessageOutbox

logger = logging.getLogger(__name__)

RETRY_INITIAL_SECONDS = 2
RETRY_BACKOFF_FACTOR = 2
RETRY_MAX_SECONDS = 60 * 60  # cap at 1h between attempts
MAX_ATTEMPTS = 20
WORKER_POLL_INTERVAL_SECONDS = 5


def _now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def backoff_seconds(attempts: int) -> float:
    """2s * 2^attempts, capped at RETRY_MAX_SECONDS."""
    return min(RETRY_INITIAL_SECONDS * (RETRY_BACKOFF_FACTOR ** attempts), RETRY_MAX_SECONDS)


def _reschedule_or_kill(entry: "MessageOutbox") -> None:
    if entry.attempts >= MAX_ATTEMPTS:
        entry.status = "dead"
        return
    entry.next_attempt_at = _now() + timedelta(seconds=backoff_seconds(entry.attempts))


async def enqueue_outbox(
    db: "AsyncSession",
    *,
    packet_id: str,
    target_user_id: str,
    target_home_url: Optional[str],
    envelope: dict,
    conversation_meta: dict,
    last_error: str,
) -> None:
    """Called from fan_out_message when deliver_to_remote_home_node exhausts
    direct delivery + all relays for one target_user_id."""
    from app.models import MessageOutbox

    entry = MessageOutbox(
        packet_id=packet_id,
        target_user_id=target_user_id,
        target_home_url=target_home_url,
        envelope=envelope,
        conversation_meta=conversation_meta,
        attempts=0,
        next_attempt_at=_now() + timedelta(seconds=RETRY_INITIAL_SECONDS),
        last_error=(last_error or "")[:2000] or None,
        status="pending",
    )
    db.add(entry)
    await db.commit()


async def _retry_once(db: "AsyncSession", entry: "MessageOutbox") -> None:
    from app.federation import deliver_to_remote_home_node, resolve_home_node
    from app.fanout import push_home_changed_to_local_contacts

    # Re-resolve via Discovery in case the URL captured at enqueue time went
    # stale (node moved, re-registered elsewhere, etc). force_refresh=True
    # bypasses the Post-R5 resolve cache so we don't retry against a cached
    # URL that's exactly what we're trying to detect as stale; a fresh
    # result also updates the cache for other callers (e.g. fan_out).
    # Fall back to the stored URL if Discovery is unreachable or has no record.
    home_url = await resolve_home_node(entry.target_user_id, force_refresh=True) or entry.target_home_url
    if not home_url:
        entry.attempts += 1
        entry.last_error = "Discovery could not resolve a home node for target_user_id"[:2000]
        _reschedule_or_kill(entry)
        await db.commit()
        return

    # Phase 2.4: if the home-node changed since we enqueued, notify local
    # contacts so they stop sending to the old address (best-effort WS push).
    if entry.target_home_url and home_url != entry.target_home_url:
        logger.info(
            "Outbox detected home change for %s: %s → %s — notifying local contacts",
            entry.target_user_id, entry.target_home_url, home_url,
        )
        try:
            await push_home_changed_to_local_contacts(
                db,
                changed_user_id=entry.target_user_id,
                home_node_url=home_url,
                home_updated_at=None,  # we don't have the exact timestamp here
            )
        except Exception as notify_err:
            logger.warning(
                "home_changed local notify failed for %s: %s", entry.target_user_id, notify_err
            )

    entry.target_home_url = home_url
    try:
        await deliver_to_remote_home_node(home_url, entry.envelope, entry.conversation_meta)
    except Exception as e:
        entry.attempts += 1
        entry.last_error = str(e)[:2000]
        _reschedule_or_kill(entry)
        await db.commit()
        logger.warning(
            "Outbox retry %d/%d failed for packet_id=%s target_user_id=%s: %s",
            entry.attempts, MAX_ATTEMPTS, entry.packet_id, entry.target_user_id, e,
        )
        return

    await db.delete(entry)
    await db.commit()
    logger.info(
        "Outbox retry delivered packet_id=%s target_user_id=%s after %d attempt(s)",
        entry.packet_id, entry.target_user_id, entry.attempts,
    )


async def _process_due_entries() -> None:
    from sqlalchemy import select
    from app.db import async_session
    from app.models import MessageOutbox

    async with async_session() as db:
        result = await db.execute(
            select(MessageOutbox).where(
                MessageOutbox.status == "pending",
                MessageOutbox.next_attempt_at <= _now(),
            )
        )
        due = result.scalars().all()
        for entry in due:
            try:
                await _retry_once(db, entry)
            except Exception:
                logger.exception(
                    "Outbox retry crashed for packet_id=%s target_user_id=%s",
                    entry.packet_id, entry.target_user_id,
                )
                await db.rollback()


async def _worker_loop() -> None:
    while True:
        try:
            await _process_due_entries()
        except Exception:
            logger.exception("Outbox worker iteration failed")
        await asyncio.sleep(WORKER_POLL_INTERVAL_SECONDS)


def start_outbox_worker() -> asyncio.Task:
    return asyncio.create_task(_worker_loop())
