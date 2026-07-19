"""personal_pc backend — блобы хранятся на домашнем ПК пользователя (storage-app).

Реализует тот же контракт `BlobBackend`, что и local/s3, но каждый вызов —
это key-аутентифицированный запрос к storage-app по ключевому протоколу
(LAN-direct или relay-fallback). Проектная спека:
    ../../../../../storage-app/docs/{SPEC,PAIRING,SETTINGS}.md

Ключевые решения (см. SETTINGS.md):
- Синхронный фасад — как LocalDiskBackend/S3Backend (роутер media.py синхронный).
- Нода аутентифицируется своим Ed25519-ключом (NODE_SIGNING_KEY_PATH), который
  должен быть сопряжён с storage-app (PAIRING.md).
- `user_id` неймспейсит удалённое хранилище (папка на пользователя на ПК).
- `key` — хэш шифротекста (контентная адресация); блобы уже E2EE, ПК видит шифр.
- Транспорт и подпись вынесены за интерфейс `PersonalPCTransport` — тестируемо и
  заменяемо; реализация транспорта — отдельная задача (ниже помечено NotImplemented).
"""

from __future__ import annotations

import base64
import hashlib
import os
import time
from dataclasses import dataclass
from typing import Optional, Protocol

from app.backends.base import BlobBackend  # noqa: F401  (контракт, которому соответствуем)


# --------------------------------------------------------------------------- #
# Конфигурация профиля (из storage.json -> personal_cloud.users[user_id])
# --------------------------------------------------------------------------- #
@dataclass
class PersonalPCSettings:
    user_id: str                    # чью данные храним (неймспейс на ПК)
    peer_pubkey: str                # "ed25519:BASE64" — публичный ключ storage-app
    relay_url: str = ""             # fallback-транспорт при NAT (пусто = только LAN)
    storage_node_id: str = ""       # id storage-app на relay (обязателен для relay)
    lan_hint: str = ""              # "host:port" для LAN-direct (или mDNS-обнаружение)
    quota_bytes: int = 0            # информационно; авторитетную квоту держит ПК
    connect_timeout_s: float = 5.0
    request_timeout_s: float = 30.0


# --------------------------------------------------------------------------- #
# Исключения. Синхронный контракт put/get/delete/exists не может вернуть статус
# «переполнено» — поэтому сигналим исключениями, а вызывающий (media.py) решает
# fallback на primary/S3 (см. SETTINGS.md §7 «переполнение → reject»).
# --------------------------------------------------------------------------- #
class PersonalPCError(Exception):
    """Базовое для всех ошибок personal_pc backend."""


class PersonalPCUnavailable(PersonalPCError):
    """Нет канала до ПК: оффлайн, диск отключён, relay недоступен."""


class PersonalPCQuotaExceeded(PersonalPCError):
    """PUT отклонён по квоте. Нода должна сделать fallback, данные не потеряны."""


class PersonalPCAuthError(PersonalPCError):
    """Пара/подпись отвергнуты storage-app (не сопряжены или ключ отозван)."""


class PersonalPCIntegrityError(PersonalPCError):
    """Хэш содержимого не совпал с key (повреждение/подмена)."""


# --------------------------------------------------------------------------- #
# Транспорт: put/get/delete/stat/usage/ping поверх подписанного канала.
# Backend от него зависит, но не знает, LAN это или relay.
# --------------------------------------------------------------------------- #
@dataclass
class PersonalPCResponse:
    status: str                     # "ok" | "not_found" | "quota_exceeded"
                                    #        | "unauthorized" | "unavailable" | "error"
    body: bytes = b""               # для GET
    size: int = 0                   # для STAT/PUT
    detail: str = ""                # человекочитаемая причина ошибки


@dataclass
class PersonalPCUsage:
    used_bytes: int
    used_files: int
    quota_bytes: int                # 0 = без лимита


