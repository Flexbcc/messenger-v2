# Core Concepts

> **Document class:** Normative (not an RFC).
> **Status:** Draft — clean restart.
> **Role of this document:** Single source of truth for the terminology of the
> OUO Protocol. Every other document (RFC, ADR, glossary, diagrams) MUST use the
> entity names and definitions established here and MUST NOT introduce a second
> name for the same entity.

## Reading rules

1. This is a **clean restart**. The OUO Protocol does **not** inherit the
   definitions of any prior specification. Where an entity has not yet been
   explicitly defined by the author, its content is marked `TODO` or captured
   as an **Open Question**. Nothing below is inferred from other projects.
2. The only statements treated as already decided are the governing principles
   explicitly accepted for OUO (see below). Where such a principle constrains an
   entity, it is quoted as **Given (accepted principle)** and is authoritative.
   Everything not covered by a stated principle is `TODO`.
3. Do not resolve a `TODO` or an Open Question by guessing. Unknowns remain
   unknown until the author decides.

## Accepted principles (authoritative)

These are the decisions already accepted for OUO. They constrain the entities
defined in this document.

- **P1.** The user owns their cryptographic identity.
- **P2.** A server is never the owner of messages.
- **P3.** Routes are temporary.
- **P4.** Infrastructure is interchangeable.
- **P5.** Servers are treated as transport, not as a source of truth.
- **P6.** The protocol uses existing, proven cryptographic algorithms
  (Signal Protocol, X25519, Ed25519, etc.), not custom ones.
- **P7.** Novel design is permitted only at the level of routing, delivery,
  packet packaging, and network organization.

## Entity template

Every entity below is described with the following sections, in this order:

`# Summary` · `# Purpose` · `# Responsibilities` · `# What it is NOT` ·
`# Lifecycle` · `# Relationships` · `# Open Questions`

---

## User

# Summary
The logical representation of a human participant in the OUO network. A User is
an abstract account-level identity that can own multiple devices.

# Purpose
To provide a stable, device-independent notion of "who" a participant is, so
that communication survives changes of device.

# Responsibilities
- Own a cryptographic identity (**Given P1**).
- TODO: everything else the User is responsible for.

# What it is NOT
- A User is **not** a [Device].
- A User is **not** a [Session].
- A User is **not** owned by a [Server] (**Given P2, P5**).
- TODO: further disambiguations.

# Lifecycle
- Appears: TODO (registration / identity creation is undefined).
- Changes: TODO.
- Removed: TODO.

# Relationships
- Owns one or more [Device].
- Holds one [Identity] (**Given P1**).
- TODO: relation to [Contact], [Home Node], [Conversation].

# Open Questions
- How is a User created and how is uniqueness established?
- Is a User globally addressable, and if so how?

---

## Identity

# Summary
The permanent cryptographic identity owned by a User. Built on proven
primitives (**Given P6**).

# Purpose
To let a participant prove who they are, independently of network connectivity.

# Responsibilities
- Anchor authentication and signing for its owner.
- TODO: exact key material, algorithms, and rotation policy.

# What it is NOT
- Identity is **not** a [Device Identity].
- Identity is **not** a [Session] key.
- Identity is **not** issued or owned by a [Server] (**Given P1, P5**).

# Lifecycle
- Appears: TODO (identity generation is undefined).
- Changes: TODO (rotation / recovery undefined).
- Removed: TODO.

# Relationships
- Belongs to exactly one [User].
- Related to [Device Identity]; relationship not yet defined.

# Open Questions
- Which exact primitive(s) back Identity (Ed25519 for signing? X25519 for
  agreement?) and how are they combined? (**P6** fixes the family, not the
  construction.)
- How is Identity recovered if all devices are lost?

---

## Device

# Summary
A concrete piece of hardware belonging to a User (phone, tablet, laptop, etc.).

# Purpose
To be the physical endpoint that runs a [Client] and participates in the
network on behalf of a User.

# Responsibilities
- Hold its own [Device Identity].
- TODO: local storage, key custody, synchronization duties.

# What it is NOT
- A Device is **not** a [User].
- A Device is **not** a [Client] (the Client is the software it runs).

