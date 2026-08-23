# 0215 — Fixed-size authenticated transport cell v1

## Construction

V1 использует стандартный PyNaCl `Aead` (XChaCha20-Poly1305), отдельный 32-byte
transport key, случайный 24-byte nonce библиотеки и OS-CSPRNG padding.
Собственных cipher/MAC primitives нет.

Внутри AEAD plaintext находятся `kind`, реальная длина, payload и random
padding. `kind=dummy` и `kind=real` снаружи неразличимы. Associated data:

```text
OUO/FIXED_CELL/v1\0 || protocol_version || cell_size
```

Поддерживаемые классы: 4 KiB, 16 KiB, 64 KiB и 256 KiB. Размер, unknown class,
AEAD failure и невозможная внутренняя длина отклоняются fail closed.

## Security boundary

Cell скрывает длину payload внутри выбранного класса и обнаруживает
corruption/tagging. Она ещё не скрывает выбранный size class, timing, peer IP
или маршрут. Для этого требуются batching, Mix, jitter, cover и onion layer.

Ключ fixed-cell domain не должен совпадать с User E2EE, Node Root,
Operational, Route или Storage key.
