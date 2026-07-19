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

## Remotes

| Host | URL |
|------|-----|
| **Gitea (primary)** | http://194.67.92.147:3000/flex/messenger-v2 |
| **GitHub (mirror)** | https://github.com/Flexbcc/messenger-v2 |

```bash
# Push both (после одноразовой настройки GitHub deploy key — см. ниже)
./scripts/push-remotes.sh
```

### GitHub: одноразово добавить deploy key (write)

1. Открой https://github.com/Flexbcc/messenger-v2/settings/keys  
2. **Add deploy key** → Allow write access  
3. Вставь ключ из `~/.ssh/github_messenger_v2.pub`  
4. `./scripts/push-remotes.sh`

Старый прод-репо (не трогаем):

```text
ssh://git@194.67.92.147:2222/flex/messenger.git
```


## Локально

Секреты и runtime-данные не коммитятся (см. `.gitignore`).  
Для нод/compose копируйте `.env.example` → `.env` вручную.
