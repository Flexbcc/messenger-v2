# Аудит «документация vs код» (2026-07-14)

Проверено чтением исходников (код не запускался). Ниже — что РЕАЛЬНО есть,
а что заявлено, но отсутствует/заглушка.

## backend — ~80% (в основном честно)
✅ Реально: 7 сервисов и порты (home 8001 / storage 8002 / discovery 8003 /
media 8004 / relay 8005; turn 8006, gateway 8007/8447; admin 9201); discovery-реестр,
регистрация, heartbeat; резолв UserID→HomeNode; Node Monitor; enrollment;
подпись релизов; федерация + relay retry; vulnerability API (без UI);
health-check loop (`DISCOVERY_HEALTHCHECK_*`); offline threshold env
(`DISCOVERY_OFFLINE_THRESHOLD_SECONDS`).
❌/🔶: `force_upgrade` не enforced; monitor poll/columns hardcoded; admin-settings
JSON не загружается UI; `personal_pc` backend — заглушка.

## frontend — каталог полный, runtime частичный
✅ Реально: E2EE 1:1 и группы; Private Mode + vault AES-GCM-256; data-driven каталог
**184/184** настроек (18 секций); persist `catalog.<id>`; тесты.
❌/🔶: **131** редактируемы в каталоге, **53** placeholder; **~15–25** влияют
на поведение через legacy-экраны; каталог не читается runtime; sync между
устройствами нет.

## client-node — 🟡 ядро работает
✅ Реально: home/storage/relay; registration + heartbeat; `DISCOVERY_NODE_URL`;
`slim-update.sh`; 15 env-настроек implemented (из 29 в спеке).
❌/🔶: 14 planned (assistance, capacity, storage prefs, update prefs);
`setup-node.sh`/`install-node.sh` не для slim; discovery не отдаёт настройки
ноде; security mode = `signed` (не `strict`); media proxy → localhost:8004.

## storage-app — частичная реализация
✅ Headless HTTP: pairing, blob store, quotas, тесты (`app/lib/`, `ppc_server_test.dart`).
❌ Flutter UI, mDNS/relay, encrypted meta.db, audit/GC — нет.

## simulation — скелет
1 пустой `src/__init__.py` + draft `scenarios/example.yaml`. Движок TODO.

---

## Обновление доков/спек (2026-07-14, вторая волна)

Синхронизированы доки и JSON-спеки по результатам полного аудита:

| Файл | Что исправлено |
|------|----------------|
| `frontend/docs/SETTINGS.md` | таблица покрытия 184/131/53/~15–25; sync = целевая; runtime gap |
| `client-node/node-settings-spec.json` | +3 env (STORAGE/RELAY_ID, RESOURCE_POLICY); `signed` не `strict`; registered_status → planned; hybrid enrollment |
| `client-node/README.md`, `docs/SETTINGS.md`, `docker-compose.yml` | убран overclaim «получает настройки»; setup/install ⚠️ |
| `backend/admin-settings-spec.json` | heartbeat/healthcheck/vulnerability → implemented; `signed`; hybrid |
| `backend/docs/SETTINGS.md`, `README.md` | порты, env, vulnerability partial, relay retry done |
| `storage-app/README.md` | статус headless-сервера |
| `WORKSPACE.md` | актуальные цифры и статусы модулей |

## Ранее (2026-07-14, первая волна)
- Каталог настроек клиента: `settings_catalog_controller.dart` + экраны.
- `slim-update.sh` для client-node.
- Relay retry в `home-node/app/federation.py`.
- `status: implemented|planned` в node/admin specs.
- Flutter import fix в `config.dart`.

## Следующий шаг
Поднять backend + client-node и проверить UX установки на практике.
