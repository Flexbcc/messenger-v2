#!/usr/bin/env python3
"""01 — register + login."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from client import unique_phone
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    phone = unique_phone()
    password = "qa-bot-password-123"
    code, reg = client.register(
        display_name="qa_bot_auth_alice",
        phone=phone,
        password=password,
    )
    report.expect(
        code == 200 and "access_token" in reg,
        title="register returns token",
        expected="200 + access_token/user_id/device_id",
        observed=f"{code} {reg}",
        bot="alice",
    )
    if code != 200:
        return

    code2, login = client.login(identifier=phone, password=password)
    report.expect(
        code2 == 200 and login.get("user_id") == reg["user_id"],
        title="login same phone",
        expected=f"200 user_id={reg['user_id']}",
        observed=f"{code2} {login}",
        bot="alice",
    )

    # wrong password
    code3, bad = client.login(identifier=phone, password="wrong-password-xxx")
    report.expect(
        code3 >= 400,
        title="login wrong password fails",
        expected="4xx error",
        observed=f"{code3} {bad}",
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("01_auth_register_login", scenario)))
