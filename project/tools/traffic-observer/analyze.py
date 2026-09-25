#!/usr/bin/env python3
"""Summarize metadata produced by the OUO L4 Traffic Observer."""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any


def percentile(values: list[float], ratio: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * ratio) - 1))
    return round(ordered[index], 3)


def load_events(path: Path) -> list[dict[str, Any]]:
    events = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            event = json.loads(line)
            if not isinstance(event, dict) or not isinstance(event.get("event"), str):
                raise ValueError(f"invalid event at line {line_number}")
            events.append(event)
    return events


def summarize(events: list[dict[str, Any]]) -> dict[str, Any]:
    edges: dict[tuple[str, str], dict[str, Any]] = defaultdict(
        lambda: {
            "flow_events": 0,
            "bytes": 0,
            "sizes": [],
            "timestamps": [],
            "connection_ids": set(),
        }
    )
    durations = []
    errors = 0
    listeners = set()
    for event in events:
        listener = event.get("listener")
        if isinstance(listener, str):
            listeners.add(listener)
        if event["event"] == "flow":
            source, target = event.get("source"), event.get("target")
            size, timestamp = event.get("bytes"), event.get("observed_at")
            if not isinstance(source, str) or not isinstance(target, str):
                continue
            if not isinstance(size, int) or size < 0 or not isinstance(timestamp, (int, float)):
                continue
            edge = edges[(source, target)]
            edge["flow_events"] += 1
            edge["bytes"] += size
            edge["sizes"].append(float(size))
            edge["timestamps"].append(float(timestamp))
            if isinstance(event.get("connection_id"), str):
                edge["connection_ids"].add(event["connection_id"])
        elif event["event"] == "connection_close" and isinstance(event.get("duration_ms"), (int, float)):
            durations.append(float(event["duration_ms"]))
        elif event["event"] == "connection_error":
            errors += 1

    edge_rows = []
    for (source, target), values in sorted(edges.items()):
        timestamps = sorted(values["timestamps"])
        gaps_ms = [
            (timestamps[index] - timestamps[index - 1]) * 1000
            for index in range(1, len(timestamps))
        ]
        edge_rows.append(
            {
                "source": source,
                "target": target,
                "connections": len(values["connection_ids"]),
                "flow_events": values["flow_events"],
                "bytes": values["bytes"],
                "chunk_size_bytes": {
                    "p50": percentile(values["sizes"], 0.50),
                    "p95": percentile(values["sizes"], 0.95),
                    "p99": percentile(values["sizes"], 0.99),
                },
                "inter_event_gap_ms": {
                    "p50": percentile(gaps_ms, 0.50),
                    "p95": percentile(gaps_ms, 0.95),
                    "p99": percentile(gaps_ms, 0.99),
                },
            }
        )
    return {
        "events": len(events),
        "listeners": len(listeners),
        "connection_errors": errors,
        "connection_duration_ms": {
            "p50": percentile(durations, 0.50),
            "p95": percentile(durations, 0.95),
            "p99": percentile(durations, 0.99),
        },
        "observed_edges": edge_rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze OUO Traffic Observer metadata")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = summarize(load_events(args.input))
    encoded = json.dumps(result, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)


if __name__ == "__main__":
    main()
