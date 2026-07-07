# 0009. Node Enrollment: Control Plane Discovery

## Статус
Accepted

## Дата
2026-07-06

## Контекст
Discovery Node (ADR-0006) сейчас является открытым каталогом: любая нода
может зарегистрироваться без проверки, heartbeat не аутентифицирован,
статус `online/offline` отражает только давность heartbeat, а не доверие
к оператору узла.

Цель проекта — гибридная децентрализованная сеть, где одна физическая
установка может совмещать роли (Home, Relay, Storage, Turn, Gateway), а
Discovery выступает **Control Plane**: регистрация, доверие, каталог,
мониторинг — без участия в доставке сообщений (data plane).

## Рассмотренные варианты

1. **Переписать Discovery как отдельный «master»-сервис** — отклонено:
   ломает существующую архитектуру и деплой.
2. **mTLS + attestation с первого дня** — отклонено для этапа 1: слишком
   тяжёлый scope; вынесено в roadmap.
3. **Эволюция текущего Discovery** с `trust_status`, `node_token` и режимом
   `ENROLLMENT_MODE=legacy|strict|hybrid` — принято.

## Решение

### Две оси состояния (не смешивать)

| Ось | Поле API | Значения | Хранение |
|-----|----------|----------|----------|
| Доверие | `trust_status` | `pending`, `trusted`, `suspended`, `compromised`, `unknown` | БД |
| Доступность | `reachability` | `online`, `offline` | вычисляется из heartbeat |

Поле `status` в API **сохраняется** как alias для `reachability`
(`online`/`offline`) — обратная совместимость с `federation.py` и клиентом.

### Режимы развёртывания

| `ENROLLMENT_MODE` | Поведение |
|-------------------|-----------|
| `legacy` (default) | Регистрация → сразу `trusted`, token не требуется |
| `strict` | Регистрация → `pending` → approve → `node_token` → heartbeat с Bearer |
| `hybrid` | Известные `node_id` → `trusted`; новые → `pending` |

### Публичный каталог

`GET /registry/nodes` возвращает только ноды с `trust_status=trusted`.
Операторский обзор всех статусов — через admin API (этап 3).

### Этап 1 (реализовано)
- Схема БД + `trust_status` / `reachability` в ответах API
- Режим `legacy` по умолчанию

### Этап 2 (реализовано)
- `strict` / `hybrid`: регистрация → `pending` + `enrollment_secret` (один раз)
- `POST /registry/enrollment/status` — poll с `enrollment_secret`
- Heartbeat: 403 для `pending`; 401 если выдан `node_token` (после approve, этап 3)

### Этап 3 (реализовано)
- Admin API: approve / suspend / reinstate / compromise / grandfather-all
- Admin UI: `/enrollment` + proxy через admin-server

### Этап 4 (реализовано)
- Home/Relay/Storage/Media/Turn `node_registration.py`: сохранение
  `enrollment_secret`, poll `POST /registry/enrollment/status`, claim
  `node_token` в `NODE_TOKEN_PATH`, Bearer на heartbeat

### Этап 5 (реализовано)
- `home-node/app/federation.py`: отбор discovery-кандидатов только с
  `status=online` и `trust_status=trusted`

### Этап 6 (реализовано)
- Attestation: `build_hash`, `release_signature`, `tls_cert_fingerprint`
- `ATTESTATION_MODE` / `MTLS_MODE` на Discovery
- Gateway Node (`gateway-node`, capability `gateway`)
- ADR-0010, `spec/0606_GATEWAY_NODE.md`

### Этап 7 (реализовано, ADR-0010)
- mTLS termination на Gateway (TLS порт 8447)
- Dev PKI: `scripts/generate-mtls-certs.sh`
- Nearest routing: `GET /gateway/routing?strategy=nearest`
- Ed25519 signed releases + HMAC fallback

### Roadmap (вне текущего MVP)

- Flutter client integration (nearest routing, mTLS client cert)
- Remote attestation (TPM/SGX)

## Последствия

- Discovery формально становится Control Plane сети, не меняя data plane.
- Все существующие ноды мигрируют в `trusted` при обновлении схемы.
- `spec/0604_DISCOVERY_NODE.md` и ADR-0006 дополнены ссылкой на этот ADR.
- Home/Relay/Storage/Turn `node_registration.py` будут обновляться поэтапно
  (этапы 2–4), без выноса в shared-модуль на первом шаге.

## Связанные документы

- [ADR-0006](0006-staged-decentralization-bootstrap-authority.md)
- [0604_DISCOVERY_NODE.md](../0604_DISCOVERY_NODE.md)
