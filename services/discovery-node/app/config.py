import os

# legacy  — register → trusted immediately (default, backward compatible)
# strict  — register → pending → admin approve → node_token
# hybrid  — known node_id → trusted; new → pending (step 2+)
ENROLLMENT_MODE = os.environ.get("ENROLLMENT_MODE", "legacy").lower()

OFFLINE_THRESHOLD_SECONDS = int(os.environ.get("DISCOVERY_OFFLINE_THRESHOLD_SECONDS", "120"))

# Admin API auth (step 3); empty = admin endpoints disabled
DISCOVERY_ADMIN_SECRET = os.environ.get("DISCOVERY_ADMIN_SECRET", "")

TRUST_STATUSES = frozenset({"pending", "trusted", "suspended", "compromised", "unknown"})
REACHABILITY_ONLINE = "online"
REACHABILITY_OFFLINE = "offline"
