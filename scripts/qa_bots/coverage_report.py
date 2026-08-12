#!/usr/bin/env python3
"""Write reports/coverage_summary.md from matrix + last run artifacts."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from catalog_gen import OUT as MATRIX_PATH
from catalog_gen import build as build_matrix
from probes import PROBES

REPORTS = Path(__file__).resolve().parent / "reports"
SUMMARY = REPORTS / "coverage_summary.md"


def main() -> None:
    REPORTS.mkdir(parents=True, exist_ok=True)
    data = build_matrix()
    MATRIX_PATH.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    s = data["summary"]
    client = data["client"]
    node = data["node"]

    persist_ids = [r["id"] for r in client if r["storage"] == "profile_settings" and r["type"] not in ("action", "read_only", "secret")]
    probe_ids = sorted(PROBES.keys())
    gaps = [
        r["id"]
        for r in client
        if r["status"] == "live"
        and r["id"] not in PROBES
        and r["coverage"] in ("persist", "skip")
    ]

    last_run = REPORTS / "last_run.md"
    last_run_txt = last_run.read_text(encoding="utf-8") if last_run.exists() else "(no messenger run yet)"

    node_live = [r for r in node if r.get("status") != "planned"]
    node_skip = [r for r in node if r.get("status") == "planned"]

    lines = [
        "# QA coverage summary",
        "",
        f"- generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
        "## KPI (catalog-driven)",
        "",
        f"| Metric | Value |",
        f"|--------|------:|",
        f"| Client settings | {s['client_total']} |",
        f"| profile_settings (persist L1) | {s['client_profile_settings']} |",
        f"| Wired live (SettingsRuntime) | {s['client_live']} |",
        f"| Verified behavior | {s['client_verified']} |",
        f"| Conditional visibility/enabling | {s['client_conditional']} |",
        f"| Critical security settings | {s['client_critical']} |",
        f"| Local client preferences | {s['client_local_preferences']} |",
        f"| Local secure values | {s['client_local_secure']} |",
        f"| Retired excluded | {s['retired_excluded']} |",
        f"| Stub | {s['client_stub']} |",
        f"| L1 persist keys (excl action/ro/secret) | {len(persist_ids)} |",
        f"| L2 privacy enum×role checks (scenario 11) | ~38 atomic |",
        f"| L3 behavioral probes | {len(probe_ids)} |",
        f"| Live without dedicated probe (expected gaps) | {len(gaps)} |",
        f"| Node catalog available | {'yes' if s['node_catalog_available'] else 'no'} |",
        f"| Node settings | {s['node_total']} |",
        f"| Node live / planned skip | {len(node_live)} / {len(node_skip)} |",
        f"| Messenger scenarios last run | see below (01–11) |",
        f"| Node / storage smoke | `node_smoke.md` / `storage_smoke.md` |",
        "",
        "## Probes (L3)",
        "",
    ]
    for pid, meta in sorted(PROBES.items()):
        lines.append(
            f"- `{pid}` — {meta.get('enforcement')} via `{meta.get('probe')}` "
            f"({meta.get('scenario')})"
        )

    lines += [
        "",
        "## Node planned (skipped)",
        "",
    ]
    for r in node_skip:
        lines.append(f"- `{r['id']}` — planned")

    lines += [
        "",
        "## Messenger last run",
        "",
        "```",
        last_run_txt.strip(),
        "```",
        "",
        "## Gaps note",
        "",
        "Ids in `live` without an L3 probe are still covered by L1 persist round-trip "
        "when `storage=profile_settings`. Add a probe only when server/runtime enforcement exists.",
        "",
        f"Matrix: `{MATRIX_PATH.name}`",
        "",
    ]
    SUMMARY.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Wrote", SUMMARY)


if __name__ == "__main__":
    main()