# Lifecycle
- Appears: TODO (device linking / enrollment undefined).
- Changes: TODO.
- Removed: TODO (de-authorization undefined).

# Relationships
- Belongs to one [User].
- Holds one [Device Identity].
- Runs a [Client].

# Open Questions
- How is a Device linked to a User?
- How is a Device revoked, and what happens to its [Session]s?

---

## Device Identity

# Summary
The per-device cryptographic identity, distinct from the User-level [Identity].

# Purpose
To let each Device authenticate and encrypt independently, so compromise or
loss of one Device is contained.

# Responsibilities
- TODO: which keys are held per device and how they relate to [Identity].

# What it is NOT
- Device Identity is **not** the User [Identity].
- Device Identity is **not** a [Session].

# Lifecycle
- Appears: TODO.
- Changes: TODO (rotation undefined).
- Removed: TODO (revocation undefined).

# Relationships
- Belongs to one [Device].
- Certified by / linked to [Identity]; mechanism TODO.

# Open Questions
- How does a Device Identity get attested by the User Identity?
- Does per-device compromise require full User re-keying?

---

## Contact

# Summary
A reference held by one User to another User with whom communication is
possible.

# Purpose
TODO: role of Contact in addressing, trust, and discovery.

# Responsibilities
- TODO.

# What it is NOT
- A Contact is **not** a [User] (it is a reference to one).
- A Contact is **not** a [Conversation].

# Lifecycle
- Appears: TODO (contact exchange undefined).
- Changes: TODO.
- Removed: TODO.

# Relationships
- Points to a [User].
- May precede a [Conversation].

# Open Questions
- How are contacts exchanged and verified?
- What data does a Contact record contain?

---

## Conversation

# Summary
A logical thread of communication between two or more participants.

# Purpose
To model an ongoing exchange independently of how its messages are transported.

# Responsibilities
- TODO: membership, ordering, and history semantics.

# What it is NOT
- A Conversation is **not** a [Session] (transport-level).
- A Conversation is **not** a [Group] (a Group is one kind of Conversation
  membership — relationship to be confirmed).

# Lifecycle
- Appears: TODO.
- Changes: TODO.
- Removed: TODO.

# Relationships
- Contains [Message]s.
- Involves two or more [User]s; group case relates to [Group].

# Open Questions
- Is a Conversation identity derived from participants, or independently
  assigned?
- Relationship between Conversation and [Group] must be fixed.

---

## Group

# Summary
A Conversation with more than two participants and its own membership model.

# Purpose
TODO: what distinguishes a Group from a two-party [Conversation].

# Responsibilities
- TODO: membership management, key distribution.

# What it is NOT
- A Group is **not** a [Server]-owned object (**Given P2, P5**).
- A Group is **not** a [Session].

# Lifecycle
- Appears: TODO (group creation undefined).
- Changes: TODO (join/leave undefined).
- Removed: TODO.

# Relationships
- Is a specialization of [Conversation].
- Contains multiple [User]s / [Device]s.

# Open Questions
- Group key management approach (**P6** requires proven primitives; exact
  scheme TODO).
- Who holds authoritative group membership if no server owns it?

---

## Session

# Summary
The temporary interaction state between two or more devices.

# Purpose
To carry the live cryptographic and transport state needed to exchange packets.

# Responsibilities
- TODO: session establishment and rekeying (built on **P6** primitives).

# What it is NOT
- A Session is **not** a [User].
- A Session is **not** a [Conversation].
- A Session is **not** permanent.

# Lifecycle
- Appears: TODO (session establishment undefined).
- Changes: TODO (rekey / ratchet undefined).
- Removed: TODO (expiry undefined).

# Relationships
- Established between [Device]s (via their [Device Identity]).
- Underlies a [Conversation]'s delivery.

# Open Questions
- Exact key-agreement construction (X3DH?) and ratchet (Double Ratchet?) —
  family fixed by **P6**, construction TODO.

---

## Packet

# Summary
The minimal unit of the OUO network protocol. Novel packaging is allowed here
(**Given P7**).

# Purpose
To carry data across the network during transmission.

# Responsibilities
- TODO: packet structure, addressing, size, and lifetime.

