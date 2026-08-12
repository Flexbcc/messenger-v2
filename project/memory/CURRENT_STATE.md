# CURRENT_STATE

_Обновлено: 2026-08-12. Источник истины — файлы, не эта заметка._

> Примечание к разделу «Заглушки» ниже: он сохранён как история состояния на
> 2026-07-23. В текущем клиенте WebRTC-звонки подключены к UI и AppController,
> Private Mode включает защищённую навигацию, основной/ложный PIN, скрытые
> чаты и duress-сценарии, а настройки аккаунта, оформления и помощи имеют
> рабочие экраны. Production-каналом остаётся PWA; macOS и Android являются
> внутренними тестовыми сборками.

## Реализовано и проверено

### Спецификация
- `spec/` — 32 md-документа (0000–0900) + 6 ADR + webview для чтения.

### Деплой (2026-07-06)
- `docker-compose.yml` (корень репо) + `Dockerfile` в каждом из 6 сервисов (`home/storage/discovery/media/relay/turn-node`) + `.env.example` + `scripts/setup-node.sh` (интерактивный: выбор роли, автоопределение LAN IP, запись `.env`, `docker compose up`) + `DEPLOY.md` (инструкция под топологию "1 главный ПК + N машин с нодами в одной локалке").
- Живьём проверено сборкой полного стека в Docker (`docker compose up --build` всех 6 сервисов + admin): все регистрируются в discovery, `/health` у всех отвечает.
- **Найдено и починено контейнеризацией**: `storage-node`/`media-node`/`relay-node` использовали `httpx` в `node_registration.py`, но не указывали его в своём `requirements.txt` — маскировалось локально общим `.venv` (там был httpx ради home-node). Добавлено в `requirements.txt` всех трёх.
- **Найдено и починено при тесте гонки старта**: `_register_once()` раньше падала один раз, если discovery ещё не поднялась (машины/контейнеры не гарантированно стартуют в одном порядке) — нода больше никогда не появлялась в реестре. Теперь `_register_with_retry()` (`app/node_registration.py`, во всех 5 не-discovery сервисах) ретраит с backoff 2с→30с, пока discovery не ответит; `_heartbeat_once()` при 404 (discovery потеряла БД/перезапустилась с нуля) сама перерегистрируется вместо вечных безуспешных heartbeat. Проверено: остановил discovery, все 5 ушли в ретраи, поднял discovery — все сами вернулись в реестр без ручных действий.
- Не сделано: TLS между нодами, авторизация admin/health/turn-credentials эндпоинтов, репликация/бэкап SQLite — см. DEPLOY.md → Известные ограничения.

