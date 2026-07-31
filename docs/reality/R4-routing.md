# R4 — Routing (as-is)

| Поле | Значение |
|------|----------|
| Фаза | R4 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0203_ROUTING.md`](../../project/spec/0203_ROUTING.md) |
| Статус заметки | confirms |

Исследование: [messages](c2d581f3-8f25-4170-962a-f4b6b2461d41) · [calls](6fb36fda-76c4-42db-a609-c2fbf2f7e7e9).

---

## As-is — сообщения

1. Client → **свой** Home (`POST /messages`).
2. Home `fan_out`: local WS/buffer; remote → Discovery resolve → direct deliver → relays.
3. Client **не** ведёт таблицу маршрутов пиров (current/previous/backup).
4. Смена `home_node_url` в Discovery = upsert с `home_updated_at` / `previous_home_node_url`; CONTROL-notify контактам пока нет (только API + лог на Home).

Код: `federation.py` (`resolve_home_node`, `deliver_to_remote_home_node`), `fanout.py`, Discovery `registry.py`.

---

## As-is — звонки

| Плоскость | Путь |
|-----------|------|
| Signaling | Те же messages/WS/federation (`call_offer|answer|ice|…`) |
| Media | TURN credentials + coturn / STUN; **не** Relay Node |
| Mid-call route change | нет |
| Restore call | нет |

ADR-0008 в целом соблюдён для «signaling = E2EE message».

---

## Confirms

- Порядок direct → relay совпадает с to-be п.1–2; Storage в LIVE = device offline, не «Home down DLQ» (R3).
- Calls signaling / media разделены.
- Relay не читает plaintext (ciphertext envelope).

---

## Gaps

| Gap | Влияние | Нужно |
|-----|---------|-------|
| Нет TTL/кэша user→home | Лишний load Discovery; stale только «до следующего send» | Частично сделано: Home кэширует `resolve_home_node` в памяти (per-process, `DISCOVERY_RESOLVE_CACHE_TTL_SECONDS`, default 60s, 0 — выключить); outbox retry всегда обходит кэш живым resolve. Discovery-side TTL/кэш всё ещё Post-R5 |
| Нет notify смены Home | Сообщения уходят на старый URL до следующего resolve fail path | Сделано (минимально, Post-R5 slice): Discovery отдаёт `home_updated_at`/`previous_home_node_url`; при обнаружении реальной смены (`app/discovery_publish.py` → `app/federation.py::_home_change_info`) новый Home лучших усилий уведомляет участников direct/group-переписок этого пользователя — локальных через WS `{type:"home_changed", user_id, home_node_url, home_updated_at}` (`app/fanout.py::push_home_changed_to_local_contacts`), удалённых через подписанный CONTROL `POST /internal/home-changed` без ciphertext (`notify_remote_home_changed`/`build_home_changed_payload`), который на стороне пира тоже толкает WS локальным контактам. `frontend/app` игнорирует/логирует `home_changed` — client peer-route кэша ещё нет, инвалидировать нечего. Ретраев/outbox для этого notify нет (best-effort только) — если он потерян, пир всё равно самовосстанавливается на следующем живом resolve |
| Нет client backup routes | Guideline §8 не выполнен | Сделано (client-side): `frontend/app` `BootstrapStore`/`NetworkBootstrap` хранит `backupHomeUrls` (+ `discoveryUrl`/`gatewayUrl`) из `routing.home_nodes` (invite redeem и `GET /gateway/routing`), обновляет их при `onAppResumed`/boot (`BootstrapStore.refreshBackups`). `NodeConfigResolver.failoverToBackupHome` теперь и переключает активный `home_url` на первый живой backup (старый primary уходит в backup-лист), а `AppController._maybeFailoverHome` дергает его из `_relogin` (сетевой fail при challenge/verify — reconnect/WS tokenProvider путь), `onAppResumed` (проверка `/health` перед резюмом) и pre-login (`register`/`loginWithPassword`), затем пытается challenge/verify на новом Home; если сессия не восстановилась — сброс на экран логина с сообщением "Home сменился". Один failover-attempt на "outage episode" (in-flight guard + cooldown 3 мин), чтобы не долбить `/health` в цикле реконнекта. Server-side (Discovery/Home CONTROL-notify контактам о смене адреса) остаётся Post-R5 |
| Нет route version/rollback | Только in-request relay list | backlog |
| Call ICE restart неполный | Обрывы хуже спеки 0303 | продукт / Post-R5 |
| TURN = first online | Нет geo/load balance | backlog |
| Signed Discovery user record | Zero Trust resolve слабее | R5 / Post-R5 |

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| User сменил Home, пир не резолвил заново | Deliver на старый URL → fail → relays → возможно всё равно fail |
| Discovery down mid-send | Resolve fail; remote недоставляем |
| Все relays down, direct blocked | Silent loss (R3) |
| TURN down | Звонок деградирует к STUN/P2P; signaling чата жив |
| Home change during call | Не специфицировано; signaling может уйти не туда |

---

## Feedback в T1

1. Явно развести message Packet routing и call media plane (**сделано в 0203**).
2. Не обещать client route table как LIVE.
3. R5: подпись Discovery user records + жизнь без Gateway (bootstrap) опираются на эти gaps.
4. Связь с R3: без outbox «новый маршрут после смены Home» не надёжен.
