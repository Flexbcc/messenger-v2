# storage-app — техническая спецификация (черновик)

## Статус
Черновик. Доп. настройки уточняются заказчиком.

## 1. Назначение
Личное хранилище блобов на домашнем ПК как **альтернатива S3/облаку** для
хранения файлов мессенджера. Два сценария:
- **Node-mode**: у пользователя есть своя нода (`../client-node`). Нода
  складывает проходящие через неё блобы на ПК вместо media/S3.
- **Direct-mode**: своей ноды нет. Телефон клиента пишет/читает блобы прямо в
  storage-app через общую сеть.

## 2. Принципы
- **Zero-knowledge**: блобы приходят уже как E2EE-шифротекст. storage-app и ПК
  НЕ имеют ключей расшифровки, видят только шифр. Ключи — только у клиентов.
- **Контентная адресация**: объект адресуется по хэшу шифротекста (SHA-256/
  BLAKE3), как в S3-слое (см. `../backend/spec/0701_S3.md`). Дедуп + скрытие имён.
- **Replaceable backend**: для media-node это ещё один storage-backend
  (`personal_pc`) рядом с `local`/`s3` — остальной код ноды не меняется.

## 3. Роли и компоненты
| Компонент | Где | Роль |
|-----------|-----|------|
| storage-app | домашний ПК (Flutter desktop) | принимает/отдаёт блобы, хранит в папке |
| media-node backend `personal_pc` | нода / `../backend` | клиент протокола со стороны ноны |
| телефон-клиент | `../frontend` | в direct-mode — клиент протокола напрямую |
| relay/turn | `../backend/services/{relay,turn}-node` | транспорт при NAT |

## 4. Модель хранения
Решения по настройкам — в [`SETTINGS.md`](SETTINGS.md). Кратко:
- Пользователь при установке выбирает **разрешённую папку** (`allowed_root`).
- Структура: `users/<user_uuid>/blobs/<aa>/<bb>/<hash>` + `meta.db` + `.tmp/`.
  Раздельные папки на пользователя (изоляция), шардинг по первым байтам хэша.
- **БД**: SQLite (WAL), только метаданные; содержимое на ФС. `meta.db` шифруется.
- **Квоты**: глобальные + per-user; при переполнении PUT → `quota_exceeded`
  (нода решает fallback), LRU-вытеснения нет.
- **GC**: удаления инициирует нода (`DELETE`) + refcount; плановый проход.
- storage-app пишет ТОЛЬКО внутрь `allowed_root`. Никаких путей наружу.

## 5. Протокол (по ключам, не S3)
Транспорт-агностичный, поверх защищённого канала (см. §7). Операции:

| Op | Запрос | Ответ |
|----|--------|-------|
| `PUT`    | hash, size, ciphertext | ok / quota_exceeded |
| `GET`    | hash | ciphertext / not_found |
| `DELETE` | hash | ok / not_found |
| `STAT`   | hash | {exists, size} |
| `USAGE`  | — | {used_bytes, used_files, quota} |
| `PING`   | — | {version, healthy} |

- Каждый запрос подписан ключом пира (Ed25519), проверяется по paired-списку.
- `hash` обязан совпадать с хэшем `ciphertext` (integrity, anti-poisoning).
- Разбиение больших файлов на чанки — TODO (см. NOTES).

## 6. Сопряжение (pairing)
См. отдельный [`PAIRING.md`](PAIRING.md). Кратко:
- У storage-app и у каждого пира (нода/телефон) — своя пара Ed25519.
- Сопряжение: короткий код / QR → обмен публичными ключами → запись в
  `paired_peers`. Только сопряжённые пиры могут PUT/GET.
- Отзыв пары (revoke) — удаление ключа, опц. удаление его блобов.

## 7. Транспорт (оба режима связности)
storage-app устанавливает канал одним из путей, в порядке предпочтения:
1. **LAN-direct** — обнаружение через mDNS/указанный адрес; TLS/Noise поверх TCP.
2. **Relay-fallback** — storage-app подключается к общей сети как клиент:
   регистрируется у discovery, держит исходящий канал к relay/turn
   (`../backend/services/{relay,turn}-node`). Пир шлёт запросы через relay →
   NAT/файрвол не мешают (исходящее соединение с ПК).

Выбор режима автоматический: пробуем LAN, иначе relay. Канал в обоих случаях
дополнительно аутентифицирован ключами пиров (§5), relay — недоверенный транзит.

## 8. Интеграция с media-node
- Backend `personal_pc` — файл `../backend/services/media-node/app/backends/personal_pc.py`
  (реализует `base.py`: `put/get/delete/exists`), подключён в `factory.py`.
  Сигнатура и маппинг операций: [`BACKEND_PERSONAL_PC.md`](BACKEND_PERSONAL_PC.md).
- Статус нода-конца: **реализованы** LAN-direct транспорт (Ed25519-подпись
  запросов по [`WIRE.md`](WIRE.md)), `_verify_integrity()` (sha256==key),
  `usage()` (парсинг USAGE). **relay-fallback — фаза 2** (см. WIRE.md «Вне охвата»).
- Профиль конфига `personal_cloud.users[UUID] = { backend: "personal_pc",
  personal_pc: { peer_pubkey, relay_url, lan_hint, quota_bytes } }` — пример:
  `../backend/config/storage.examples/personal-pc.user.example.jsonc`.

## 9. Безопасность
- ПК никогда не получает plaintext и ключей расшифровки. Блобы лежат как есть
  (уже E2EE-шифротекст); `meta.db` шифруется ключом из OS-keystore.
- Все операции авторизованы подписью пира; неизвестный ключ → отказ.
- relay — недоверенный: сквозная аутентификация запросов, integrity по хэшу.
- Запись строго внутри `allowed_root`; защита от path traversal.
- Rate-limit и квоты против abuse со стороны пира.

## 10. Открытые вопросы
См. [`NOTES.md`](NOTES.md).
