# SUMMARY

## Архитектура
- **Спецификация**: `spec/` (32 md + 8 ADR). Ключевые: Protocol-first, E2EE = libsignal (X3DH+Double Ratchet), staged decentralization (root Discovery Node на bootstrap-этапе), password bridge (ADR-0007).
- **Backend**: Python/FastAPI, SQLite. 5 сервисов:
  - `home-node` (8001) — auth, чаты/группы, сообщения, WS, федерация.
  - `storage-node` (8002) — буфер офлайн-сообщений.
  - `discovery-node` (8003) — резолв UserID→HomeNode, реестр нод (регистрация/heartbeat/статус/версия) = ROOT для bootstrap-стадии.
  - `media-node` (8004) — файлы (клиент шифрует до загрузки).
  - `relay-node` (8005) — пересылка Packet (fallback + микрохаб-функция), сам регистрируется в discovery.
  - Все ноды (кроме discovery) самостоятельно регистрируются + heartbeat в discovery.
- **Admin**: `project/admin/` — read-only Node Monitor (таблица нод: статус/версия/heartbeat), опрашивает discovery-node.
- **Client**: Flutter (web-first сейчас, mobile/desktop — позже, ничего не собираем под них пока).
  - Дизайн-система: `lib/theme/`, `lib/widgets/` (чёрно-белый, Apple HIG).
  - E2EE 1:1 и группы — реально работают (libsignal_protocol_dart, sender-key для групп).
  - Private Mode/Secret Room — mock UI, PIN хэшируется (Argon2id) и персистентен, хранилище скрытых чатов НЕ зашифровано отдельно.

## Текущий статус (проверено тестами/вручную)
- Backend: регистрация (телефон+имя, пароль), вход по идентификатору, чаты/группы, E2EE 1:1 и групповое, федерация между Home Node, relay-fallback, self-registration+heartbeat — всё работает.
- Client: 5 Dart-тестов зелёные (crypto roundtrip, live backend integration, group crypto, widget boot, private mode persistence). `flutter analyze` чисто.
- Настройки (Уведомления, Автозагрузка) — реально сохраняются локально (SharedPreferences).
- Не собираем APK/IPA — работаем через `flutter test` и веб.

## Принятые решения (ADR)
1. Protocol-first, не framework-first.
2. E2EE = X3DH + Double Ratchet (libsignal), не своя крипто.
3. Rust — целевой язык Core (не для MVP).
4. MVP поэтапно: язык на сервис, Crypto API стабилен.
5. Backend Python/FastAPI, клиент Flutter, реальный E2EE сразу (не заглушка).
6. Bootstrap-центр: один discovery-node — регистрация/мониторинг нод. Осознанное отступление от Decentralization First, roadmap на децентрализацию.
7. Временный вход по телефону/логину/email + пароль (Argon2id). Осознанное отступление от «без паролей», roadmap — убрать после device-to-identity binding.
8. БД остаётся SQLite (не переходим на Postgres).
9. Групповое E2EE — sender-key через libsignal, не своя схема.

## TODO
- [ ] Android/iOS сборка и permissions — отложено, не сейчас.
- [ ] Настройки: Аккаунт/Оформление/Помощь/О приложении — ещё заглушки.
- [ ] Private Mode: реальное шифрование хранилища — нужен отдельный security review перед стартом.
- [ ] Групповое E2EE: нет add/remove участников, нет ротации ключа при выходе.
- [x] Многонодовый живой тест: 3 relay-node (разные версии 0.1.0/0.2.0) + home/storage/media/discovery — все 7 видны в Node Monitor (`project/admin/`), каждый relay независимо работает как микрохаб (проверено прямым вызовом `/relay/forward`).
- [ ] Найден пробел: `_find_relay_url` в federation.py берёт первый "online" relay из списка discovery, но не проверяет реальную доступность и не переключается на другой relay при обрыве связи с уже выбранным — если он вдруг стал недоступен, но discovery ещё не пометил его offline (heartbeat не протух), доставка зафейлится вместо ретрая на другой relay. Нужно чинить отдельной задачей (retry across relays).
