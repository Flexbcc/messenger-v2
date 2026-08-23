# 0254 — Evidence-bound TrustRecord proposals

Status: implemented for promotion, degradation and security suspension.

Discovery materializes deterministic unsigned TrustRecord proposals from:

- Reliability eligibility commitments for promotion;
- offline degradation commitments;
- cryptographic Security Reputation commitments for suspension.

For one subject and ledger epoch, security suspension has priority over
degradation, and degradation has priority over promotion. The proposal is bound
to the current subject ledger head, exact authority epoch, committee, threshold,
evidence commitment and evidence time. Its UUID is deterministic over those
fields.

`GET /registry/trust-record-proposals` exposes unsigned/published/stale status.
The background runtime refreshes the proposal set. Discovery never adds a
validator signature and never applies an unsigned proposal.

Secure deployment uses `TRUST_PROPOSAL_MODE=report`: historical quorum records
must remain ingestible even when a receiving Discovery has not yet replicated
the underlying evidence. Validators are responsible for signing only a proposal
whose evidence they independently retrieved and verified.

Partial votes are submitted to
`POST /registry/trust-record-proposal-votes`. Discovery accepts only the exact
locally materialized unsigned proposal, rejects stale proposals, validators
outside the assigned committee, revoked/expired credentials, invalid signatures
and a second conflicting signature from the same validator. Votes are unique by
`(record_id, validator_id)` and duplicate delivery is idempotent. Discovery
constructs and ingests the signed TrustRecord only when the configured threshold
has been reached; all normal Trust Ledger chain and authority checks run again at
that boundary.

This collector does not give Discovery a signing key. Automated validator-side
evidence retrieval and signing remains a separate runtime: until it is present,
votes must be produced by an independently controlled validator implementation.
