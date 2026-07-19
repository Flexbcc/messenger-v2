#!/usr/bin/env python3
"""03 — direct chat Alice ↔ Bob (opaque ciphertext)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from client import collect_ws_events
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="chat")
    bob = Bot.create(client, role="bob", scenario="chat")

    code, conv = alice.create_direct(bob.user_id)
    report.expect(
        code == 200 and "id" in conv,
        title="create direct conversation",
        expected="200 + id",
        observed=f"{code} {conv}",
        bot="alice",
    )
    if code != 200:
        return
    conv_id = conv["id"]

    payload = "qa-bot-ciphertext-hello"
    events = collect_ws_events(
        bob.ws_url(),
        trigger=lambda: alice.send_message(conv_id, ciphertext=payload, content_type="text"),
        timeout=6.0,
    )
    ws_hit = any(
        e.get("type") == "new_message"
        and (e.get("message") or {}).get("ciphertext") == payload
        for e in events
    )
    # WS optional soft-fail if fanout slow — still check REST history
    code_m, msgs = bob.list_messages(conv_id)
    rest_hit = code_m == 200 and any(
        isinstance(m, dict) and m.get("ciphertext") == payload for m in (msgs or [])
    )
    report.expect(
        rest_hit,
        title="bob sees message via REST history",
        expected=f"message ciphertext={payload}",
        observed=f"{code_m} {msgs}",
        bot="bob",
    )
    report.expect(
        ws_hit or rest_hit,
        title="bob receives via WS or REST",
        expected="WS new_message or REST history",
        observed=f"ws_hit={ws_hit} events={events!r}",
        bot="bob",
    )

    # reply
    reply = "qa-bot-ciphertext-reply"
    code_r, _ = bob.send_message(conv_id, ciphertext=reply)
    code_a, amsgs = alice.list_messages(conv_id)
    report.expect(
        code_r == 200
        and code_a == 200
        and any(m.get("ciphertext") == reply for m in (amsgs or []) if isinstance(m, dict)),
        title="alice sees bob reply",
        expected=reply,
        observed=f"send={code_r} get={code_a} {amsgs}",
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("03_direct_chat", scenario)))
