#!/usr/bin/env python3
"""11 — L2: privacy/contacts enum × role matrix from catalog (client policy)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from catalog_gen import OUT as MATRIX_PATH
from catalog_gen import build as build_matrix
from harness import exit_code, run_scenario
from policy import (
    calls_allowed,
    group_invites_allowed,
    incoming_messages_allowed,
    is_blocked,
    username_search_allowed,
)


def _rows() -> list[dict]:
    if MATRIX_PATH.exists():
        data = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    else:
        data = build_matrix()
    return [
        r
        for r in data["client"]
        if r["id"].startswith(("privacy.", "contacts."))
        and r.get("type") in ("single_select", "boolean", "list")
    ]


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="matrix")
    bob = Bot.create(client, role="bob", scenario="matrix")
    carol = Bot.create(client, role="carol", scenario="matrix")

    rows = _rows()
    report.expect(
        len(rows) > 0,
        title="catalog privacy/contacts rows loaded",
        expected=">0",
        observed=str(len(rows)),
    )

    checks = 0

    # Expand single_select privacy policies that have client evaluators
    for policy_id, evaluator in [
        ("privacy.calls_from", "calls"),
        ("privacy.incoming_messages", "incoming"),
        ("privacy.group_invites", "group"),
    ]:
        row = next((r for r in rows if r["id"] == policy_id), None)
        if not row or not row.get("enums"):
            continue
        for enum_val in row["enums"]:
            lists = {}
            if policy_id == "privacy.calls_from" and enum_val == "selected":
                lists["privacy.calls_allowlist"] = [alice.user_id]
            alice.apply_privacy({policy_id: enum_val}, lists, merge=True)
            _, blob = alice.get_profile_settings()

            for role_name, uid, is_contact in [
                ("stranger", carol.user_id, False),
                ("contact", bob.user_id, True),
                ("allowlisted", alice.user_id, False),
            ]:
                if evaluator == "calls":
                    allowed = calls_allowed(blob, uid, is_contact=is_contact)
                    if enum_val == "nobody":
                        expect = False
                    elif enum_val == "everyone":
                        expect = True
                    elif enum_val == "contacts":
                        expect = is_contact
                    elif enum_val == "selected":
                        expect = uid == alice.user_id
                    else:
                        expect = allowed
                elif evaluator == "incoming":
                    allowed = incoming_messages_allowed(blob, uid, is_contact=is_contact)
                    if enum_val == "nobody":
                        expect = False
                    elif enum_val == "contacts":
                        expect = is_contact
                    else:
                        expect = True
                else:  # group
                    allowed = group_invites_allowed(blob, uid, is_contact=is_contact)
                    if enum_val == "nobody":
                        expect = False
                    elif enum_val == "everyone":
                        expect = True
                    elif enum_val == "contacts":
                        expect = is_contact
                    elif enum_val == "selected":
                        expect = uid in (blob.get("lists") or {}).get("privacy.group_invites_list", [])
                    else:
                        expect = allowed

                checks += 1
                report.expect(
                    allowed == expect,
                    title=f"{policy_id}={enum_val} × {role_name}",
                    expected=str(expect),
                    observed=str(allowed),
                    bot="alice",
                )

    # booleans: username_search true/false
    for flag in (True, False):
        alice.apply_privacy({"privacy.username_search": flag}, merge=True)
        _, blob = alice.get_profile_settings()
        checks += 1
        report.expect(
            username_search_allowed(blob) is flag,
            title=f"privacy.username_search={flag}",
            expected=str(flag),
            observed=str(username_search_allowed(blob)),
            bot="alice",
        )

    # blocked list
    alice.apply_privacy({}, {"contacts.blocked_list": [carol.user_id]}, merge=True)
    _, blob = alice.get_profile_settings()
    checks += 1
    report.expect(
        is_blocked(blob, carol.user_id) and not is_blocked(blob, bob.user_id),
        title="contacts.blocked_list matrix",
        expected="carol blocked, bob not",
        observed=str((blob.get("lists") or {}).get("contacts.blocked_list")),
        bot="alice",
    )

    report.expect(
        checks >= 20,
        title="matrix expanded enough checks",
        expected=">=20 atomic policy checks",
        observed=str(checks),
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("11_privacy_enum_matrix", scenario)))
