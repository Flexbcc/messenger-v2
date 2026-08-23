# 0211 — User-signed BootstrapRecord v1

## Назначение

Discovery хранит и раздаёт BootstrapRecord, но не создаёт и не переподписывает
его. Авторитетом является Identity Root пользователя. `UserID` вычисляется как
полный SHA-256 от Ed25519 Identity public key с префиксом `ouo-user-v1-`.

## Объект

`ouo-bootstrap-record/1` содержит `record_id`, self-certifying `user_id`,
`identity_public_key`, `identity_version`, ограниченный список HTTPS/WSS ingress,
`record_version`, `issued_at`, `expires_at` и Ed25519 signature пользователя.
Максимальный срок — 24 часа.

Подпись имеет domain separation `OUO/BOOTSTRAP_RECORD/v1` и покрывает весь
объект кроме самой подписи. Неизвестные поля отклоняются.

## Правила Discovery

- проверить self-certifying UserID, подпись, expiry и структуру до записи;
- не принимать rollback `identity_version` или `record_version`;
- конфликтующие объекты одной версии отклонять как equivocation;
- возвращать сохранённый объект без собственной подписи и модификации;
- клиент всегда повторно проверяет объект независимо от Discovery.

D1/D2/D3 реплицируют только исходные endpoint-signed объекты через bounded
pull-gossip. Каждый получатель заново выполняет полную проверку. Версии идут
последовательно; конфликт одной версии фиксирует split view и замораживает
критический control plane, не превращая Discovery в Identity authority.

Таблица `user_records` остаётся legacy API на время миграции и не является
целевым источником Identity/route authority.
