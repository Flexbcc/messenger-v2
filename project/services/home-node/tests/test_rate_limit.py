from app.rate_limit import allow, reset


def test_rate_limit_blocks_after_max():
    reset("k")
    for _ in range(60):
        assert allow("k", max_events=60) is True
    assert allow("k", max_events=60) is False


def test_rate_limit_resets():
    reset("k2")
    assert allow("k2", max_events=1) is True
    assert allow("k2", max_events=1) is False
    reset("k2")
    assert allow("k2", max_events=1) is True
