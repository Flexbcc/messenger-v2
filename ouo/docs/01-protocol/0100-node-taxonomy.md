# Node Taxonomy

> **Document class:** Architectural (not API, not implementation).
> **Status:** Draft — clean restart.
> **Source of truth for terminology:** [0000-core-concepts.md](../00-overview/0000-core-concepts.md).
> **Scope:** Defines the node types of the OUO Protocol and separates them by
> role. Routing mechanics, packet format, and APIs are out of scope and are
> covered by later documents.

## Position of this document

OUO is a clean restart; the prior `project/spec/` is not inherited. This
document works from the accepted model:

- The user owns their cryptographic identity; it is the **only** permanent
  entity in the system.
- Servers are interchangeable infrastructure.
- Routes are temporary.
- Servers do not hold permanent message history.
- The primary message queue lives on the **client**.
- A server-side queue is permitted **only** as a temporary delivery buffer.

## Classification: role vs deployment mode vs implementation service

Not all "nodes" are different programs. A key idea of OUO is to separate three
distinct concepts:

- **Role node** — a logical role in the protocol (what a node *does* on the
  wire). A single program may perform several roles at once.
- **Deployment mode** — how and where a node is *placed* and who may reach it
  (a policy/topology concern, not a distinct wire role).
- **Implementation service** — a concrete program/container. Out of scope for
  this architectural document; mentioned only to keep the boundary clear.

Applying this classification to the eleven node types:

| Node type          | Classification            |
| ------------------ | ------------------------- |
| Bootstrap Node     | Role node                 |
| Witness Node       | Role node                 |
| Delivery Node      | Role node (may aggregate Relay + Storage + temporary queue) |
| Relay Node         | Role node                 |
| Storage Node       | Role node                 |
| Media Storage Node | Role node                 |
| Home Node          | Role node (optional, trusted) |
| Public Node        | Deployment mode           |
| Private Node       | Deployment mode           |
| Local Node         | Deployment mode           |
| Corporate Node     | Deployment mode (managed variant of Home/Local/Public/Private) |

**Naming note.** The role nodes `Relay Node`, `Storage Node`, and
`Media Storage Node` are the same entities named `Relay`, `Storage`, and
`Media Storage` in Core Concepts. The `-Node` suffix here denotes the role in
the taxonomy; the entities are identical.

## Fixed invariants

These are decided and constrain every node type below.

1. A node is **not** a user.
2. A user is **not** required to run their own node.
3. An ordinary user may rely entirely on public infrastructure.
4. Running one's own node is an **optional** mode.
5. A Local Node is useful for LAN/offline exchange but is **not** a mandatory
   part of the global network.
6. A server-side queue is **not** a guarantee of permanent storage.
7. If any node dies, the system MUST **degrade**, not break.
8. No node may be the single source of truth for a user's identity.
9. The only permanent entity is the user's cryptographic identity.

---

## 1. Bootstrap Node

# Summary
The first point of entry into the network. A **role node**.

# Purpose
To let a client that knows nothing about the current network obtain a starting
list of available service nodes.

# Responsibilities
- Provide a client with a list of available service nodes: witness, delivery,
  relay, media.
- TODO: how that list is obtained, ranked, and refreshed.

# What it MUST know
- How to reach a set of currently available service nodes.
- TODO: exact contents of the returned node list.

# What it MUST NOT know
- It MUST NOT own the user.
- It MUST NOT store conversations.
- It MUST NOT act as a global registry of people.

# What it MAY store temporarily
- TODO: whether it may cache a node list, and for how long.

# Lifecycle
- Appears: TODO (how a client first learns of a Bootstrap Node — shipped list,
  DNS, manual entry — undefined).
- Operates: on client entry to the network.
- Retires: TODO.

# Failure Behavior
- If unavailable, a client must be able to fall back to another Bootstrap Node
  (invariant 7). TODO: fallback discovery mechanism.

# Relationships
- Points clients toward [Witness Node], [Delivery Node], [Relay Node],
  [Media Storage Node].
- Interchangeable (accepted principle P4).

# Open Questions
- How does a client discover Bootstrap Nodes in the first place?
- Is the returned list signed/attested, and by whom?
- How is a malicious Bootstrap Node (returning a poisoned node list) mitigated?

---

## 2. Witness Node

# Summary
A node that holds temporary **Route Records** and helps locate a current route
to a `user_id`. A **role node**.

# Purpose
To answer "what is the current route to this user?" without knowing anything
about the user's content or social graph.

# Responsibilities
- Store temporary Route Records.
- Help find the current route to a `user_id`.
- Enforce the TTL of each Route Record.

