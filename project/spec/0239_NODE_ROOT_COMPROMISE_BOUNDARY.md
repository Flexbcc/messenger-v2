# 0239 — Node Root Compromise and Transition Boundary

Status: fail-closed v1 boundary implemented and verified locally. Automatic
NodeID continuity/recovery is intentionally not implemented without a
precommitted recovery policy.

## Why Operational rotation is insufficient

NodeID is the hash of the Node Root public key. Rotating an Operational Key
preserves NodeID because the old Root signs the new short-lived certificate.
If the Root itself is compromised, that signature no longer proves recovery:
the attacker can produce it too.

OUO v1 therefore does not interpret a new Root as a transparent replacement.

## Implemented fail-closed response

1. Validators publish a node-wide `TrustRecord(action=revocation)` for the old
   NodeID. This transition is terminal in TrustRecord v1.
2. Registration, heartbeat, portable observer work and NodeAdvertisement
   control-plane paths reject the old NodeID.
3. Legacy admin approve/reinstate/re-enroll/grandfather and manual level
   operations cannot override the quorum decision in enforce mode.
4. The operator generates a new Root, which necessarily produces a new NodeID.
5. The new NodeID starts at L0. It receives no old Level, Capability,
   reputation, peer history or validator rights.
6. Claiming an old alias with the new Root is rejected as an identity conflict;
   claiming an infrastructure role without a new quorum CapabilityCertificate
   is rejected.

This is recovery by new identity, not identity continuity. It is deliberately
inconvenient but does not create an authority shortcut around a compromised
self-certifying identity.

## Why no automatic transition object yet

A safe continuity object would require a recovery authority established before
the incident. At minimum:

- old and new NodeID plus proof of possession of the new Root;
- a precommitted Node RecoveryPolicy and recovery-policy version;
- threshold recovery proofs independent of the compromised Root;
- validator quorum at an explicit historical Authority epoch;
- terminal old identity, transition epoch/hash and conflict detection;
- explicit rules for which reputation, Level and capabilities are reset or
  separately reissued;
- replay, rollback, expiry and recovery-key revocation rules.

Letting the old Root alone sign a transition fails under the exact compromise
being recovered from. Letting an ordinary admin or one Discovery bind the new
Root would make that component a Node Identity authority. Letting validator
quorum transfer all rights without a precommit would weaken Sybil isolation.

## Future protocol gate

Before `NodeIdentityTransition v1` can be implemented:

1. specify `NodeRecoveryPolicy` and its secure bootstrap;
2. define independent recovery factors/custody;
3. define quorum transition and conflict semantics;
4. prove that the old NodeID cannot be reactivated;
5. make Level/Capability transfer opt-in and separately quorum-signed, with L0
   reset as the default;
6. add D1/D2/D3 replication, partition/freeze and hard-fork recovery tests.

Until this gate is met, the only safe supported result is a new L0 NodeID.

## Verified invariants

- quorum revocation excludes the old NodeID from Discovery and returns 403 on
  re-registration;
- a new Root cannot take over the old legacy alias;
- a new Root cannot inherit a Relay/Storage/Discovery capability by declaring
  it;
- a new Root can register only as a distinct L0 Home identity in the reference
  path;
- no table or object silently maps old NodeID trust/capabilities to the new one.

## Residual work

- `NodeRecoveryPolicy` protocol and custody ceremony;
- audited transition object and D1/D2/D3 ledger;
- operator UX and contact/peer warnings for changed NodeID;
- external security review before any continuity claim.
