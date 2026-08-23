# 0242 — Node Transport Certificate v1

Operational Ed25519 key нельзя использовать как onion/KEM key. Нода создаёт
отдельный X25519 Transport Key и получает краткоживущий root-signed certificate:

- self-certifying NodeID и Root public key;
- X25519 transport public key;
- `key_usage = OUO/SPHINX_TRANSPORT`;
- serial, issued/expiry не более семи дней;
- Node Root Ed25519 signature с отдельным domain.

Transport private key не является Node Root, Operational или Validator key.
Компрометация ограничена сроком certificate и transport role. Конкретный
Sphinx provider отвечает за допустимость X25519 KEM и packet construction;
certificate сам по себе не определяет onion-математику.

Текущий integration target — отдельный Rust provider через bounded persistent
Unix socket. Кандидат для review: поддерживаемая Apache-2.0 реализация Nym
Sphinx; подключение запрещено до проверки packet geometry, SURB API, известных
версий, dependency lock и совместимости с сертификатами OUO.
