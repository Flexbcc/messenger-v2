#!/usr/bin/env python3
"""06 — fail path: duplicate register must error."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from client import unique_phone
from harness import exit_code, run_scenario


def scenario(client, report) -> None:
    phone = unique_phone()
    password = "qa-bot-password-123"
    code1, first = client.register(
        display_name="qa_bot_dup_first",
        phone=phone,
        password=password,
    )
    report.expect(
        code1 == 200,
        title="first register ok",
        expected="200",
        observed=f"{code1} {first}",
        bot="alice",
    )
    if code1 != 200:
        return

    code2, second = client.register(
        display_name="qa_bot_dup_second",
        phone=phone,
        password=password,
    )
    detail = ""
    if isinstance(second, dict):
        detail = str(second.get("detail", second))
    report.expect(
        code2 >= 400,
        title="duplicate phone register rejected",
        expected="4xx (phone/login/email already registered)",
        observed=f"{code2} {second}",
        bot="alice",
    )
    report.expect(
        "already" in detail.lower() or code2 >= 400,
        title="error mentions already registered",
        expected="detail contains already registered",
        observed=detail or str(second),
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("06_fail_duplicate_register", scenario)))