### Backend (Python/FastAPI, SQLite, порты 8001–8005)
- **home-node** (8001) — регистрация (телефон+имя обяз., логин/email опц., пароль — ADR-0007) + Ed25519 challenge-response (per-device), `/auth/login` по идентификатору+паролю (создаёт новое Device при входе с нового устройства), чаты/группы, отправка/история сообщений, WebSocket, prekey-bundle, федерация.
- **storage-node** (8002) — буфер офлайн-сообщений (TTL).
- **discovery-node** (8003) — резолв UserID→HomeNode; реестр нод с heartbeat + статус online/offline + версия ПО.
- **media-node** (8004) — upload/download зашифрованных файлов.
- **relay-node** (8005) — реальная пересылка Packet (fallback при недоступности прямой доставки).
- Federation relay selection (`home-node/app/federation.py: _find_relay_url`/`_fastest_reachable`, 2026-07-06) исправлено: раньше брался первый `online` relay из списка Discovery (порядок регистрации, не реальная доступность/скорость) — тот самый пробел "нет retry across relays" из прошлой сессии. Теперь все online-кандидаты пингуются `/health` параллельно, побеждает первый ответивший; недоступный/медленный relay просто проигрывает гонку. Проверено вручную: 3 relay-кандидата с искусственными задержками 0.1/1.0/3.0с (прокси), медленный зарегистрирован в Discovery первым — выбран быстрый за 0.13с. Полный E2E федеративный сценарий (прямая доставка таймаутит за 5с → relay fallback укладывается в свои 10с) тоже проверен с искусственной 6с-задержкой на прямом пути.
- Все 4 не-discovery ноды саморегистрируются + heartbeat в discovery (ADR-0006). Все 5 сервисов (включая relay/storage/media, добавлено 2026-07-06) теперь с CORS — нужно для админки, которая бьёт `/health` каждой ноды напрямую из браузера.
- Каждая нода отдаёт в `/health` поле `load` с self-reported метрикой нагрузки (2026-07-06): home — online_users/active_ws_connections; relay — forwarded_count; storage — buffered_count; media — files_count/bytes_total; discovery — registered_nodes/registered_users.
- `admin/` — Node Monitor (read-only таблица нод) расширен (2026-07-06): колонки **Пинг** (браузер меряет RTT до каждой ноды напрямую через `fetch(/health)`, цветовой индикатор good/ok/bad/недоступен) и **Нагрузка** (форматированная load-метрика по роли), плюс инлайн-спарклайны истории для обоих (`admin/app.js`: `history` Map в памяти браузера, до 40 последних замеров на ноду ≈3.3 мин при 5с-поллинге, сбрасывается при перезагрузке страницы — сознательно не персистентно, это всё ещё read-only bootstrap-инструмент без бэкенда для хранения метрик). Живьём проверено на 7 нодах — статусы/версии/пинг/нагрузка корректны для всех 5 основных сервисов, тренд на графике реально двигается (проверено: серия `/relay/forward` подняла `forwarded_count` 0→3, ступенька видна на спарклайне relay-local в реальном времени). 2 доп. relay-фикстуры из прошлых тестовых сессий недоступны для пинга — запущены со старым кодом без CORS, не перезапускались.

### Client (Flutter, web-first, реально работает)
- E2EE 1-на-1 через `libsignal_protocol_dart` (X3DH+Double Ratchet). Тесты: `test/crypto_roundtrip_test.dart`, `test/live_backend_integration_test.dart`.
- Дизайн-система: `lib/theme/` (colors/typography/spacing) + `lib/widgets/` (AppButton, AppTextField, AppAvatar, AppListTile, StatusDot, UnreadBadge). Стиль: чёрно-белый iOS/Apple HIG.
- **Групповое E2EE реализовано** (sender-key, spec/0301): `CryptoService.createGroupSenderKeyDistribution/processGroupSenderKeyDistribution/encryptGroup/decryptGroup` (libsignal_protocol_dart group-примитивы). Распространение ключа — через скрытые control-сообщения (`content_type=sender_key_distribution`) в 1:1-сессии с каждым участником, один раз за сессию на группу (`AppController._distributeGroupKeyIfNeeded`). Отправка в группах включена. Тест: `test/group_crypto_test.dart`.
- Экраны реальные: onboarding, чаты, чат (текст+фото, теперь и группы), новый чат/группа, профиль, настройки.

