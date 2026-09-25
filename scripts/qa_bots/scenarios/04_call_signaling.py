#!/usr/bin/env python3
"""04 — call signaling envelopes (no WebRTC media)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="call")
    bob = Bot.create(client, role="bob", scenario="call")

    code, conv = alice.create_direct(bob.user_id)
    report.expect(code == 200, title="create conv for call", expected="200", observed=f"{code} {conv}", bot="alice")
    if code != 200:
        return
    conv_id = conv["id"]

    steps = [
        ("alice", "call_offer", "offer-sdp-stub"),
        ("bob", "call_answer", "answer-sdp-stub"),
        ("alice", "call_ice_candidate", "ice-stub"),
        ("bob", "call_end", "end"),
    ]
    for actor_name, ctype, cipher in steps:
        actor = alice if actor_name == "alice" else bob
        c, body = actor.send_message(conv_id, ciphertext=cipher, content_type=ctype)
        report.expect(
            c == 200 and body.get("content_type") == ctype,
            title=f"send {ctype}",
            expected=f"200 content_type={ctype}",
            observed=f"{c} {body}",
            bot=actor_name,
        )

    code_m, msgs = bob.list_messages(conv_id)
    types = [m.get("content_type") for m in (msgs or []) if isinstance(m, dict)]
    for need in ("call_offer", "call_answer", "call_end"):
        report.expect(
            need in types,
            title=f"history contains {need}",
            expected=need,
            observed=str(types),
            bot="bob",
        )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("04_call_signaling", scenario)))
