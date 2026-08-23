# 0255 — Node Challenge Observer Runtime

Status: availability, Storage, Discovery and Relay delivery execution implemented and wired in
secure node services.

Every participating Home/Relay/Storage/Media/TURN/Gateway can run the same
portable observer lifecycle:

1. prove possession of its root-certified Operational Key;
2. pull only assignments addressed to its NodeID;
3. sign an accepted/declined ACK;
4. resolve the subject through the quorum Federation TrustCache;
5. execute the challenge;
6. publish a signed, assignment-bound, privacy-minimized TrustObservation.

Availability checks require HTTPS, no redirects, a valid quorum-resolved
endpoint and `/health` response whose self-certifying NodeID equals the assigned
subject. Latency uses a monotonic clock. Local exception details are never
published.

Assignment pull, ACK and observation publication use bounded failover across
configured D1/D2/D3 origins. A single unavailable Discovery therefore does not
stop observer execution; each receiving Discovery still performs full portable
credential, replay and assignment validation.

Storage challenge sends a fresh 4096-byte CSPRNG cell over authenticated
federation, persists it in a separate five-minute table, fetches it through a
single-use opaque token and verifies bytes plus SHA-256 in constant-time
comparisons. Global and per-observer quotas bound disk use; mailbox state is
never touched.

Discovery challenge asks the target Discovery to resolve a known observer
NodeID and compares the returned endpoint with the observer's independent
quorum TrustCache view. A fabricated or stale endpoint therefore fails.

Relay delivery uses a fresh opaque 4096-byte CSPRNG cell and the path
`Observer A -> subject Relay -> independent assigned observer B`. Both hops use
federation authentication and quorum-resolved endpoints. Node B returns a
domain-separated receipt signed by its Operational Key; A verifies that
signature against B's quorum TrustCache credential. The subject Relay therefore
cannot claim delivery without either reaching B or compromising B's key. The
receiver is stateless, accepts only a certified Relay origin, enforces a
five-minute expiry, and never handles user messages, identities or mailboxes.

Relay assignments require at least two observers. The proposal scheduler skips
an impossible Relay challenge instead of producing an assignment that could
only degrade reputation because no independent destination exists.
