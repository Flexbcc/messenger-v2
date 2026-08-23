# PVE2 OUO node lab

This package describes one isolated Linux VM running 12 OUO logical nodes plus
the coturn data-plane process:

| Role | Count | Per instance | Persistent state |
|---|---:|---:|---|
| Discovery | 3 | 1 vCPU / 512 MiB | registry, ledger, checkpoints |
| Home | 3 | 1 vCPU / 1 GiB | user/home DB, identity and transport keys |
| Relay | 2 | 1 vCPU / 512 MiB | identity keys, replay/link state |
| Storage | 2 | 1 vCPU / 512 MiB | opaque mailbox cells, identity keys |
| Gateway | 1 | 1 vCPU / 384 MiB | identity and invite state |
| TURN API | 1 | 1 vCPU / 384 MiB | identity state |
| coturn | 1 process | 0.5 vCPU / 256 MiB | no message plaintext |

CPU limits are ceilings, not reservations. The recommended VM baseline is
4 physical/vCPU threads, 10 GiB RAM, 80 GiB disk and Debian 12 or Ubuntu 24.04.
Six vCPU and 12–16 GiB RAM are preferable for chaos and concurrent traffic.

## Exposure

The `ouo-internal` Docker network has `internal: true`. Only these endpoints are
bound on the VM host, and all are loopback-only:

- D1 `127.0.0.1:18031`;
- D2 `127.0.0.1:18032`;
- D3 `127.0.0.1:18033`;
- Gateway `127.0.0.1:18080`.

They are intended for an SSH/Tailscale tunnel. The Proxmox panel is not part of
this compose project and must never be published by it.

## Security stages

1. Copy `.env.example` to an untracked `.env` and replace every secret with an
   independently generated value.
2. Start only D1/D2/D3 for genesis/bootstrap.
3. Provision the public Capability/Trust Authority states. Private authority
   keys must remain outside the VM.
4. Enroll every node and place its own Capability Certificate in its own volume.
5. Start the remaining roles. Verify that D1/D2/D3 expose one converged signed
   peer view before enabling validator runtimes.
6. Provision Validator Keys only into selected validator volumes and set the
   validator runtime variables for those containers. The optional
   `compose.validators.yml` maps seven separately provisioned validators; it
   must not be used before their public credentials are in the authority state.
7. Install internal TLS, change every advertised endpoint to HTTPS/WSS and set
   `NODE_CHALLENGE_ALLOW_HTTP=false` before any non-isolated use.

`NODE_CHALLENGE_ALLOW_HTTP=true` is an explicit lab-only bridge because the
application containers currently expose plain HTTP inside the isolated Docker
network. Federation requests remain signed, but HTTP does not hide metadata or
ciphertext from a compromised VM/network namespace. It is not production-safe.

## Persistent boundaries

Every logical node has a separate named volume. Root, Operational, Transport
and Validator keys must never be shared between volumes. Removing/recreating a
container preserves identity; deleting its volume destroys that boundary and
is therefore a destructive operation requiring explicit approval.

Storage is limited in application configuration to 1 GiB of opaque cells per
instance. Docker named volumes themselves do not enforce disk quotas, so the VM
filesystem must also have monitoring and a free-space alert.

## Commands for the approved deployment stage

These commands are documentation only and have not been run:

```bash
cd project/deploy/pve2-node-lab
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d discovery-d1 discovery-d2 discovery-d3
docker compose --env-file .env ps
```

After authority provisioning, the validator override is added explicitly:

```bash
docker compose --env-file .env -f compose.yml -f compose.validators.yml config --quiet
```

Starting all services, generating/provisioning secrets, modifying VM networking
or exposing ports must wait for explicit approval and the read-only VM audit.

## Readiness boundary

Compose `healthy` proves only that a process answers `/health`. Cluster readiness
requires factual logs for registration, heartbeat, three-source convergence,
signed challenge assignments, Relay delivery receipts, Trust votes and ledger
application. Those checks intentionally belong to the later VM test phase and
have not been claimed by this package.