# What it is NOT
- A Packet is **not** a [Message].
- A Packet is **not** an [Envelope] (relationship TODO).
- A Packet exists only during transmission.

# Lifecycle
- Appears: TODO (on send).
- Changes: TODO (in transit).
- Removed: TODO (on delivery / drop).

# Relationships
- May carry a [Message], an [Envelope], acknowledgements, or control data.
- Handled by [Relay] / [Delivery Node].

# Open Questions
- Exact packet format (**P7** permits novelty here).
- Relationship between Packet and [Envelope].

---

## Envelope

# Summary
A protocol-level wrapper around payload/metadata. Its exact relationship to
[Packet] is not yet defined.

# Purpose
TODO: what the Envelope adds beyond the [Packet].

# Responsibilities
- TODO.

# What it is NOT
- An Envelope is **not** a [Message] (the plaintext content).
- An Envelope is **not** necessarily a [Packet].

# Lifecycle
- Appears: TODO.
- Changes: TODO.
- Removed: TODO.

# Relationships
- Wraps a [Message] or other payload.
- Relationship to [Packet] TODO.

# Open Questions
- Is the Envelope the encrypted container inside a Packet, or a distinct layer?
- What metadata lives in the Envelope vs the Packet? (metadata protection is a
  stated concern — see security docs.)

---

## Message

# Summary
The minimal unit of information a User intends to communicate.

# Purpose
To represent user-visible content and system events within a [Conversation].

# Responsibilities
- TODO: content types, ordering, delivery/read semantics.

# What it is NOT
- A Message is **not** a [Packet].
- A Message is **not** owned by a [Server] (**Given P2**).

# Lifecycle
- Appears: TODO (composition).
- Changes: TODO (edit/react — undefined).
- Removed: TODO (deletion — undefined).

# Relationships
- Belongs to a [Conversation].
- May reference [Media].
- Transported inside an [Envelope]/[Packet].

# Open Questions
- Enumerable set of message content types.
- Edit/delete/reaction semantics.

---

## Media

# Summary
Binary content (image, video, audio, file) associated with a [Message].

# Purpose
To carry large or non-text payloads separately from the message body.

# Responsibilities
- TODO: encryption, chunking, referencing.

# What it is NOT
- Media is **not** a [Message] (it is referenced by one).
- Media stored on infrastructure is **not** owned by a [Server] (**Given P2**).

# Lifecycle
- Appears: TODO (upload undefined).
- Changes: TODO.
- Removed: TODO (retention undefined).

# Relationships
- Referenced by a [Message].
- Held by [Media Storage].

# Open Questions
- Encryption and addressing scheme for media (**P6** primitives; construction
  TODO).

---

## Route

# Summary
A temporary path through the network by which packets reach a recipient.
Routes are temporary by principle (**Given P3**).

# Purpose
To determine how a [Packet] travels from sender to recipient. Novel routing is
allowed here (**Given P7**).

# Responsibilities
- TODO: route computation, selection, rotation.

# What it is NOT
- A Route is **not** permanent (**Given P3**).
- A Route is **not** a [Route Record] (the record describes/attests a route).

# Lifecycle
- Appears: TODO (route discovery undefined).
- Changes: TODO (rotation undefined — see routing-rotation).
- Removed: TODO (expiry undefined; temporary by **P3**).

# Relationships
- Described/attested by a [Route Record].
- Traverses [Relay] / [Delivery Node]s.

# Open Questions
- How is a Route computed and rotated (**P7** permits novelty)?
- What is the lifetime of a Route?

---

## Route Record

# Summary
A record that describes a current [Route] to a `user_id`. Signed by the user's
[Identity] key and limited by a TTL. Stored temporarily by [Witness Node]s.

# Purpose
To let others locate the current route to a user, verifiably and temporarily.

# Responsibilities
- Carry a route to a `user_id`, authenticated by the user's identity key.

# What it is NOT
- **Not** the [Route] itself.
- **Not** a [Message].
- **Not** permanent — bounded by TTL.

# Lifecycle
- Appears: published by the user (mechanism TODO).
- Changes: re-published as routes rotate (**Given P3**).
- Removed: expires on TTL.

# Relationships
- Describes a [Route]; stored by [Witness Node]s.
- Signed with the user's [Identity] key.

