# 0253 — Security Reputation

Status: implemented for TrustRecord equivocation; additional proof adapters
remain incremental.

## Boundary

Security Reputation is separate from Reliability Reputation. Packet loss,
latency and downtime never become cryptographic misconduct evidence.

Implemented proofs cover validator signatures on conflicting, otherwise valid:

- TrustRecords for the same subject and epoch;
- Operational Credential Revocations for the same node and revocation epoch.

Discovery stores each conflicting object once and joins it with the accepted
object, so the proof can be independently checked.

Repeated delivery of the same conflict is idempotent and cannot inflate the
score. Only the intersection of the two signer sets is attributed; validators
that signed only one branch are not accused by this evidence.

## Result

`GET /registry/security-reputation-candidates` returns a canonical
`evidence_commitment` and recommends `suspension`. It never mutates Trust,
revokes a key or changes Capability. A separately selected validator committee
must inspect the evidence and issue a quorum TrustRecord.

`GET /registry/security-evidence` returns both complete signed objects for
every referenced proof. A validator must re-run object, signature, authority
epoch and conflict checks; trusting the Discovery's label is insufficient.

## Next proof adapters

- conflicting AuthorityCheckpoint signatures;
- conflicting RandomnessCheckpoint signatures;
- conflicting CapabilityCertificate signatures;
- forged attestations and signed protocol state;
- replay evidence only where attribution is cryptographically sound.
