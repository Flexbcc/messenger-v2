"""
SSH-канал пульта оператора — обслуживание СВОИХ серверов.

ДВА КАНАЛА, РАЗНЫЕ ЗАДАЧИ
    mTLS (operator_transport.py) — телеметрия и реестр федерации.
    Работает для любой ноды, включая чужие: данные берутся из discovery,
    куда ноды сами их присылают.

    SSH (этот модуль) — обслуживание серверов: деплой, перезапуск
    контейнеров, чтение логов. Работает только там, где у тебя есть
    root-доступ, то есть на своих машинах.

    Разделение не формальное: чужая нода не даёт SSH и не должна.
    Её владелец обслуживает её сам.

ПЕРЕНОС ИЗ scripts/operator-console.py
    Логика инвентаря и команд взята оттуда. Отличия: команды собираются
    через shlex.quote, хосты и пути настраиваются через окружение, а не
    зашиты в код.
"""
from __future__ import annotations

import asyncio
import os
import shlex
from pathlib import Path
from typing import Any, Optional

# ── Настройки ───────────────────────────────────────────────────────────────
SSH_KEY = Path(os.environ.get("OPERATOR_SSH_KEY", "/ssh/id_operator"))
INSTALL_DIR = os.environ.get("OPERATOR_INSTALL_DIR", "/opt/messenger/project")
SSH_TIMEOUT = int(os.environ.get("OPERATOR_SSH_TIMEOUT", "120"))


def _parse_hosts() -> dict[str, str]:
    """
    OPERATOR_SSH_HOSTS="main=root@1.2.3.4,worker=root@5.6.7.8"

    Псевдонимы вместо адресов: инвентарь нод ссылается на «main»/«worker»,
    а конкретные адреса живут в конфигурации.
    """
    raw = os.environ.get("OPERATOR_SSH_HOSTS", "")
    hosts: dict[str, str] = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair or "=" not in pair:
            continue
        alias, _, target = pair.partition("=")
        hosts[alias.strip()] = target.strip()
    return hosts


HOSTS = _parse_hosts()


def _parse_inventory() -> list[dict[str, Any]]:
    """
    OPERATOR_NODE_INVENTORY="discovery-node:main:8003,home-node:worker:8001"
    формат: <compose-сервис>:<псевдоним хоста>:<порт|->

    Порт «-» означает внутренний сервис без своего health-эндпоинта.
    """
    raw = os.environ.get("OPERATOR_NODE_INVENTORY", "")
    items: list[dict[str, Any]] = []
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(":")
        if len(parts) < 2:
            continue
        service, alias = parts[0].strip(), parts[1].strip()
        port: Optional[int] = None
        if len(parts) > 2 and parts[2].strip() not in ("", "-"):
            try:
                port = int(parts[2])
            except ValueError:
                port = None
        items.append({"service": service, "host_alias": alias, "port": port})
    return items


INVENTORY = _parse_inventory()


class SshUnavailable(RuntimeError):
    """SSH не настроен или недоступен — сообщение годится для показа."""


def ssh_configured() -> bool:
    return bool(HOSTS) and SSH_KEY.is_file()


def describe() -> dict[str, Any]:
    """Состояние SSH-канала для страницы диагностики."""
    return {
        "configured": ssh_configured(),
        "key": {"path": str(SSH_KEY), "exists": SSH_KEY.is_file()},
        "hosts": {alias: target for alias, target in HOSTS.items()},
        "install_dir": INSTALL_DIR,
        "inventory": INVENTORY,
    }


def _resolve_host(alias: str) -> str:
    if alias not in HOSTS:
        raise SshUnavailable(
            f"Хост «{alias}» не настроен. Известные: {', '.join(sorted(HOSTS)) or 'ни одного'}. "
            "Задайте OPERATOR_SSH_HOSTS в .env пульта."
        )
    return HOSTS[alias]


async def run(alias: str, command: str, *, timeout: int | None = None) -> tuple[int, str]:
    """
    Выполнить команду на сервере по SSH.

    Возвращает (код возврата, объединённый stdout+stderr).
    Исключение бросается только если SSH недоступен как таковой —
    ненулевой код возврата это нормальный результат, его разбирает вызывающий.
    """
    if not SSH_KEY.is_file():
        raise SshUnavailable(
            f"SSH-ключ не найден: {SSH_KEY}. "
            "Смонтируйте его в пульт и укажите OPERATOR_SSH_KEY."
        )

    host = _resolve_host(alias)
    argv = [
        "ssh",
        "-o", "BatchMode=yes",              # без интерактивных запросов пароля
        "-o", "ConnectTimeout=25",
        "-o", "StrictHostKeyChecking=accept-new",
        "-i", str(SSH_KEY),
        "-o", "IdentitiesOnly=yes",         # не подсовывать другие ключи агента
        host,
        command,
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout or SSH_TIMEOUT)
        return proc.returncode or 0, out.decode(errors="replace").strip()
    except asyncio.TimeoutError:
        return 1, f"SSH: превышено время ожидания ({timeout or SSH_TIMEOUT} с)"
    except FileNotFoundError:
        raise SshUnavailable(
            "Клиент ssh не найден в контейнере пульта. "
            "Добавьте openssh-client в образ admin-server."
        ) from None
    except OSError as e:
        return 1, f"SSH: {e}"


