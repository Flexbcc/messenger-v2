"""Unit tests for the Post-R5 user->home resolve cache helpers (no HTTP/DB)."""
from app.federation import _cache_lookup, _cache_store


def test_cache_store_then_lookup_hits_before_expiry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=159.9) == "http://home-a"


def test_cache_lookup_misses_at_or_after_expiry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=160.0) is None


def test_cache_lookup_misses_when_absent():
    cache: dict[str, tuple[str, float]] = {}
    assert _cache_lookup(cache, "unknown", now=0.0) is None


def test_cache_store_with_zero_or_negative_ttl_disables_caching():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=0)
    assert cache == {}
    assert _cache_lookup(cache, "u1", now=100.0) is None


def test_cache_store_overwrites_previous_entry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    _cache_store(cache, "u1", "http://home-b", now=110.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=111.0) == "http://home-b"
