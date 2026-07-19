# Handoff: автодеплой + операторская модель

Документ для **backend/devops-агента**. Описывает топологию, Gitea pipeline, подключение новых нод, политику безопасности (без публичной админки) и troubleshooting.

_Обновлено: 2026-07-07_

---

## Принципы (обязательно)

| Принцип | Реализация |
|---------|------------|
| **Настройка через терминал** | `.env`, `node.profile`, `cluster.env` — правка на сервере или через `enroll-worker.sh` / `setup-autodeploy.sh` |
| **Админка не торчит наружу** | `admin` слушает только `127.0.0.1:9201` (docker-compose). Доступ: SSH-туннель. **Не** в `NODE_SERVICES` на production main |
| **Enrollment через CLI** | `./scripts/approve-pending-nodes.sh` — не через публичный веб |
| **Одинаковые cluster-настройки** | `JWT_SECRET`, `CLUSTER_ID`, `ENROLLMENT_MODE`, … — одинаковы на main и всех workers (`config/deploy/cluster.env.example`) |
| **Новая нода = автодеплой** | `enroll-worker.sh` с Mac: git, deploy keys, workers.list, первый `deploy.sh` |
| **Обновление кода** | `git push origin main` → webhook → main `deploy.sh` → workers по SSH |

### Админка (bootstrap UI) — будущее

Текущий `admin/` (Node Monitor, setup, enrollment) — **временный bootstrap** (ADR-0006), не целевая архитектура.

Целевая модель:
- оператор работает в **SSH + скрипты**;
- опционально UI только через `ssh -L 9201:127.0.0.1:9201 root@MAIN` на localhost;
- позже — отдельный operator-tool с auth, без прямого доступа к `.env` по HTTP.

**Срочно на уже развёрнутом main (194.67.92.147):** закрыть порт 9201 в панели хостинга + ufw:

```bash
ssh root@194.67.92.147 'ufw delete allow 9201/tcp 2>/dev/null; ufw reload; ufw status'
cd /opt/messenger/project && git pull && docker compose up -d --build
# admin теперь только 127.0.0.1
```

---

## Текущая топология

| Сервер | IP | Роль |
|--------|-----|------|
| **MAIN** | `194.67.92.147` | Gitea, discovery, gateway, PWA-хост |
| **WORKER** | `161.104.18.45` | home, storage, media, relay, turn |

| Сервис | URL |
|--------|-----|
| Gitea UI | `http://194.67.92.147:3000` |
| Git SSH | `ssh://git@194.67.92.147:2222/flex/messenger.git` |
| Gitea user | `flex` (не `admin` — зарезервировано в Gitea) |
| Discovery | `http://194.67.92.147:8003` |
| Gateway | `http://194.67.92.147:8007` |
| Home | `http://161.104.18.45:8001` |
| Media | `http://161.104.18.45:8004` |

**Пути:**
- проект: `/opt/messenger/project`
- Gitea docker: `/opt/gitea`

---

## Как работает автодеплой (полностью автоматический)

```
[Mac]  ./scripts/push-deploy.sh   (или git push origin main)
          ↓
[Gitea flex/messenger]  push event
          ↓ webhook
[MAIN] deploy.sh
          ├─ git pull (deploy key)
          ├─ node-update.sh  → discovery + gateway
          └─ deploy-workers.sh → SSH каждый worker → node-update.sh
```

**Ничего руками на серверах после push не нужно.**

### Локальная суперадминка (Operator Console)

На Mac — единая панель управления всеми нодами:

```bash
cp config/deploy/laptop.env.example config/deploy/laptop.env   # один раз
./scripts/setup-laptop-ssh.sh                                  # один раз
./scripts/start-operator.sh
# → http://127.0.0.1:9300/
```

Возможности:
- health main + worker + список нод discovery
- **Commit + Push → автодеплой** одной кнопкой
- принудительный `deploy.sh` на main
- approve pending нод
- live tail deploy log

