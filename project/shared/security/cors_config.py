import os
from urllib.parse import urlsplit

from shared.security.config import INTERNAL_SECURITY_MODE


def client_allowed_origins(env_name: str = "CLIENT_ALLOWED_ORIGINS") -> list[str]:
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return [] if INTERNAL_SECURITY_MODE == "signed" else ["*"]

    origins: list[str] = []
    for item in raw.split(","):
        origin = item.strip().rstrip("/")
        if not origin:
            continue
        if origin == "*":
            if INTERNAL_SECURITY_MODE == "signed":
                raise RuntimeError(f"{env_name} cannot contain * in signed mode")
            return ["*"]
        parsed = urlsplit(origin)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path:
            raise RuntimeError(f"invalid origin in {env_name}: {origin}")
        if origin not in origins:
            origins.append(origin)
    return origins
