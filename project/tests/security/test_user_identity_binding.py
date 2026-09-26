from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.user_identity_binding import (
    issue_user_identity_binding,
    validate_user_identity_binding,
)
from shared.security.keys import public_key_b64


NOW = datetime(2026, 9, 26, 15, 0, tzinfo=timezone.utc)


def _binding(root: SigningKey, device: SigningKey):
    return issue_user_identity_binding(
        user_id="legacy-account-uuid",
        identity_signing_key=root,
        identity_version=1,
        authorizing_device_id="device-a",
        device_signing_key=device,
        issued_at=NOW,
    )


def _validate(binding, device):
    return validate_user_identity_binding(
        binding,
        now=NOW,
        expected_user_id="legacy-account-uuid",
        expected_device_id="device-a",
        expected_device_public_key=public_key_b64(device),
    )


def test_dual_signed_binding_is_valid():
    device = SigningKey.generate()
    assert _validate(_binding(SigningKey.generate(), device), device).valid


def test_account_substitution_breaks_binding():
    root, device = SigningKey.generate(), SigningKey.generate()
    binding = _binding(root, device)
    binding["user_id"] = "other-account"
    result = validate_user_identity_binding(
        binding,
        now=NOW,
        expected_user_id="other-account",
        expected_device_id="device-a",
        expected_device_public_key=public_key_b64(device),
    )
    assert not result.valid
    assert result.reason == "invalid Identity Root signature"


def test_root_or_device_signature_cannot_be_omitted():
    root, device = SigningKey.generate(), SigningKey.generate()
    binding = _binding(root, device)
    binding["device_signature"] = binding["identity_signature"]
    result = _validate(binding, device)
    assert not result.valid
    assert result.reason == "invalid device signature"


def test_expired_binding_is_rejected():
    root, device = SigningKey.generate(), SigningKey.generate()
    binding = _binding(root, device)
    result = validate_user_identity_binding(
        binding,
        now=NOW + timedelta(minutes=13),
        expected_user_id="legacy-account-uuid",
        expected_device_id="device-a",
        expected_device_public_key=public_key_b64(device),
    )
    assert not result.valid
    assert result.reason == "binding has expired"


def test_existing_root_cannot_be_replaced_without_transition():
    old_root, new_root, device = (
        SigningKey.generate(),
        SigningKey.generate(),
        SigningKey.generate(),
    )
    binding = _binding(new_root, device)
    old_key = public_key_b64(old_root)
    result = validate_user_identity_binding(
        binding,
        now=NOW,
        expected_user_id="legacy-account-uuid",
        expected_device_id="device-a",
        expected_device_public_key=public_key_b64(device),
        current_identity_public_key=old_key,
    )
    assert not result.valid
    assert result.reason == "Identity Root replacement requires transition"
