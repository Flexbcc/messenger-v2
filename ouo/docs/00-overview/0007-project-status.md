# Project Status

> **Document class:** Architectural decision journal (not documentation, not an
> RFC).
> **Status:** Draft — clean restart.
> **Rule:** This journal records only decisions that have been **explicitly**
> made by the author. Nothing here is inferred. Undecided matters live under
> **Discussion** or **Future Ideas**, or are marked `TODO`.

## Approved

Decisions explicitly accepted so far.

- **A1 — Governing principles.** The seven principles P1–P7 are accepted and are
  authoritative for all OUO design (see
  [0000-core-concepts.md](0000-core-concepts.md#accepted-principles-authoritative)):
  1. The user owns their cryptographic identity.
  2. A server is never the owner of messages.
  3. Routes are temporary.
  4. Infrastructure is interchangeable.
  5. Servers are transport, not a source of truth.
  6. Use existing, proven cryptography (Signal Protocol, X25519, Ed25519, …),
     not custom algorithms.
  7. Novelty is permitted only in routing, delivery, packet packaging, and
     network organization.
- **A2 — Cryptographic primitive family.** OUO builds on the Signal Protocol
  family and the named primitives X25519 and Ed25519. (This fixes the *family*
  only; exact constructions are not yet decided — see Discussion.)
- **A3 — Clean restart.** OUO does not inherit the prior `project/spec/`
  specification as its source of truth. Core Concepts are authored fresh; any
  entity not yet defined is `TODO`.
- **A4 — Documentation methodology.** Every specification/RFC document uses the
  fixed 12-section structure (Summary, Motivation, Problem, Goals, Non Goals,
  Architecture, Data Flow, Security, Failure Scenarios, Alternatives, Open
  Questions, Future Work). No code, no API in architecture documents, no mixing
  of philosophy/architecture/implementation. Unknowns are marked `TODO` or as
  Open Questions rather than invented.
- **A5 — Core Concepts structure.** Every entity in the Core Concepts document
  uses the fixed 6-section structure (Summary, Purpose, Responsibilities, What
  it is NOT, Lifecycle, Relationships, Open Questions), and the Core Concepts
  document is the single source of truth for terminology.
- **A6 — Foundation-first ordering.** Vision, Philosophy, Goals, and RFCs are
  not written until every base entity is defined. Foundation documents
  (Core Concepts, Project Status, Glossary) come first.
- **A7 — Node taxonomy.** The eleven node types are defined and classified in
  [../01-protocol/0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md).
  Decided facts:
  - Three-way classification: **role node** (logical protocol role) vs
    **deployment mode** (placement/access policy) vs **implementation service**
    (concrete program — out of scope here). Role nodes: Bootstrap, Witness,
    Delivery, Relay, Storage, Media Storage, Home. Deployment modes: Public,
    Private, Local, Corporate.
  - Nine fixed invariants (node ≠ user; a user need not run a node; ordinary
    users may use public infrastructure; own node is optional; Local Node is not
    mandatory; server queue ≠ permanent storage; node death degrades not breaks;
    no node is the single source of truth for identity; the only permanent
    entity is the user's cryptographic identity).
  - Preliminary role definitions accepted as stated by the author for Bootstrap,
    Witness, Delivery, Relay, Storage, Media Storage, Home, Public, Private,
    Local, Corporate.
  - Route Records are signed by the user's identity key, TTL-bounded, and stored
    temporarily by Witness Nodes.
  - Delivery Node MAY aggregate Relay + Storage + a temporary queue; the primary
    message queue stays on the client.
  - Media Storage Nodes never hold media keys (keys travel inside E2EE
    messages).
- **A8 — Documentation Quality Standard.** The project adopts the standard in
  [0008-documentation-standard.md](0008-documentation-standard.md): documentation
  is the source of truth; every statement is tagged (FACT / OBSERVATION / OPTION
  / DECISION / TODO / QUESTION); research holds no decisions; RFCs describe only
  decisions; every decision gets an ADR; every document carries a Status +
  Last-updated block; cross-reference instead of duplicating; AI-friendly
  writing; assumptions marked `ASSUMPTION`; architecture changes marked
  `BREAKING CHANGE`.
  - **BREAKING CHANGE** to the development pipeline (previously stated in the
    methodology as Research → Comparison → Discussion → Decision → RFC →
    Implementation). The final, exception-free pipeline is:
    **Research → Comparison → Decision → ADR → RFC → Implementation.**
    Comparison lives in `docs/12-comparison/`, Decisions in
    `docs/13-decisions/`, ADRs in `docs/07-adr/`. Reason: alignment with A8.
- **A9 — Foundation stage.** A **Foundation** stage is inserted between
  Comparison and Decision, authored in `docs/14-foundation/`, describing
  conceptual protocol models ("what is OUO?") without making decisions.
  - **BREAKING CHANGE** to the A8 pipeline. Final pipeline:
    **Research → Comparison → Foundation → Decision → ADR → Specification (RFC)
    → Implementation.** Reason: the protocol needs a conceptual system model
    before any decision. The first Foundation document is
    [../14-foundation/0001-system-model.md](../14-foundation/0001-system-model.md).

## Discussion

Topics currently open and under active design.

- **D1 — Node taxonomy.** *Largely resolved by A7.* The node types, their
  classification, and preliminary roles are decided. Remaining open items:
  - Which nodes are required for MVP (`Required for MVP` is mostly TODO in the
    Node Role Matrix).
  - Bootstrap Node discovery: how a client finds Bootstrap Nodes initially, and
    whether the returned node list is signed.
  - Witness Node: Route Record contents, default TTL, replication factor, and
    publication authentication (anti-poisoning).
  - Boundary between Delivery / Relay / Storage when one program performs all
    three; delivery/read receipt semantics.
  - Media Storage retention policy and blob addressing.
  - Uplink/relay mechanism for Private and Local nodes.
  - Which controls a Corporate Node may apply without breaking E2EE.
- **D2 — Server vs node roles.** Whether "Server" is a role container or a
  concrete deployable, and how it maps onto the node taxonomy, is undefined.
  Partially clarified by A7's role/deployment/service split, but the exact
  Server ↔ taxonomy mapping is still TODO.
- **D3 — Exact cryptographic constructions.** A2 fixes the primitive family; the
  concrete key-agreement (e.g. X3DH?) and ratchet (e.g. Double Ratchet?)
  constructions are not yet decided. TODO.
- **D4 — Packet vs Envelope.** Whether the Envelope is the encrypted container
  inside a Packet or a separate layer is undefined. TODO.
- **D5 — Route vs Route Record vs Witness.** What a Route Record contains, who
  signs it, and the Witness Node's exact function are undefined. TODO.
- **D6 — Conversation vs Group.** The precise relationship between Conversation
  and Group is undefined. TODO.
- **D7 — Identity vs Device Identity.** How the per-device identity is attested
  by the user identity, and the impact of device compromise, is undefined. TODO.

## Rejected

Ideas explicitly declined.

- **R1 — Inheriting the prior specification.** Using the existing
  `project/spec/` glossary, ADRs, and node documents as OUO's source of truth
  was considered and rejected in favor of a clean restart (see A3).
- **R2 — Custom cryptographic algorithms.** Designing bespoke cryptographic
  primitives is rejected; only proven algorithms are used (see P6 / A2).

## Future Ideas

Ideas noted for later, without any decision.

- **F1 — Onion routing.** Reserved as future work in the documentation structure
  (`docs/03-network/0310-onion-routing-future.md`). No decision made.
- TODO: capture further future ideas as they are raised by the author.
