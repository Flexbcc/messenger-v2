# 0245 — Contact Capability и Adaptive PoW v1

Неизвестный отправитель получает только endpoint-signed capability на один
маленький `initial_contact_text`. Объект содержит opaque mailbox token,
permissions, quota, expiry и уникальный ID; он не выдаёт голос, media или
неограниченный messaging channel.

Adaptive PoW не является доверием. Bounded gate хранит одноразовые challenges
с TTL, ограничивает память и поддерживает 0–24 leading zero bits. В нормальном
режиме difficulty 0; её повышает только внешний admission/load controller для
anonymous flood. Certified peers этот gate не проходят.

Валидатор обязан получить ожидаемый issuer public key из уже проверенного
BootstrapRecord/Device Certificate; доверять ключу внутри самой capability
запрещено. Persistent usage store хранит только hash capability ID, атомарно
расходует quota и поддерживает отзыв без сохранения mailbox token.

Home ingress нельзя подключать к legacy device login key или серверному ключу:
это сделало бы Home authority контакта. Runtime enforcement блокируется до
Phase A Identity Root/Device Certificate resolver; после него порядок проверки:
cheap bounds/PoW (только anonymous) -> trusted issuer resolve -> signature/expiry
-> atomic quota consume -> opaque fixed-cell mailbox write.
