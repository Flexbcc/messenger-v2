"""Unit tests for the Post-R5 CONTROL notify "home changed" detection
(docs/reality/R4-routing.md Gaps "Нет notify смены Home"). No HTTP/DB —
just the pure Discovery-response-to-notify-info mapping."""
import httpx

from app.config import settings
from app.federation import _home_change_info


def _resp(status_code: int, body: dict) -> httpx.Response:
    return httpx.Response(status_code=status_code, json=body)


def test_home_change_info_none_when_home_unchanged():
    resp = _resp(200, {"home_node_url": settings.public_url, "previous_home_node_url": None})
    assert _home_change_info("u1", resp) is None


def test_home_change_info_none_when_previous_equals_this_node():
    resp = _resp(200, {"home_node_url": settings.public_url, "previous_home_node_url": settings.public_url})
    assert _home_change_info("u1", resp) is None


def test_home_change_info_returns_info_on_real_move():
    resp = _resp(
        200,
        {
            "home_node_url": settings.public_url,
            "previous_home_node_url": "http://old-home.example",
            "home_updated_at": "2026-07-22T00:00:00Z",
        },
    )
    info = _home_change_info("u1", resp)
    assert info == {
        "user_id": "u1",
        "home_node_url": settings.public_url,
        "home_updated_at": "2026-07-22T00:00:00Z",
    }


def test_home_change_info_none_on_non_200():
    resp = _resp(404, {})
    assert _home_change_info("u1", resp) is None
