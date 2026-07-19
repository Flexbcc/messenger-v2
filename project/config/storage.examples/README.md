# Шаблоны хранилища медиа (S3-compatible)

Файлы здесь — **заготовки** для `config/storage.json`. Секреты не в git.

## Режимы

| Профиль | Смысл |
|---------|--------|
| `local-only` | Только диск VPS (текущий дефолт) |
| `hybrid-backup.*` | Медиа локально, бэкап в S3 (рекомендуется) |
| `primary-s3.*` | Все медиа сразу в S3 |

## Провайдеры (hybrid-backup)

| Файл | Провайдер | Endpoint |
|------|-----------|----------|
| `hybrid-backup.aws.json` | Amazon S3 | `https://s3.{region}.amazonaws.com` |
| `hybrid-backup.yandex.json` | Yandex Object Storage | `https://storage.yandexcloud.net` |
| `hybrid-backup.selectel.json` | Selectel | `https://s3.storage.selcloud.ru` |
| `hybrid-backup.cloudflare-r2.json` | Cloudflare R2 | `https://{account}.r2.cloudflarestorage.com` |
| `hybrid-backup.minio.json` | MinIO (свой) | свой `S3_ENDPOINT` |
| `hybrid-backup.backblaze.json` | Backblaze B2 | `https://s3.{region}.backblazeb2.com` |
| `hybrid-backup.timeweb.json` | Timeweb S3 | endpoint из панели |

## Primary S3

| Файл | Провайдер |
|------|-----------|
| `primary-s3.aws.json` | AWS |
| `primary-s3.yandex.json` | Yandex |
| `primary-s3.minio.json` | MinIO |

## Быстрый старт

```bash
# на worker (161.104.18.45):
cd /opt/messenger/project

cp config/storage.examples/storage.secrets.env.example config/storage.secrets.env
nano config/storage.secrets.env   # bucket, keys, region

./scripts/apply-storage-profile.sh hybrid-backup.yandex --reload
```

С Mac (через SSH):

```bash
./scripts/apply-storage-profile.sh hybrid-backup.yandex  # локально
scp config/storage.json root@161.104.18.45:/opt/messenger/project/config/
ssh root@161.104.18.45 'cd /opt/messenger/project && docker compose exec -T media-node python3 -c "from app.config_loader import reload_settings; reload_settings()"'
```

## Плейсхолдеры в шаблонах

| Плейсхолдер | Переменная в storage.secrets.env |
|-------------|----------------------------------|
| `__S3_BUCKET__` | `S3_BUCKET` |
| `__S3_ACCESS_KEY__` | `S3_ACCESS_KEY` |
| `__S3_SECRET_KEY__` | `S3_SECRET_KEY` |
| `__S3_REGION__` | `S3_REGION` |
| `__S3_ENDPOINT__` | `S3_ENDPOINT` |
| `__R2_ACCOUNT_ID__` | `R2_ACCOUNT_ID` |

## Личное облако пользователя

См. `personal-cloud.user.example.jsonc`

## Важно

- На сервере лежат **зашифрованные** blob'ы (E2EE) — S3 видит ciphertext.
- `config/storage.secrets.env` и production `storage.json` с ключами — **не коммитить**.
- Локальный путь: `data/media/` на хосте → `/data/media_blobs` в контейнере.