async def compose(alias: str, args: str, *, timeout: int | None = None) -> tuple[int, str]:
    """docker compose в каталоге установки на удалённом сервере."""
    return await run(
        alias, f"cd {shlex.quote(INSTALL_DIR)} && docker compose {args}", timeout=timeout
    )


# ── Операции обслуживания ───────────────────────────────────────────────────


async def services_status() -> list[dict[str, Any]]:
    """Состояние контейнеров на всех своих серверах."""
    if not ssh_configured():
        raise SshUnavailable(
            "SSH-канал не настроен: нет ключа или списка хостов. "
            "Телеметрия федерации при этом доступна — она идёт через mTLS."
        )

    async def one(item: dict[str, Any]) -> dict[str, Any]:
        service = item["service"]
        rc, out = await compose(
            item["host_alias"],
            f"ps {shlex.quote(service)} 2>/dev/null | tail -n +2 | head -1",
            timeout=25,
        )
        return {
            **item,
            "running": "Up" in out,
            "ps_line": out,
            "error": out if rc != 0 and not out.strip() else None,
        }

    return list(await asyncio.gather(*(one(i) for i in INVENTORY)))


async def restart_service(service: str) -> dict[str, Any]:
    """Перезапустить контейнер. Сервис должен быть в инвентаре."""
    item = next((i for i in INVENTORY if i["service"] == service), None)
    if item is None:
        raise SshUnavailable(
            f"Сервис «{service}» не в инвентаре. "
            f"Известные: {', '.join(i['service'] for i in INVENTORY) or 'ни одного'}"
        )
    rc, out = await compose(item["host_alias"], f"restart {shlex.quote(service)}", timeout=90)
    return {"service": service, "ok": rc == 0, "output": out}


async def service_logs(service: str, lines: int = 200) -> dict[str, Any]:
    """Последние строки лога контейнера."""
    item = next((i for i in INVENTORY if i["service"] == service), None)
    if item is None:
        raise SshUnavailable(f"Сервис «{service}» не в инвентаре")

    lines = max(1, min(lines, 2000))  # верхняя граница, чтобы не тянуть гигабайты
    rc, out = await compose(
        item["host_alias"], f"logs --tail {lines} {shlex.quote(service)}", timeout=60
    )
    return {"service": service, "ok": rc == 0, "lines": out.splitlines()}


async def deploy_status() -> dict[str, Any]:
    """Что сейчас развёрнуто: git-ревизия, статус последнего деплоя, вебхук."""
    if not ssh_configured():
        raise SshUnavailable("SSH-канал не настроен")

    alias = "main" if "main" in HOSTS else next(iter(HOSTS), "")
    d = shlex.quote(INSTALL_DIR)

    _, head = await run(alias, f"git -C {d} rev-parse --short HEAD 2>/dev/null || echo unknown", timeout=25)
    _, branch = await run(alias, f"git -C {d} rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown", timeout=25)
    _, status = await run(alias, f"cat {d}/config/deploy/last-deploy.status 2>/dev/null || true", timeout=25)
    _, webhook = await run(alias, "systemctl is-active messenger-deploy-webhook 2>/dev/null || echo inactive", timeout=25)

    return {
        "git_head": head or "unknown",
        "git_branch": branch or "unknown",
        "last_deploy": status or "нет данных",
        "webhook_active": webhook.strip() == "active",
    }


async def deploy_pull(alias: str | None = None) -> dict[str, Any]:
    """
    Обновить код на сервере и пересобрать.

    Намеренно не делает git push с ноутбука: пульт управляет серверами,
    а не публикует код. Код попадает в репозиторий обычным git push,
    отсюда — только раскатка того, что уже в ветке.
    """
    if not ssh_configured():
        raise SshUnavailable("SSH-канал не настроен")

    target = alias or ("main" if "main" in HOSTS else next(iter(HOSTS), ""))
    d = shlex.quote(INSTALL_DIR)
    rc, out = await run(
        target,
        f"cd {d} && git pull --ff-only 2>&1 && docker compose up -d --build 2>&1",
        timeout=600,
    )
    return {"host": target, "ok": rc == 0, "output": out}
