"""Shared scenario entrypoint helpers."""
from __future__ import annotations

import os
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from assertlib import ScenarioReport
from bugs import clear_run_bugs_marker
from client import DEFAULT_HOME, HomeClient


def home_url() -> str:
    return os.environ.get("HOME_URL", DEFAULT_HOME).rstrip("/")


def run_scenario(name: str, fn) -> ScenarioReport:
    clear_run_bugs_marker()
    url = home_url()
    report = ScenarioReport(name=name, home_url=url)
    print(f"\n=== {name} @ {url} ===")
    try:
        with HomeClient(url) as client:
            code, health = client.health()
            if code != 200:
                report.expect(
                    False,
                    title="home /health",
                    expected="200 OK",
                    observed=f"{code} {health}",
                )
                return report
            fn(client, report)
    except Exception as e:
        report.expect(
            False,
            title="scenario crashed",
            expected="no exception",
            observed=f"{type(e).__name__}: {e}\n{traceback.format_exc()}",
        )
    print(f"=== {name}: {report.status} (pass={report.passes} fail={report.fails}) ===\n")
    return report


def exit_code(report: ScenarioReport) -> int:
    return 1 if report.fails else 0