# Open Questions
- Exact contents of a Route Record.
- Default TTL and replication factor across Witness Nodes.
- Publication/authentication mechanism (anti-poisoning).

---

## Bootstrap Node

> Role defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#1-bootstrap-node).
> Classification: **role node**.

# Summary
The first point of entry into the network: gives a client a starting list of
available service nodes (witness, delivery, relay, media).

# Purpose
To let a client that knows nothing about the current network find service nodes.

# Responsibilities
- Provide the initial list of available service nodes.

# What it is NOT
- **Not** the owner of a user.
- **Not** a store of conversations.
- **Not** a global registry of people.
- **Not** a source of truth (**Given P5**); interchangeable (**Given P4**).

# Lifecycle
- Appears: TODO (how a client first learns of a Bootstrap Node).
- Operates: on client entry to the network.
- Removed: TODO.

# Relationships
- Points clients to [Witness Node], [Delivery Node], [Relay], [Media Storage].

# Open Questions
- How does a client discover Bootstrap Nodes initially?
- Is the returned node list signed, and by whom?

---

## Witness Node

> Role defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#2-witness-node).
> Classification: **role node**.

# Summary
A node that holds temporary, signed [Route Record]s and helps locate the current
route to a `user_id`.

# Purpose
To answer "what is the current route to this user?" without seeing content or
social graph.

# Responsibilities
- Store temporary Route Records and enforce their TTL.
- Serve route lookups by `user_id`.

# What it is NOT
- **Not** a store of messages, contacts, chat lists, or history.
- **Not** an owner of messages (**Given P2, P5**); interchangeable (**Given P4**).

# Lifecycle
- Appears: TODO (how a node joins the witness set).
- Changes: accepts signed Route Records.
- Removed: Route Records expire on TTL; node retirement TODO.

# Relationships
- Stores [Route Record]s describing a [Route].
- Queried by [Client]s and possibly [Delivery Node]s.

# Open Questions
- Route Record contents, replication factor, and default TTL.
- Authentication of Route Record publication (anti-poisoning).

---

## Delivery Node

> Role defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#3-delivery-node).
> Classification: **role node** that MAY aggregate [Relay] + [Storage] +
> temporary queue.

# Summary
A generalized role for the temporary delivery of encrypted [Envelope]s. Not a
permanent message store.

# Purpose
To move encrypted envelopes toward a recipient and briefly hold them when the
recipient is momentarily unavailable.

# Responsibilities
- Deliver encrypted envelopes temporarily.
- MAY include relay behavior and a temporary queue. The **primary** queue stays
  on the [Client].

# What it is NOT
- **Not** a permanent store of messages (**Given P2**).
- **Not** a source of truth; transport only (**Given P5**).
- Does **not** read envelope content.

# Lifecycle
- Appears: TODO.
- Changes: accept → queue if needed → forward → drop on receipt/TTL.
- Removed: TODO.

# Relationships
- May incorporate [Relay] and [Storage] behavior.
- Consumes route info originating from [Witness Node].

# Open Questions
- Boundary between Delivery / Relay / Storage when one program does all three.
- Delivery/read receipt semantics.

---

## Relay

> Role defined as **Relay Node** in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#4-relay-node).
> Classification: **role node**. (`Relay` and `Relay Node` are the same entity.)

# Summary
A node that forwards encrypted [Packet]s between participants or other nodes,
needed for NAT, unstable routes, and unreachable direct connections.

# Purpose
To bridge participants when a direct connection is impossible or unstable.

# Responsibilities
- Forward encrypted packets to the next hop (**P7** permits routing novelty).

# What it is NOT
- **Not** an owner of messages (**Given P2, P5**).
- Does **not** read packet content.

# Lifecycle
- Appears / changes / removed: TODO.

# Relationships
- Handles [Packet]s along a [Route].
- May be a sub-function of a [Delivery Node].

# Open Questions
- Is Relay usually standalone or a capability of Delivery Nodes?
- Does relaying include brief buffering, or is that strictly [Storage]?

---

## Storage

> Role defined as **Storage Node** in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#5-storage-node).
> Classification: **role node**. (`Storage` and `Storage Node` are the same
> entity.)

