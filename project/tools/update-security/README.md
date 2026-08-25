# OUO node update security

Изолированное окружение:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## 1. Offline ceremony

```bash
.venv/bin/python ouo_tuf.py ceremony \
  --output ../../config/tuf/ceremony
```

Создаются реальные encrypted Ed25519 PKCS#8 keys, `root` 3-of-5 и `targets`
2-of-3. Каталог ceremony не публикуется. В production каждый private key и его
passphrase передаются отдельному offline custodian; локальная совокупная папка
предназначена только для закрытого стенда/первичной церемонии.

## 2. Signed release bundle

```bash
.venv/bin/python ouo_tuf.py build-release \
  --ceremony ../../config/tuf/ceremony \
  --artifact /secure/build/ouo-node-1.0.0.tar.gz \
  --target node/ouo-node-1.0.0.tar.gz \
  --release-version 1.0.0 --release-epoch 1 \
  --protocol-version 1 --minimum-protocol-version 1 \
  --rollout-percent 10 --output /secure/release-1
```

Production-процесс должен собирать signatures на физически раздельных signing
stations; команда выше является stand ceremony coordinator и требует весь
ceremony-каталог.

## 3. Publisher

```bash
.venv/bin/python ouo_tuf.py publish \
  --bundle /secure/release-1 --repository ../../config/tuf/repository
```

Publisher не получает private keys. Он заново проверяет TUF thresholds,
expiry, metadata linkage, artifact hash/length и critical custom fields. Новый
immutable release публикуется через atomic `current` symlink; старые releases
сохраняются. `transparency.json` связывает release с hashes metadata/artifact.

## 4. Node prepare + activation

`prepare-secure-node-update.py` скачивает artifact только после TUF verification
и создаёт private receipt. `install-verified-node-update.py` повторно проверяет
hash/length, безопасно распаковывает tar без links/devices/path traversal,
атомарно переключает `current`, выполняет заданный оператором restart и health
gate. При неуспехе возвращается прежний symlink; high-watermark записывается
только после успешного health.