# What it MUST know
- A mapping from `user_id` to one or more current, signed Route Records.
- The TTL/expiry of each Route Record.

# What it MUST NOT know
- It MUST NOT store messages.
- It MUST NOT store contacts.
- It MUST NOT store chat lists.
- It MUST NOT store history.

# What it MAY store temporarily
- Route Records, until their TTL expires.

# Lifecycle
- Appears: TODO (how a Witness Node joins the witness set).
- Operates: accepts signed Route Records; serves route lookups.
- Retires: Route Records expire on TTL; TODO for node retirement.

# Failure Behavior
- A Route Record MUST be signed by the user's identity key, so a dishonest or
  dead Witness cannot forge routes; clients can query another Witness
  (invariant 7). TODO: how many witnesses hold a given record and how they are
  chosen.

# Relationships
- Stores [Route Record]s that describe a [Route].
- Queried by clients (and possibly [Delivery Node]s) to resolve a route.
- Interchangeable (P4).

# Open Questions
- What exactly does a Route Record contain?
- How many Witness Nodes hold a given record (replication factor)?
- What is the default TTL?
- How is Route Record publication authenticated to prevent spam/poisoning?

---

## 3. Delivery Node

# Summary
A generalized role for the temporary delivery of encrypted envelopes. A
**role node** that MAY aggregate Relay and temporary-queue functions.

# Purpose
To move encrypted envelopes toward a recipient and briefly hold them when the
recipient is momentarily unavailable — without becoming a permanent store.

# Responsibilities
- Deliver encrypted envelopes on a temporary basis.
- MAY include relay behavior and a temporary queue.
- TODO: exact delivery/acknowledgement semantics.

# What it MUST know
- The next hop / destination needed to move an envelope forward.
- TODO: routing inputs it consumes.

# What it MUST NOT know
- It MUST NOT be a permanent store of messages.
- It MUST NOT read envelope content (inherited from Relay behavior / P2, P5).

# What it MAY store temporarily
- Encrypted envelopes in a temporary delivery queue, subject to TTL / delivery
  receipt. The **primary** queue remains on the client (accepted model).

# Lifecycle
- Appears: TODO.
- Operates: accept → (queue if needed) → forward/deliver → drop on receipt/TTL.
- Retires: TODO.

# Failure Behavior
- Loss of a Delivery Node must not lose the message: the client retains the
  primary queue and can re-deliver via another Delivery Node (invariants 6, 7).

# Relationships
- May incorporate [Relay Node] and [Storage Node] behavior.
- Consumes route information originating from [Witness Node].
- Interchangeable (P4).

# Open Questions
- Where is the boundary between "Delivery Node", "Relay Node", and
  "Storage Node" when one program performs all three?
- Delivery/read receipt semantics.

---

## 4. Relay Node

# Summary
A node that forwards encrypted packets between participants or other nodes. A
**role node**.

# Purpose
To bridge participants when a direct connection is impossible or unstable
(NAT, unstable routes, unreachable peers).

# Responsibilities
- Forward encrypted packets between participants or nodes.
- TODO: next-hop selection.

# What it MUST know
- Enough addressing to pass a packet to its next hop.

# What it MUST NOT know
- It MUST NOT read packet content.

# What it MAY store temporarily
- TODO: whether a relay may briefly buffer in-flight packets (vs Storage Node
  responsibility).

# Lifecycle
- Appears / operates / retires: TODO.

# Failure Behavior
- If a relay dies mid-path, the route is re-established via another relay
  (routes are temporary — P3; invariant 7).

# Relationships
- Carries [Packet]s along a [Route].
- May be a sub-function of a [Delivery Node].
- Interchangeable (P4).

# Open Questions
- Is Relay always a standalone node or usually a capability of Delivery Nodes?
- Does relaying include any temporary buffering, or is that strictly the
  Storage Node's job?

---

## 5. Storage Node

# Summary
A temporary buffer for encrypted envelopes. A **role node**.

# Purpose
To speed up delivery when a recipient is temporarily unavailable — never to be
a source of truth.

# Responsibilities
- Buffer encrypted envelopes temporarily.
- Delete data after TTL **or** after a delivery receipt.

# What it MUST know
- Which buffered envelope is addressed to which destination (opaque routing
  handle).
- The TTL / delivery-receipt state of each buffered item.

# What it MUST NOT know
- It MUST NOT read envelope content.
- It MUST NOT be treated as a source of truth (P5).

# What it MAY store temporarily
- Encrypted envelopes, until TTL expiry or delivery receipt — whichever comes
  first.

