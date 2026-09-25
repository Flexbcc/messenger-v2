import re


MEDIA_ID_LENGTH = 64
MEDIA_ID_PATTERN = r"^[0-9a-f]{64}$"
_MEDIA_ID_RE = re.compile(MEDIA_ID_PATTERN)


def is_valid_media_id(value: object) -> bool:
    """Return whether *value* is a canonical SHA-256 media identifier."""
    return isinstance(value, str) and _MEDIA_ID_RE.fullmatch(value) is not None


def validate_media_id(value: object) -> str:
    if not is_valid_media_id(value):
        raise ValueError("media_id must be a lowercase SHA-256 digest")
    return value
