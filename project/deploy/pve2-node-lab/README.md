# PVE2 OUO node lab

This package describes one isolated Linux VM running 14 OUO logical nodes plus
the coturn data-plane process:

| Role | Count | Per instance | Persistent state |
|---|---:|---:|---|
| Discovery | 3 | 1 vCPU / 512 MiB | registry, ledger, checkpoints |
| Home | 5 | 1 vCPU / 1 GiB | user/home DB, identity and transport keys |
| Relay | 2 | 1 vCPU / 512 MiB | identity keys, replay/link state |
| Storage | 2 | 1 vCPU / 512 MiB | opaque mailbox cells, identity keys |
| Gateway | 1 | 1 vCPU / 384 MiB | identity and invite state |
| TURN API | 1 | 1 vCPU / 384 MiB | identity state |
| coturn | 1 process | 0.5 vCPU / 256 MiB | no message plaintext |

CPU limits are ceilings, not reservations. The recommended VM baseline is
4 physical/vCPU threads, 10 GiB RAM, 80 GiB disk and Debian 12 or Ubuntu 24.04.
Six vCPU and 14–18 GiB RAM are preferable for chaos and concurrent traffic.

## Exposure

The `ouo-internal` Docker network has `internal: true`. Only these endpoints are
bound on the VM host, and all are loopback-only:

- D1 `127.0.0.1:18031`;
- D2 `127.0.0.1:18032`;
- D3 `127.0.0.1:18033`;
- Home A–E `127.0.0.1:18101`–`127.0.0.1:18105`;
- Gateway `127.0.0.1:18080`.

They are intended for an SSH/Tailscale tunnel. The Proxmox panel is not part of
this compose project and must never be published by it.

## Automated strict lab

The isolated lab is provisioned without disabling signed validation or TLS:

```bash
./lab-up.sh
```

После запуска можно создать 25 независимых тестовых пользователей и проверить
100 сообщений между разными Home Node. Клиентские приватные ключи и подробный
отчёт сохраняются только в игнорируемом `runtime/operator`:

```bash
docker compose --env-file runtime/lab.env --profile tools run --rm verifier
```

После перезапуска сервисов сохранность истории и клиентская расшифровка
проверяются повторно:

```bash
docker compose --env-file runtime/lab.env --profile tools run --rm restart-verifier
```

Верификатор шифрует каждое сообщение отдельным X25519 + HKDF + AES-GCM
конвертом и расшифровывает его только приватным ключом получателя. Это проверка
реального зашифрованного транспорта стенда; production-клиент при этом
по-прежнему использует собственный ratchet, а не тестовый формат конверта.

The default command starts the five Home nodes plus three Discovery, two Relay
and two Storage nodes. Gateway and TURN remain optional because their public
TLS/mTLS boundary must be configured separately. The one-shot provisioner
still creates their credentials in advance, so enabling them never reuses a
core node identity.

The one-shot provisioner creates a 5-of-7 authority, a distinct Root,
Operational and Transport identity for every service, and a quorum-signed
Capability Certificate for its role. Runtime credentials and operator-only
validator private keys are written below ignored `runtime/`; they are never
part of the image or Git repository. Re-running `lab-up.sh` preserves the
existing identities. Re-provisioning requires deliberate removal of the lab
volumes and `runtime/` together. The provisioner creates a private lab CA and a
separate TLS certificate for every service. Advertised endpoints use HTTPS/WSS
and `NODE_CHALLENGE_ALLOW_HTTP=false`.

## Persistent boundaries

Every logical node has a separate named volume. Root, Operational, Transport
and Validator keys must never be shared between volumes. Removing/recreating a
container preserves identity; deleting its volume destroys that boundary and
is therefore a destructive operation requiring explicit approval.

Storage is limited in application configuration to 1 GiB of opaque cells per
instance. Docker named volumes themselves do not enforce disk quotas, so the VM
filesystem must also have monitoring and a free-space alert.

## Readiness boundary

Compose `healthy` proves only that a process answers `/health`. Cluster readiness
also requires every Discovery service to expose the full signed peer view.
`lab-up.sh` waits for that condition before starting the data plane; the
verifier then requires every Home to see two signed Relay and two signed Storage
candidates before creating users. Public exposure, DNS, external anti-DDoS and
Proxmox networking remain outside this local package.