## Заглушки (UI есть, backend/логики нет)
- Звонки — UI (`calls_screen.dart`) по-прежнему полностью моковый (не подключён к реальной логике). Но сигналинг реализован и работает целиком, кроме самого WebRTC/медиа:
  - `lib/calls/call_signal.dart` — модель + типы `call_offer/answer/ice_candidate/reject/cancel/end/busy`.
  - `lib/calls/call_signaling_service.dart` — encode/decode поверх уже существующей 1:1 E2EE-сессии `CryptoService`, без сети (сеть — за `AppController`, по образцу `_distributeGroupKeyIfNeeded`).
  - `lib/calls/active_call.dart` — `ActiveCall`: in-memory состояние одного текущего звонка (callId, peer, kind, outgoing/answered, remoteSdp, pendingRemoteIceCandidates) для будущего UI/WebRTC.
  - `AppController.currentCall` + методы `startCall/answerCall/sendIceCandidate/rejectCall/cancelCall/endCall` — реально шлют/принимают эти сигналы через `_api.sendMessage`/WebSocket. Входящие `call_offer`, когда уже есть текущий звонок, автоматически отвечают `call_busy`. `_onRealtimeEvent`/`loadHistory` декодируют/маршрутизируют `call_*`, не показывая как чат-пузырь.
  - Тест: `test/call_signaling_test.dart` (4 кейса, encode/decode-уровень, зелёные). Полный цикл `AppController` (startCall→answerCall→ICE→endCall) вручную проверен живым прогоном против настоящего backend (одноразовый скрипт, не оставлен в репозитории) — работает end-to-end.
  - **Известное ограничение теста**: `CryptoService.loadOrCreate()`/`AuthKeyPair.loadOrCreate()` используют нена­мещённые (глобальные) ключи `SharedPreferences` — два реальных `AppController` в одном процессе делят одну и ту же identity, поэтому постоянный автотест на два полных `AppController` писать нельзя (та же причина, по которой `live_backend_integration_test.dart` тестирует `ApiClient`+`CryptoService.ephemeral()` напрямую, а не через `AppController`).
  - **Turn Node сделан** (2026-07-06): `services/turn-node/` — новая FastAPI-нода, self-registration+heartbeat в Discovery (`capabilities=["turn"]`, паттерн ADR-0006 скопирован из relay-node), `POST /turn/credentials` выдаёт временные TURN-креды по стандартной схеме "TURN REST API" (shared secret + HMAC-SHA1, совместимо с coturn `use-auth-secret`). Живьём проверено: `/health`, выдача credentials (HMAC сверен независимым расчётом), появление в `discovery-node` по `?capability=turn`. **Сама ретрансляция медиа (RFC 8656) не реализована этим сервисом и не будет** — осознанно, нужен реальный coturn рядом с тем же `TURN_SHARED_SECRET` (см. `services/turn-node/README.md`), это отдельная задача деплоя, не блокирует остальную работу. Endpoint `/turn/credentials` без авторизации вызывающего (как у media-node upload) — смягчается только коротким TTL, см. README → известное ограничение.
  - **WebRTC интегрирован** (2026-07-06): `flutter_webrtc` подключён (`pubspec.yaml`). `lib/calls/call_media_controller.dart` — `CallMediaController`, единственный модуль, трогающий flutter_webrtc напрямую (по аналогии с `CryptoService` для libsignal): создание `RTCPeerConnection`+`getUserMedia`, offer/answer, буферизация ICE-кандидатов до `setRemoteDescription`, upstream `connectionState` (`connecting/connected/disconnected/failed/closed`, упрощено из `RTCIceConnectionState`).
    - `ActiveCall` расширен: `media` (`CallMediaController?`), `waitingForNetwork` (bool, отдельно от `answered`/`outgoing`), `reconnectTimer`.
    - `AppController.startCall(peerUserId, kind)`/`answerCall()` больше не принимают `sdp` снаружи — сами создают `CallMediaController` (с ICE-серверами из `_resolveIceServers()`: STUN всегда + TURN-креды с первой online-ноды `capability=turn` через Discovery, если доступна — иначе тихо STUN-only) и сами генерируют offer/answer. Локальные ICE-кандидаты уходят в сигналинг автоматически (`_wireMedia`), публичного `sendIceCandidate` больше нет.
    - **Устойчивость к сети реализована** (spec/0303_CALLS.md → «Устойчивость соединения», пользовательское требование от 2026-07-06): `disconnected` → `waitingForNetwork=true` + `restartIce()` + таймер 20с (`_networkRecoveryTimeout`), НЕ шлёт `call_end`. `connected` после этого → сброс. Только `failed` (сразу или по таймауту без восстановления) реально завершает звонок (`_teardownAfterMediaFailure`, шлёт `end`/`cancel`/`reject` по фазе звонка).
    - `ApiClient.findNodes(capability)`/`fetchTurnCredentials(url)` — новые методы (Discovery + Turn Node напрямую), `AppConfig.discoveryNodeUrl` добавлен.
    - **Границы проверки**: `flutter analyze` чист, весь permanent test suite зелёный (не задет — ни один тест не касался старых сигнатур `startCall/answerCall`, т.к. постоянного теста на них не было, см. ограничение выше). `flutter build web` собирается чисто с `flutter_webrtc`; живой смоук в браузере (`messenger-web`, порт 9100) — приложение грузится, никаких ошибок в консоли/failed network после добавления зависимости. **Реальный аудио/видео звонок между двумя вкладками НЕ проверен** — `calls_screen.dart` всё ещё не имеет кнопки/UI для вызова `startCall`/`answerCall`, а `flutter_webrtc` не работает под `flutter test` (нужен настоящий браузер/устройство с платформенными каналами) — таким образом настоящая проверка живого звонка ждёт следующего шага (UI).
  - Не сделано: реальный coturn-процесс, UI (`calls_screen.dart` не подключён к `currentCall`, входящий/текущий звонок нечем показать пользователю).
