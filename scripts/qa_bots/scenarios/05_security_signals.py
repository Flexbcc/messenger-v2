#!/usr/bin/env python3
"""05 — security-signals to online trusted peer (Carol on WS)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from client import collect_ws_events
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="sec")
    carol = Bot.create(client, role="carol", scenario="sec")

    # Persist Carol as trusted contact stand-in (server blob).
    alice.put_profile_settings(
        {"notifications.security_alerts": True},
        {"security.trusted_contacts": [carol.user_id]},
    )

    event_id = 42

    def trigger() -> None:
        alice.security_signal(event_id, [carol.user_id])

    events = collect_ws_events(carol.ws_url(), trigger=trigger, timeout=6.0)
    hit = next(
        (
            e
            for e in events
            if e.get("type") == "security_signal"
            and e.get("event") == event_id
            and e.get("from_user_id") == alice.user_id
        ),
        None,
    )
    report.expect(
        hit is not None,
        title="carol receives security_signal on WS",
        expected=f"type=security_signal event={event_id} from={alice.user_id}",
        observed=repr(events),
        bot="carol",
    )

    # Offline target should not crash; delivered may be 0
    code, body = alice.security_signal(7, ["00000000-0000-0000-0000-000000000099"])
    report.expect(
        code == 200 and body.get("ok") is True,
        title="signal to unknown target returns ok",
        expected="200 {ok:true, delivered:0?}",
        observed=f"{code} {body}",
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("05_security_signals", scenario)))
