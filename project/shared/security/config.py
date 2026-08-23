import os

INTERNAL_SECURITY_MODE = os.environ.get("INTERNAL_SECURITY_MODE", "legacy").lower()
FEDERATION_NODE_ID_MODE = os.environ.get("FEDERATION_NODE_ID_MODE", "report").lower()
if FEDERATION_NODE_ID_MODE not in ("legacy", "report", "enforce"):
    raise RuntimeError("FEDERATION_NODE_ID_MODE must be legacy, report, or enforce")
FEDERATION_ENVELOPE_MODE = os.environ.get("FEDERATION_ENVELOPE_MODE", "legacy").lower()
FEDERATION_CAPABILITY_MODE = os.environ.get("FEDERATION_CAPABILITY_MODE", "report").lower()
if FEDERATION_CAPABILITY_MODE not in ("legacy", "report", "enforce"):
    raise RuntimeError("FEDERATION_CAPABILITY_MODE must be legacy, report, or enforce")
FEDERATION_TIMESTAMP_SKEW_SECONDS = int(os.environ.get("FEDERATION_TIMESTAMP_SKEW_SECONDS", "120"))
FEDERATION_MAX_BODY_BYTES = int(os.environ.get("FEDERATION_MAX_BODY_BYTES", str(1024 * 1024)))
if not 1024 <= FEDERATION_MAX_BODY_BYTES <= 16 * 1024 * 1024:
    raise RuntimeError("FEDERATION_MAX_BODY_BYTES must be between 1024 and 16777216")
TRUST_CACHE_TTL_SECONDS = int(os.environ.get("TRUST_CACHE_TTL_SECONDS", "60"))
NONCE_TTL_SECONDS = int(os.environ.get("FEDERATION_NONCE_TTL_SECONDS", "300"))
ENVELOPE_NONCE_TTL_SECONDS = int(os.environ.get("FEDERATION_ENVELOPE_NONCE_TTL_SECONDS", "86400"))
ENVELOPE_DEFAULT_TTL_SECONDS = int(os.environ.get("FEDERATION_ENVELOPE_TTL_SECONDS", "86400"))

HDR_NODE_ID = "X-Federation-Node-Id"
HDR_TIMESTAMP = "X-Federation-Timestamp"
HDR_NONCE = "X-Federation-Nonce"
HDR_SIGNATURE = "X-Federation-Signature"

# Storage buffer limits (P4)
BUFFER_MAX_ENVELOPE_BYTES = int(os.environ.get("BUFFER_MAX_ENVELOPE_BYTES", str(256 * 1024)))
BUFFER_MAX_ENTRIES_PER_RECIPIENT = int(os.environ.get("BUFFER_MAX_ENTRIES_PER_RECIPIENT", "500"))
# Политика при переполнении буфера:
#   reject — вернуть 429 (по умолчанию, безопасно)
#   fifo   — удалить самое старое сообщение и принять новое
BUFFER_EVICTION_POLICY = os.environ.get("BUFFER_EVICTION_POLICY", "reject").lower()