- Настройки: Уведомления и автозагрузка (Данные и хранилище) теперь реально сохраняются локально (`LocalSettingsStore`, SharedPreferences) — не синхронизируются с бэкендом (нет API). Устройства/сеть/размер кэша — по-прежнему мок.
- Аккаунт/Оформление/Помощь/О приложении в Настройках — snackbar-заглушки.
- Групповые чаты: создаются, отправка отключена в UI (нет групповой крипто-схемы).
- Private Mode / Secret Room (`lib/screens/private_mode/`) — UI мок, но PIN теперь персистентный: Argon2id-хэш в SharedPreferences (не plaintext), переживает перезапуск. Хранилище скрытых чатов/сообщений по-прежнему НЕ зашифровано отдельно — это большая отдельная задача с обязательным security review (см. spec/0402 → Требования к реализации), не сделана.

## Федерация (Фазы 2.1–2.4, реализовано 2026-07-23)

Полный статус — см. `docs/FEDERATION.md`. Кратко:

- **Фаза 2.1 — Подписанные User Records**: Discovery подписывает запись `user_id→home_node_url` Ed25519 (PyNaCl). Home-node проверяет подпись перед использованием записи — атакующий, скомпрометировавший Discovery, не может молча перенаправить трафик. Файлы: `services/discovery-node/app/record_signer.py`, `shared/security/record_verifier.py`, `GET /discovery-pubkey`. Fail-open: нет подписи → предупреждение + принять (совместимость со старым Discovery), неверная подпись → отказ.

- **Фаза 2.2 — Multi-hop Relay**: цепочка `direct → L1 relay → L2 hub`. `hop_count` передаётся в relay-payload; relay-node при неудаче прямой доставки (hop=1) запрашивает L2-хабы у Discovery (trust_level≥2) и пересылает с hop=2. Хаб не эскалирует дальше (MAX_HOPS=2, защита от петель). Файлы: `services/relay-node/app/main.py`, `shared/security/payload_builder.py`.

- **Фаза 2.3 — Latency-aware routing**: Discovery измеряет RTT при каждом health-check и сохраняет в `latency_ms`. Home-node сортирует relay-кандидатов по `latency_ms` перед ping-гонкой — быстрый relay выигрывает детерминированнее. Файлы: `services/discovery-node/app/health.py`, `services/home-node/app/federation.py`.

- **Фаза 2.4 — Backup routes + notify при смене Home**: если все пути доставки (direct + relay + hub) упали — сообщение немедленно буферизуется в Storage Node (`_buffer_envelope_for_recipients`), а durable outbox ретраит асинхронно. При ретрае outbox: если Discovery вернул новый home_node_url — WS `home_changed` пушится локальным контактам. Файлы: `services/home-node/app/federation.py`, `services/home-node/app/outbox.py`.

- **Trust levels (Фаза 1, реализована ранее)**: L0=local-only (нет транзита), L1=relay-eligible, L2=hub. Продвижение — вручную через admin UI после статистики. Пороги: L0→L1: 1000 сообщений + 3 дня + <5% ошибок; L1→L2: 5000 + 14 дней + <2%. Метрики CPU/RAM/диск/uptime/ws-соединений в heartbeat. История продвижений в `trust_level_history`.

