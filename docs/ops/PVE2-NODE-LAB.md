# PVE2 OUO node lab

Фактическое состояние стенда на 2026-08-22. Это функциональный baseline для
проверки федерации, а не production-ready secure cluster.

## Хост и VM

- Proxmox node: только `pve2`.
- VMID: `106`, имя `ouo-test-01`.
- Guest: Debian 12 Bookworm.
- Guest IP: `192.168.100.50/24`, gateway `192.168.100.1`.
- VM: 8 vCPU, 24 GiB RAM, системный диск 32 GiB.
- Docker Engine: 29.7.2; Docker Compose: 5.5.0.
- Исходный код в VM: `/opt/ouo-messenger`.
- Базовый source commit: `3ddc867cd642a6d67e9328025964b5daf45bfb25`
  (`messenger-v2/main` на момент развёртывания).
- Пустой дополнительный диск 160 GiB не форматировался и не подключался.
- Tailscale/WireGuard не подключались.

## Топология

Compose-файл: `project/docker-compose.pve2-lab.yml`.

Все сервисы находятся только во внутренней Docker-сети
`ouo-pve2-lab_ouo-control`. Host/public port publishing отсутствует.

| Service | Node ID | Docker endpoint | Persistent volume |
|---|---|---|---|
| Discovery | — | `http://discovery:8003` | `discovery-data` |
| Gateway | `gateway-pve2` | `http://gateway:8007` | `gateway-data` |
| Home A | `home-a` | `http://home-a:8001` | `home-a-data` |
| Home B | `home-b` | `http://home-b:8001` | `home-b-data` |
| Home C | `home-c` | `http://home-c:8001` | `home-c-data` |
| Storage | `storage-pve2` | `http://storage:8002` | `storage-data` |
| Relay | `relay-pve2` | `http://relay:8005` | `relay-data` |
| TURN credential API | `turn-pve2` | `http://turn-api:8006` | `turn-data` |

Discovery не регистрирует саму себя. Остальные семь сервисов регистрируются с
capabilities `gateway`, `home` (три записи), `storage`, `relay`, `turn` и
отправляют heartbeat.

## Режим безопасности baseline

- `ENROLLMENT_MODE=legacy`;
- `INTERNAL_SECURITY_MODE=legacy`;
- `FEDERATION_ENVELOPE_MODE=legacy`;
- Discovery active health checks включены с интервалом 10 секунд;
- heartbeat offline threshold — 120 секунд;
- Home Nodes не объявляют участие в Relay/Storage/Witness;
- registration PoW оставлен включённым (difficulty 4).

Legacy здесь нужен только для первого функционального baseline. В нём L0-ноды
получают `trust_status=trusted` от Discovery без quorum и capability
certificates. Это не соответствует целевой hostile-network модели и не должно
использоваться как production security claim.

## Фактически подтверждённые проверки

| Проверка | Результат |
|---|---|
| Docker containers | 8/8 `Up` |
| `/health` | 8/8 `status=ok` |
| Registration/heartbeat | 7/7 service nodes online |
| Active Discovery probes | 7/7 `health_status=online` |
| Gateway routing | видит Gateway и Home A/B/C; `nearest` выбирается по latency |
| Direct federation | Home A → Home B, HTTP 200, ciphertext сохранён |
| Relay federation | Home A → Relay → Home C, `relay_direct`, ciphertext сохранён |
| Delivery ACK | Home B → Home A, HTTP 200; повторный ACK также 200 |
| Multi-device | второй device Bob зарегистрирован; список содержит 2 устройства |
| Multi-device catch-up | второе устройство получает новое сообщение через `after=` cursor |
| Offline Storage | store → fetch → ACK 204 → empty |
| Home restart persistence | Home B после restart сохранила ciphertext в `/data/home.db` |
| Home failure/rejoin | Home C перешла `offline`, после старта вернулась `online` |
| Discovery outage | прогретый Home A → Home B data plane продолжил доставку |
| Relay outage | прямой Home A → Home B data plane продолжил доставку |
| TURN credential API | выдаёт username/password, TTL 600, UDP/TCP URIs |

Live client smoke test: `project/scripts/pve2-cluster-smoke.py`.

На момент последней проверки суммарное потребление восьми контейнеров было
примерно 488 MiB RAM, CPU около 0.1% на контейнере в idle. Системный диск:
2.7 GiB из 32 GiB (10%).

## Найденные проблемы current main

1. `services/gateway-node/Dockerfile` требует
   `releases/clients/manifest.json`, но файл игнорируется Git и отсутствует в
   чистом clone. В VM установлен минимальный lab manifest без ссылок на старые
   VPS. Канонический tracked manifest или безопасный build fallback ещё нужно
   оформить отдельно.
2. Legacy receiver требует `X-Federation-Node-Id`, а
   `shared/security/http_client.py` его не отправлял в legacy mode. Исправление
   добавлено локально для POST/GET/DELETE; регрессионные тесты:
   `project/tests/security/test_http_client_legacy.py` (3 passed).

Эти изменения находятся в локальной рабочей копии и в VM, но не публиковались
в remote repository.

## Управление и восстановление

Команды выполняются внутри VM:

```bash
cd /opt/ouo-messenger/project

docker compose \
  --env-file .env.pve2-lab \
  -f docker-compose.pve2-lab.yml ps -a

docker compose \
  --env-file .env.pve2-lab \
  -f docker-compose.pve2-lab.yml up -d

docker compose \
  --env-file .env.pve2-lab \
  -f docker-compose.pve2-lab.yml logs --since 10m
```

Повтор live smoke test из Discovery-контейнера:

```bash
docker cp scripts/pve2-cluster-smoke.py \
  ouo-pve2-lab-discovery-1:/tmp/pve2-cluster-smoke.py
docker exec ouo-pve2-lab-discovery-1 \
  python /tmp/pve2-cluster-smoke.py
```

Контролируемый restart одной ноды:

```bash
docker restart ouo-pve2-lab-home-b-1
```

Не выполнять `docker compose down -v`: ключ `-v` удалит persistent volumes.

## Что ещё не подтверждено

- три независимых Discovery и их gossip/quorum;
- strict/signed enrollment, Operational/Capability Certificates и authority
  state в реальном контейнерном стенде;
- mTLS между нодами;
- настоящий coturn media relay через NAT (сейчас проверен только credential API);
- TURN UDP/TCP/relay port range и внешний IP;
- Relay fallback при недоступном прямом Home route;
- Storage redundancy между несколькими Storage Nodes;
- полные replay/downgrade/malicious-node и chaos suites;
- Tailscale/WireGuard admin plane;
- перенос Docker data на дополнительный 160 GiB диск.

До подтверждения этих пунктов стенд нельзя называть готовым secure cluster.
