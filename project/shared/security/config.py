import os


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


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value

INTERNAL_SECURITY_MODE = os.environ.get("INTERNAL_SECURITY_MODE", "signed").lower()
if INTERNAL_SECURITY_MODE not in ("legacy", "off", "signed"):
    raise RuntimeError("INTERNAL_SECURITY_MODE must be legacy, off, or signed")
FEDERATION_NODE_ID_MODE = os.environ.get("FEDERATION_NODE_ID_MODE", "enforce").lower()
if FEDERATION_NODE_ID_MODE not in ("legacy", "report", "enforce"):
    raise RuntimeError("FEDERATION_NODE_ID_MODE must be legacy, report, or enforce")
FEDERATION_ENVELOPE_MODE = os.environ.get("FEDERATION_ENVELOPE_MODE", "signed").lower()
if FEDERATION_ENVELOPE_MODE not in ("legacy", "signed"):
    raise RuntimeError("FEDERATION_ENVELOPE_MODE must be legacy or signed")
FEDERATION_CAPABILITY_MODE = os.environ.get("FEDERATION_CAPABILITY_MODE", "enforce").lower()
if FEDERATION_CAPABILITY_MODE not in ("legacy", "report", "enforce"):
    raise RuntimeError("FEDERATION_CAPABILITY_MODE must be legacy, report, or enforce")

ALLOW_INSECURE_FEDERATION_MODES = _env_bool(
    "ALLOW_INSECURE_FEDERATION_MODES", False
)
if not ALLOW_INSECURE_FEDERATION_MODES and (
    INTERNAL_SECURITY_MODE != "signed"
    or FEDERATION_NODE_ID_MODE != "enforce"
    or FEDERATION_ENVELOPE_MODE != "signed"
    or FEDERATION_CAPABILITY_MODE != "enforce"
):
    raise RuntimeError(
        "legacy/off/report federation modes require "
        "ALLOW_INSECURE_FEDERATION_MODES=true"
    )

FEDERATION_TIMESTAMP_SKEW_SECONDS = _env_int(
    "FEDERATION_TIMESTAMP_SKEW_SECONDS", 120, 5, 900
)
FEDERATION_MAX_BODY_BYTES = _env_int(
    "FEDERATION_MAX_BODY_BYTES", 1024 * 1024, 1024, 16 * 1024 * 1024
)
TRUST_CACHE_TTL_SECONDS = _env_int("TRUST_CACHE_TTL_SECONDS", 60, 1, 3600)
NONCE_TTL_SECONDS = _env_int("FEDERATION_NONCE_TTL_SECONDS", 300, 30, 86400)
ENVELOPE_NONCE_TTL_SECONDS = _env_int(
    "FEDERATION_ENVELOPE_NONCE_TTL_SECONDS", 86400, 60, 2_592_000
)
ENVELOPE_DEFAULT_TTL_SECONDS = _env_int(
    "FEDERATION_ENVELOPE_TTL_SECONDS", 86400, 1, 2_592_000
)
if not 1 <= ENVELOPE_DEFAULT_TTL_SECONDS <= ENVELOPE_NONCE_TTL_SECONDS:
    raise RuntimeError(
        "FEDERATION_ENVELOPE_TTL_SECONDS must be positive and no greater than nonce TTL"
    )

HDR_NODE_ID = "X-Federation-Node-Id"
HDR_TIMESTAMP = "X-Federation-Timestamp"
HDR_NONCE = "X-Federation-Nonce"
HDR_SIGNATURE = "X-Federation-Signature"

# Storage buffer limits (P4)
BUFFER_MAX_ENVELOPE_BYTES = _env_int(
    "BUFFER_MAX_ENVELOPE_BYTES", 256 * 1024, 1024, 16 * 1024 * 1024
)
BUFFER_MAX_ENTRIES_PER_RECIPIENT = _env_int(
    "BUFFER_MAX_ENTRIES_PER_RECIPIENT", 500, 1, 100_000
)
# Политика при переполнении буфера:
#   reject — вернуть 429 (по умолчанию, безопасно)
#   fifo   — удалить самое старое сообщение и принять новое
BUFFER_EVICTION_POLICY = os.environ.get("BUFFER_EVICTION_POLICY", "reject").lower()
if BUFFER_EVICTION_POLICY not in ("reject", "fifo"):
    raise RuntimeError("BUFFER_EVICTION_POLICY must be reject or fifo")
