# Messenger v2

Монорепозиторий продукта (клиент, storage-app, ноды, backend, QA-боты, docs).

Создан рядом со старым деревом `/Users/apple/messenger` (и отдельным deploy-репо `project/` → Gitea `flex/messenger`).  
Этот репозиторий — **чистый снимок исходников** без `data/`, `.env`, build-артефактов.

## Структура

| Путь | Назначение |
|------|------------|
| `frontend/` | Flutter-клиент мессенджера |
| `storage-app/` | Приложение персонального хранилища (PPC) |
| `client-node/` | Slim home/storage/relay нода |
| `main-node/` | Operator home + panel/ops |
| `backend/` | Полный стек (discovery, gateway, media, …) |
| `project/` | Production compose + автодеплой (legacy Gitea pipeline) |
| `scripts/qa_bots/` | Каталог-driven QA боты |
| `docs/` | Документация модулей |
| `ouo-settings-web-spec/` | Каталог настроек (спека) |

## Gitea (цель)

Старый прод-репо (не трогаем без нужды):

```text
ssh://git@194.67.92.147:2222/flex/messenger.git
```

Новый репозиторий (создать в UI Gitea под пользователем `flex`):

```text
имя: messenger-v2
remote: ssh://git@194.67.92.147:2222/flex/messenger-v2.git
```

После создания пустого репо на Gitea:

```bash
cd /Users/apple/messenger-v2
git remote add origin ssh://git@194.67.92.147:2222/flex/messenger-v2.git
GIT_SSH_COMMAND='ssh -i ~/.ssh/messenger_ops -o IdentitiesOnly=yes -p 2222' \
  git push -u origin main
```

Gitea UI: `http://194.67.92.147:3000`

Автодеплой webhook со старого `flex/messenger` на v2 **не вешаем**, пока не решите переключить pipeline.

## Локально

Секреты и runtime-данные не коммитятся (см. `.gitignore`).  
Для нод/compose копируйте `.env.example` → `.env` вручную.
