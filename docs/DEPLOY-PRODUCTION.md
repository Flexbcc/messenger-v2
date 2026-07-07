# Production deploy: Gitea + auto-deploy on push

Один **main server** (VPS с белым IP). После настройки обновление:

```bash
git add .
git commit -m "update"
git push origin main
```

Сервер сам подтянет код и пересоберёт Docker-сервисы.

## Что где лежит на сервере

| Путь | Назначение |
|------|------------|
| `/opt/gitea` | Gitea (приватный Git) |
| `/opt/messenger/project` | рабочая копия + `docker compose` |
| `/var/log/messenger-deploy.log` | лог автодеплоя |

## Этап 1 — первичная установка (один раз)

### 1. Залить проект на сервер

С ноутбука (если git ещё нет на сервере):

```bash
cd project
./scripts/deploy-from-laptop.sh --host root@MAIN_IP --role main --ip MAIN_IP
```

Или вручную скопировать `project/` в `/opt/messenger/project`.

### 2. На сервере — Docker + main node

```bash
ssh root@MAIN_IP
cd /opt/messenger/project
chmod +x scripts/*.sh deploy.sh
sudo ./scripts/install-node.sh --role main --ip MAIN_IP --non-interactive
```

Поднимутся: `discovery-node`, `gateway-node`, `admin`.

### 3. Gitea + webhook автодеплоя

```bash
sudo ./scripts/setup-gitea.sh
```

Скрипт:
- поднимает Gitea в `/opt/gitea` (UI на `:3000`, git по SSH на `:2222`);
- создаёт пользователя `admin` и репозиторий `messenger`;
- ставит webhook → при push в `main` запускается `./deploy.sh`;
- сохраняет пароли в `config/deploy/gitea.env` (не коммитить).

### 4. SSH-ключ в Gitea

На ноутбуке:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/messenger_gitea -N ""
cat ~/.ssh/messenger_gitea.pub
```

Скопировать ключ в Gitea: **Settings → SSH / GPG Keys → Add Key**  
(`http://MAIN_IP:3000`)

В `~/.ssh/config`:

```
Host messenger-git
  HostName MAIN_IP
  Port 2222
  User git
  IdentityFile ~/.ssh/messenger_gitea
```

## Этап 2 — ежедневная работа

### Вариант A — одна команда с ноутбука

```bash
cd project
./scripts/push-deploy.sh --host messenger-git
```

### Вариант B — обычный git

```bash
git remote add origin ssh://git@MAIN_IP:2222/admin/messenger.git
git push -u origin main
```

После push Gitea вызывает webhook → `deploy.sh` → `node-update.sh`:
- `git pull`
- `docker compose build` + `up -d` для сервисов из `config/deploy/node.profile`
- health-check `/health`

### Ручной деплой на сервере

```bash
ssh root@MAIN_IP 'cd /opt/messenger/project && ./deploy.sh'
```

### Логи

```bash
ssh root@MAIN_IP 'tail -f /var/log/messenger-deploy.log'
ssh root@MAIN_IP 'cd /opt/messenger/project && docker compose ps'
```

## Worker-ноды (доп. VPS)

На worker после установки Docker:

```bash
git clone ssh://git@MAIN_IP:2222/admin/messenger.git /opt/messenger/project
cd /opt/messenger/project
MAIN_IP=... THIS_IP=... WORKER_ROLE=full ./scripts/bootstrap-worker.sh
```

Обновление worker:

```bash
cd /opt/messenger/project && ./scripts/node-update.sh
```

Или cron раз в час: `git pull && ./scripts/node-update.sh`.

## Nginx + SSL (опционально)

Пример для `git.example.com` — `deploy/gitea/nginx-gitea.conf.example`.

```bash
sudo certbot --nginx -d git.example.com
```

В `/opt/gitea/.env` поменять `GITEA_ROOT_URL=https://git.example.com/`, перезапустить Gitea.

## PWA (фронт)

Отдельно от backend-нод:

```bash
cd client/messenger_app
./scripts/ship-pwa.sh
```

## Сравнение с bare git

В `init-main-server.sh` уже есть `/var/git/messenger.git` с post-receive hook.
**Gitea** даёт UI, issues, SSH keys и webhook — удобнее для одного оператора.
Bare git можно не использовать, если включён Gitea (`setup-gitea.sh`).

## Безопасность

- **Admin (:9201)** — только `127.0.0.1`, доступ через SSH-туннель. Не в `NODE_SERVICES` на production.
- Закройте **9201** в ufw и панели хостинга на уже развёрнутых серверах.
- Gitea `:3000` / SSH `:2222` — только для оператора; лучше за VPN или ограничение по IP.
- `config/deploy/gitea.env` и `.env` — не в git.
- Enrollment: `./scripts/approve-pending-nodes.sh` (терминал), не публичный веб.

См. подробности: **`docs/HANDOFF-AUTODEPLOY.md`**

## Troubleshooting

| Проблема | Решение |
|----------|---------|
| push rejected | Добавьте SSH key в Gitea |
| webhook не срабатывает | `systemctl status messenger-deploy-webhook` |
| deploy падает | `tail /var/log/messenger-deploy.log` |
| git pull на сервере | Проверьте `config/deploy/gitea.env`, credentials в `~/.git-credentials` |
