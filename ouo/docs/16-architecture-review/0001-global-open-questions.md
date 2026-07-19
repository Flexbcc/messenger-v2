# Architecture Review: Global Open Questions

> **Status:** Open
> **Last updated:** 2026-07-08
> **Document class:** Architecture review (architect's working document). **Not**
> an RFC, **not** a Design Paper, **not** Foundation, **not** a Decision.
> **Analyst stance:** This document only *finds and frames* problems. It fixes
> nothing, decides nothing, and proposes no final design. "Possible Directions"
> lists *research directions*, never solutions.
> **Scope of analysis:** the entire authored corpus —
> [Core Concepts](../00-overview/0000-core-concepts.md),
> [Glossary](../00-overview/0005-glossary.md),
> [Project Status](../00-overview/0007-project-status.md),
> [Documentation Standard](../00-overview/0008-documentation-standard.md),
> [Node Taxonomy](../01-protocol/0100-node-taxonomy.md),
> [Methodology](../11-research/00-methodology.md),
> [Research: Distributed Messaging](../11-research/01-existing-systems/0001-distributed-messaging.md),
> [Comparison](../12-comparison/0001-distributed-messaging.md),
> [System Model](../14-foundation/0001-system-model.md),
> [Identity Model](../15-design-papers/0001-identity-model.md),
> [User Lifecycle](../15-design-papers/0002-user-lifecycle.md).

## Guiding questions

`OBSERVATION:` Every problem below was found by repeatedly asking: *What can
break? What will not scale? Which scenarios are forgotten? What is impossible to
implement? What contradicts what?*

---

## Q-0001

# Category
Identity

# Description
The identity anchor is entirely undecided: seven candidate models are catalogued
(Account, Public Key, Hash(Public Key), UUID, Certificate, DID, Multi-device)
with no choice made.

# Why It Matters
Almost every other decision depends on it. Route Records are "signed by the
user's identity key", contacts reference a user, delivery targets a `user_id` —
all of these presuppose what an identity *is*. Nothing downstream can be
specified until this is fixed.

# Related Documents
[Identity Model](../15-design-papers/0001-identity-model.md), Core Concepts
(User, Identity), User Lifecycle (0001, 0010, 0011).

# Possible Directions
Study which anchor models satisfy P1–P7 simultaneously; study composition
(multi-device root over a key/hash/DID anchor).

# Blocking Level
Critical

# Status
Open

---

## Q-0002

# Category
Identity

# Description
The relationship between `Identity` (user-level) and `Device Identity`
(device-level) is undefined: whether the user identity is a single root that
attests device keys, whether one device is authoritative, or some other model.

# Why It Matters
Device add/replace/loss/removal (Lifecycle 0010–0013) and revocation all hinge
on this. Without it, multi-device, recovery, and post-compromise cannot be
specified, and the two entities risk being defined circularly.

# Related Documents
Core Concepts (Identity, Device Identity), Identity Model §3.7, User Lifecycle
(0010–0013).

# Possible Directions
Study root-key-attests-devices vs cross-signing vs threshold schemes.

# Blocking Level
Critical

# Status
Open

---

## Q-0003

# Category
Identity

# Description
Tension between P1 ("the user's cryptographic identity is the only permanent
entity") and the absence of any recovery model. If the sole permanent anchor is
key material that can be lost with no recovery, "permanence" is not guaranteed
in practice.

# Why It Matters
If identity cannot survive device loss, the central invariant is undermined for
real users. Recovery, backup, and permanence are entangled and may be
contradictory as currently stated.

# Related Documents
System Model (Invariants, Information Ownership), Identity Model (Open Questions
2), User Lifecycle (0011, 0012, 0016).

# Possible Directions
Study recovery approaches (recovery phrase, social recovery, threshold, hardware)
and whether any preserve P1 without introducing a source of truth.

# Blocking Level
High

# Status
Open

---

## Q-0004

# Category
Identity / Metadata

# Description
Undecided whether an OUO identity must be human-readable or purely
cryptographic, with naming layered separately.

# Why It Matters
Determines whether a naming/discovery authority exists (a potential source of
truth and metadata concentrator), which touches P5 and the metadata model.

# Related Documents
Identity Model (Open Questions 1, 9), System Model (System Boundaries), User
Lifecycle (0004).

# Possible Directions
Study self-authenticating identifiers plus optional naming overlays (e.g.
DNS-to-key style) as separable layers.

# Blocking Level
High

# Status
Open

---

## Q-0005

# Category
Identity

# Description
Whether one human may hold multiple unlinkable identities, and whether the model
must support this explicitly, is undefined.

# Why It Matters
Affects local storage model, first-launch flow, and metadata unlinkability. Low
blocking, but cheap to forget and expensive to retrofit.

# Related Documents
Identity Model (Open Questions 11), User Lifecycle (0001).

# Possible Directions
Decide as an explicit in/out-of-scope statement during identity design.

# Blocking Level
Low

# Status
Open

---

## Q-0006

# Category
Security / Trust

# Description
The adversary model for untrusted infrastructure is undefined: honest-but-
curious, actively malicious, or a tiered mix.

# Why It Matters
No security property can be stated or evaluated without it. Every claim about
relays, storage, witnesses, and metadata is unfalsifiable until the adversary is
named. This blocks the entire security specification.

# Related Documents
System Model (Trust Model), Threat Model (0006-threat-model, empty),
[0302-threat] research (none yet).

# Possible Directions
Study Signal/Session/SimpleX threat models; define adversary tiers per node
role.

# Blocking Level
Critical

# Status
Open

---

## Q-0007

# Category
Security

# Description
"No node can read message content" is strongly implied by P2/P5 but is not
stated as a formal, absolute invariant.

# Why It Matters
Nodes' MUST-NOT-know clauses depend on it. If it is not an invariant, sealed-
content guarantees are informal and could be violated by a future feature.

# Related Documents
System Model (Invariants — flagged as QUESTION), Node Taxonomy (MUST NOT know).

# Possible Directions
Decide whether to elevate to a hard invariant and define its exact scope
(content vs metadata).

# Blocking Level
High

# Status
Open

---

## Q-0008

# Category
Metadata

# Description
Metadata observability and ownership are unresolved. In particular, a Witness
Node maps `user_id → route`; depending on design it may observe presence,
reachability, and — via lookups — social-graph signals.

# Why It Matters
Metadata is the hardest property to protect and the easiest to leak. If witness
lookups expose who-is-looking-for-whom, the system leaks the social graph even
with perfect content encryption.

# Related Documents
System Model (Information Ownership — Metadata = QUESTION), Node Taxonomy
(Witness), Comparison (Matrix 4).

# Possible Directions
Study private lookup (PIR-like), sealed-sender analogues, witness query
unlinkability.

# Blocking Level
High

# Status
Open

---

## Q-0009

# Category
Trust

# Description
The trust relationship *between* a single user's own devices is undefined
(full mutual trust, tiered, primary/secondary).

# Why It Matters
Determines blast radius of one compromised device and the mechanics of fan-out,
sync, and removal.

# Related Documents
System Model (Trust Model), User Lifecycle (0010, 0012, 0013), Identity Model
§3.7.

# Possible Directions
Study per-device capability scoping vs uniform device trust.

# Blocking Level
Medium

# Status
Open

---

## Q-0010

# Category
Routing / Node

# Description
Bootstrap discovery is a circular dependency: a client needs a Bootstrap Node to
find service nodes, but has no defined way to find the first Bootstrap Node
without a pre-existing authority.

# Why It Matters
If unsolved, no client can ever join the network from a cold start, or the
solution silently reintroduces a central authority (contradicting P4/P5). This
is a foundational bootstrapping paradox.

# Related Documents
Node Taxonomy (Bootstrap Node — Open Questions), User Lifecycle (0003),
[0301-bootstrap] (empty).

# Possible Directions
Study shipped seed lists, DNS seeds, peer-exchange, verifiable node lists — as
*directions*, not choices.

# Blocking Level
Critical

# Status
Open

---

## Q-0011

# Category
Routing

# Description
Route Record contents, default TTL, refresh cadence, and replication factor are
undefined (only "signed by identity key, TTL-bounded, held by witnesses" is
fixed).

# Why It Matters
Delivery, reconnection, and offline recovery all depend on route resolution. TTL
choice trades reachability against churn and privacy; replication trades
availability against metadata spread.

# Related Documents
Core Concepts (Route Record), Node Taxonomy (Witness), User Lifecycle (0003,
0006, 0009).

# Possible Directions
Study TTL/replication regimes from DHTs and Session swarms.

# Blocking Level
High

# Status
Open

---

## Q-0012

# Category
Routing / Security

# Description
Anti-abuse for route publication is undefined: poisoning (false routes), spam,
and sybil attacks on the witness set.

# Why It Matters
Route Records are self-signed, which prevents forging *another* user's route —
but does not prevent flooding, squatting, eclipse, or a sybil witness set
returning selective/censored answers. Reachability is only as trustworthy as the
witness layer's abuse resistance.

# Related Documents
Node Taxonomy (Witness — Open Questions), Q-0015, User Lifecycle (0003).

# Possible Directions
Study proof-of-work/stake gating, redundant witnesses with cross-checking,
eclipse resistance.

# Blocking Level
Critical

# Status
Open

---

## Q-0013

# Category
Routing / Scaling

# Description
Witness lookup scaling to a global user population is undefined. How does
`user_id → route` resolution scale to millions of users and high churn? Is the
witness layer a DHT, a gossip set, or something else?

# Why It Matters
A protocol meant to last decades must scale. An unscalable lookup layer becomes
either centralized (contradicting P4) or unreliable.

# Related Documents
Node Taxonomy (Witness), [0311-network-scaling] (empty), Q-0011.

# Possible Directions
Study DHT topologies, swarm assignment, sharding of the witness keyspace.

# Blocking Level
High

# Status
Open

---

## Q-0014

# Category
Routing

# Description
Tension between P3 ("routes are temporary") and reliable reachability. Aggressive
route rotation improves privacy but risks stale routes and failed delivery;
long-lived routes ease delivery but weaken P3.

# Why It Matters
The rotation cadence directly couples privacy, delivery success, and witness
load. Getting it wrong breaks delivery or leaks patterns.

# Related Documents
[0121-routing-rotation] (empty), Core Concepts (Route, Route Record), User
Lifecycle (0009).

# Possible Directions
Study rotation-vs-reachability trade-offs; overlap windows; make-before-break
route publication.

# Blocking Level
High

# Status
Open

---

## Q-0015

# Category
Node / Trust (Contradiction)

# Description
Potential contradiction: invariant 8 says "no node is the single source of truth
for a user's identity", yet the witness layer is the authority for *where a user
currently is*. If the witness set is small or poisonable, it becomes a de-facto
source of truth for reachability, even if not for identity.

# Why It Matters
A subtle violation of the spirit of P5/invariant 8: content ownership is
decentralized, but reachability may not be. An adversary controlling reachability
can censor or eclipse a user without ever owning their identity.

# Related Documents
Node Taxonomy (invariants, Witness), System Model (Invariants), Q-0012, Q-0013.

# Possible Directions
Study whether reachability must be held to the same "no single source of truth"
standard as identity, and how.

# Blocking Level
High

# Status
Open

---

## Q-0016

# Category
Node (Definition conflict)

# Description
The `Server` entity is not mapped onto the node taxonomy: whether "Server" is a
role container, a deployable, or a synonym is unresolved (D2). Core Concepts
lists `Server` while the taxonomy speaks of role nodes and deployment modes.

# Why It Matters
Ambiguous top-level vocabulary causes divergent interpretation by independent
implementers — precisely what the Glossary's "one name per entity" rule forbids.

# Related Documents
Core Concepts (Server), Node Taxonomy, Project Status (D2).

# Possible Directions
Decide whether `Server` is retired, redefined as "any node", or kept as
deployment container.

# Blocking Level
Medium

# Status
Open

---

## Q-0017

# Category
Node / Reliability

# Description
Invariant 7 ("if any node dies, the system degrades, not breaks") has no defined
degradation semantics: no quorum, redundancy factor, or minimum-viable-node-set
is specified.

# Why It Matters
"Degrade gracefully" is untestable without defining *what* degrades and *how
much* redundancy is required. Independent implementations could disagree on
survivability.

# Related Documents
Node Taxonomy (invariants), [0122-failure-recovery] (empty), User Lifecycle
(0008, 0009).

# Possible Directions
Study minimum redundancy per role; define degradation levels.

# Blocking Level
High

# Status
Open

---

## Q-0018

# Category
Node / Sustainability

# Description
Node operator incentives and long-term sustainability are undefined. "Infra is
interchangeable" (P4) presumes a supply of nodes, but nothing defines *why*
anyone runs public witness/delivery/storage nodes for decades.

# Why It Matters
For a protocol meant to last decades, the economic/operational sustainability of
the public node supply is an existential question. Comparable systems used
incentives (Session/Oxen) or nonprofit hosting (Signal/Matrix).

# Related Documents
Node Taxonomy (Public Node), Comparison, System Model.

# Possible Directions
Study volunteer, nonprofit, federated-org, and incentive-based node supply
models (without adopting any).

# Blocking Level
Medium

# Status
Open

---

## Q-0019

# Category
Documentation integrity

# Description
Two integrity defects: (a) filename number collision — both `0100-overview.md`
and `0100-node-taxonomy.md` exist in `01-protocol/`; (b) terminology drift —
Core Concepts uses `Relay`/`Storage`/`Media Storage` while the taxonomy uses
`Relay Node`/`Storage Node`/`Media Storage Node` (reconciled by notes, but two
names persist against the "one name per entity" rule).

# Why It Matters
Independent implementers and AIs may treat drifted names as distinct entities;
number collisions break ordering assumptions.

# Related Documents
Node Taxonomy, Core Concepts, Glossary, Documentation Standard (rule 7).

# Possible Directions
Renumber the colliding file; canonicalize one name per entity.

# Blocking Level
Low

# Status
Open

---

## Q-0020

# Category
Delivery

# Description
Delivery guarantee when *all* of the sender's devices are offline is undefined.
The primary queue lives on the client; if the client never reconnects, the
message is never sent, and no node holds it.

# Why It Matters
Users expect "send and forget". A purely client-held outbound queue means
messages can silently never leave. This is a core UX/reliability gap.

# Related Documents
Node Taxonomy (accepted model: client holds primary queue), User Lifecycle
(0006, 0008, 0009), [0107-message-delivery] (empty).

# Possible Directions
Study optional outbound staging on a trusted/home node vs strict client-held
queue; define the guarantee explicitly.

# Blocking Level
High

# Status
Open

---

## Q-0021

# Category
Delivery / Multi-device

# Description
Storage deletion policy versus multi-device fan-out is undefined: may a Storage
Node delete a buffered message after the *first* device receipt, or only after
*all* devices receive it? How are a user's current devices even known to
storage?

# Why It Matters
Delete-on-first loses messages for offline sibling devices; delete-on-all
requires storage to know the device set (a metadata leak) and to hold data
longer (against the "temporary buffer" model). Either way, data-loss or
metadata-leak risk.

# Related Documents
Node Taxonomy (Storage, Delivery), User Lifecycle (0007, 0009), Q-0009.

# Possible Directions
Study per-device queues, acknowledgement aggregation, TTL-bounded retention.

# Blocking Level
High

# Status
Open

---

## Q-0022

# Category
Delivery

# Description
Message ordering and cross-device consistency after offline gaps are undefined.

# Why It Matters
Without ordering semantics, conversations can display inconsistently across
devices, and after an offline gap history may reassemble differently per device.

# Related Documents
User Lifecycle (0006, 0009), [0119-multi-device] (empty).

# Possible Directions
Study causal ordering, per-conversation sequencing, vector clocks.

# Blocking Level
Medium

# Status
Open

---

## Q-0023

# Category
Delivery / Trust

# Description
Delivery/read receipt authenticity is undefined given no node is a source of
truth. What proves delivery to the sender without trusting a node's word?

# Why It Matters
Receipts asserted by nodes contradict P5; end-to-end receipts require the
recipient to be reachable. The guarantee must be defined or receipts are
meaningless/forgeable.

# Related Documents
User Lifecycle (0006, 0007), System Model (Invariants).

# Possible Directions
Study end-to-end signed receipts vs best-effort node hints.

# Blocking Level
Medium

# Status
Open

---

## Q-0024

# Category
Delivery

# Description
Deduplication is undefined when a message reaches a user via multiple relays,
multiple witnesses, or multiple devices.

# Why It Matters
Redundancy (needed for "degrade not break") implies duplicates; without dedup,
users see repeats and receipts double-count.

# Related Documents
User Lifecycle (0007, 0009), Q-0017.

# Possible Directions
Study idempotent message identifiers and replay-safe dedup.

# Blocking Level
Medium

# Status
Open

---

## Q-0025

# Category
Backup / Recovery

# Description
No backup model exists, and it is in tension with P2 (no node owns messages). If
backups are needed for recovery (Q-0003), where do encrypted backups live, and
who holds them without becoming a de-facto owner?

# Why It Matters
Recovery, phone replacement, and multi-device onboarding all depend on some
durable, restorable state. A backup that lives on a node risks contradicting P2;
a backup that lives nowhere makes recovery impossible.

# Related Documents
[0118-backup] (empty), User Lifecycle (0010, 0011, 0016), Q-0003, System Model
(Information Ownership).

# Possible Directions
Study client-held encrypted backups, user-controlled home-node backups,
distributed encrypted backup — as directions only.

# Blocking Level
High

# Status
Open

---

## Q-0026

# Category
Security / Multi-device

# Description
Device revocation propagation without a source of truth is undefined. When a
device is lost or removed (Lifecycle 0012/0013), how do contacts and nodes
reliably learn to stop trusting/delivering to it?

# Why It Matters
Slow or unreliable revocation lengthens the post-compromise window. Without a
source of truth, revocation must propagate peer-to-peer, which is hard to make
timely and complete.

# Related Documents
User Lifecycle (0012, 0013), [0207-post-compromise-security] (empty), Q-0002.

# Possible Directions
Study self-signed revocation records with TTL, transparency logs, contact-side
verification.

# Blocking Level
High

# Status
Open

---

## Q-0027

# Category
Identity / Deletion

# Description
Full identity deletion semantics are undefined: what is actually deletable, how
contacts learn of deletion (tombstones), and whether an identifier can be
re-registered by someone else afterward.

# Why It Matters
Messages belong to participants (P2), so copies at contacts cannot be recalled;
identifier reuse could enable impersonation. Deletion must be honestly scoped.

# Related Documents
User Lifecycle (0016), System Model (Information Ownership), Q-0001.

# Possible Directions
Study tombstone records, non-reusable identifiers, TTL-bounded residue.

# Blocking Level
Medium

# Status
Open

---

## Q-0028

# Category
Media

# Description
Media blob lifetime versus message references is undefined. Media Storage holds
encrypted blobs temporarily with a TTL, but a message referencing a blob may be
read after the blob expires, producing dangling references.

# Why It Matters
Users expect media in old messages to open. TTL-bounded media storage plus
long-lived message history is an inherent mismatch.

# Related Documents
Node Taxonomy (Media Storage), Core Concepts (Media), [0109-media-transfer]
(empty).

# Possible Directions
Study re-upload on access, sender-side retention, configurable retention.

# Blocking Level
Medium

# Status
Open

---

## Q-0029

# Category
Calls

# Description
Real-time calls conflict with the store-and-forward / temporary-route model.
Calls need low-latency, bidirectional, presence-aware connectivity (TURN/WebRTC
per the file structure), which differs fundamentally from asynchronous
encrypted-envelope delivery.

# Why It Matters
The routing/delivery model designed for async messaging may not serve real-time
media at all; presence (needed for calls) is itself undefined and is a metadata
concern.

# Related Documents
[0117-calls] (empty), [0309-webrtc]/[0308-turn] (empty), System Model.

# Possible Directions
Study a separate signaling+media path; define presence scope and its metadata
cost.

# Blocking Level
High

# Status
Open

---

## Q-0030

# Category
Groups

# Description
Group membership authority and group key management are undefined when no server
owns the group.

# Why It Matters
"Who is authoritatively in the group?" has no answer without a source of truth;
group key distribution and membership changes are notoriously hard to make
consistent and secure in a decentralized setting.

# Related Documents
Core Concepts (Group, Conversation — relationship also open), [0116-groups]
(empty), Project Status (D6).

# Possible Directions
Study admin-signed membership, MLS-style group key agreement, eventual-
consistency membership.

# Blocking Level
Medium

# Status
Open

---

## Q-0031

# Category
Scope boundary

# Description
Whether contact exchange and user discovery are part of the OUO protocol or an
application concern is unresolved (flagged in the System Model boundary).

# Why It Matters
It blocks Lifecycle 0004 and shapes whether discovery infrastructure (a metadata
concentrator and potential source of truth) exists inside OUO at all.

# Related Documents
System Model (System Boundaries — QUESTION), User Lifecycle (0004), Identity
Model (Open Questions 9), [0106-contact-exchange] (empty).

# Possible Directions
Decide the boundary explicitly before specifying discovery.

# Blocking Level
High

# Status
Open

---

## Q-0032

# Category
Meta / Process (Dependency structure)

# Description
There is a decision-ordering meta-dependency and a dependency *cycle*. Linear
chain: identity anchor (Q-0001) → route records signed by identity → delivery.
Cycle: recovery (Q-0003) needs backup (Q-0025); backup location needs the trust
model (Q-0009) and adversary model (Q-0006); the trust model needs the identity
model (Q-0001/Q-0002); recovery feeds back into identity permanence (Q-0003).

# Why It Matters
If these are decided in the wrong order, later decisions will force earlier ones
to be reopened. The cycle (identity ↔ recovery ↔ backup ↔ trust) must be
resolved as a coherent bundle, not piecemeal.

# Related Documents
All Stage-1 items; ROADMAP.md.

# Possible Directions
Resolve the identity+trust+adversary bundle jointly before routing/delivery.

# Blocking Level
Critical

# Status
Open

---

## Q-0033

# Category
Documentation integrity

# Description
The Documentation Quality Standard (rule 6) requires a Status + Last-updated
block on every document, but documents authored before the standard
(`0000-core-concepts`, `0005-glossary`, `0007-project-status`, `0100-node-taxonomy`,
`11-research/0001-distributed-messaging`) still lack it.

# Why It Matters
Non-compliance with the project's own standard erodes the "documentation is the
source of truth" guarantee and its AI-friendliness.

# Related Documents
Documentation Standard (rule 6), the listed documents.

# Possible Directions
Retrofit version blocks (a mechanical, non-breaking pass).

# Blocking Level
Low

# Status
Open

---

# Master list — all open questions by criticality

`OBSERVATION:` Single consolidated list, sorted by blocking level. IDs link to
the entries above.

## Critical
- Q-0001 — Identity anchor undecided.
- Q-0002 — User↔Device identity relationship undefined.
- Q-0006 — Adversary model undefined.
- Q-0010 — Bootstrap discovery circular dependency.
- Q-0012 — Witness/route anti-abuse (poisoning, sybil, eclipse).
- Q-0032 — Decision-ordering meta-dependency and identity↔recovery↔backup↔trust
  cycle.

## High
- Q-0003 — Recovery vs P1 permanence tension.
- Q-0004 — Human-readable naming vs self-authenticating identity.
- Q-0007 — "No node reads content" not a formal invariant.
- Q-0008 — Metadata observability/ownership (witness leaks social graph).
- Q-0011 — Route Record contents / TTL / replication undefined.
- Q-0013 — Witness lookup scaling.
- Q-0014 — Route rotation vs reachability tension.
- Q-0015 — Witness as de-facto reachability source of truth vs invariant 8.
- Q-0017 — Degradation semantics undefined.
- Q-0020 — Delivery guarantee when all sender devices offline.
- Q-0021 — Storage deletion vs multi-device fan-out.
- Q-0025 — Backup model undefined, tension with P2.
- Q-0026 — Device revocation propagation without source of truth.
- Q-0029 — Real-time calls vs store-and-forward model.
- Q-0031 — Contact exchange / discovery: in OUO or application?

## Medium
- Q-0009 — Trust between a user's own devices.
- Q-0016 — `Server` entity vs node taxonomy mapping.
- Q-0018 — Node operator incentives / long-term sustainability.
- Q-0022 — Ordering/consistency across devices and offline gaps.
- Q-0023 — Receipt authenticity without a source of truth.
- Q-0024 — Deduplication across relays/witnesses/devices.
- Q-0027 — Identity deletion semantics / identifier reuse / tombstones.
- Q-0028 — Media blob TTL vs long-lived message references.
- Q-0030 — Group membership authority and key management.

## Low
- Q-0005 — Multiple identities per human.
- Q-0019 — Filename collision + Relay/Relay-Node terminology drift.
- Q-0033 — Version-block compliance gap in pre-standard documents.

*(End of analysis. No decisions, no fixes, no recommendations. See
[ROADMAP.md](ROADMAP.md) for the design-phase grouping.)*
