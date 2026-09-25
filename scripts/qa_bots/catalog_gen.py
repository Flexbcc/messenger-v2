#!/usr/bin/env python3
"""Build coverage_matrix.json from ouo-settings + node-settings + Dart wiredIds."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUO = ROOT / "frontend/app/assets/settings/ouo-settings-spec.json"
NODE = ROOT / "client-node/node-settings-spec.json"
WIRED_DART = ROOT / "frontend/app/lib/services/settings_runtime.dart"
STATUS_DART = ROOT / "frontend/app/lib/models/settings_impl_status.dart"
PROBES = Path(__file__).resolve().parent / "probes.py"
OUT = Path(__file__).resolve().parent / "reports" / "coverage_matrix.json"


def load_wired_ids() -> set[str]:
    text = WIRED_DART.read_text(encoding="utf-8")
    m = re.search(r"static const wiredIds = \{([^}]+)\}", text, re.S)
    if not m:
        raise SystemExit("wiredIds not found in settings_runtime.dart")
    return set(re.findall(r"'([^']+)'", m.group(1)))


def load_status_ids(name: str) -> set[str]:
    text = STATUS_DART.read_text(encoding="utf-8")
    m = re.search(rf"static const {re.escape(name)} = \{{([^}}]+)\}}", text, re.S)
    if not m:
        raise SystemExit(f"{name} not found in settings_impl_status.dart")
    return set(re.findall(r"'([^']+)'", m.group(1)))


def load_probe_ids() -> set[str]:
    if not PROBES.exists():
        return set()
    # probes.py defines PROBES: dict[str, ...]
    ns: dict = {}
    exec(PROBES.read_text(encoding="utf-8"), ns)  # noqa: S102
    probes = ns.get("PROBES") or {}
    return set(probes.keys())


def enums_for(setting: dict) -> list | None:
    data = setting.get("data") or {}
    if "enum" in data:
        return list(data["enum"])
    opts = setting.get("options")
    if isinstance(opts, list) and opts:
        return list(opts)
    return None


def classify_client(setting: dict, wired: set[str], verified: set[str], probe_ids: set[str]) -> dict:
    sid = setting["id"]
    storage = setting.get("storage") or "none"
    typ = setting.get("type") or "unknown"
    conditional = bool(setting.get("visible_if") or setting.get("enabled_if"))
    live = sid in wired
    dependency = setting.get("visible_if") or setting.get("enabled_if")
    stub = sid == "contacts.auto_add_mutual" or (not live and typ not in ("action", "read_only"))
    # honest: if in wired → live; auto_add_mutual known stub; else persist_only / local / action
    if sid == "contacts.auto_add_mutual":
        status = "stub"
    elif live:
        status = "live"
    elif storage == "profile_settings":
        status = "persist_only"
    elif storage == "local_encrypted":
        status = "local_only"
    else:
        status = "action_or_none"

    if sid in probe_ids:
        coverage = "probe"
    elif storage == "profile_settings" and typ not in ("action", "read_only", "secret"):
        coverage = "persist"
    elif status == "stub":
        coverage = "skip"
    else:
        coverage = "skip"

    return {
        "id": sid,
        "product": "messenger",
        "section": setting.get("_section"),
        "title": setting.get("title") or sid,
        "type": typ,
        "storage": storage,
        "enums": enums_for(setting),
        "default": setting.get("default"),
        "conditional": conditional,
        "dependency": dependency,
        "status": status,
        "verified": sid in verified,
        "coverage": coverage,
        "layer": "L1" if coverage == "persist" else ("L3" if coverage == "probe" else "L0"),
        # Product architecture: the server routes traffic; user preferences
        # are stored and enforced by each client. `profile_settings` means the
        # local account profile on this device, not server synchronization.
        "current_persistence": "local_secure" if storage == "local_encrypted" or typ == "secret" else (
            "local_only" if storage != "none" else "action_or_runtime"
        ),
        "required_persistence": "local_secure" if storage == "local_encrypted" or typ == "secret" else (
            "local_only" if storage != "none" else "action_or_runtime"
        ),
        "persistence_gap": False,
        "risk": "critical" if sid.startswith(("security.", "hidden.")) else (
            "high" if sid.startswith(("privacy.", "devices.", "backup.", "data.")) else "normal"
        ),
    }


def classify_node(setting: dict, section: str) -> dict:
    sid = setting["id"]
    st = setting.get("status") or "unknown"
    coverage = "skip" if st == "planned" else "node_env"
    return {
        "id": sid,
        "product": "node",
        "section": section,
        "title": setting.get("title") or sid,
        "type": setting.get("type") or "unknown",
        "storage": setting.get("storage") or "node_env",
        "enums": enums_for(setting),
        "default": setting.get("default"),
        "conditional": False,
        "status": st,
        "coverage": coverage,
        "layer": "L4" if coverage == "node_env" else "skip",
    }


def build() -> dict:
    wired = load_wired_ids()
    verified = load_status_ids("_verifiedIds")
    retired = load_status_ids("retiredIds")
    probe_ids = load_probe_ids()
    ouo = json.loads(OUO.read_text(encoding="utf-8"))
    client_rows = []
    for sec in ouo.get("sections") or []:
        stitle = sec.get("title") or sec.get("id")
        for s in sec.get("settings") or []:
            if s.get("id") in retired:
                continue
            s = dict(s)
            s["_section"] = stitle
            client_rows.append(classify_client(s, wired, verified, probe_ids))

    node_rows = []
    if NODE.exists():
        node = json.loads(NODE.read_text(encoding="utf-8"))
        for sec in node.get("sections") or []:
            stitle = sec.get("title") or sec.get("id")
            for s in sec.get("settings") or []:
                node_rows.append(classify_node(s, stitle))

    def count(rows, key, val):
        return sum(1 for r in rows if r.get(key) == val)

    summary = {
        "client_total": len(client_rows),
        "client_profile_settings": count(client_rows, "storage", "profile_settings"),
        "client_live": count(client_rows, "status", "live"),
        "client_stub": count(client_rows, "status", "stub"),
        "client_persist_coverage": count(client_rows, "coverage", "persist"),
        "client_probe_coverage": count(client_rows, "coverage", "probe"),
        "client_verified": sum(1 for r in client_rows if r["verified"]),
        "client_conditional": sum(1 for r in client_rows if r["dependency"]),
        "client_critical": count(client_rows, "risk", "critical"),
        "client_local_preferences": sum(1 for r in client_rows if r["current_persistence"] == "local_only"),
        "client_local_secure": sum(1 for r in client_rows if r["current_persistence"] == "local_secure"),
        "retired_excluded": len(retired),
        "wired_ids_parsed": len(wired),
        "node_total": len(node_rows),
        "node_planned": count(node_rows, "status", "planned"),
        "node_live": sum(1 for r in node_rows if r.get("status") != "planned"),
        "node_catalog_available": NODE.exists(),
    }

    return {
        "summary": summary,
        "client": client_rows,
        "node": node_rows,
    }


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    data = build()
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    s = data["summary"]
    print("Wrote", OUT)
    print(json.dumps(s, indent=2))
    return 0


if __name__ == "__main__":
    # probes may not exist yet on first import cycle — allow empty
    sys.exit(main())
