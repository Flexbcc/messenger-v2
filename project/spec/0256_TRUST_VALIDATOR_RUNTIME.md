# 0256 — Independent Trust Validator Runtime

Status: opt-in promotion/degradation validator runtime implemented.

A node with the certified `validator` capability may enable the runtime with:

- `NODE_VALIDATOR_ENABLED=true`;
- `NODE_VALIDATOR_ID=<committee member id>`;
- `NODE_VALIDATOR_KEY_PATH=<provisioned Ed25519 seed file>`;
- at least two `FEDERATION_DISCOVERY_URLS`;
- `NODE_VALIDATOR_MINIMUM_SOURCES` (default `2`).

The Validator Key is separately provisioned and is never generated from, or
replaced by, the Node Root or Operational Key. Startup fails if the explicit key
is absent or malformed.

For every cycle the runtime:

1. obtains unsigned TrustRecord proposals from independent Discovery origins;
2. requires one exact proposal variant from the configured source quorum;
3. rejects split-view proposals with multiple quorum variants;
4. independently obtains the action-specific evidence from those origins;
5. requires a unique quorum evidence view with the exact commitment and levels;
6. signs the domain-separated TrustRecord payload;
7. submits the same vote to multiple Discovery nodes;
8. records completion only after the submission source quorum accepts it.

Restarted duplicate delivery is safe because Ed25519 signatures are
deterministic and the Discovery collector is idempotent per
`(record_id, validator_id)`.

Automated signing currently covers promotion and degradation. Suspension is
deliberately fail-closed: matching reputation views alone do not prove
equivocation. Until the runtime can locally validate both conflicting signed
objects against the historical authority epoch, a security-sanction vote must
come from an independent validator implementation. The quorum collector and
Trust Ledger already support that vote.