# Lifecycle
- Appears: TODO.
- Operates: accept encrypted envelope → hold → release on delivery → delete.
- Retires: data MUST be deleted after TTL or delivery receipt.

# Failure Behavior
- Because the primary queue is on the client, loss of a Storage Node does not
  lose the message (invariants 6, 7).

# Relationships
- Serves [Delivery Node] behavior.
- Holds [Envelope]s destined along a [Route].
- Interchangeable (P4).

# Open Questions
- Default TTL and its relationship to the Witness Node Route Record TTL.
- Deletion guarantees after a delivery receipt.

---

## 6. Media Storage Node

# Summary
A node that temporarily stores encrypted media blobs (photos, videos, files).
A **role node**.

# Purpose
To hold large encrypted binary payloads separately from message delivery.

# Responsibilities
- Temporarily store encrypted media blobs.
- TODO: retention window and addressing.

# What it MUST know
- An opaque handle/address for each stored blob.

# What it MUST NOT know
- It MUST NOT hold the keys to the media. Keys travel only inside the E2EE
  message.
- It MUST NOT read media content.

# What it MAY store temporarily
- Encrypted media blobs. TODO: retention policy.

# Lifecycle
- Appears: TODO.
- Operates: accept encrypted blob → serve by handle → expire.
- Retires: TODO (retention/expiry undefined).

# Failure Behavior
- TODO: re-upload / re-fetch behavior when a Media Storage Node is unavailable.

# Relationships
- Holds [Media] referenced by a [Message]; keys arrive via E2EE [Message].
- Interchangeable (P4).

# Open Questions
- Retention policy and blob addressing scheme.
- Behavior when a referenced blob has already expired.

---

## 7. Home Node

# Summary
An **optional**, trusted node belonging to a user or organization. A
**role node**.

# Purpose
To optionally assist a user with device synchronization, route holding, and a
temporary queue — as a convenience, never a requirement.

# Responsibilities
- MAY help a user synchronize devices.
- MAY hold routes and a temporary queue for its user.
- MUST NOT be required for an ordinary user to function.

# What it MUST know
- TODO: which of its user's routes / device set it tracks.

# What it MUST NOT know
- It MUST NOT be the single source of truth for the user's identity
  (invariant 8).
- It MUST NOT own the user's messages (P2).

# What it MAY store temporarily
- Routes and a temporary delivery queue for its user (temporary, per
  invariant 6).

# Lifecycle
- Appears: when a user/organization opts to run one.
- Operates: assists sync/routing/queueing for its user.
- Retires: user can migrate away; the system must keep working without it.

# Failure Behavior
- Because a Home Node is optional and not the identity source of truth, its loss
  degrades convenience but does not break the user (invariants 7, 8, 9).

