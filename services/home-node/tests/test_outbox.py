"""Unit tests for outbox backoff helpers (no DB required)."""
from types import SimpleNamespace

from app.outbox import MAX_ATTEMPTS, RETRY_MAX_SECONDS, _reschedule_or_kill, backoff_seconds


def test_backoff_seconds_doubles_and_caps():
    assert backoff_seconds(0) == 2
    assert backoff_seconds(1) == 4
    assert backoff_seconds(5) == 64
    assert backoff_seconds(30) == RETRY_MAX_SECONDS


def test_reschedule_or_kill_marks_dead_after_max_attempts():
    entry = SimpleNamespace(attempts=MAX_ATTEMPTS, status="pending", next_attempt_at=None)
    _reschedule_or_kill(entry)
    assert entry.status == "dead"


def test_reschedule_or_kill_reschedules_before_max_attempts():
    entry = SimpleNamespace(attempts=1, status="pending", next_attempt_at=None)
    _reschedule_or_kill(entry)
    assert entry.status == "pending"
    assert entry.next_attempt_at is not None
