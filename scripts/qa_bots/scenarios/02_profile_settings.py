#!/usr/bin/env python3
"""02 — profile-settings round-trip + blocked list."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="settings")
    bob = Bot.create(client, role="bob", scenario="settings")

    values = {
        "privacy.username_search": False,
        "notifications.messages_enabled": True,
        "notifications.calls_enabled": False,
        "ui.theme": "system",
    }
    lists = {
        "contacts.blocked_list": [bob.user_id],
        "security.trusted_contacts": [bob.user_id],  # server blob stand-in for trusted list
    }
    code, put = alice.put_profile_settings(values, lists)
    report.expect(
        code == 200 and put.get("ok") is True,
        title="PUT profile-settings",
        expected="200 {ok: true}",
        observed=f"{code} {put}",
        bot="alice",
    )

    code2, got = alice.get_profile_settings()
    report.expect(
        code2 == 200
        and got.get("values", {}).get("privacy.username_search") is False
        and got.get("values", {}).get("notifications.calls_enabled") is False,
        title="GET profile-settings values match",
        expected=str(values),
        observed=f"{code2} {got}",
        bot="alice",
    )
    report.expect(
        bob.user_id in (got.get("lists") or {}).get("contacts.blocked_list", []),
        title="blocked_list contains bob",
        expected=bob.user_id,
        observed=str((got.get("lists") or {}).get("contacts.blocked_list")),
        bot="alice",
    )
    report.expect(
        bob.user_id in (got.get("lists") or {}).get("security.trusted_contacts", []),
        title="trusted_contacts list persisted in profile-settings",
        expected=bob.user_id,
        observed=str((got.get("lists") or {}).get("security.trusted_contacts")),
        bot="alice",
    )

    code3, devices = alice.list_devices()
    report.expect(
        code3 == 200 and isinstance(devices, list) and len(devices) >= 1,
        title="list devices",
        expected="200 non-empty list",
        observed=f"{code3} {devices}",
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("02_profile_settings", scenario)))