- **Биометрия удалена**: из всех экранов и состояния (`pin_setup_screen.dart`, `unlock_screen.dart`, `privacy_settings_screen.dart`, `privacy_pin_section_screen.dart`, `private_mode_state.dart`, `pin_keypad.dart`).

## Тесты (2026-07-23)

- **`tests/test_federation_chain.py`** — интеграционный тест цепочки федерации (Task #37, завершён). Без Docker/сети, чистый unit-уровень:
  - `TestSignedUserRecords` (5 тестов) — Ed25519 sign+verify: корректная подпись, подмена URL, чужой ключ, изменённая подпись, base64url без padding.
  - `TestHopCountGuard` (3 теста) — `build_relay_forward_payload`: hop_count в payload, default=1, кастомное значение.
  - `TestTrustDegradation` (4 теста) — порог офлайн-деградации: L2≥7д, L2<7д, L1≥14д, L0 не деградирует.
  - `TestRateLimit` (4 теста) — скользящее окно: в лимите, за лимитом, истечение окна, разные origins независимы.
  - `TestMeshHeartbeatUpdate` (3 теста) — `update_mesh_from_heartbeat_response`: пиры добавляются, пустой ответ=0, self_node_id исключается.
  - `TestLatencySort` (2 теста) — сортировка relay по latency_ms, None → inf (последний).
  - `TestBufferFallback` (1 тест) — buffer_for_offline_user вызван для каждого получателя кроме отправителя.

## Реализовано в сессии 3 (2026-07-23)

- **#40 Nonce cleanup** — `shared/security/nonce_cleanup.py`: фоновый asyncio-loop, purge каждые 5 мин (настраивается `NONCE_CLEANUP_INTERVAL_SECONDS`). Подключён в `on_startup` всех нод.
- **#41 Buffer eviction** — `BUFFER_EVICTION_POLICY=reject|fifo` (env). FIFO удаляет старейшее сообщение при переполнении; reject возвращает 429. Лимит `BUFFER_MAX_ENTRIES_PER_RECIPIENT`.
- **#42 Federation counters** — `_fed_counters` (direct_ok/relay_ok/buffer_ok/failed) в `home-node/app/federation.py`, отдаются в `/health` → `load.federation`. Виджет в `admin/nodes.html`.
- **#43 Audit log** — `discovery-node/app/audit.py`: таблица `admin_audit_log`, IP-трекинг (X-Forwarded-For) всех admin-действий. Страница `admin/audit.html`.
- **#44 Key rotation** — `discovery-node/app/key_rotation.py`: rotating/retiring ключи с grace period (3 дня). `GET /discovery-pubkeys` возвращает все действующие. `POST /admin/discovery/rotate-key`.
- **#45 Delivery status** — `Message.delivery_status` (sent/delivered/read) + `delivered_at`/`read_at`. `PATCH /{conv}/messages/{id}/status` — идемпотентный (статус только растёт), WS-событие `message_status_update` → отправителю. SQLite migration в `db.py`.
- **#46 Pagination** — `GET /conversations/{id}/messages` теперь возвращает `MessagePage { items, has_more, next_cursor }`. `next_cursor` — ISO datetime для `before=`. Лимит 1–200 (default 50).
- **#47 Search** — `ChatSearchScreen` полностью реализован (клиентский поиск по расшифрованному тексту, подсветка вхождений `_HighlightText`). Кнопка `search` добавлена прямо в AppBar `chat_screen.dart`.
- **#48 check-deploy.sh** — `scripts/check-deploy.sh`: читает URL из `.env`, пингует `/health` всех нод, печатает статус/build/federation counters. Exit code = число недоступных нод.
- **#49 Health dashboard** — `admin/health.html`: статичный HTML без сервера, URLs в localStorage, авто-опрос 10/30/60 с, fed counters, индикаторы.

## Не сделано
- Миграция SQLite → PostgreSQL (ждёт решения).
- Android-сборка не проверена на устройстве (permissions, cleartext HTTP).
- Offline-детект нод не протестирован живьём (логика простая, риск низкий).
- Push-уведомления о входящем звонке в background (Task #17, бэклог).