class PersonalPCTransport(Protocol):
    """Абстракция канала до storage-app. Реализация подписывает запросы ключом
    ноды, устанавливает канал (LAN-direct → relay-fallback) и проверяет
    отпечаток `peer_pubkey`."""

    def request(
        self,
        op: str,                    # "PUT" | "GET" | "DELETE" | "STAT" | "USAGE" | "PING"
        *,
        user_id: str,
        key: str = "",
        body: bytes = b"",
    ) -> PersonalPCResponse: ...

    def close(self) -> None: ...


_DEFAULT_PORT = 7345


def _sha256_hex(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def _parse_lan_base(lan_hint: str) -> str:
    """`lan_hint` = "host[:port]" или "http(s)://host[:port]" → base URL.
    Порт по умолчанию — 7345 (WIRE.md). Без схемы — http (LAN-direct)."""
    hint = (lan_hint or "").strip()
    if not hint:
        raise PersonalPCUnavailable("lan_hint пуст: LAN-direct недоступен (relay — фаза 2)")
    scheme = "http"
    rest = hint
    if "://" in hint:
        scheme, rest = hint.split("://", 1)
    rest = rest.rstrip("/")
    if ":" in rest:
        host, _port = rest.rsplit(":", 1)
        # если после ':' не число (например IPv6 без порта) — берём как есть с деф. портом
        if _port.isdigit():
            return f"{scheme}://{rest}"
        return f"{scheme}://{rest}:{_DEFAULT_PORT}"
    return f"{scheme}://{rest}:{_DEFAULT_PORT}"


class _LanDirectTransport:
    """LAN-direct HTTP-транспорт по WIRE.md. Подписывает каждый запрос Ed25519
    ключом ноды (canonical: METHOD\\nPATH\\ntimestamp\\nhex(sha256(body))),
    ставит заголовки X-PPC-Node-Id/Pubkey/Timestamp/Signature."""

    # BlobBackend op -> (HTTP-метод, шаблон пути)
    _ROUTES = {
        "PUT": ("PUT", "/ppc/blob/{user_id}/{key}"),
        "GET": ("GET", "/ppc/blob/{user_id}/{key}"),
        "DELETE": ("DELETE", "/ppc/blob/{user_id}/{key}"),
        "STAT": ("GET", "/ppc/stat/{user_id}/{key}"),
        "USAGE": ("GET", "/ppc/usage"),
        "REVOKE": ("POST", "/ppc/revoke"),
        "PING": ("GET", "/ppc/health"),
    }

    def __init__(self, cfg: PersonalPCSettings, node_signing_key_path: str):
        import httpx  # локальный импорт: тяжёлую зависимость тянем только при сборке транспорта
        from nacl.signing import SigningKey

        self._cfg = cfg
        base = _parse_lan_base(cfg.lan_hint)
        self._client = httpx.Client(
            base_url=base,
            timeout=httpx.Timeout(
                cfg.request_timeout_s, connect=cfg.connect_timeout_s
            ),
        )
        # Ключ ноды: тот же формат, что shared/security/keys.py (urlsafe-b64 seed).
        seed = self._load_seed(node_signing_key_path)
        self._sk = SigningKey(seed)
        self._pubkey_b64 = base64.b64encode(bytes(self._sk.verify_key)).decode()
        self._node_id = os.getenv("MEDIA_NODE_ID", "media-local")

    @staticmethod
    def _load_seed(path: str) -> bytes:
        if not path:
            raise PersonalPCAuthError("NODE_SIGNING_KEY_PATH не задан")
        try:
            text = open(path, "r", encoding="utf-8").read().strip()
        except OSError as e:
            raise PersonalPCAuthError(f"не могу прочитать ключ ноды: {e}")
        if not text:
            raise PersonalPCAuthError("ключ ноды пуст")
        return base64.urlsafe_b64decode(text.encode())

    def _sign_headers(self, method: str, path: str, body: bytes) -> dict:
        ts = str(int(time.time()))
        canonical = f"{method}\n{path}\n{ts}\n{_sha256_hex(body)}".encode()
        sig = self._sk.sign(canonical).signature
        return {
            "X-PPC-Node-Id": self._node_id,
            "X-PPC-Pubkey": f"ed25519:{self._pubkey_b64}",
            "X-PPC-Timestamp": ts,
            "X-PPC-Signature": base64.b64encode(sig).decode(),
        }

    def request(
        self,
        op: str,
        *,
        user_id: str,
        key: str = "",
        body: bytes = b"",
    ) -> PersonalPCResponse:
        import httpx

        try:
            method, tmpl = self._ROUTES[op]
        except KeyError:
            return PersonalPCResponse(status="error", detail=f"unknown op {op}")

        path = tmpl.format(user_id=user_id, key=key)
        params = {"user_id": user_id} if op == "USAGE" else None
        headers = self._sign_headers(method, path, body)
        if op == "PUT":
            headers["Content-Type"] = "application/octet-stream"

        try:
            resp = self._client.request(
                method, path, params=params,
                content=body if op == "PUT" else None,
                headers=headers,
            )
        except httpx.HTTPError as e:
            return PersonalPCResponse(status="unavailable", detail=str(e))

        return self._interpret(op, resp)

    @staticmethod
    def _interpret(op: str, resp) -> PersonalPCResponse:
        code = resp.status_code
        detail = ""
        if code >= 400:
            try:
                detail = resp.json().get("detail", "") or resp.json().get("error", "")
            except Exception:
                detail = resp.text[:200]

        if code == 401:
            return PersonalPCResponse(status="unauthorized", detail=detail)
        if code == 413:
            return PersonalPCResponse(status="quota_exceeded", detail=detail)
        if code == 422:
            return PersonalPCResponse(status="integrity", detail=detail)
        if code == 404:
            # GET/STAT → not_found (не ошибка); DELETE идемпотентен (тоже not_found→ok у backend)
            return PersonalPCResponse(status="not_found", detail=detail)
        if code >= 500:
            return PersonalPCResponse(status="unavailable", detail=detail or f"HTTP {code}")
        if code != 200:
            return PersonalPCResponse(status="error", detail=detail or f"HTTP {code}")

        # 200 OK
        if op == "GET":
            return PersonalPCResponse(status="ok", body=resp.content, size=len(resp.content))
        if op in ("PUT", "STAT", "USAGE", "PING", "DELETE"):
            size = 0
            try:
                size = int(resp.json().get("size", 0))
            except Exception:
                pass
            return PersonalPCResponse(status="ok", body=resp.content, size=size)
        return PersonalPCResponse(status="ok", body=resp.content)

    def close(self) -> None:
        try:
            self._client.close()
        except Exception:
            pass


class _RelayHttpResponse:
    """Minimal httpx-like wrapper for _LanDirectTransport._interpret."""

    def __init__(self, status_code: int, content: bytes):
        self.status_code = status_code
        self.content = content
        self.text = content.decode("utf-8", errors="replace")

    def json(self):
        import json

        return json.loads(self.text)


class _RelayTransport:
    """Relay-fallback: тот же PPC-протокол, но через relay invoke."""

    def __init__(self, cfg: PersonalPCSettings, node_signing_key_path: str):
        from nacl.signing import SigningKey

        self._cfg = cfg
        self._node_signing_key_path = node_signing_key_path
        seed = _LanDirectTransport._load_seed(node_signing_key_path)
        self._sk = SigningKey(seed)
        self._pubkey_b64 = base64.b64encode(bytes(self._sk.verify_key)).decode()
        self._node_id = os.getenv("MEDIA_NODE_ID", "media-local")

    def _sign_headers(self, method: str, path: str, body: bytes) -> dict:
        ts = str(int(time.time()))
        canonical = f"{method}\n{path}\n{ts}\n{_sha256_hex(body)}".encode()
        sig = self._sk.sign(canonical).signature
        return {
            "X-PPC-Node-Id": self._node_id,
            "X-PPC-Pubkey": f"ed25519:{self._pubkey_b64}",
            "X-PPC-Timestamp": ts,
            "X-PPC-Signature": base64.b64encode(sig).decode(),
        }

    def request(
        self,
        op: str,
        *,
        user_id: str,
        key: str = "",
        body: bytes = b"",
    ) -> PersonalPCResponse:
        from urllib.parse import urlencode

        from shared.storage.personal_pc_pairing import ppc_relay_invoke

        try:
            method, tmpl = _LanDirectTransport._ROUTES[op]
        except KeyError:
            return PersonalPCResponse(status="error", detail=f"unknown op {op}")

        path = tmpl.format(user_id=user_id, key=key)
        invoke_path = path
        if op == "USAGE":
            invoke_path = f"{path}?{urlencode({'user_id': user_id})}"
        headers = self._sign_headers(method, path, body)
        if op == "PUT":
            headers["Content-Type"] = "application/octet-stream"

        try:
            status_code, content, _ = ppc_relay_invoke(
                relay_url=self._cfg.relay_url,
                storage_node_id=self._cfg.storage_node_id,
                method=method,
                path=invoke_path,
                headers=headers,
                body=body if op == "PUT" else b"",
                signing_key_path=self._node_signing_key_path,
                caller_node_id=self._node_id,
                timeout_s=self._cfg.request_timeout_s,
            )
        except Exception as e:
            return PersonalPCResponse(status="unavailable", detail=str(e))

        return _LanDirectTransport._interpret(op, _RelayHttpResponse(status_code, content))

    def close(self) -> None:
        pass


class _CompositeTransport:
    """Ordered failover: LAN-direct → relay. Sticks to first working route."""

    def __init__(self, transports: list[PersonalPCTransport]):
        self._transports = transports
        self._active_idx: Optional[int] = None

    def request(
        self,
        op: str,
        *,
        user_id: str,
        key: str = "",
        body: bytes = b"",
    ) -> PersonalPCResponse:
        last = PersonalPCResponse(status="unavailable", detail="all transports failed")
        if self._active_idx is not None:
            order = list(range(self._active_idx, len(self._transports))) + list(
                range(0, self._active_idx)
            )
        else:
            order = list(range(len(self._transports)))

        for idx in order:
            try:
                resp = self._transports[idx].request(
                    op, user_id=user_id, key=key, body=body
                )
            except (OSError, ConnectionError) as e:
                last = PersonalPCResponse(status="unavailable", detail=str(e))
                continue
            if resp.status == "unavailable":
                last = resp
                continue
            self._active_idx = idx
            return resp
        return last

    def close(self) -> None:
        for tx in self._transports:
            try:
                tx.close()
            except Exception:
                pass


def build_default_transport(
    cfg: PersonalPCSettings,
    node_signing_key_path: str,
) -> PersonalPCTransport:
    """Собирает транспорт по умолчанию.

    Приоритет: LAN-direct (`cfg.lan_hint`) → relay-fallback
    (`cfg.relay_url` + `cfg.storage_node_id`). При обоих маршрутах — failover.
    """
    transports: list[PersonalPCTransport] = []
    if cfg.lan_hint:
        transports.append(_LanDirectTransport(cfg, node_signing_key_path))
    if cfg.relay_url and cfg.storage_node_id:
        transports.append(_RelayTransport(cfg, node_signing_key_path))
    if not transports:
        raise PersonalPCUnavailable("нет ни lan_hint, ни relay (relay_url + storage_node_id)")
    if len(transports) == 1:
        return transports[0]
    return _CompositeTransport(transports)


# --------------------------------------------------------------------------- #
# Backend
# --------------------------------------------------------------------------- #
class PersonalPCBackend:
    """BlobBackend поверх storage-app на домашнем ПК."""

    name = "personal_pc"

    def __init__(
        self,
        cfg: PersonalPCSettings,
        transport: Optional[PersonalPCTransport] = None,
        node_signing_key_path: str = "",
    ):
        self.cfg = cfg
        self._transport = transport
        self._node_signing_key_path = node_signing_key_path

    # -- контракт BlobBackend ------------------------------------------------ #
    def put(self, key: str, data: bytes) -> None:
        """Сохранить блоб. Идемпотентно (контентная адресация).
        raises PersonalPCQuotaExceeded — если ПК отклонил по квоте (fallback у ноды);
        raises PersonalPCUnavailable — если ПК недоступен."""
        resp = self._tx().request("PUT", user_id=self.cfg.user_id, key=key, body=data)
        if resp.status == "ok":
            return
        if resp.status == "quota_exceeded":
            raise PersonalPCQuotaExceeded(f"{self.cfg.user_id}: {resp.detail or 'quota'}")
        self._raise(resp)

    def get(self, key: str) -> Optional[bytes]:
        """Вернуть блоб или None, если его нет. Проверяет хэш содержимого."""
        resp = self._tx().request("GET", user_id=self.cfg.user_id, key=key)
        if resp.status == "not_found":
            return None
        if resp.status != "ok":
            self._raise(resp)
        self._verify_integrity(key, resp.body)
        return resp.body

    def delete(self, key: str) -> None:
        """Удалить блоб. Идемпотентно (not_found не ошибка)."""
        resp = self._tx().request("DELETE", user_id=self.cfg.user_id, key=key)
        if resp.status in ("ok", "not_found"):
            return
        self._raise(resp)

    def exists(self, key: str) -> bool:
        """Есть ли блоб (через STAT)."""
        resp = self._tx().request("STAT", user_id=self.cfg.user_id, key=key)
        if resp.status == "ok":
            return True
        if resp.status == "not_found":
            return False
        self._raise(resp)

    # -- сверх контракта (управление/мониторинг) ----------------------------- #
    def usage(self) -> PersonalPCUsage:
        """Занятый объём/файлы и квота на стороне ПК (для экрана статуса ноды)."""
        import json

        resp = self._tx().request("USAGE", user_id=self.cfg.user_id)
        if resp.status != "ok":
            self._raise(resp)
        try:
            data = json.loads(resp.body.decode() or "{}")
        except (ValueError, UnicodeDecodeError) as e:
            raise PersonalPCError(f"USAGE: неразбираемый ответ: {e}")
        return PersonalPCUsage(
            used_bytes=int(data.get("used_bytes", 0)),
            used_files=int(data.get("used_files", 0)),
            quota_bytes=int(data.get("quota_bytes", 0)),
        )

    def ping(self) -> bool:
        """Жив ли ПК и установлен ли канал (health-check без исключений)."""
        try:
            return self._tx().request("PING", user_id=self.cfg.user_id).status == "ok"
        except PersonalPCError:
            return False

    def revoke(self) -> None:
        """Self-revoke pairing на storage-app (POST /ppc/revoke)."""
        resp = self._tx().request("REVOKE", user_id=self.cfg.user_id)
        if resp.status != "ok":
            self._raise(resp)

    def close(self) -> None:
        if self._transport is not None:
            self._transport.close()
            self._transport = None

    # -- внутреннее ---------------------------------------------------------- #
    def _tx(self) -> PersonalPCTransport:
        if self._transport is None:
            self._transport = build_default_transport(self.cfg, self._node_signing_key_path)
        return self._transport

    def _verify_integrity(self, key: str, data: bytes) -> None:
        """key — hex SHA-256 шифротекста (контентная адресация, WIRE.md).
        Сверяем, что ПК вернул именно запрошенный блоб."""
        actual = hashlib.sha256(data).hexdigest()
        if actual != key:
            raise PersonalPCIntegrityError(
                f"{self.cfg.user_id}: хэш не совпал (ожидался {key}, получен {actual})"
            )

    @staticmethod
    def _raise(resp: PersonalPCResponse) -> None:
        if resp.status == "unauthorized":
            raise PersonalPCAuthError(resp.detail or "not paired / key revoked")
        if resp.status == "unavailable":
            raise PersonalPCUnavailable(resp.detail or "storage-app offline")
        if resp.status == "integrity":
            raise PersonalPCIntegrityError(resp.detail or "content hash mismatch")
        raise PersonalPCError(f"{resp.status}: {resp.detail}")