# Relationships
- Serves one [User] (or an organization's users, cf. Corporate deployment).
- May perform [Witness]/[Delivery]/[Media Storage] roles per policy.
- Interchangeable (P4) — the user can replace it.

# Open Questions
- What state a Home Node may cache while remaining replaceable.
- Multi-device sync mechanics (deferred to a later document).

---

## 8. Public Node

# Summary
A node reachable from the public network. A **deployment mode**.

# Purpose
To provide open infrastructure that ordinary users can rely on without running
anything themselves.

# Responsibilities
- Perform one or more role-node functions (witness / delivery / media / home)
  according to its policy.

# What it MUST know
- Determined entirely by the role(s) it runs (see role nodes above).

# What it MUST NOT know
- Determined by the role(s) it runs; the role-level MUST-NOTs still apply
  (e.g. no reading content, no permanent history).

# What it MAY store temporarily
- Determined by the role(s) it runs.

# Lifecycle
- Appears / operates / retires: per the roles it hosts.

# Failure Behavior
- As interchangeable public infrastructure, its loss is absorbed by other
  public nodes (invariants 4, 7).

# Relationships
- A deployment mode that hosts [Witness Node] / [Delivery Node] /
  [Media Storage Node] / [Home Node] roles.

# Open Questions
- Which role combinations are recommended/allowed for a public deployment.

---

## 9. Private Node

# Summary
A node owned by a user or organization, not necessarily publicly reachable. A
**deployment mode**.

# Purpose
To let an owner run OUO infrastructure that is not exposed to the public
network.

# Responsibilities
- Perform role-node functions for its owner.
- MAY use a relay/uplink to reach the wider network.

# What it MUST know
- Determined by the role(s) it runs, plus how to reach its uplink/relay.

# What it MUST NOT know
- Determined by the role(s) it runs; role-level MUST-NOTs apply.

# What it MAY store temporarily
- Determined by the role(s) it runs.

# Lifecycle
- Appears / operates / retires: per owner and hosted roles.

# Failure Behavior
- Its loss affects only its owner's convenience; global connectivity is
  unaffected (invariants 2, 3, 7).

# Relationships
- A deployment mode; reaches the network via [Relay Node] / uplink.

# Open Questions
- Uplink/relay mechanism for a non-public node (deferred to network documents).

---

## 10. Local Node

# Summary
A node operating inside a LAN/office. A **deployment mode**.

# Purpose
To enable local exchange, including offline, without depending on the global
network.

# Responsibilities
- Serve local exchange within a LAN/office.
- MAY operate without internet for local exchange.
- Requires an uplink/delivery/relay to reach the outside.

# What it MUST know
- The local participants it serves.
- How to reach an uplink when external delivery is needed.

# What it MUST NOT know
- Determined by the role(s) it runs; role-level MUST-NOTs apply.

# What it MAY store temporarily
- Determined by the role(s) it runs.

# Lifecycle
- Appears / operates / retires: per local deployment.

# Failure Behavior
- Its loss affects only local convenience; it is not a mandatory part of the
  global network (invariants 5, 7).

# Relationships
- A deployment mode; needs [Relay Node] / [Delivery Node] uplink for external
  reach.

# Open Questions
- Offline/LAN discovery and exchange mechanics (deferred).

---

## 11. Corporate Node

# Summary
A managed variant of a Home / Local / Public / Private Node, operated by an
organization. A **deployment mode**.

# Purpose
To let an organization operate OUO infrastructure for a group of users.

# Responsibilities
- MAY serve a group of users.
- MUST NOT break E2EE.

# What it MUST know
- Determined by the underlying deployment mode and hosted roles.

# What it MUST NOT know
- It MUST NOT be able to read E2EE content.
- It MUST NOT become the single source of truth for any user's identity
  (invariant 8).

# What it MAY store temporarily
- Determined by the role(s) it runs (temporary buffers only, per invariant 6).

# Lifecycle
- Appears / operates / retires: per organizational policy.

# Failure Behavior
- Organizational management must not create a hard dependency: on failure,
  served users degrade to other infrastructure (invariants 7, 8).

# Relationships
- A managed variant of [Home Node] / [Local Node] / [Public Node] /
  [Private Node].

# Open Questions
- Which controls an organization may apply without violating E2EE.
- Relationship to group/organization membership (deferred).

---

# Node Role Matrix

Legend: `Yes` / `No` = decided; `TODO` = not yet decided; `Temp` = temporary
buffer only. "Role" and "Deployment" indicate the classification.

| Node Type          | Role or Deployment Mode | Required for MVP | Stores Messages | Stores Routes | Stores Media | Publicly Reachable | Can Be Replaced |
| ------------------ | ----------------------- | ---------------- | --------------- | ------------- | ------------ | ------------------ | --------------- |
| Bootstrap Node     | Role                    | TODO             | No              | No            | No           | Yes                | Yes             |
| Witness Node       | Role                    | TODO             | No              | Temp (TTL)    | No           | TODO               | Yes             |
| Delivery Node      | Role                    | TODO             | Temp (buffer)   | TODO          | No           | TODO               | Yes             |
| Relay Node         | Role                    | TODO             | No              | No            | No           | TODO               | Yes             |
| Storage Node       | Role                    | TODO             | Temp (TTL)      | No            | No           | TODO               | Yes             |
| Media Storage Node | Role                    | TODO             | No              | No            | Temp         | TODO               | Yes             |
| Home Node          | Role (optional)         | No               | Temp (queue)    | Temp          | TODO         | TODO               | Yes             |
| Public Node        | Deployment              | TODO             | Per role        | Per role      | Per role     | Yes                | Yes             |
| Private Node       | Deployment              | No               | Per role        | Per role      | Per role     | No                 | Yes             |
| Local Node         | Deployment              | No               | Per role        | Per role      | Per role     | No                 | Yes             |
| Corporate Node     | Deployment              | No               | Per role        | Per role      | Per role     | TODO               | Yes             |

Notes:
- "Can Be Replaced = Yes" for every node follows from accepted principle P4
  (infrastructure is interchangeable) and invariant 9 (only the user's
  cryptographic identity is permanent).
- "Stores Messages" is at most `Temp` for any node; no node is a permanent
  message store (invariant 6, accepted model).
- `Required for MVP` is largely TODO because the MVP node set has not yet been
  decided.
