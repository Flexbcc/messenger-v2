# Ops: Enrollment strict (Post-R5)

Default Discovery `ENROLLMENT_MODE=legacy` auto-trusts every registering node (open Sybil).  
For production / shared clusters use **`strict`** (or `hybrid`).

## Env (Discovery on MAIN)

```bash
ENROLLMENT_MODE=strict
DISCOVERY_ADMIN_SECRET=<long-random>
```

Restart discovery-node. Existing nodes: use Admin → grandfather-all once if migrating from legacy, then new nodes stay `pending` until approve.

## Compromised recovery

Admin → node → **Ре-энролл** (`POST /admin/registry/nodes/{id}/re-enroll`) → give `enrollment_secret` to node operator → approve again.

See: [`R5-security-as-is.md`](../reality/R5-security-as-is.md), ADR-0009.
