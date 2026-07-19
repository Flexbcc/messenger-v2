# Glossary

> **Document class:** Project dictionary.
> **Status:** Draft — clean restart.
> **Rule:** Terms here MUST match the entities in
> [0000-core-concepts.md](0000-core-concepts.md). The Core Concepts document is
> the authoritative source; this glossary is a short index. Definitions not yet
> decided are marked `TODO`. `Status` values: **Accepted** (constrained by an
> accepted principle), **Draft** (named but undefined), **Undefined** (new term,
> role not yet decided).

---

## User
- **Definition:** Logical representation of a human participant; owns a
  cryptographic Identity and may own multiple Devices.
- **Not to be confused with:** Device, Session, Contact.
- **Related terms:** Identity, Device, Contact, Conversation, Home Node.
- **Status:** Draft (ownership of identity is Accepted per P1; rest TODO).

## Identity
- **Definition:** Permanent cryptographic identity owned by a User; built on
  proven primitives (P6).
- **Not to be confused with:** Device Identity, Session.
- **Related terms:** User, Device Identity.
- **Status:** Draft (construction TODO).

## Device
- **Definition:** Concrete hardware belonging to a User; holds its own Device
  Identity.
- **Not to be confused with:** User, Client.
- **Related terms:** User, Device Identity, Client.
- **Status:** Draft.

## Device Identity
- **Definition:** Per-device cryptographic identity, distinct from the
  User-level Identity.
- **Not to be confused with:** Identity, Session.
- **Related terms:** Device, Identity.
- **Status:** Draft (attestation to Identity TODO).

## Contact
- **Definition:** A reference held by one User to another User.
- **Not to be confused with:** User, Conversation.
- **Related terms:** User, Conversation.
- **Status:** Draft (exchange/verification TODO).

## Conversation
- **Definition:** Logical thread of communication between two or more
  participants, independent of transport.
- **Not to be confused with:** Session, Group.
- **Related terms:** Message, Group, User.
- **Status:** Draft.

## Group
- **Definition:** A Conversation with more than two participants and its own
  membership model.
- **Not to be confused with:** Conversation (two-party), Session.
- **Related terms:** Conversation, User, Device.
- **Status:** Draft (relationship to Conversation TODO).

## Session
- **Definition:** Temporary interaction state between two or more Devices.
- **Not to be confused with:** User, Conversation.
- **Related terms:** Device, Device Identity, Conversation.
- **Status:** Draft (construction TODO; primitive family Accepted per P6).

## Packet
- **Definition:** Minimal unit of the network protocol; exists only during
  transmission.
- **Not to be confused with:** Message, Envelope.
- **Related terms:** Envelope, Message, Relay, Delivery Node.
- **Status:** Draft (format is a novelty area per P7).

## Envelope
- **Definition:** Protocol-level wrapper around payload/metadata; relationship
  to Packet undefined.
- **Not to be confused with:** Message, Packet.
- **Related terms:** Packet, Message.
- **Status:** Undefined (layer semantics TODO).

## Message
- **Definition:** Minimal unit of information a User intends to communicate.
- **Not to be confused with:** Packet, Envelope.
- **Related terms:** Conversation, Media, Envelope.
- **Status:** Draft.

## Media
- **Definition:** Binary content (image, video, audio, file) referenced by a
  Message.
- **Not to be confused with:** Message.
- **Related terms:** Message, Media Storage.
- **Status:** Draft.

## Route
- **Definition:** Temporary path through the network by which packets reach a
  recipient.
- **Not to be confused with:** Route Record.
- **Related terms:** Route Record, Relay, Delivery Node.
- **Status:** Draft (temporariness Accepted per P3; computation is a novelty
  area per P7).

## Route Record
- **Definition:** A record describing a current Route to a `user_id`, signed by
  the user's Identity key and bounded by a TTL; stored temporarily by Witness
  Nodes.
- **Not to be confused with:** Route, Message.
- **Related terms:** Route, Witness Node, Identity.
- **Status:** Draft (signed + TTL + Witness-stored decided; contents/TTL value
  TODO).

## Bootstrap Node
- **Definition:** Role node; first point of entry that gives a client a list of
  available service nodes (witness/delivery/relay/media). Not a user owner, not
  a message store, not a global registry of people.
- **Not to be confused with:** Witness Node, Delivery Node.
- **Related terms:** Network, Witness Node, Delivery Node, Relay, Media Storage.
- **Status:** Draft (role node; discovery mechanism TODO; interchangeable per
  P4).

## Witness Node
- **Definition:** Role node; stores temporary signed Route Records and resolves
  the current route to a `user_id`. Stores no messages, contacts, chat lists, or
  history.
