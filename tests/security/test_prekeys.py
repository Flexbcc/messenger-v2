import copy

import pytest

from shared.prekeys import PREKEY_CONSUMPTION_MODE, consume_one_prekey, count_unused_prekeys, merge_prekeys


@pytest.fixture
def sample_bundle():
    return {
        "identity_key": "ik",
        "registration_id": 1,
        "signed_prekey": {"id": 1, "public_key": "sp", "signature": "sig"},
        "prekeys": [
            {"id": 10, "public_key": "pk10"},
            {"id": 11, "public_key": "pk11"},
        ],
    }


def test_merge_prekeys_dedupes(sample_bundle):
    merged = merge_prekeys(sample_bundle, [{"id": 11, "public_key": "x"}, {"id": 12, "public_key": "y"}])
    assert len(merged["prekeys"]) == 3


def test_count_unused(sample_bundle):
    bundle = copy.deepcopy(sample_bundle)
    bundle["consumed_prekey_ids"] = [10]
    assert count_unused_prekeys(bundle) == 1


def test_consume_one_prekey(sample_bundle):
    updated, client = consume_one_prekey(sample_bundle)
    assert len(client["prekeys"]) == 1
    assert client["prekeys"][0]["id"] == 10
    assert 10 in updated["consumed_prekey_ids"]


def test_strict_mode_response(monkeypatch, sample_bundle):
    monkeypatch.setenv("PREKEY_CONSUMPTION_MODE", "legacy")
    import shared.prekeys as mod

    mod.PREKEY_CONSUMPTION_MODE = "legacy"
    from shared.prekeys import build_prekey_bundle_response

    resp = build_prekey_bundle_response("dev-1", sample_bundle, api_version=1)
    assert resp["api_version"] == 1
    assert len(resp["bundle"]["prekeys"]) == 1
    assert "_updated_bundle" in resp


def test_v0_forces_legacy(monkeypatch, sample_bundle):
    monkeypatch.setenv("PREKEY_CONSUMPTION_MODE", "strict")
    import shared.prekeys as mod

    mod.PREKEY_CONSUMPTION_MODE = "strict"
    from shared.prekeys import build_prekey_bundle_response, resolve_prekey_mode

    assert resolve_prekey_mode(0) == "legacy"
    assert resolve_prekey_mode(1) == "strict"
    resp = build_prekey_bundle_response("dev-1", sample_bundle, api_version=0)
    assert resp["api_version"] == 0
    assert len(resp["bundle"]["prekeys"]) == 2