Проверка цепочки: `./scripts/ensure-autodeploy.sh`  
Смотреть лог после push: `./scripts/watch-deploy.sh`

### Сервисы по ролям (`config/deploy/node.profile`)

**MAIN** (production):
```
NODE_SERVICES="discovery-node gateway-node"
```
`admin` — **не** в автодеплое; поднять вручную при отладке: `docker compose up -d admin` + SSH-туннель.

**WORKER:**
```
NODE_SERVICES="home-node storage-node media-node relay-node turn-node"
```

### Порты наружу

| Сервер | Открыть | Не открывать |
|--------|---------|--------------|
| MAIN | 22, 3000*, 2222*, 8003, 8007, 7357** | **9201**, 8001 |
| WORKER | 22, 8001, 8004, 8006 | 8002, 8005 |

\* Gitea — лучше ограничить VPN/свой IP  
\** PWA static, если раздаётся с main

---

## Общие настройки (одинаковые на всех нодах)

Шаблон: `config/deploy/cluster.env.example`

Обязательно синхронизировать между main и workers:

| Переменная | Зачем |
|------------|--------|
| `JWT_SECRET` | токены home-node |
| `CLUSTER_ID` | остров / оператор |
| `ENROLLMENT_MODE` | `hybrid` на prod |
| `INTERNAL_SECURITY_MODE` | пока `legacy`, потом `signed` |
| `FEDERATION_ENVELOPE_MODE` | пока `legacy` |

Уникальны per-machine: `HOME_NODE_PUBLIC_URL`, `*_NODE_ID`, `DISCOVERY_NODE_URL` (на worker = IP main).

Правка на сервере:

```bash
nano /opt/messenger/project/.env
cd /opt/messenger/project && ./scripts/node-update.sh
```

---

## Скрипты: справочник

### Ежедневно (Mac)

| Команда | Назначение |
|---------|------------|
| `git push origin main` | деплой backend (main + workers) |
| `scripts/push-deploy.sh` | commit + push одной командой |
| `scripts/test-autodeploy.sh` | smoke: marker в git + health на серверах |

### Новая worker-нода (полный автодеплой)

```bash
# один раз на Mac:
cp config/deploy/laptop.env.example config/deploy/laptop.env
# заполнить GITEA_PASSWORD, MAIN_HOST, MAIN_IP

./scripts/setup-laptop-ssh.sh
./scripts/enroll-worker.sh --worker root@NEW_IP --worker-ip NEW_IP
```

`enroll-worker.sh` делает **6 шагов**:
1. rsync + `setup-autodeploy.sh --role main` на main  
2. rsync + `setup-autodeploy.sh --role worker` на worker  
3. orchestrator SSH key main → worker  
4. deploy keys в Gitea (API)  
5. `workers.list` на main  
6. первый `./deploy.sh`  

После enroll — approve нод:

```bash
ssh root@194.67.92.147 'cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh'
```

### На MAIN

| Скрипт | Назначение |
|--------|------------|
| `deploy.sh` | webhook entry: node-update + deploy-workers + prune |
| `scripts/node-update.sh` | git pull + docker compose |
| `scripts/deploy-workers.sh` | SSH → workers из `config/deploy/workers.list` |
| `scripts/setup-autodeploy.sh --role main` | git remote, webhook, orchestrator key |
| `scripts/approve-pending-nodes.sh` | enrollment без веб-UI |
| `scripts/setup-gitea.sh` | Gitea с нуля |
| `scripts/fix-autodeploy-main.sh` | донастройка webhook если enroll оборвался |

### На WORKER

| Скрипт | Назначение |
|--------|------------|
| `scripts/setup-autodeploy.sh --role worker` | git remote + node.profile |
| `scripts/node-update.sh` | pull + docker (вызывается с main через deploy-workers) |

### Библиотеки `scripts/lib/`

