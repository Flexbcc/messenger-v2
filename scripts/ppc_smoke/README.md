# PPC smoke tests (storage-app pairing)

Fast unit checks and optional manual E2E helpers for Personal PC (PPC) storage pairing.

> **Not enrollment ops.** Docker smoke here uses `ENROLLMENT_MODE=legacy` for a minimal
> discovery+relay stack. Operator strict/hybrid admission (pending → approve → `node_token`)
> is documented in [`docs/modules/backend/ENROLLMENT-STRICT.md`](../docs/modules/backend/ENROLLMENT-STRICT.md)
> and main-node `:9205/ops`.

## Prerequisites

- **Python 3.11+** with `pytest`, `httpx`, `pynacl`, and `zeroconf` (see `backend/services/home-node/requirements.txt`)
- **Unit tests** — no Docker or running services
- **Integration tests** — storage-app running locally (default port `7345`), a fresh QR pairing payload, and a node Ed25519 seed file

Generate or reuse a node signing key (base64url seed file) for integration runs:

```bash
python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())" > /tmp/node.ed25519.seed
```

## Scripts

| Script | Purpose |
|--------|---------|
| `run_unit.sh` | Fast pytest checks (no Docker) |
| `run_docker_smoke.sh` | Docker integration smoke (discovery + relay) |
| `run_e2e_smoke.sh` | Full local E2E: Docker stack + headless storage-app + pair + blob |
| `run_integration.sh` | Optional E2E pair + blob round-trip when env vars are set |
| `ppc_e2e_pair.py` | Helper: scrape pairing code from headless log → `POST /ppc/pair` |

```bash
./scripts/ppc_smoke/run_unit.sh
./scripts/ppc_smoke/run_docker_smoke.sh   # needs Docker
./scripts/ppc_smoke/run_e2e_smoke.sh      # needs Docker + Flutter/Dart (local-first)
./scripts/ppc_smoke/run_integration.sh   # skips unless env vars present
```

## Docker smoke (relay stack)

Minimal **discovery-node** (8003) + **relay-node** (8005) via `docker-compose.smoke.yml`. Proves the PPC invoke router returns **502 offline** when no storage-app agent is connected. Full pairing/blob E2E still requires **storage-app on the host**.

**Prerequisites:** Docker with Compose v2.

```bash
./scripts/ppc_smoke/run_docker_smoke.sh
```

What it does:

1. `docker compose -f scripts/ppc_smoke/docker-compose.smoke.yml up -d --build`
2. Waits for `GET http://localhost:8005/health`
3. `POST /relay/ppc/test-storage-id/invoke` with `{}` → expects **502** `PPC agent offline`
4. `docker compose down`

Ephemeral state lives under `scripts/ppc_smoke/.data/` (gitignored).

## Full E2E smoke (local-first)

End-to-end check: Docker **discovery + relay**, **headless storage-app** on the host, pairing, LAN blob round-trip, and relay invoke when the agent is online.

**Prerequisites:**

- Docker with Compose v2
- **Flutter SDK** (includes Dart) — `storage-app/app` depends on the Flutter SDK even for headless mode
- Python 3.11+ with `httpx` and `pynacl`

```bash
./scripts/ppc_smoke/run_e2e_smoke.sh
```

What it does:

1. `docker compose -f scripts/ppc_smoke/docker-compose.smoke.yml up -d --build`
2. Waits for relay `GET /health`; confirms invoke returns **502 offline** before the agent connects
3. Starts headless storage-app in the background with:
   - `PPC_INSECURE_KEYS=1`
   - `PPC_ROOT=scripts/ppc_smoke/.data/ppc`
   - `PPC_PORT=7345`
   - `PPC_RELAY_URL=http://localhost:8005`
   - `PPC_STORAGE_NODE_ID=smoke-storage-pc`
   - `PPC_DISCOVERY_URL=http://localhost:8003`
4. Waits for `GET http://127.0.0.1:7345/ppc/health`
5. Waits for relay agent WS → `POST /relay/ppc/smoke-storage-pc/invoke` with `GET /ppc/health` returns **200** (not 502)
6. Generates node Ed25519 seed under `.data/node.ed25519.seed`
7. `ppc_e2e_pair.py` — reads `pairing-код` from headless log → `POST /ppc/pair`
8. `ppc_blob_smoke.py` — PUT/GET blob via LAN (`127.0.0.1:7345`) and via relay
9. Tears down storage-app and `docker compose down`

