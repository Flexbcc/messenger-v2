"""
Транспорт пульта оператора — mTLS-соединения с нодами.

КОНТЕКСТ
    Пульт запускается на машине оператора, а не на сервере. Ноды при этом
    закрыты: их админ-порт принимает только тех, кто предъявил клиентский
    сертификат, выпущенный CA федерации.

    Этот модуль отвечает за предъявление сертификата и за то, чтобы пульт
    не мог случайно выйти за рамки своих прав на чужих нодах.

МОДЕЛЬ ПРАВ
    Свои ноды (в OPERATOR_OWNED_NODES) — полный доступ: телеметрия,
    конфигурация, перезапуск.

    Чужие ноды — только то, что нода сама отдаёт в discovery по heartbeat,
    и операции реестра федерации (approve/suspend/trust level). Напрямую
    к чужой ноде пульт не ходит: её владелец управляет ею сам, иначе
    обещание «твои данные на твоём сервере» перестаёт быть правдой.
"""
from __future__ import annotations

import os
import ssl
from pathlib import Path
from typing import Any, Optional

import httpx

# ── Пути к сертификатам ─────────────────────────────────────────────────────
CERT_DIR = Path(os.environ.get("OPERATOR_CERT_DIR", "/certs"))
CLIENT_CERT = CERT_DIR / os.environ.get("OPERATOR_CERT_NAME", "operator.crt")
CLIENT_KEY = CERT_DIR / os.environ.get("OPERATOR_KEY_NAME", "operator.key")
CA_CERT = CERT_DIR / "ca.crt"

# ── Адреса шлюзов ───────────────────────────────────────────────────────────
# Пульт ходит на mTLS-шлюз, а не напрямую на порт ноды.
DISCOVERY_GATEWAY = os.environ.get("OPERATOR_DISCOVERY_URL", "").rstrip("/")
HOME_GATEWAY = os.environ.get("OPERATOR_HOME_URL", "").rstrip("/")

# ── Свои ноды ───────────────────────────────────────────────────────────────
# Список node_id через запятую. Только для них разрешены операции,
# выходящие за рамки телеметрии и реестра.
OWNED_NODES = {
    n.strip()
    for n in os.environ.get("OPERATOR_OWNED_NODES", "").split(",")
    if n.strip()
}


class OperatorTransportError(RuntimeError):
    """Проблема с сертификатами или связью — сообщение годится для показа."""


def certificates_present() -> bool:
    return CLIENT_CERT.is_file() and CLIENT_KEY.is_file() and CA_CERT.is_file()


def describe_certificates() -> dict[str, Any]:
    """Состояние сертификатов — для страницы диагностики пульта."""
    return {
        "cert_dir": str(CERT_DIR),
        "client_cert": {"path": str(CLIENT_CERT), "exists": CLIENT_CERT.is_file()},
        "client_key": {"path": str(CLIENT_KEY), "exists": CLIENT_KEY.is_file()},
        "ca_cert": {"path": str(CA_CERT), "exists": CA_CERT.is_file()},
        "ready": certificates_present(),
    }


def _build_ssl_context() -> ssl.SSLContext:
    """
    SSL-контекст с клиентским сертификатом.

    Проверка сертификата сервера включена: иначе кто-то, перехвативший
    соединение, мог бы притвориться нодой и собрать наши админ-запросы.
    Доверяем только своему CA — публичные удостоверяющие центры здесь
    не при чём.
    """
    if not certificates_present():
        missing = [
            str(p)
            for p in (CLIENT_CERT, CLIENT_KEY, CA_CERT)
            if not p.is_file()
        ]
        raise OperatorTransportError(
            "Не найдены сертификаты оператора: "
            + ", ".join(missing)
            + ". Выпустите их: bash scripts/generate-operator-cert.sh <имя> "
            "и скопируйте в operator-console/certs/"
        )

    ctx = ssl.create_default_context(cafile=str(CA_CERT))
    ctx.load_cert_chain(certfile=str(CLIENT_CERT), keyfile=str(CLIENT_KEY))
    ctx.check_hostname = False  # сертификаты нод выписаны на CN=localhost
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def client(timeout: float = 15.0) -> httpx.AsyncClient:
    """
    HTTP-клиент, предъявляющий сертификат оператора.

    Использование:
        async with operator_transport.client() as c:
            r = await c.get(f"{DISCOVERY_GATEWAY}/admin/registry/nodes")
    """
    return httpx.AsyncClient(verify=_build_ssl_context(), timeout=timeout)


def is_owned(node_id: str) -> bool:
    """Наша ли это нода — то есть можно ли выходить за рамки телеметрии."""
    return node_id in OWNED_NODES


def require_owned(node_id: str) -> None:
    """
    Проверка перед операцией, затрагивающей внутренности ноды.

    Реестр федерации (approve, suspend, trust level) сюда не относится —
    это наше право как оператора федерации, и оно применимо к любой ноде.
    А вот менять конфиг или перезапускать сервисы можно только у себя.
    """
    if node_id not in OWNED_NODES:
        raise OperatorTransportError(
            f"Нода «{node_id}» не в списке ваших ({', '.join(sorted(OWNED_NODES)) or 'список пуст'}). "
            "Управлять чужой нодой нельзя — её владелец делает это сам. "
            "Доступны телеметрия и операции реестра федерации."
        )


async def discovery_request(
    method: str,
    path: str,
    *,
    json_body: Optional[dict] = None,
    params: Optional[dict] = None,
    timeout: float = 15.0,
) -> httpx.Response:
    """
    Запрос к admin API discovery через mTLS-шлюз.

    Секрет discovery подставляет шлюз на стороне сервера — пульт его
    не знает и не хранит. Единственный ключ доступа здесь — сертификат.
    """
    if not DISCOVERY_GATEWAY:
        raise OperatorTransportError(
            "OPERATOR_DISCOVERY_URL не задан — пульт не знает, куда обращаться. "
            "Укажите адрес mTLS-шлюза, например https://node.example.com:9443"
        )

    url = f"{DISCOVERY_GATEWAY}/{path.lstrip('/')}"
    try:
        async with client(timeout=timeout) as c:
            return await c.request(method, url, json=json_body, params=params)
    except ssl.SSLError as e:
        raise OperatorTransportError(
            f"TLS-соединение отклонено: {e}. "
            "Проверьте, что отпечаток вашего сертификата есть в allowlist ноды "
            "(config/nginx/operators-allowlist.conf) и шлюз перезагружен."
        ) from e
    except httpx.ConnectError as e:
        raise OperatorTransportError(
            f"Не удалось подключиться к {DISCOVERY_GATEWAY}: {e}. "
            "Проверьте адрес шлюза и что порт открыт для вашего IP."
        ) from e


async def home_request(
    method: str,
    path: str,
    *,
    json_body: Optional[dict] = None,
    params: Optional[dict] = None,
    timeout: float = 15.0,
) -> httpx.Response:
    """Запрос к монитору своей home-ноды через mTLS-шлюз."""
    if not HOME_GATEWAY:
        raise OperatorTransportError(
            "OPERATOR_HOME_URL не задан — управление своей нодой недоступно."
        )

    url = f"{HOME_GATEWAY}/{path.lstrip('/')}"
    try:
        async with client(timeout=timeout) as c:
            return await c.request(method, url, json=json_body, params=params)
    except ssl.SSLError as e:
        raise OperatorTransportError(f"TLS-соединение отклонено: {e}") from e
    except httpx.ConnectError as e:
        raise OperatorTransportError(
            f"Не удалось подключиться к {HOME_GATEWAY}: {e}"
        ) from e
