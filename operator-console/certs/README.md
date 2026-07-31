# certs/

Сюда кладутся три файла:

| Файл | Что это | Откуда взять |
|------|---------|--------------|
| `ca.crt` | Корневой сертификат федерации | `project/config/mtls/ca.crt` |
| `operator.crt` | Сертификат этого устройства | `project/config/mtls/operators/<имя>.crt` |
| `operator.key` | Приватный ключ | `project/config/mtls/operators/<имя>.key` |

## Выпуск

На машине, где лежит CA:

```bash
cd project
bash scripts/generate-operator-cert.sh alex-macbook
```

## Перенос

Приватный ключ — это полный доступ к управлению федерацией. Переносите
только по защищённому каналу:

```bash
scp project/config/mtls/operators/alex-macbook.key \
    operator-console/certs/operator.key
chmod 600 operator-console/certs/operator.key
```

Не отправляйте ключ почтой, мессенджерами и не кладите в облако.

## Если устройство потеряно

На машине с CA отзовите доступ и обновите ноды:

```bash
bash scripts/revoke-operator-cert.sh alex-macbook
# затем разложить operators-allowlist.conf по нодам и nginx -s reload
```

Остальные сертификаты продолжат работать.

---

Файлы в этой папке в `.gitignore` — они не попадут в репозиторий.
