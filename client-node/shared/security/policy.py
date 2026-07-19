"""Capability → allowed HTTP routes (ADR-0011)."""

ENDPOINT_CAPABILITIES: dict[tuple[str, str], set[str]] = {
    ("POST", "/internal/deliver"): {"home", "relay"},
    ("POST", "/relay/forward"): {"home", "relay"},
    ("POST", "/buffer"): {"home", "relay"},
    ("GET", "/buffer"): {"home"},  # prefix match handled separately
    ("DELETE", "/buffer"): {"home"},
    ("POST", "/media"): {"home"},
    ("GET", "/media"): {"home"},  # prefix /media/{id}
}


def allowed_capabilities(method: str, path: str) -> set[str]:
    method_u = method.upper()
    if path.startswith("/buffer/") and method_u == "GET":
        return ENDPOINT_CAPABILITIES[("GET", "/buffer")]
    if path.startswith("/buffer/") and method_u == "DELETE":
        return ENDPOINT_CAPABILITIES[("DELETE", "/buffer")]
    if path.startswith("/media/") and method_u == "GET":
        return ENDPOINT_CAPABILITIES[("GET", "/media")]
    return ENDPOINT_CAPABILITIES.get((method_u, path), set())
