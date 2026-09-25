"""Bug list: JSONL + markdown summary under reports/."""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPORTS_DIR = Path(__file__).resolve().parent / "reports"
BUGS_JSONL = REPORTS_DIR / "bugs.jsonl"
BUGS_MD = REPORTS_DIR / "bugs.md"
RUN_SUMMARY = REPORTS_DIR / "last_run.md"


@dataclass
class BugRecord:
    ts: str
    scenario: str
    title: str
    expected: str
    observed: str
    home_url: str
    bot: str = ""
    severity: str = "fail"
    extra: dict[str, Any] = field(default_factory=dict)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_reports_dir() -> Path:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    return REPORTS_DIR


def append_bug(bug: BugRecord) -> None:
    ensure_reports_dir()
    with BUGS_JSONL.open("a", encoding="utf-8") as f:
        f.write(json.dumps(asdict(bug), ensure_ascii=False) + "\n")
    _rewrite_bugs_md()


def record_fail(
    *,
    scenario: str,
    title: str,
    expected: str,
    observed: str,
    home_url: str,
    bot: str = "",
    severity: str = "fail",
    **extra: Any,
) -> BugRecord:
    bug = BugRecord(
        ts=_now(),
        scenario=scenario,
        title=title,
        expected=expected,
        observed=observed,
        home_url=home_url,
        bot=bot,
        severity=severity,
        extra=extra,
    )
    append_bug(bug)
    return bug


def _rewrite_bugs_md() -> None:
    ensure_reports_dir()
    if not BUGS_JSONL.exists():
        BUGS_MD.write_text("# QA bots — bugs\n\n(empty)\n", encoding="utf-8")
        return
    lines = ["# QA bots — bugs", ""]
    with BUGS_JSONL.open(encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            b = json.loads(raw)
            lines.append(
                f"- **{b.get('ts')}** `{b.get('scenario')}` · {b.get('bot') or '—'} — "
                f"**{b.get('title')}**\n"
                f"  - expected: {b.get('expected')}\n"
                f"  - observed: {b.get('observed')}"
            )
    BUGS_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_run_summary(
    *,
    home_url: str,
    results: list[tuple[str, str, int, int]],
) -> Path:
    """results: list of (scenario, status, passes, fails)."""
    ensure_reports_dir()
    lines = [
        "# QA bots — last run",
        "",
        f"- home: `{home_url}`",
        f"- ts: {_now()}",
        "",
        "| Scenario | Status | pass | fail |",
        "|----------|--------|------|------|",
    ]
    for name, status, p, f in results:
        lines.append(f"| `{name}` | {status} | {p} | {f} |")
    lines.append("")
    lines.append(f"Bugs log: `{BUGS_JSONL.relative_to(REPORTS_DIR.parent)}`")
    RUN_SUMMARY.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return RUN_SUMMARY


def clear_run_bugs_marker() -> None:
    """Optional: keep cumulative bugs.jsonl; write a session marker."""
    ensure_reports_dir()
    marker = REPORTS_DIR / "session.txt"
    marker.write_text(f"session_start={_now()}\nhome={os.environ.get('HOME_URL', '')}\n", encoding="utf-8")