# Summary
A temporary buffer for encrypted [Envelope]s, used only to speed delivery when
the recipient is temporarily unavailable.

# Purpose
To hold undeliverable envelopes briefly — never as a source of truth.

# Responsibilities
- Buffer encrypted envelopes temporarily.
- Delete data after TTL **or** a delivery receipt.

# What it is NOT
- **Not** the owner of messages (**Given P2**).
- **Not** a source of truth (**Given P5**).
- **Not** permanent.
- Does **not** read envelope content.

# Lifecycle
- Appears: TODO.
- Changes: accept → hold → release on delivery.
- Removed: data MUST be deleted after TTL or delivery receipt.

# Relationships
- Serves [Delivery Node] behavior; holds [Envelope]s destined via a [Route].

# Open Questions
- Default TTL and its relation to the [Witness Node] Route Record TTL.
- Deletion guarantees after a receipt.

---

## Media Storage

> Role defined as **Media Storage Node** in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#6-media-storage-node).
> Classification: **role node**. (`Media Storage` and `Media Storage Node` are
> the same entity.)

# Summary
A node that temporarily stores encrypted [Media] blobs (photos, videos, files).

# Purpose
To hold large encrypted binary payloads separately from message delivery.

# Responsibilities
- Temporarily store encrypted media blobs, addressed by opaque handle.

# What it is NOT
- **Not** an owner of content (**Given P2, P5**).
- Does **not** hold the media keys — keys travel only inside the E2EE
  [Message].
- Does **not** read media content.

# Lifecycle
- Appears: TODO.
- Changes: accept blob → serve by handle → expire.
- Removed: TODO (retention undefined).

# Relationships
- Holds [Media] referenced by a [Message]; keys arrive via E2EE [Message].

# Open Questions
- Retention policy and blob addressing scheme.
- Behavior when a referenced blob has expired.

---

## Home Node

> Role defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#7-home-node).
> Classification: **role node (optional, trusted)**.

# Summary
An **optional**, trusted node of a User or organization that may assist with
device sync, route holding, and a temporary queue.

# Purpose
To provide convenience (sync, routing, queueing) — never a requirement. OUO
MUST NOT require a Home Node for an ordinary user.

# Responsibilities
- MAY help synchronize a User's devices, hold routes, and hold a temporary
  queue.
- MUST NOT be required for an ordinary user to function.

# What it is NOT
- **Not** the owner of the User's messages (**Given P2**).
- **Not** the single source of truth for the User's identity.
- **Not** mandatory; interchangeable (**Given P4**).

# Lifecycle
- Appears: when a user/organization opts to run one.
- Changes: assists sync/routing/queueing.
- Removed: user can migrate away; system keeps working without it.

# Relationships
- Serves one [User] (or organization users, cf. Corporate Node).
- May perform [Witness Node]/[Delivery Node]/[Media Storage] roles per policy.

# Open Questions
- What state a Home Node may cache while remaining replaceable.
- Multi-device sync mechanics (deferred).

---

## Public Node

> Defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#8-public-node).
> Classification: **deployment mode** (not a distinct wire role).

# Summary
A node reachable from the public network, hosting one or more role-node
functions (witness / delivery / media / home) per policy.

# Purpose
To provide open infrastructure ordinary users can rely on without running
anything.

# Responsibilities
- Perform its hosted role(s); role-level MUST-NOTs still apply.

# What it is NOT
- **Not** a distinct wire role — it is a placement of role nodes.
- **Not** a source of truth (**Given P5**); interchangeable (**Given P4**).

# Lifecycle
- Per the roles it hosts.

# Relationships
- Hosts [Witness Node]/[Delivery Node]/[Media Storage]/[Home Node] roles.
- One of the deployment modes: [Private Node], [Local Node], [Corporate Node].

# Open Questions
- Which role combinations are recommended/allowed for a public deployment.

---

## Private Node

> Defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#9-private-node).
> Classification: **deployment mode**.

# Summary
A node owned by a User or organization, not necessarily publicly reachable; may
use a relay/uplink to reach the wider network.

# Purpose
To let an owner run infrastructure not exposed to the public network.

# Responsibilities
- Perform role-node functions for its owner; use relay/uplink for external
  reach.

