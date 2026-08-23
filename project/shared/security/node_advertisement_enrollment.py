"""Discovery-side report-only validation for NodeAdvertisement migration."""

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping, Optional

from shared.security.node_advertisement import validate_node_advertisement


@dataclass(frozen=True)
class NodeAdvertisementReport:
    status: str
    detail: Optional[str] = None
    advertisement_json: Optional[str] = None
    epoch: Optional[int] = None
    endpoints: tuple[str, ...] = ()
    supported_transports: tuple[str, ...] = ()
    supported_protocols: tuple[str, ...] = ()


def evaluate_node_advertisement_report(
    advertisement: Optional[Mapping[str, Any]],
    *,
    mode: str,
    now: datetime,
    identity_node_id: Optional[str],
    advertised_node_url: str,
    minimum_epoch: int = 0,
    existing_advertisement_json: Optional[str] = None,
) -> NodeAdvertisementReport:
    """Validate without granting trust or capabilities.

    During migration the legacy registration alias remains the database key.
    A valid advertisement is bound to the independently validated NodeID and
    must contain the URL used by that registration.
    """
    if mode == "off":
        return NodeAdvertisementReport("skipped")
    if mode not in {"report", "enforce"}:
        return NodeAdvertisementReport("invalid_mode", f"unsupported mode: {mode}")
    if advertisement is None:
        return NodeAdvertisementReport("absent")
    if not isinstance(advertisement, Mapping):
        return NodeAdvertisementReport("invalid", "advertisement must be an object")
    if not identity_node_id:
        return NodeAdvertisementReport(
            "unverifiable", "a valid bound Node Identity is required"
        )

    validation = validate_node_advertisement(
        advertisement,
        now=now,
        minimum_epoch=max(0, minimum_epoch),
    )
    if not validation.valid:
        return NodeAdvertisementReport("invalid", validation.reason)
    if advertisement.get("node_id") != identity_node_id:
        return NodeAdvertisementReport("identity_mismatch", "advertisement NodeID is not bound")
    endpoints = tuple(advertisement.get("endpoints", ()))
    if advertised_node_url not in endpoints:
        return NodeAdvertisementReport(
            "endpoint_mismatch", "registration node_url is not signed by the advertisement"
        )
    if existing_advertisement_json and advertisement["epoch"] == minimum_epoch:
        try:
            existing_advertisement = json.loads(existing_advertisement_json)
        except (TypeError, ValueError):
            return NodeAdvertisementReport(
                "invalid_state", "stored advertisement is not valid JSON"
            )
        if existing_advertisement != dict(advertisement):
            return NodeAdvertisementReport(
                "equivocation",
                "different signed advertisements use the same subject epoch",
            )

    return NodeAdvertisementReport(
        "valid",
        advertisement_json=json.dumps(
            dict(advertisement), sort_keys=True, separators=(",", ":")
        ),
        epoch=advertisement["epoch"],
        endpoints=endpoints,
        supported_transports=tuple(advertisement["supported_transports"]),
        supported_protocols=tuple(advertisement["supported_protocols"]),
    )
