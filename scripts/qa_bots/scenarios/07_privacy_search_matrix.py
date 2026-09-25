#!/usr/bin/env python3
"""07 — search privacy: phone off / username on / id lookup; peer with username off → 403."""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from client import unique_login
from harness import exit_code, run_scenario
from policy import phone_search_allowed, phone_search_policy, username_search_allowed


def _wait_discovery(client, login: str, *, expect_status: int, attempts: int = 8) -> tuple[int, object]:
    last = (0, {})
    for _ in range(attempts):
        last = client.discovery_search_login(login)
        if last[0] == expect_status:
            return last
        time.sleep(0.4)
    return last


def scenario(client, report) -> None:
    dcode, _ = client.discovery_health()
    report.expect(
        dcode == 200,
        title="discovery /health",
        expected="200",
        observed=str(dcode),
    )
    if dcode != 200:
        return

    alice = Bot.create(client, role="alice", scenario="search")
    carol = Bot.create(client, role="carol", scenario="search")
    bob = Bot.create(client, role="bob", scenario="search")

    login_alice = unique_login("alice")
    login_carol = unique_login("carol")

    # Alice: findable by username, NOT by phone (client policy). User-id still open on discovery.
    code_p, _ = alice.update_profile(login=login_alice, display_name=f"Alice {login_alice}")
    report.expect(code_p == 200, title="alice set login", expected="200", observed=str(code_p), bot="alice")
    alice.apply_privacy(
        {
            "privacy.username_search": True,
            "privacy.phone_search": "nobody",
            "profile.username_enabled": True,
            "profile.username": login_alice,
        }
    )
    code_g, blob = alice.get_profile_settings()
    report.expect(
        code_g == 200
        and username_search_allowed(blob)
        and phone_search_policy(blob) == "nobody"
        and not phone_search_allowed(blob),
        title="alice: username ON, phone search nobody",
        expected="username_search=true phone_search=nobody → phoneSearchAllowed=false",
        observed=f"{blob}",
        bot="alice",
    )

    # Carol: username search disabled
    carol.update_profile(login=login_carol, display_name=f"Carol {login_carol}")
    carol.apply_privacy({"privacy.username_search": False, "privacy.phone_search": "everyone"})

    # Discovery search by username
    sc, sbody = _wait_discovery(client, login_alice, expect_status=200)
    report.expect(
        sc == 200 and isinstance(sbody, dict) and sbody.get("user_id") == alice.user_id,
        title="discovery find alice by username",
        expected=f"200 user_id={alice.user_id}",
        observed=f"{sc} {sbody}",
        bot="bob",
    )

    sc2, sbody2 = _wait_discovery(client, login_carol, expect_status=403)
    report.expect(
        sc2 == 403,
        title="discovery: carol username search disabled → 403",
        expected="403 Username search disabled",
        observed=f"{sc2} {sbody2}",
        bot="bob",
    )

    # User-id resolve (no privacy gate on discovery today)
    ic, ibody = client.discovery_user_by_id(alice.user_id)
    report.expect(
        ic == 200,
        title="discovery resolve by user_id (always open today)",
        expected="200 — note: no privacy.user_id_search gate on server",
        observed=f"{ic} {ibody}",
        bot="bob",
    )

    # Phone: client would block; no phone directory API
    report.expect(
        not phone_search_allowed(blob),
        title="client would block phone search for alice",
        expected="phoneSearchAllowed=false (privacy.phone_search=nobody)",
        observed=f"policy={phone_search_policy(blob)} allowed={phone_search_allowed(blob)}",
        bot="alice",
    )
    report.expect(
        True,  # documented situation
        title="phone directory API absent (expected soft gap)",
        expected="UI: «API каталога ещё нет» when phone search everyone",
        observed="no /registry/users/search?phone= — bots assert client policy only",
        bot="bob",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("07_privacy_search_matrix", scenario)))
