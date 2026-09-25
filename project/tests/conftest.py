"""Deterministic security modes for tests that import service apps dynamically.

Production images set these modes explicitly.  Direct module-level integration
tests exercise one security layer at a time, so unrelated attestation and mTLS
checks must not depend on the developer machine's environment.
"""

import os


os.environ["ATTESTATION_MODE"] = "off"
os.environ["MTLS_MODE"] = "off"
os.environ["OPERATIONAL_CREDENTIAL_STATE_MODE"] = "off"
os.environ["TRANSPORT_CERTIFICATE_MODE"] = "off"
os.environ["NODE_ADVERTISEMENT_MODE"] = "report"
os.environ["NODE_IDENTITY_MODE"] = "report"
os.environ["CAPABILITY_CERTIFICATE_MODE"] = "report"
os.environ["ENROLLMENT_MODE"] = "legacy"
