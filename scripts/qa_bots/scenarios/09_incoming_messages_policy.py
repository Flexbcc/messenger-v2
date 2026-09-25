#!/usr/bin/env python3
"""09 — incoming_messages + blocked_list policy situations."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from harness import exit_code, run_scenario
from policy import incoming_messages_allowed, is_blocked


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="inbox")
    bob = Bot.create(client, role="bob", scenario="inbox")
    carol = Bot.create(client, role="carol", scenario="inbox")

    # Alice: nobody may message first
    alice.apply_privacy({"privacy.incoming_messages": "nobody"})
    _, blob = alice.get_profile_settings()
    report.expect(
        not incoming_messages_allowed(blob, bob.user_id, is_contact=False),
        title="alice incoming=nobody blocks stranger bob",
        expected="False",
        observed=str(incoming_messages_allowed(blob, bob.user_id, is_contact=False)),
        bot="alice",
    )
    report.expect(
        not incoming_messages_allowed(blob, bob.user_id, is_contact=True),
        title="alice incoming=nobody blocks even contacts",
        expected="False",
        observed=str(incoming_messages_allowed(blob, bob.user_id, is_contact=True)),
        bot="alice",
    )

    # Carol: contacts only
    carol.apply_privacy({"privacy.incoming_messages": "contacts"})
    _, cblob = carol.get_profile_settings()
    report.expect(
        not incoming_messages_allowed(cblob, bob.user_id, is_contact=False),
        title="carol contacts-only blocks stranger",
        expected="False",
        observed=str(incoming_messages_allowed(cblob, bob.user_id, is_contact=False)),
        bot="carol",
    )
    report.expect(
        incoming_messages_allowed(cblob, bob.user_id, is_contact=True),
        title="carol contacts-only allows contact",
        expected="True",
        observed=str(incoming_messages_allowed(cblob, bob.user_id, is_contact=True)),
        bot="carol",
    )

    # Bob blocks Alice
    bob.apply_privacy({}, {"contacts.blocked_list": [alice.user_id]})
    _, bblob = bob.get_profile_settings()
    report.expect(
        is_blocked(bblob, alice.user_id),
        title="bob blocked_list contains alice",
        expected=alice.user_id,
        observed=str((bblob.get("lists") or {}).get("contacts.blocked_list")),
        bot="bob",
    )

    # Server still delivers messages (client would hide) — document gap
    code, conv = alice.create_direct(bob.user_id)
    if code == 200:
        c2, _ = alice.send_message(conv["id"], ciphertext="hi-despite-block")
        report.expect(
            c2 == 200,
            title="server still accepts message to blocker (client filters)",
            expected="200 — block is client-side today",
            observed=str(c2),
            bot="alice",
        )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("09_incoming_messages_policy", scenario)))