Headless log: `scripts/ppc_smoke/.data/storage-app-headless.log`.

Override defaults with the same `PPC_*` env vars storage-app uses (`PPC_RELAY_URL`, `PPC_STORAGE_NODE_ID`, `PPC_DISCOVERY_URL`, `PPC_PORT`, `PPC_ROOT`, `PPC_USER_ID`).

> **CI:** GitHub Actions runs unit tests on every push and Docker relay smoke (`502 offline`) on `workflow_dispatch`. Full E2E is **local-first** because it needs Flutter + a long-running headless process. Optional CI E2E is available via workflow input `run_e2e: true` (see below).

## Manual E2E steps

1. **Start storage-app** on your PC and open the pairing screen (QR / 6-digit code).

2. **Copy the pairing payload** — JSON with `"kind": "ouo_ppc_pair"` (from QR decode or storage-app UI).

3. **Pair** (bypasses owner panel, calls `POST /ppc/pair` directly):

   ```bash
   python3 storage-app/tools/ppc_pair_smoke.py \
     --payload /tmp/ppc_pair.json \
     --user-id alice \
     --signing-key /path/to/node.ed25519.seed
   ```

   Or set env vars and use the integration runner:

   ```bash
   export PPC_PAIR_PAYLOAD_FILE=/tmp/ppc_pair.json
   export PPC_USER_ID=alice
   export NODE_SIGNING_KEY=/path/to/node.ed25519.seed
   ./scripts/ppc_smoke/run_integration.sh
   ```

4. **Blob round-trip** (after successful pair):

   LAN-direct:

   ```bash
   python3 storage-app/tools/ppc_blob_smoke.py \
     --user-id alice \
     --signing-key /path/to/node.ed25519.seed \
     --lan-hint 192.168.1.42:7345
   ```

   Relay fallback:

   ```bash
   python3 storage-app/tools/ppc_blob_smoke.py \
     --user-id alice \
     --signing-key /path/to/node.ed25519.seed \
     --relay-url https://relay.example.org \
     --storage-node-id storage-home-pc
   ```

   Or via env:

   ```bash
   export PPC_LAN_HINT=192.168.1.42:7345
   # or: export PPC_RELAY_URL=... PPC_STORAGE_NODE_ID=...
   ./scripts/ppc_smoke/run_integration.sh
   ```

## Integration environment variables

| Variable | Required for | Description |
|----------|--------------|-------------|
| `PPC_PAIR_PAYLOAD` | pair | Inline pairing JSON string |
| `PPC_PAIR_PAYLOAD_FILE` | pair | Path to pairing JSON file (used if `PPC_PAIR_PAYLOAD` unset) |
| `PPC_USER_ID` | pair, blob | Node/user id sent as peer id |
| `NODE_SIGNING_KEY` | pair, blob | Path to node Ed25519 seed file |
| `PPC_LAN_HINT` | blob (LAN) | e.g. `192.168.1.42:7345` |
| `PPC_RELAY_URL` | blob (relay) | Relay base URL |
| `PPC_STORAGE_NODE_ID` | blob (relay) | Storage-app node id on relay |

Pair step runs when `PPC_USER_ID`, `NODE_SIGNING_KEY`, and (`PPC_PAIR_PAYLOAD` or `PPC_PAIR_PAYLOAD_FILE`) are set. Blob step runs when those are set **and** (`PPC_LAN_HINT` or both `PPC_RELAY_URL` + `PPC_STORAGE_NODE_ID`).

## CI

GitHub Actions workflow `.github/workflows/ppc-smoke.yml`:

| Trigger | Jobs |
|---------|------|
| **push** (path-filtered) | `unit` — `run_unit.sh` |
| **workflow_dispatch** | `unit`, `docker-smoke` (`run_docker_smoke.sh`), optional `e2e-smoke` |

- **docker-smoke** — relay router only (502 when no agent); no Flutter/Dart.
- **e2e-smoke** — runs only when `run_e2e: true` on manual dispatch; installs Flutter and runs `run_e2e_smoke.sh`. Prefer running E2E locally for faster iteration.

Integration (`run_integration.sh`) is skipped in CI unless secrets/env are configured.

See also: `storage-app/docs/PAIRING-FLOWS.md`, `storage-app/docs/WIRE.md`.
