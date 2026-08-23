# Локальный тестовый кластер нод

## Назначение

`project/scripts/local-node-cluster-test.py` поднимает восемь независимых
uvicorn-процессов только на `127.0.0.1`:

| Процессы | Роль |
|---|---|
| D1, D2, D3 | независимые Discovery DB и signing keys |
| Home A, B, C | отдельные Home DB, Node Root и operational keys |
| Relay | HTTP fallback + persistent binary WebSocket и fail-closed validation |
| Storage | legacy buffer + opaque fixed-cell mailbox, idempotency, TTL и capability ACK |

Порты выдаются ОС динамически. Все DB, keys и логи создаются внутри
`project/test-results/local-node-cluster/<run-id>/`; каталог исключён из Git.
Существующие данные проекта, Docker и Proxmox не затрагиваются.

Последний подтверждённый запуск:
`project/test-results/local-node-cluster/20260822T141248Z-611880f0/summary.json`
— `49/49 PASS`.

## Запуск

Требуется Python 3.11 с зависимостями проекта:

```bash
cd /Users/apple/messenger/project
python3.11 scripts/local-node-cluster-test.py
```

Среда Codex может потребовать отдельное разрешение на bind loopback sockets.
Скрипт всегда завершает временные процессы и сохраняет `summary.json`, даже
если одна из проверок упала.

Полный backend regression suite:

```bash
cd /Users/apple/messenger/project
OUO_PYTHON_BIN=/path/to/python3.11 ./scripts/test-backend.sh
```

## Проверяемый контракт

- регистрация и heartbeat Home/Relay/Storage и двух Discovery peers (7 records);
- live rejection просроченного Operational Certificate в enforce mode;
- replay старого, ещё действующего Operational Certificate после rotation
  отклоняется, а новый operational key остаётся highest-seen;
- валидные Node Identity и NodeAdvertisement reports;
- свежий signed NodeAdvertisement принимается и сохраняется через heartbeat;
- 5-of-7 CapabilityCertificate enforcement для Relay L2 и Storage L4;
- Relay обновляет CapabilityCertificate epoch 1→2 через heartbeat только по
  корректному `previous_hash` и продолжает работать после rotation;
- 5-of-7 TrustRecord promotion и отказ 4-of-7;
- quorum TrustRecord автоматически переносится D1→D2/D3 через background
  pull/retry и независимо появляется в каждом ledger;
- quorum ChallengeAssignment автоматически переносится D1→D2/D3 и повторно
  проверяется каждой репликой;
- quorum RandomnessCheckpoint сначала сходится D1→D2/D3; assignment v2 затем
  принимается только после локального deterministic observer recomputation;
- root-signed Operational Credential state сходится D1→D2/D3, после чего
  portable pull/ACK/observation работает на D2 в high-watermark enforce mode;
- 5-of-7 Operational Credential revocation сходится D1→D2/D3; D2 отклоняет
  старый live key с `403`, а три Discovery сохраняют ACK/TrustObservation,
  подписанные до `effective_at`;
- node-wide TrustRecord revocation сходится D1→D2/D3, исключает subject из
  каталога и блокирует повторную регистрацию с `403`;
- quorum suspension в Authority epoch 2 и явный reinstatement в следующем
  Authority epoch 3 сходятся D1→D2/D3; после reinstatement live admission
  восстанавливается без изменения Level;
- observer получает назначение через D2 по короткоживущему Operational-Key
  proof без bearer secret D1; nonce replay отклоняется, portable ACK принимается;
- подписанный ACK, принятый D2, независимо перепроверяется и фоново сходится в
  append-only журналах D1/D3;
- assignment-bound signed TrustObservation переводит D2 в `completed`, затем
  фоново и независимо воспроизводит completion в D1/D3;
- Home на ASGI-границе возвращает `413` для federation body больше 1 MiB до
  FastAPI JSON parsing и криптографии;
- одинаковый user-signed BootstrapRecord в D1/D2/D3;
- Home A → Home B и exact outer replay rejection;
- signed forwarding через Relay;
- два binary batches в одном authenticated WebSocket и close `4403` на replay;
- Home-side persistent WebSocket adapter: reuse двух batches на одной session;
- реальные Relay/Storage/Discovery synthetic challenges и три подписанных
  privacy-minimized TrustObservation в D1;
- bounded Reliability snapshot без auto-promotion;
- Storage idempotency, restart persistence, legacy ACK deletion и opaque
  fixed-cell mailbox round-trip с endpoint-side decrypt;
- semantic delivery ACK между Home;
- сохранение data plane и доступность D2/D3 при остановленном D1;
- Relay fail closed, если target нельзя подтвердить control plane;
- Home DB после restart;
- OperationalKey rotation Home B с тем же NodeID и успешной доставкой после
  обновления Discovery/cache;
- direct delivery при остановленном Relay;
- quorum equivocation включает persistent governance freeze, но не data plane.

## Что тест пока не доказывает

- независимость операторов/ASN: все процессы находятся на одном Mac;
- Proxmox networking, NAT, firewall, Tailscale/WireGuard и resource limits;
- TURN/cross-NAT и voice;
- реальный network partition, packet loss и bandwidth pressure;
- background gossip/retry Trust Ledger при реальном host/network partition
  (loopback startup/recovery и D1→D2/D3 pull уже проверены);
- TLS termination для настоящего WSS, QUIC, Mix, cover traffic или K-of-N.

Эти свойства нельзя считать готовыми по результатам loopback test.
