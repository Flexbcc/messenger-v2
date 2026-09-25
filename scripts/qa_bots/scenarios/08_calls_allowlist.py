#!/usr/bin/env python3
"""08 — calls_from + calls_allowlist matrix; signaling still accepted by server."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from harness import exit_code, run_scenario
from policy import calls_allowed


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="calls")
    bob = Bot.create(client, role="bob", scenario="calls")
    carol = Bot.create(client, role="carol", scenario="calls")

    # Bob: only allowlist may call (Alice on list, Carol not).
    bob.apply_privacy(
        {"privacy.calls_from": "selected"},
        {"privacy.calls_allowlist": [alice.user_id]},
    )
    _, blob = bob.get_profile_settings()

    report.expect(
        calls_allowed(blob, alice.user_id, is_contact=False) is True,
        title="policy: alice on allowlist may call bob",
        expected="callsAllowed(alice)=True",
        observed=str(calls_allowed(blob, alice.user_id, is_contact=False)),
        bot="bob",
    )
    report.expect(
        calls_allowed(blob, carol.user_id, is_contact=False) is False,
        title="policy: carol NOT on allowlist cannot call bob",
        expected="callsAllowed(carol)=False",
        observed=str(calls_allowed(blob, carol.user_id, is_contact=False)),
        bot="bob",
    )
    report.expect(
        calls_allowed(blob, carol.user_id, is_contact=True) is False,
        title="policy: selected ignores contacts flag",
        expected="False even if is_contact",
        observed=str(calls_allowed(blob, carol.user_id, is_contact=True)),
        bot="bob",
    )

    # nobody — blocks everyone
    bob.apply_privacy({"privacy.calls_from": "nobody"}, {"privacy.calls_allowlist": []})
    _, blob2 = bob.get_profile_settings()
    report.expect(
        not calls_allowed(blob2, alice.user_id, is_contact=True),
        title="policy: calls_from=nobody blocks alice",
        expected="False",
        observed=str(calls_allowed(blob2, alice.user_id, is_contact=True)),
        bot="bob",
    )

    # everyone
    bob.apply_privacy({"privacy.calls_from": "everyone"})
    _, blob3 = bob.get_profile_settings()
    report.expect(
        calls_allowed(blob3, carol.user_id, is_contact=False),
        title="policy: calls_from=everyone allows stranger",
        expected="True",
        observed=str(calls_allowed(blob3, carol.user_id, is_contact=False)),
        bot="bob",
    )

    # Server does not enforce: carol can still POST call_offer (client would drop).
    bob.apply_privacy(
        {"privacy.calls_from": "selected"},
        {"privacy.calls_allowlist": [alice.user_id]},
    )
    code, conv = carol.create_direct(bob.user_id)
    report.expect(code == 200, title="create conv carol→bob", expected="200", observed=f"{code}", bot="carol")
    if code == 200:
        c_sig, body = carol.send_message(
            conv["id"],
            ciphertext="offer-from-stranger",
            content_type="call_offer",
        )
        report.expect(
            c_sig == 200,
            title="server accepts call_offer from non-allowlisted (client would reject)",
            expected="200 — enforcement is client SettingsRuntime.callsAllowed",
            observed=f"{c_sig} {body}",
            bot="carol",
        )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("08_calls_allowlist", scenario)))
