import pytest

from shared.security.body_limit import FederationBodyLimitMiddleware


def _scope(path, headers=()):
    return {
        "type": "http",
        "method": "POST",
        "path": path,
        "headers": list(headers),
    }


async def _consume_app(scope, receive, send):
    while True:
        message = await receive()
        if message["type"] == "http.request" and not message.get("more_body", False):
            break
    await send({"type": "http.response.start", "status": 204, "headers": []})
    await send({"type": "http.response.body", "body": b""})


@pytest.mark.asyncio
async def test_declared_oversize_is_rejected_before_receive(monkeypatch):
    import shared.security.body_limit as body_limit

    monkeypatch.setattr(body_limit, "FEDERATION_MAX_BODY_BYTES", 8)
    receive_calls = 0

    async def receive():
        nonlocal receive_calls
        receive_calls += 1
        raise AssertionError("oversized declared body must not be received")

    sent = []

    async def send(message):
        sent.append(message)

    middleware = FederationBodyLimitMiddleware(_consume_app, path_prefixes=("/internal/",))
    await middleware(
        _scope("/internal/deliver", ((b"content-length", b"9"),)),
        receive,
        send,
    )
    assert sent[0]["status"] == 413
    assert receive_calls == 0


@pytest.mark.asyncio
async def test_chunked_oversize_is_rejected_before_application_parse(monkeypatch):
    import shared.security.body_limit as body_limit

    monkeypatch.setattr(body_limit, "FEDERATION_MAX_BODY_BYTES", 8)
    incoming = iter(
        [
            {"type": "http.request", "body": b"12345", "more_body": True},
            {"type": "http.request", "body": b"67890", "more_body": False},
        ]
    )

    async def receive():
        return next(incoming)

    sent = []

    async def send(message):
        sent.append(message)

    middleware = FederationBodyLimitMiddleware(_consume_app, path_prefixes=("/relay/",))
    await middleware(_scope("/relay/forward"), receive, send)
    assert sent[0]["status"] == 413


@pytest.mark.asyncio
async def test_unrelated_path_is_not_subject_to_federation_limit(monkeypatch):
    import shared.security.body_limit as body_limit

    monkeypatch.setattr(body_limit, "FEDERATION_MAX_BODY_BYTES", 8)
    incoming = iter(
        [{"type": "http.request", "body": b"x" * 20, "more_body": False}]
    )

    async def receive():
        return next(incoming)

    sent = []

    async def send(message):
        sent.append(message)

    middleware = FederationBodyLimitMiddleware(_consume_app, path_prefixes=("/internal/",))
    await middleware(_scope("/users/profile"), receive, send)
    assert sent[0]["status"] == 204


@pytest.mark.asyncio
async def test_signed_missing_headers_are_rejected_before_body_receive(monkeypatch):
    import shared.security.body_limit as body_limit

    monkeypatch.setattr(body_limit, "INTERNAL_SECURITY_MODE", "signed")
    receive_calls = 0

    async def receive():
        nonlocal receive_calls
        receive_calls += 1
        raise AssertionError("malformed signed request body must not be received")

    sent = []

    async def send(message):
        sent.append(message)

    middleware = FederationBodyLimitMiddleware(_consume_app, path_prefixes=("/mailbox/",))
    await middleware(_scope("/mailbox/store"), receive, send)
    assert sent[0]["status"] == 401
    assert receive_calls == 0