| Файл | Назначение |
|------|------------|
| `deploy-common.sh` | DEPLOY_ROOT, git_sync, compose_update |
| `gitea-api.sh` | deploy keys через API |
| `ssh-keys.sh` | orchestrator + deploy keys, workers.list |
| `laptop-env.sh` | Mac: ssh/rsync без паролей |
| `firewall.sh` | ufw (без 9201) |

---

## Ключевые файлы (не в git)

| Файл | Где | Содержимое |
|------|-----|------------|
| `config/deploy/node.profile` | каждый сервер | `NODE_SERVICES` |
| `config/deploy/workers.list` | main | `root@161.104.18.45` |
| `config/deploy/gitea.env` | main | пароль flex, webhook secret |
| `config/deploy/laptop.env` | Mac | пароль, хосты |
| `.env` | каждый сервер | секреты, URLs |

### SSH-ключи

| Ключ | Назначение |
|------|------------|
| `/root/.ssh/messenger_deploy` | git pull с Gitea |
| `/root/.ssh/messenger_orchestrator` | main → worker |

### systemd

```
/etc/systemd/system/messenger-deploy-webhook.service
→ scripts/deploy-webhook.py @ 127.0.0.1:9009
→ лог: /var/log/messenger-deploy.log
```

---

## Операции через терминал

### Деплой

```bash
cd project && git push origin main
ssh root@194.67.92.147 'tail -f /var/log/messenger-deploy.log'
```

### Ручной деплой

```bash
ssh root@194.67.92.147 'cd /opt/messenger/project && ./deploy.sh'
```

### Health

```bash
curl -s http://194.67.92.147:8003/health
curl -s http://161.104.18.45:8001/health
ssh root@194.67.92.147 'cd /opt/messenger/project && docker compose ps'
```

### Enrollment (без админки)

```bash
# все pending
ssh root@194.67.92.147 'cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh'

# одна нода
ssh root@194.67.92.147 'cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh home-cv7616931'

# список
SECRET=$(ssh root@194.67.92.147 'grep DISCOVERY_ADMIN_SECRET /opt/messenger/project/.env | cut -d= -f2')
curl -s http://194.67.92.147:8003/admin/registry/nodes -H "X-Discovery-Admin-Secret: $SECRET" | python3 -m json.tool
```

### Админка (только через туннель)

```bash
ssh -L 9201:127.0.0.1:9201 root@194.67.92.147
# браузер: http://127.0.0.1:9201/
```

На main должен быть запущен admin: `docker compose up -d admin` (не в NODE_SERVICES — не перезапускается автоматически при deploy).

### Smoke на сервере

```bash
ssh root@194.67.92.147 'cd /opt/messenger/project && ./scripts/integration-smoke.sh'
# на main FAIL home/media — нормально (они на worker)
```

---

## PWA (фронт) — отдельно

Backend autodeploy **не** собирает Flutter.

```bash
cd client/messenger_app
HOME_NODE_URL=http://161.104.18.45:8001 \
MEDIA_NODE_URL=http://161.104.18.45:8004 \
DISCOVERY_NODE_URL=http://194.67.92.147:8003 \
./scripts/build-web-pwa.sh
```

См. `docs/pwa-deploy.md`.

---

## Troubleshooting

### Git / Gitea

| Симптом | Диагностика | Решение |
|---------|-------------|---------|
| `push rejected` | `ssh -T -p 2222 git@194.67.92.147` | SSH key в Gitea (flex → Settings → Keys) |
| `dubious ownership` | git pull на сервере | `setup-server-git.sh` (safe.directory) |
| `Push to create is not enabled` | первый push | создать `flex/messenger` в Gitea UI |
| deploy key не работает | Gitea → repo → Deploy Keys | `register-gitea-deploy-keys.sh` |

### Webhook / deploy

