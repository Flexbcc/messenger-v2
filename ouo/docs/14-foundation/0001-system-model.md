# OUO System Model

> **Status:** Draft
> **Last updated:** 2026-07-08
> **Document class:** Foundation. Describes possible conceptual models of the
> protocol. **Not** a Decision, **not** an ADR, **not** a Specification.
> **Level:** Architecture. This document answers *what exists*, never *how*.
> **Constraints:** No JSON, no API, no packet sequences, no code — architectural
> models only.
> **Statement tags** (per
> [../00-overview/0008-documentation-standard.md](../00-overview/0008-documentation-standard.md)):
> `DECISION` marks an already-accepted principle (cross-referenced, not decided
> here); `OBSERVATION`, `OPTION`, `ASSUMPTION`, `QUESTION`, `TODO` mark
> non-decided content. This Foundation document introduces no new `DECISION`.

---

# What is OUO?

`OBSERVATION:` At the most abstract level, OUO is **a model of interaction
between self-owned cryptographic identities that exchange authenticated,
encrypted information across interchangeable, temporary transport.**

`OBSERVATION:` OUO is deliberately *not* described as any of the following:

- not "a messenger" (a messenger is one application built on the model);
- not "a server" (servers are replaceable participants in the model);
- not "an application" (an application is an implementation, not the model).

`OBSERVATION:` The model has three abstract layers, described conceptually only:

- an **identity layer** — the permanent cryptographic selves that communicate;
- a **transport/routing layer** — the temporary, replaceable paths and nodes
  that carry information;
- an **interaction layer** — the conversations and information the identities
  actually exchange.

