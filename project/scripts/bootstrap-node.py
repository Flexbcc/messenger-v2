#!/usr/bin/env python3
"""Safe first-run installer for an OUO node.

Interactive by default. Automation uses --non-interactive and --dry-run.
Existing secrets are preserved, and no data is ever removed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import secrets
import subprocess
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / ".env"
OWNER_CARD = ROOT / "data" / "owner-access.txt"


def ask(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    return input(f"{label}{suffix}: ").strip() or default


def yes_no(label: str, default: bool = True) -> bool:
    marker = "Y/n" if default else "y/N"
    value = input(f"{label} [{marker}]: ").strip().lower()
    if not value:
        return default
    return value in {"y", "yes", "д", "да"}


def choose(label: str, options: list[tuple[str, str]], default: str) -> str:
    print(f"\n{label}")
    for key, title in options:
        print(f"  {key}) {title}")
    while True:
        value = ask("Выбор", default)
        if any(value == key for key, _ in options):
            return value
        print("Введите один из предложенных номеров.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install an OUO node")
    parser.add_argument("--network", choices=("public", "private", "join"))
    admin = parser.add_mutually_exclusive_group()
    admin.add_argument("--admin", dest="admin", action="store_true")
    admin.add_argument("--no-admin", dest="admin", action="store_false")
    parser.set_defaults(admin=None)
    parser.add_argument("--owner", default="Owner")
    parser.add_argument("--alias", default="My OUO node")
    parser.add_argument("--exposure", choices=("local", "private", "site"), default="local")
    parser.add_argument("--domain", default="")
    parser.add_argument("--discovery-url", default="")
    parser.add_argument("--public-url", default="")
    parser.add_argument("--cluster-id", default="")
    parser.add_argument("--non-interactive", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--lab-insecure",
        action="store_true",
        help="explicitly allow legacy trust modes for an isolated test network",
    )
    parser.add_argument("--start", action="store_true", help="start Docker after configuration")
    return parser.parse_args()


def load_env() -> tuple[list[str], dict[str, str]]:
    lines = ENV_FILE.read_text("utf-8").splitlines() if ENV_FILE.exists() else []
    values: dict[str, str] = {}
    for line in lines:
        if line and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return lines, values


def atomic_update(patch: dict[str, str]) -> None:
    lines, _ = load_env()
    managed = set(patch)
    output = [line for line in lines if not ("=" in line and line.split("=", 1)[0] in managed)]
    if output and output[-1] != "":
        output.append("")
    output.append("# Managed by scripts/bootstrap-node.py")
    output.extend(f"{key}={value}" for key, value in patch.items())
    tmp = ENV_FILE.with_suffix(".env.tmp")
    tmp.write_text("\n".join(output) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(ENV_FILE)


def strong_secret() -> str:
    return secrets.token_urlsafe(48)


def discovery_public_keys(discovery_url: str) -> str:
    """Fetch the advertised Discovery verification keys for a lab join.

    This is explicit trust-on-first-use and is therefore only used together
    with ``--lab-insecure``. Production installs must provision authority
    state and pinned keys through the strict deployment workflow.
    """
    url = f"{discovery_url.rstrip('/')}/discovery-pubkeys"
    with urllib.request.urlopen(url, timeout=5) as response:
        payload = json.load(response)
    entries = payload.get("public_keys") or payload.get("keys")
    if not isinstance(entries, list):
        entries = []
    keys = [
        entry if isinstance(entry, str) else entry.get("public_key")
        for entry in entries
        if isinstance(entry, (str, dict))
    ]
    if not keys or not all(isinstance(key, str) and key for key in keys):
        raise RuntimeError("Discovery returned no usable public keys")
    return ",".join(dict.fromkeys(keys))


def compose_command() -> list[str]:
    """Use the Compose v2 plugin when available, otherwise Debian's binary."""
    plugin = subprocess.run(
        ["docker", "compose", "version"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if plugin.returncode == 0:
        return ["docker", "compose"]
    return ["docker-compose"]


def stable_node_id(existing: dict[str, str]) -> str:
    if existing.get("HOME_NODE_ID"):
        return existing["HOME_NODE_ID"]
    seed = secrets.token_bytes(32)
    return f"node-{hashlib.sha256(seed).hexdigest()[:24]}"


def service_plan(network: str, admin_enabled: bool) -> list[str]:
    # The headless management API is independent from either browser panel.
    # This keeps a --no-admin node manageable from an explicitly paired phone.
    services = ["home-node", "management-node"]
    if network == "private":
        services = [
            "discovery-node", "gateway-node", "storage-node", "relay-node",
            "turn-node", "coturn", "home-node", "management-node",
        ]
    if admin_enabled:
        services.append("admin")
    return services


def main() -> int:
    args = parse_args()
    print("\nOUO — мастер установки ноды")
    print("Существующие данные и контейнеры не удаляются.\n")
    _, existing = load_env()

    if args.non_interactive:
        network = args.network or "public"
        admin_enabled = True if args.admin is None else args.admin
        owner_name, alias, exposure, site = args.owner, args.alias, args.exposure, args.domain
    else:
        admin_enabled = yes_no("Нужна веб-панель управления?", True)
        network_choice = choose(
            "Как должна работать нода?",
            [("1", "Подключиться к общей сети OUO"), ("2", "Создать собственную изолированную сеть")],
            "1",
        )
        network = "public" if network_choice == "1" else "private"
        owner_name = ask("Имя владельца (не аккаунт мессенджера)", args.owner)
        alias = ask("Псевдоним ноды в вашей панели", args.alias)
        exposure, site = "local", ""
        if admin_enabled:
            access = choose(
                "Как открывать админку?",
                [("1", "SSH / localhost"), ("2", "Tailscale / WireGuard"), ("3", "Домен с автоматическим HTTPS")],
                "1",
            )
            exposure = {"1": "local", "2": "private", "3": "site"}[access]
            if exposure == "site":
                site = ask("Домен без пути (например node.example.com)")

    lab_insecure = args.lab_insecure
    if not args.non_interactive and not args.dry_run:
        lab_insecure = yes_no(
            "Лабораторный режим без strict mTLS/capability certificates? "
            "Только для изолированного стенда",
            False,
        )

    if exposure == "site" and not site:
        raise SystemExit("--domain is required when --exposure=site")
    if args.start and network in {"public", "join"} and not args.discovery_url:
        raise SystemExit("--discovery-url is required for a public/child node")
    if network == "join" and not args.cluster_id:
        raise SystemExit("--cluster-id is required when joining a private network")

    node_id = stable_node_id(existing)
    cluster_id = (
        args.cluster_id
        or existing.get("CLUSTER_ID")
        or (f"private-{secrets.token_hex(8)}" if network == "private" else "ouo-public")
    )
    services = service_plan(network, admin_enabled)
    print("План:")
    network_title = {
        "private": "собственная",
        "join": "дочерняя нода частной сети",
        "public": "общая OUO",
    }[network]
    print(f"  сеть: {network_title}")
    print(f"  Node ID: {node_id}")
    print(f"  сервисы: {', '.join(services)}")
    print(f"  Admin: {'да' if admin_enabled else 'нет'}")
    print(f"  защита: {'LAB LEGACY (не публиковать)' if lab_insecure else 'strict/fail-closed'}")
    if args.start and not lab_insecure:
        raise SystemExit(
            "Automatic start requires configured strict certificates/authority state. "
            "For an isolated test network, explicitly pass --lab-insecure."
        )
    if args.dry_run:
        print("\nDRY-RUN: файлы и Docker не изменены.")
        return 0

    values = {
        "OUO_NETWORK_MODE": network,
        "NODE_DISPLAY_NAME": alias,
        "CLUSTER_ID": cluster_id,
        "HOME_NODE_ID": node_id,
        "OWNER_PANEL_ENABLED": "true" if admin_enabled else "false",
    }
    if args.discovery_url:
        discovery_url = args.discovery_url.rstrip("/")
        values.update({
            "DISCOVERY_NODE_URL": discovery_url,
            "ROUTE_DISCOVERY_URLS": discovery_url,
            "PEER_DISCOVERY_URLS": discovery_url,
        })
        if lab_insecure:
            values["DISCOVERY_SIGNING_PUBLIC_KEYS"] = discovery_public_keys(
                discovery_url
            )
    if args.public_url:
        values["HOME_NODE_PUBLIC_URL"] = args.public_url.rstrip("/")
    if lab_insecure:
        values.update({
            "ALLOW_INSECURE_FEDERATION_MODES": "true",
            "ALLOW_INSECURE_DISCOVERY_MODES": "true",
            "ALLOW_INSECURE_HOME_MODES": "true",
            "ALLOW_INSECURE_GATEWAY_MTLS": "true",
            "ALLOW_INSECURE_STORAGE_MODE": "true",
        })
    for key in (
        "JWT_SECRET", "DISCOVERY_ADMIN_SECRET", "GATEWAY_INVITE_SECRET",
        "MEDIA_ACCESS_SECRET", "MESH_NOTIFY_SECRET", "PUSH_PROXY_SECRET",
        "TURN_SHARED_SECRET", "OWNER_PANEL_SECRET",
    ):
        values[key] = existing.get(key) or strong_secret()

    admin_key = ""
    console_token = ""
    if admin_enabled:
        admin_key = existing.get("ADMIN_PANEL_SECRET") or strong_secret()
        console_token = existing.get("ADMIN_CONSOLE_PATH", "").strip("/") or secrets.token_urlsafe(48)
        values.update({
            "ADMIN_BIND": "127.0.0.1" if exposure == "local" else "0.0.0.0",
            "ADMIN_PORT": existing.get("ADMIN_PORT", "9201"),
            "ADMIN_CONSOLE_PATH": f"/{console_token}",
            "ADMIN_PANEL_SECRET": admin_key,
            "OWNER_PANEL_SECRET": values["OWNER_PANEL_SECRET"],
        })
    atomic_update(values)

    if admin_enabled:
        OWNER_CARD.parent.mkdir(parents=True, exist_ok=True)
        base = f"https://{site}" if exposure == "site" else f"http://127.0.0.1:{values['ADMIN_PORT']}"
        url = f"{base}/{console_token}/"
        OWNER_CARD.write_text(
            "OUO OWNER ACCESS — хранить как пароль от сервера\n\n"
            f"Владелец: {owner_name}\nПсевдоним: {alias}\nNode ID: {node_id}\n"
            f"Адрес панели: {url}\nКлюч владельца: {admin_key}\n",
            encoding="utf-8",
        )
        os.chmod(OWNER_CARD, 0o600)
        print(f"\nАдрес панели: {url}")
        print(f"Карточка владельца: {OWNER_CARD}")
    else:
        print("\nВеб-панель не установлена и её маршруты отключены.")

    print(
        "Мобильное управление включено через отдельный management API.\n"
        "После запуска создайте одноразовый QR/код сопряжения:\n"
        "  docker compose exec management-node "
        "python /app/ouoctl.py pair --role owner --expires 5"
    )

    if args.start or (not args.non_interactive and yes_no("Запустить Docker сейчас?", False)):
        subprocess.run([*compose_command(), "up", "-d", "--build", *services], cwd=ROOT, check=True)
        print("Нода запущена.")
    else:
        print(f"Запуск пропущен. Команда: docker compose up -d --build {' '.join(services)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