# What it is NOT
- **Not** a distinct wire role — a placement of role nodes.
- **Not** a global dependency; interchangeable (**Given P4**).

# Lifecycle
- Per owner and hosted roles.

# Relationships
- One of the deployment modes; reaches the network via [Relay]/uplink.

# Open Questions
- Uplink/relay mechanism for a non-public node (deferred to network docs).

---

## Local Node

> Defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#10-local-node).
> Classification: **deployment mode**.

# Summary
A node operating inside a LAN/office; may work without internet for local
exchange and needs an uplink/delivery/relay to reach outside.

# Purpose
To enable local (including offline) exchange without depending on the global
network.

# Responsibilities
- Serve local exchange; require an uplink for external delivery.

# What it is NOT
- **Not** a mandatory part of the global network.
- **Not** a distinct wire role — a placement of role nodes.

# Lifecycle
- Per local deployment.

# Relationships
- One of the deployment modes; needs [Relay]/[Delivery Node] uplink for
  external reach.

# Open Questions
- Offline/LAN discovery and exchange mechanics (deferred).

---

## Corporate Node

> Defined in
> [0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md#11-corporate-node).
> Classification: **deployment mode** (managed variant of Home/Local/Public/
> Private).

# Summary
A managed variant of a [Home Node]/[Local Node]/[Public Node]/[Private Node],
operated by an organization; may serve a group of users.

# Purpose
To let an organization operate OUO infrastructure for a group of users.

# Responsibilities
- MAY serve a group of users.
- MUST NOT break E2EE.

# What it is NOT
- **Not** able to read E2EE content.
- **Not** an owner of messages (**Given P2, P5**).
- **Not** the single source of truth for any user's identity.

# Lifecycle
- Per organizational policy.

# Relationships
- A managed variant of [Home Node]/[Local Node]/[Public Node]/[Private Node].

# Open Questions
- Which controls an organization may apply without violating E2EE.
- Relationship to group/organization membership (deferred).

---

## Client

# Summary
The user-facing software that runs on a [Device] and participates in OUO.

# Purpose
To provide the user interface and to perform local cryptography, storage, and
synchronization on behalf of a User.

# Responsibilities
- TODO: exact client duties (UI, key custody, sync).

# What it is NOT
- A Client is **not** a [Server].
- A Client is **not** a [Device] (it runs on one).

# Lifecycle
- Appears / operates / retires: TODO.

# Relationships
- Runs on a [Device]; acts for a [User].
- Speaks the protocol to [Server]/node types.

# Open Questions
- Which responsibilities are mandatory for a "compatible client"?

---

## Server

# Summary
Any node providing infrastructure services. Transport, never a source of truth
(**Given P5**).

# Purpose
To move and temporarily hold data — nothing more authoritative than that.

# Responsibilities
- TODO: which node roles a Server may fulfill (see node types above).

# What it is NOT
- A Server is **not** the owner of messages (**Given P2**).
- A Server is **not** a source of truth (**Given P5**).
- A Server is **not** a [Client].
- Any given Server is interchangeable (**Given P4**).

# Lifecycle
- Appears / operates / retires: TODO.

# Relationships
- May act as [Bootstrap Node], [Witness Node], [Delivery Node], [Relay],
  [Storage], [Media Storage], [Home Node], and/or a deployment class
  ([Public]/[Private]/[Local]/[Corporate] Node) — exact mapping TODO.

# Open Questions
- Is "Server" a role container or a concrete deployable? Relationship between
  Server and the node taxonomy must be fixed.

---

## Network

# Summary
The collection of all nodes and the protocol relationships between them.
Novel organization is allowed here (**Given P7**).

# Purpose
To provide the interchangeable transport substrate over which Users
communicate.

# Responsibilities
- TODO: membership, discovery, scaling.

# What it is NOT
- The Network is **not** an owner of messages (**Given P2, P5**).
- The Network is composed of interchangeable infrastructure (**Given P4**).

# Lifecycle
- Appears / operates / retires: TODO (network formation undefined).

# Relationships
- Composed of all node types defined above.

# Open Questions
- How is the Network formed, joined, and scaled (**P7** permits novelty)?