`DECISION` (accepted principles P1–P7,
[../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md#accepted-principles-authoritative)):
the identity is owned by the user and permanent; the transport is
interchangeable and non-authoritative; routes are temporary.

`QUESTION:` Is OUO best framed as a *routing-and-delivery* model with identity
attached, or as an *identity* model with routing attached? The framing above
lists identity first; this ordering is not yet decided.

---

# Core Entities

`OBSERVATION:` The entities below are the vocabulary of the model. Their
authoritative definitions live in
[../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md);
this section states only their **conceptual role**, without implementation.

- **User** — the logical human participant; the party on whose behalf
  everything happens.
- **Identity** — the permanent cryptographic self of a User; the anchor of
  authenticity.
- **Device** — a concrete endpoint through which a User acts; holds its own
  device-level identity.
- **Node** — any piece of transport infrastructure playing a protocol role
  (e.g. bootstrap, witness, delivery, relay, storage, media storage, home). See
  [../01-protocol/0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md).
- **Network** — the collection of Nodes and the relationships between them; the
  replaceable substrate.
- **Route** — a temporary path by which information reaches a recipient.
- **Conversation** — a logical thread of interaction between Identities,
  independent of transport.
- **Message** — a unit of information a User intends to communicate.
- **Media** — large binary content referenced by a Message.
- **Packet** — the minimal unit that crosses the Network during transmission.

`OBSERVATION:` The entities separate cleanly into three groups matching the
three layers: identity-layer (User, Identity, Device); transport-layer (Node,
Network, Route, Packet); interaction-layer (Conversation, Message, Media).

---

# System Boundaries

`OBSERVATION:` What is **part of** the OUO model:

- the cryptographic identities and their relationships;
- the model of packaging, routing, and delivering information;
- the roles that Nodes may play in transport;
- the logical structure of Conversations, Messages, and Media as carried
  information.

`OBSERVATION:` What is **not part of** the OUO model:

- any specific application or user interface built on top of OUO;
- any specific physical transport (the public internet, Bluetooth, LAN, Tor,
  etc.) — these are implementation substrates the model may run over;
- any specific storage backend or media store implementation;
- the human user themselves (a User is the model's representation of them, not
  the person).

`ASSUMPTION:` The boundary places *mechanism* (identity, packaging, routing,
delivery) inside OUO and *product* (apps, UX, deployment choices) outside it.
This is a working boundary for the Foundation stage, not yet a decision.

`QUESTION:` Are contact exchange and discovery inside the OUO model, or are they
an application concern layered on top? Not yet decided.

---

# Invariants

`OBSERVATION:` The following statements are proposed to always hold in the model.
Those already accepted are tagged `DECISION` with their source; the rest are
tagged as not-yet-decided.

- `DECISION` (P1): The user's cryptographic Identity is permanent and
  user-owned.
- `DECISION` (P1 / node invariant 8): Identity does not depend on any Node; no
  Node is the single source of truth for an Identity.
- `DECISION` (P2): A Node is not the owner of a User; messages belong to their
  participants, not to servers.
- `DECISION` (P3): A Route is temporary.
- `DECISION` (P4 / node invariant): Infrastructure is interchangeable; any Node
  can be replaced.
- `DECISION` (P5): A server is not a source of truth; it is transport.
- `DECISION` (node invariant 9): The only permanent entity in the system is the
  user's cryptographic Identity.
- `DECISION` (node invariant 7): If any Node dies, the system degrades rather
  than breaks.
- `ASSUMPTION:` An Identity may act through multiple Devices without any Device
  becoming authoritative over the Identity. (Consistent with P1; exact model
  TODO.)
- `QUESTION:` Must every Packet be end-to-end encrypted such that no Node can
  read content, as an absolute invariant? Strongly implied by P2/P5 but not yet
  stated as a formal invariant.

---

# Trust Model

`OBSERVATION:` This section describes *whom the model treats as trusted vs
untrusted*, at the conceptual level. Most of it is not yet decided.

- `DECISION` (P1): A User trusts their own cryptographic Identity / keys as the
  root of trust.
- `ASSUMPTION:` A User trusts their own Device(s) to the extent required to hold
  and use their keys. The degree of trust between Devices of the same User is
  TODO.
- `ASSUMPTION:` A User *optionally* trusts a Home Node they or their organization
  control, but the model must not *require* that trust (Home Node is optional
  per [../01-protocol/0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#7-home-node)).
- `ASSUMPTION:` All other infrastructure (bootstrap, witness, delivery, relay,
  storage, media storage) is treated as **untrusted transport** — it moves and
  briefly holds encrypted data but is not trusted with content or authority.
- `QUESTION:` Is untrusted infrastructure assumed *honest-but-curious*,
  *actively malicious*, or *some tiered mix*? Not yet decided; this is central
  to the threat model.
- `QUESTION:` What trust, if any, is placed in the party that answers route
  lookups (Witness Node), given that Route Records are self-signed by the User's
  Identity?

`OBSERVATION:` The trusted core is therefore small: the User's Identity and
their own Devices. Everything else is, by default, untrusted infrastructure.

---

# Information Ownership

`OBSERVATION:` Conceptual ownership of each kind of information. Accepted items
are tagged `DECISION`; undecided items are tagged accordingly.

- **Identity** — `DECISION` (P1): owned by the User.
- **Messages** — `DECISION` (P2): owned by the participants of the Conversation,
  never by a Node.
- **Media** — `ASSUMPTION:` owned by the participants; infrastructure holds only
  encrypted blobs and never the keys (consistent with the Media Storage role).
  Formal ownership statement TODO.
- **Routes** — `OBSERVATION:` a Route is temporary and not "owned" in a lasting
  sense; a Route Record about a User is self-signed by that User's Identity.
  Ownership framing beyond this is TODO.
- **Metadata** — `QUESTION:` who "owns" and who may observe metadata (who talks
  to whom, when, sizes, timing) is undecided and is a core open problem.
- **Contacts** — `ASSUMPTION:` owned by the User and held client-side; not owned
  by infrastructure. Whether contacts are inside the OUO model at all is a
  `QUESTION` (see System Boundaries).
- **Keys** — `DECISION` (P1): identity keys are owned by the User; `ASSUMPTION:`
  device-level keys are owned by the respective Device under the User's
  authority. Exact custody model TODO.

---

# Open Questions

`QUESTION:` Should OUO be framed identity-first or routing-first?

`QUESTION:` Are discovery and contact exchange part of the OUO model or layered
above it?

`QUESTION:` What adversary model applies to untrusted infrastructure
(honest-but-curious vs malicious vs tiered)?

`QUESTION:` Is "no Node can read content" a formal, absolute invariant?

`QUESTION:` Who may observe metadata, and what metadata protection is in scope
for the model itself vs left to implementations?

`QUESTION:` What is the trust and custody model *between* multiple Devices of the
same User?

`QUESTION:` How far does the model's boundary extend — does it include
presence, receipts, and group membership as first-class concepts, or are these
interaction-layer details deferred?

*(End of Foundation document. No Decision, ADR, or Specification follows.)*
