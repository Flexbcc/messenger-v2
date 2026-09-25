import hmac
import os
import re
from pathlib import Path

from shared.security.webpush import validate_vapid_public_key


_DEVELOPMENT_SECRETS = {
    "changeme",
    "changeme-push-secret",
    "dev-secret-change-me-in-production",
}


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be a boolean")


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


def _security_mode() -> str:
    value = os.environ.get("PUSH_PROXY_SECURITY_MODE", "strict").strip().lower()
    if value not in {"legacy", "strict"}:
        raise RuntimeError("PUSH_PROXY_SECURITY_MODE must be legacy or strict")
    return value


class Settings:
    legacy_fcm_server_key: str | None = os.environ.get("FCM_SERVER_KEY")
    fcm_service_account_path: str | None = os.environ.get(
        "FCM_SERVICE_ACCOUNT_PATH"
    )
    fcm_project_id: str | None = os.environ.get("FCM_PROJECT_ID")
    apns_key_id: str | None = os.environ.get("APNS_KEY_ID")
    apns_team_id: str | None = os.environ.get("APNS_TEAM_ID")
    apns_bundle_id: str | None = os.environ.get("APNS_BUNDLE_ID", "com.example.messenger")
    apns_key_path: str | None = os.environ.get("APNS_KEY_PATH")
    apns_sandbox: bool = _env_bool("APNS_SANDBOX", False)
    push_proxy_secret: str = os.environ.get("PUSH_PROXY_SECRET", "")
    token_encryption_secret: str = os.environ.get(
        "PUSH_TOKEN_ENCRYPTION_SECRET", ""
    )
    security_mode: str = _security_mode()
    strict_security: bool = security_mode == "strict"
    database_url: str = os.environ.get("DATABASE_URL", "push_tokens.db")
    # TTL для хранения токена без активности (дней)
    token_stale_days: int = _bounded_int("TOKEN_STALE_DAYS", 90, 1, 3650)
    vapid_private_key: str | None = os.environ.get("VAPID_PRIVATE_KEY")
    vapid_public_key: str | None = os.environ.get("VAPID_PUBLIC_KEY")
    vapid_subject: str = os.environ.get("VAPID_SUBJECT", "mailto:admin@localhost")


settings = Settings()


def validate_security_configuration() -> None:
    """Reject repository-known credentials in every runtime mode."""
    secrets = {
        "PUSH_PROXY_SECRET": settings.push_proxy_secret,
        "PUSH_TOKEN_ENCRYPTION_SECRET": settings.token_encryption_secret,
    }
    minimum_bytes = 32 if settings.strict_security else 16
    if not settings.strict_security and not _env_bool(
        "ALLOW_INSECURE_PUSH_PROXY", False
    ):
        raise RuntimeError(
            "legacy Push Proxy mode requires ALLOW_INSECURE_PUSH_PROXY=true"
        )
    for name, value in secrets.items():
        if len(value.encode("utf-8")) < minimum_bytes or value in _DEVELOPMENT_SECRETS:
            raise RuntimeError(f"{name} must be a random secret of at least {minimum_bytes} bytes")
    if hmac.compare_digest(
        settings.push_proxy_secret, settings.token_encryption_secret
    ):
        raise RuntimeError("Push Proxy authentication and encryption secrets must differ")

    if settings.legacy_fcm_server_key:
        raise RuntimeError(
            "FCM_SERVER_KEY uses the retired legacy API; configure "
            "FCM_SERVICE_ACCOUNT_PATH for FCM HTTP v1"
        )
    if settings.fcm_project_id and not settings.fcm_service_account_path:
        raise RuntimeError(
            "FCM_PROJECT_ID requires FCM_SERVICE_ACCOUNT_PATH"
        )
    if settings.fcm_service_account_path:
        account_path = Path(settings.fcm_service_account_path)
        if not account_path.is_file():
            raise RuntimeError("FCM_SERVICE_ACCOUNT_PATH must reference a file")
        if account_path.stat().st_size > 64 * 1024:
            raise RuntimeError("FCM service account file is too large")
    if settings.fcm_project_id and not re.fullmatch(
        r"[a-z][a-z0-9-]{4,62}", settings.fcm_project_id
    ):
        raise RuntimeError("FCM_PROJECT_ID is invalid")

    if not settings.strict_security:
        return

    apns_values = {
        "APNS_KEY_ID": settings.apns_key_id,
        "APNS_TEAM_ID": settings.apns_team_id,
        "APNS_KEY_PATH": settings.apns_key_path,
    }
    configured_apns = [name for name, value in apns_values.items() if value]
    if configured_apns and len(configured_apns) != len(apns_values):
        raise RuntimeError("APNs configuration must be complete")
    if configured_apns and settings.apns_bundle_id == "com.example.messenger":
        raise RuntimeError("APNS_BUNDLE_ID must not use the example value")

    if bool(settings.vapid_private_key) != bool(settings.vapid_public_key):
        raise RuntimeError("VAPID private and public keys must be configured together")
    if settings.vapid_public_key:
        try:
            validate_vapid_public_key(settings.vapid_public_key)
        except ValueError as exc:
            raise RuntimeError("VAPID_PUBLIC_KEY is invalid") from exc
    if settings.vapid_private_key and settings.vapid_subject == "mailto:admin@localhost":
        raise RuntimeError("VAPID_SUBJECT must identify a real operator contact")
