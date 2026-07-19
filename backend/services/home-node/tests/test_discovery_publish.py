"""Tests for profile helper functions."""
import pytest

from app.profile_helpers import normalize_login, username_search_enabled


def test_normalize_login_strips_and_lowercases():
    assert normalize_login("@KekWekke_User") == "kekwekke_user"


def test_normalize_login_empty_returns_none():
    assert normalize_login("") is None
    assert normalize_login(None) is None


def test_normalize_login_invalid_raises():
    with pytest.raises(ValueError):
        normalize_login("ab")


def test_username_search_enabled_default_true():
    assert username_search_enabled(None) is True
    assert username_search_enabled({}) is True


def test_username_search_enabled_from_blob():
    blob = {"values": {"privacy.username_search": False}}
    assert username_search_enabled(blob) is False
