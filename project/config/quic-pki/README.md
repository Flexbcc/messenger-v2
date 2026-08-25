# QUIC stand PKI

Отдельная TLS PKI для HTTP/3/QUIC data plane. Генератор создаёт цепочку:

```text
offline Root CA → QUIC issuing CA → relay leaf certificate
```

Root key и issuing key не монтируются в контейнеры. Relay получает только свой
`tls.crt`, `tls.key` и `ca-chain.crt`; Home получает только `trust/ca-chain.crt`.
Весь `generated/` исключён из Git.

Создание нового стенда (существующий каталог генератор не перезаписывает):

```bash
project/scripts/generate-quic-pki.sh \
  --inventory project/config/quic-pki/stand.example.csv \
  --output project/config/quic-pki/generated
```

Для реального DNS/IP скопируйте inventory за пределы Git и замените значения.
URL в `RELAY_URL` обязан использовать DNS/IP из SAN сертификата. Настройки:

```text
RELAY_QUIC_ENABLED=true
RELAY_TLS_CERT_FILE=/run/secrets/quic/tls.crt
RELAY_TLS_KEY_FILE=/run/secrets/quic/tls.key
RELAY_QUIC_CA_FILE=/run/secrets/quic/ca-chain.crt
```

Root key следует после выпуска issuing CA перенести в offline encrypted storage.
Компрометация issuing key требует выпуска нового intermediate и ротации leaf.
