# QA bots — catalog-driven coverage (messenger + node + storage)

Not “9 hand scenarios = full QA”. Coverage is generated from catalogs:

| Layer | Mechanism | Scale |
|-------|-----------|------:|
| L0 | `catalog_gen.py` → `reports/coverage_matrix.json` | 184 + 29 node |
| L1 | `10_catalog_persist_roundtrip` batch PUT/GET | ~all `profile_settings` |
| L2 | `11_privacy_enum_matrix` enum × roles | privacy/contacts |
| L3 | `probes.py` + scenarios 05/07–09 | behavioral |
| L4 | `run_node_smoke` / `run_storage_smoke` | products |

KPI: `reports/coverage_summary.md` (not scenario count).

## Requirements

- Home `:8001`, Discovery `:8003` (for messenger + search probes)
- Optional main-node `:9205` / client `:18011` for node smoke
- Python 3.11+, `httpx`, `websockets`

```bash
# Full product orchestration
./scripts/qa_bots/run_all_products.sh

# Messenger only (01–11)
./scripts/qa_bots/run_messenger_bots.sh

# Refresh matrix
python3 scripts/qa_bots/catalog_gen.py
```

## Scenarios

| # | File | Layer |
|---|------|-------|
| 01–06 | auth, settings, chat, call, security, duplicate | smoke |
| 07–09 | search / calls allowlist / incoming+block | L3 probes |
| 10 | catalog persist round-trip | L1 |
| 11 | privacy/contacts enum matrix | L2 |

## Probes registry

See [`probes.py`](probes.py). Add a probe only when enforcement exists (server or `SettingsRuntime`). Otherwise L1 persist is enough.

## Runners

| Script | Role |
|--------|------|
| `run_all.sh` / `run_messenger_bots.sh` | messenger scenarios |
| `run_node_smoke.sh` | health/panel/ops + planned skip list |
| `run_storage_smoke.sh` | `ppc_smoke/run_unit.sh` (optional `PPC_E2E=1`) |
| `run_all_products.sh` | all of the above + coverage summary |

## Bugs

Failures → `reports/bugs.jsonl` + `bugs.md`.
