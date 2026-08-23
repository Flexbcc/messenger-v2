import os
import tempfile


_tmp_dir = tempfile.mkdtemp(prefix="storage_test_")
os.environ.setdefault("STORAGE_DB_PATH", os.path.join(_tmp_dir, "storage.db"))
os.environ.setdefault("FEDERATION_NONCE_DB_PATH", os.path.join(_tmp_dir, "nonces.db"))
os.environ.setdefault("FEDERATION_AUDIT_DB_PATH", os.path.join(_tmp_dir, "audit.db"))
os.environ.setdefault("NODE_SIGNING_KEY_PATH", os.path.join(_tmp_dir, "node_signing_key"))
