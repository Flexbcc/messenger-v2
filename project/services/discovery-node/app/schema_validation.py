"""Reusable bounded input types for public Discovery API schemas."""
from __future__ import annotations

from typing import Annotated
from urllib.parse import urlsplit

from pydantic import AfterValidator, Field, StringConstraints


def _service_url(value: str) -> str:
    parsed = urlsplit(value)
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError("invalid service URL port") from exc
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("service URL must be an HTTP(S) origin without credentials or path")
    return value.rstrip("/")


Identifier = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=128),
]
ShortText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=256),
]
DisplayText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=120),
]
EncodedKey = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=16, max_length=1024),
]
ServiceUrl = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=8, max_length=2048),
    AfterValidator(_service_url),
]
Capability = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=64),
]
Capabilities = Annotated[list[Capability], Field(max_length=32)]
