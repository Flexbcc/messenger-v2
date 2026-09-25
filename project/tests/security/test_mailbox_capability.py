import pytest

from shared.security.mailbox_capability import (
    derive_mailbox_token,
    generate_mailbox_token,
    mailbox_token_bytes,
)


def test_random_mailbox_token_is_256_bit_opaque_capability():
    first = generate_mailbox_token()
    second = generate_mailbox_token()
    assert first != second
    assert len(first) == 43
    assert len(mailbox_token_bytes(first)) == 32


def test_derived_mailbox_token_is_domain_and_epoch_separated():
    secret = b"m" * 32
    first = derive_mailbox_token(secret=secret, mailbox_scope="device-a", epoch=1)
    same = derive_mailbox_token(secret=secret, mailbox_scope="device-a", epoch=1)
    rotated = derive_mailbox_token(secret=secret, mailbox_scope="device-a", epoch=2)
    other = derive_mailbox_token(secret=secret, mailbox_scope="device-b", epoch=1)
    assert first == same
    assert len({first, rotated, other}) == 3


@pytest.mark.parametrize("token", ["", "a" * 42, "!" * 43, "a" * 44])
def test_invalid_mailbox_token_fails_closed(token):
    with pytest.raises(ValueError):
        mailbox_token_bytes(token)


def test_short_derivation_secret_is_rejected():
    with pytest.raises(ValueError, match="at least 32 bytes"):
        derive_mailbox_token(secret=b"short", mailbox_scope="device-a", epoch=1)