- **Not to be confused with:** Delivery Node, Relay.
- **Related terms:** Route Record, Route, Identity.
- **Status:** Draft (role node; TTL/replication/publication auth TODO; not a
  message owner per P2/P5).

## Delivery Node
- **Definition:** Role node; generalized temporary delivery of encrypted
  envelopes. May aggregate Relay + Storage + a temporary queue. Not a permanent
  message store; primary queue stays on the client.
- **Not to be confused with:** Relay, Storage.
- **Related terms:** Relay, Storage, Route, Witness Node, Envelope.
- **Status:** Draft (role node; receipt semantics and role boundaries TODO;
  transport-only per P5).

## Relay
- **Definition:** Role node (a.k.a. Relay Node); forwards encrypted packets
  between participants or nodes for NAT / unstable / unreachable paths, without
  reading content.
- **Not to be confused with:** Delivery Node, Storage.
- **Related terms:** Packet, Route, Delivery Node.
- **Status:** Draft (role node; standalone-vs-capability TODO; not a message
  owner per P2/P5).

## Storage
- **Definition:** Role node (a.k.a. Storage Node); temporary buffer for
  encrypted envelopes, deleted after TTL or delivery receipt. Not a source of
  truth.
- **Not to be confused with:** Media Storage, Relay.
- **Related terms:** Delivery Node, Route, Envelope.
- **Status:** Draft (role node; TTL value/deletion guarantees TODO; not a source
  of truth per P5).

## Media Storage
- **Definition:** Role node (a.k.a. Media Storage Node); temporarily stores
  encrypted media blobs. Holds no media keys — keys travel only inside the E2EE
  message.
- **Not to be confused with:** Storage (general), Media.
- **Related terms:** Media, Message.
- **Status:** Draft (role node; retention/addressing TODO; not a content owner
  per P2/P5).

## Home Node
- **Definition:** Optional, trusted role node of a user/organization that may
  assist with device sync, route holding, and a temporary queue. Never required
  for an ordinary user.
- **Not to be confused with:** Delivery Node, Storage.
- **Related terms:** User, Server, Witness Node, Delivery Node.
- **Status:** Draft (optional role node; cached state/sync TODO; interchangeable
  per P4; not identity source of truth).

## Public Node
- **Definition:** Deployment mode; a node reachable from the public network,
  hosting one or more role-node functions per policy.
- **Not to be confused with:** Private Node, Local Node, Corporate Node.
- **Related terms:** Server, Network, Witness/Delivery/Media Storage/Home Node.
- **Status:** Draft (deployment mode; recommended role combos TODO).

## Private Node
- **Definition:** Deployment mode; owned by a user/organization, not necessarily
  publicly reachable; may use a relay/uplink.
- **Not to be confused with:** Public Node, Local Node, Corporate Node.
- **Related terms:** Server, Network, Relay.
- **Status:** Draft (deployment mode; uplink mechanism TODO).

## Local Node
- **Definition:** Deployment mode; runs inside a LAN/office, may work offline
  for local exchange, needs an uplink/delivery/relay for external reach. Not a
  mandatory part of the global network.
- **Not to be confused with:** Public Node, Private Node, Corporate Node.
- **Related terms:** Server, Network, Relay, Delivery Node.
- **Status:** Draft (deployment mode; LAN/offline mechanics TODO).

## Corporate Node
- **Definition:** Deployment mode; a managed variant of Home/Local/Public/
  Private Node operated by an organization, may serve a group of users, MUST NOT
  break E2EE.
- **Not to be confused with:** Public Node, Private Node, Local Node.
- **Related terms:** Home Node, Local Node, Public Node, Private Node.
- **Status:** Draft (deployment mode; org controls within E2EE TODO; not a
  message owner per P2/P5).

## Client
- **Definition:** User-facing software running on a Device that participates in
  OUO.
- **Not to be confused with:** Server, Device.
- **Related terms:** Device, User, Server.
- **Status:** Draft.

## Server
- **Definition:** Any node providing infrastructure services; transport, never a
  source of truth.
- **Not to be confused with:** Client.
- **Related terms:** all node types, Network.
- **Status:** Draft (transport-only per P5; not a message owner per P2;
  interchangeable per P4; role/taxonomy mapping TODO).

## Network
- **Definition:** The collection of all nodes and the protocol relationships
  between them.
- **Not to be confused with:** Server (a single node).
- **Related terms:** all node types.
- **Status:** Draft (organization is a novelty area per P7; interchangeable
  infrastructure per P4).
