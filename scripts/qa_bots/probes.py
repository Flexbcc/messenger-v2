"""Behavioral probes registry (L3). Keys = setting ids with real enforcement checks."""

from __future__ import annotations

# Maps setting_id → metadata. Scenarios 07–09 implement these probes.
PROBES: dict[str, dict] = {
    "privacy.username_search": {
        "product": "discovery",
        "probe": "discovery_search_login",
        "scenario": "07_privacy_search_matrix",
        "enforcement": "server",
    },
    "privacy.phone_search": {
        "product": "client_policy",
        "probe": "phone_search_allowed",
        "scenario": "07_privacy_search_matrix",
        "enforcement": "client",
    },
    "privacy.calls_from": {
        "product": "client_policy",
        "probe": "calls_allowed_matrix",
        "scenario": "08_calls_allowlist",
        "enforcement": "client",
    },
    "privacy.calls_allowlist": {
        "product": "client_policy",
        "probe": "calls_allowed_matrix",
        "scenario": "08_calls_allowlist",
        "enforcement": "client",
    },
    "privacy.incoming_messages": {
        "product": "client_policy",
        "probe": "incoming_messages_matrix",
        "scenario": "09_incoming_messages_policy",
        "enforcement": "client",
    },
    "contacts.blocked_list": {
        "product": "client_policy",
        "probe": "is_blocked",
        "scenario": "09_incoming_messages_policy",
        "enforcement": "client",
    },
    "contacts.trusted_list": {
        "product": "client_policy",
        "probe": "security_trusted_standin",
        "scenario": "05_security_signals",
        "enforcement": "client",
    },
}