| Симптом | Диагностика | Решение |
|---------|-------------|---------|
| push ок, серверы старые | `systemctl status messenger-deploy-webhook` | `fix-autodeploy-main.sh` |
| лог без `deploy triggered` | Gitea → Webhooks → Recent Deliveries | пересоздать webhook, проверить secret в `gitea.env` |
| `deploy.sh` падает | `tail -50 /var/log/messenger-deploy.log` | смотреть docker build OOM → swap на worker |
| worker не обновился | `cat config/deploy/workers.list` | `add-worker.sh root@IP`; проверить orchestrator: `ssh -i /root/.ssh/messenger_orchestrator root@161.104.18.45 echo ok` |

### Docker / ноды

| Симптом | Диагностика | Решение |
|---------|-------------|---------|
| SSH оборвался при build | слабый VPS | swap 2G + `./scripts/node-update.sh` на worker |
| home offline в discovery | `curl worker:8001/health` | firewall 8001; approve enrollment |
| `pending` после deploy | `approve-pending-nodes.sh` | hybrid mode требует approve |
| smoke FAIL discovery/gateway на worker | норма | discovery/gateway только на main |
| smoke FAIL discovery/gateway на main | `docker compose ps` | `node-update.sh` |

### Админка / безопасность

| Симптом | Решение |
|---------|---------|
| Monitor `Failed to fetch` + `discovery-node:8003` | браузер не резолвит Docker DNS; мониторинг через `/api/monitor/registry/nodes` (после git pull admin) |
| Setup показывает JWT | обновить admin-server (секреты маскируются); **закрыть 9201** |
| 9201 открыт в интернет | `ufw delete allow 9201`; `ADMIN_BIND=127.0.0.1` в compose |

### enroll-worker оборвался

```bash
./scripts/fix-autodeploy-main.sh
# или вручную на main:
cd /opt/messenger/project && GITEA_PASSWORD=... ./scripts/setup-gitea-webhook.sh
```

---

## Чеклист для backend-агента

### При изменении кода

1. `git push origin main`
2. подождать ~30–60 с
3. `test-autodeploy.sh` или curl health
4. при новом сервисе — добавить в `NODE_SERVICES` на нужной машине

### При добавлении worker

1. `enroll-worker.sh --worker root@IP --worker-ip IP`
2. `approve-pending-nodes.sh` на main
3. проверить `workers.list` и orchestrator SSH

### Security backlog

- [ ] Закрыть 9201 на 194.67.92.147 (ufw + панель хостинга)
- [ ] Gitea :3000 / :2222 — только свой IP или VPN
- [ ] `INTERNAL_SECURITY_MODE=signed` (после тестов клиента)
- [ ] HTTPS nginx + certbot (PWA iOS, WebRTC)
- [ ] Бэкап `data/*.db` по cron на workers

### Не коммитить

`.env`, `data/`, `config/deploy/gitea.env`, `laptop.env`, `node.profile`, `workers.list`

---

## Связанные документы

| Файл | Содержание |
|------|------------|
| `docs/DEPLOY-PRODUCTION.md` | краткий production guide |
| `docs/pwa-deploy.md` | Flutter Web / телефон |
| `docs/architecture-network.md` | схема сети |
| `config/deploy/cluster.env.example` | общие env для всех нод |
| `spec/ADR/0006-staged-decentralization-bootstrap-authority.md` | почему admin — bootstrap |

---

## Быстрый старт для нового агента

```bash
# 1. Прочитать этот файл
# 2. Проверить живость:
curl -s http://194.67.92.147:8003/health
curl -s http://161.104.18.45:8001/health

# 3. Закрыть публичную админку (если ещё открыта):
ssh root@194.67.92.147 'ufw delete allow 9201/tcp 2>/dev/null; ufw status'

# 4. Любое изменение backend:
cd project && git push origin main

# 5. Новый worker:
./scripts/enroll-worker.sh --worker root@NEW --worker-ip NEW
ssh root@194.67.92.147 'cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh'
```
