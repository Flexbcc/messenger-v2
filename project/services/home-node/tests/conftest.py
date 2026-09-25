"""Session-wide env setup for tests that spin up the real app/DB (currently
only test_delivery_ack.py) — must run before app.config.settings is first
imported anywhere, hence living in conftest.py rather than the test module."""
import os
import tempfile

_tmp_dir = tempfile.mkdtemp(prefix="home_test_")
os.environ.setdefault("HOME_DB_PATH", os.path.join(_tmp_dir, "home.db"))
os.environ.setdefault("HOME_NODE_PUBLIC_URL", "http://test-home.invalid")
os.environ.setdefault("DISCOVERY_NODE_URL", "http://test-discovery.invalid")
os.environ.setdefault("FEDERATION_NONCE_DB_PATH", os.path.join(_tmp_dir, "federation_nonces.db"))
os.environ.setdefault("FEDERATION_AUDIT_DB_PATH", os.path.join(_tmp_dir, "federation_audit.db"))
os.environ.setdefault("NODE_SIGNING_KEY_PATH", os.path.join(_tmp_dir, "node_signing_key"))
os.environ.setdefault("NODE_TOKEN_PATH", os.path.join(_tmp_dir, "node_token"))
os.environ.setdefault("ENROLLMENT_SECRET_PATH", os.path.join(_tmp_dir, "enrollment_secret"))
