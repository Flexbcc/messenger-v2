import os


class Settings:
    fcm_server_key: str | None = os.environ.get("FCM_SERVER_KEY")
    apns_key_id: str | None = os.environ.get("APNS_KEY_ID")
    apns_team_id: str | None = os.environ.get("APNS_TEAM_ID")
    apns_bundle_id: str | None = os.environ.get("APNS_BUNDLE_ID", "com.example.messenger")
    apns_key_path: str | None = os.environ.get("APNS_KEY_PATH")
    apns_sandbox: bool = os.environ.get("APNS_SANDBOX", "false").lower() == "true"
    push_proxy_secret: str = os.environ.get("PUSH_PROXY_SECRET", "changeme")
    database_url: str = os.environ.get("DATABASE_URL", "push_tokens.db")
    # TTL для хранения токена без активности (дней)
    token_stale_days: int = int(os.environ.get("TOKEN_STALE_DAYS", "90"))
    vapid_private_key: str | None = os.environ.get("VAPID_PRIVATE_KEY")
    vapid_public_key: str | None = os.environ.get("VAPID_PUBLIC_KEY")
    vapid_subject: str = os.environ.get("VAPID_SUBJECT", "mailto:admin@localhost")


settings = Settings()
