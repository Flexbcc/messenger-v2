#!/usr/bin/env python3
"""10 — L1: batch persist round-trip for all profile_settings catalog ids."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from catalog_gen import OUT as MATRIX_PATH
from catalog_gen import build as build_matrix
from harness import exit_code, run_scenario
from values import is_lists_key, is_values_key, sample_list_value, sample_value


def _matrix_rows() -> list[dict]:
    if MATRIX_PATH.exists():
        data = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    else:
        data = build_matrix()
        MATRIX_PATH.parent.mkdir(parents=True, exist_ok=True)
        MATRIX_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return [r for r in data["client"] if r.get("storage") == "profile_settings"]


def scenario(client, report) -> None:
    alice = Bot.create(client, role="alice", scenario="persist")
    bob = Bot.create(client, role="bob", scenario="persist")
    rows = _matrix_rows()

    values: dict = {}
    lists: dict = {}
    skipped = 0
    for row in rows:
        # reconstruct minimal setting dict for values.py
        setting = {
            "id": row["id"],
            "type": row["type"],
            "storage": row["storage"],
            "enums": row.get("enums"),
            "default": row.get("default"),
        }
        if is_values_key(setting):
            v = sample_value(setting, variant="primary")
            if v is None:
                skipped += 1
                continue
            values[row["id"]] = v
        elif is_lists_key(setting):
            lists[row["id"]] = sample_list_value(setting, peer_ids=[bob.user_id], variant="one")
        else:
            skipped += 1

    code, put = alice.put_profile_settings(values, lists)
    report.expect(
        code == 200 and put.get("ok") is True,
        title="batch PUT profile-settings",
        expected=f"200 ok, {len(values)} values, {len(lists)} lists",
        observed=f"{code} {put}",
        bot="alice",
    )
    if code != 200:
        return

    code2, got = alice.get_profile_settings()
    report.expect(code2 == 200, title="GET profile-settings", expected="200", observed=str(code2), bot="alice")
    if code2 != 200:
        return

    gvals = got.get("values") or {}
    glists = got.get("lists") or {}

    fail_ids = []
    for kid, want in values.items():
        gotv = gvals.get(kid)
        # JSON may coerce ints; compare loosely for numbers
        ok = gotv == want or (isinstance(want, (int, float)) and gotv == want)
        if not ok:
            fail_ids.append(kid)
            report.expect(
                False,
                title=f"persist {kid}",
                expected=repr(want),
                observed=repr(gotv),
                bot="alice",
            )

    for kid, want in lists.items():
        gotl = glists.get(kid)
        if gotl != want:
            fail_ids.append(kid)
            report.expect(
                False,
                title=f"persist list {kid}",
                expected=repr(want),
                observed=repr(gotl),
                bot="alice",
            )

    matched_v = len(values) - sum(1 for k in values if k in fail_ids)
    matched_l = len(lists) - sum(1 for k in lists if k in fail_ids)
    report.expect(
        len(fail_ids) == 0,
        title="all profile_settings round-trip",
        expected=f"{len(values)} values + {len(lists)} lists match GET",
        observed=f"ok_values={matched_v}/{len(values)} ok_lists={matched_l}/{len(lists)} skipped={skipped} fails={fail_ids[:12]}",
        bot="alice",
    )

    # alt variant spot-check: flip booleans / second enum
    alt_values = {}
    for row in rows:
        setting = {
            "id": row["id"],
            "type": row["type"],
            "storage": row["storage"],
            "enums": row.get("enums"),
            "default": row.get("default"),
        }
        if not is_values_key(setting):
            continue
        if row["type"] in ("boolean", "single_select", "number"):
            alt_values[row["id"]] = sample_value(setting, variant="alt")
    merged = {**values, **alt_values}
    alice.put_profile_settings(merged, lists)
    _, got2 = alice.get_profile_settings()
    g2 = got2.get("values") or {}
    alt_fail = [k for k, w in alt_values.items() if g2.get(k) != w]
    report.expect(
        len(alt_fail) == 0,
        title="alt variant round-trip (bool/select/number)",
        expected=f"{len(alt_values)} alt values match",
        observed=f"fails={alt_fail[:12]} count={len(alt_fail)}",
        bot="alice",
    )


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("10_catalog_persist_roundtrip", scenario)))
