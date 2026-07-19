# Research: Distributed Messaging Systems

> **Document class:** Research (existing systems). **Not** an RFC, **not** a
> specification, **not** an architecture proposal.
> **Status:** Draft.
> **Rule:** This document only investigates how existing systems work. It
> contains no conclusions, no recommendations, and no decisions. The recurring
> "Ideas potentially useful for OUO" section lists neutral observations of
> transferable techniques; it does **not** propose or decide anything for OUO.
> Facts the author of this document is unsure about are marked `TODO / verify`.

## Scope and method

Each system below is examined against the same eleven questions:

1. What is the permanent entity?
2. How is a user identified?
3. How is a user found?
4. How does delivery work?
5. How does offline work?
6. How does device change work?
7. How do groups work?
8. How do calls work?
9. Pros?
10. Cons?
11. Ideas potentially useful for OUO?

Systems covered: Signal, Session, SimpleX, Matrix, XMPP, Briar, Tor, Tox,
Nostr. Tor is not a messenger; it is included as anonymity/transport
infrastructure that messengers build upon.

---

## Signal

- **Permanent entity:** The user's long-term identity key pair. An account is
  registered on Signal's centralized servers and historically bound to a phone
  number; usernames were later added as an alternative discovery handle.
- **User identification:** Phone number (E.164), and more recently an optional
  username; registration lock / PIN protects the account.
- **User discovery:** Private contact discovery — the client checks its address
  book against the server; Signal has used trusted execution (SGX enclaves) to
  limit what the server learns.
- **Delivery:** Centralized Signal servers accept and queue ciphertext, push via
  FCM/APNs, and delete messages after delivery. "Sealed sender" hides the
  sender identity from the server for established contacts.
- **Offline:** The server holds undelivered ciphertext transiently until the
  device reconnects, then deletes it.
- **Device change:** Encryption uses X3DH + Double Ratchet. Linked devices are
  managed by the Sesame protocol; the phone has historically been the primary
  device. Re-registering changes the identity and the "safety number".
- **Groups:** "Private groups" (v2) use anonymous credentials / zero-knowledge
  so the server does not learn group membership.
- **Calls:** 1:1 and group calls over WebRTC; Signal-operated TURN servers for
  NAT traversal; an SFU for group calls.
- **Pros:** Strong, audited E2EE; simple UX; metadata reduction via sealed
  sender and private groups.
- **Cons:** Centralized single provider; historical phone-number dependency;
  server is a single operational trust point.
- **Ideas potentially useful for OUO:** X3DH + Double Ratchet (already in OUO's
  accepted primitive family), sealed-sender-style metadata hiding, private
  contact discovery, membership-hiding group credentials.

---

## Session

- **Permanent entity:** A long-term key pair; the account *is* the public key.
  A mnemonic recovery phrase (seed) reconstructs it.
- **User identification:** "Session ID", a string derived from the account
  public key. No phone number or email.
- **User discovery:** Direct exchange of the Session ID; there is no central
  user directory.
- **Delivery:** Onion routing over the Oxen service-node network. Each account
  is served by a "swarm" (a group of service nodes) that provides store-and-
  forward.
- **Offline:** Swarm nodes hold messages for an account until retrieved, subject
  to TTL.
- **Device change:** Restore the account from the recovery seed; multi-device is
  achieved by sharing the account key. `TODO / verify:` Session historically
  used a simplified session model and reduced per-session forward secrecy
  compared to upstream Signal to support this multi-device model.
- **Groups:** Closed groups, and open "communities" hosted by a Session Open
  Group Server (SOGS).
- **Calls:** 1:1 voice/video calls over WebRTC.
- **Pros:** No phone number; metadata resistance via onion routing;
  decentralized store-and-forward via swarms; key-based identity.
- **Cons:** Dependence on an incentivized (cryptocurrency-backed) service-node
  network; onion-routing latency; `TODO / verify` regarding forward-secrecy
  trade-offs.
- **Ideas potentially useful for OUO:** Account = key pair with a recovery seed;
  swarm-based store-and-forward keyed by the account public key; onion routing
  over a service-node network.

---

## SimpleX

- **Permanent entity:** No global user identity. Identity is effectively the set
  of pairwise connections; keys and queues are per contact.
- **User identification:** No user identifiers at all. Connections are made via
  an out-of-band invitation link / QR code that carries queue addresses and
  keys.
- **User discovery:** There is no discovery by identifier; a user shares an
  invitation link. Each contact pair uses separate messaging queues.
- **Delivery:** Messages traverse SMP (Simplex Messaging Protocol) relay servers
  that host unidirectional queues — typically separate queues per direction. The
  relay sees queue IDs, not user identities. An optional relay/proxy mode hides
  the sender's IP from the destination relay.
- **Offline:** A relay holds messages in the queue until the recipient fetches
  them, subject to TTL.
- **Device change:** The profile is stored locally; migration is via database
  export/import; desktop can be linked to mobile. `TODO / verify` exact
  multi-device sync details.
- **Groups:** Groups are implemented client-side as a membership set with
  pairwise connections to each member; there is no server-side group object.
- **Calls:** Audio/video calls over WebRTC.
- **Pros:** No user identifiers → strong metadata privacy; no central directory;
  disposable queues.
- **Cons:** No discovery by identifier (links must be exchanged); group scaling
  cost grows with pairwise connections; added UX friction.
- **Ideas potentially useful for OUO:** No-global-identifier design;
  unidirectional per-contact queues; disposable/rotatable queue addresses;
  relay that sees only opaque queue IDs.

---

## Matrix

- **Permanent entity:** A user account on a "homeserver", plus per-device keys.
  Account data and room history persist on the homeserver.
- **User identification:** Matrix ID of the form `@localpart:homeserver`.
- **User discovery:** Via the homeserver and optional identity servers that map
  email/phone to a Matrix ID; there is a user directory.
- **Delivery:** Federation between homeservers. Each room is replicated as a
  directed acyclic graph (DAG) of events across all participating homeservers,
  with eventual consistency and state resolution.
- **Offline:** Homeservers store events and history persistently; a client syncs
  when it reconnects.
- **Device change:** Per-device keys; cross-signing lets a user attest their own
  devices; an encrypted key backup can be stored server-side; devices are
  verified interactively.
- **Groups:** Rooms are the core primitive; a 1:1 chat is just a two-member
  room. E2EE rooms use the Megolm group ratchet.
- **Calls:** 1:1 VoIP over WebRTC; group calls via newer approaches (SFU /
  Element Call). `TODO / verify` current group-call architecture.
- **Pros:** Open federation; full synchronized history; large ecosystem and
  bridges.
- **Cons:** Homeservers hold history persistently and see substantial metadata
  (social graph); room replication is heavy; protocol complexity.
- **Ideas potentially useful for OUO:** Federation model; cross-signing for
  device trust; encrypted server-side key backup. (Persistent homeserver history
  is contrary to OUO's stated model and is noted here only as an observation,
  not a recommendation.)

---

## XMPP

- **Permanent entity:** A JID account (`user@domain`) hosted on a server.
- **User identification:** JID, optionally with a resource:
  `user@domain/resource`.
- **User discovery:** Via the server; roster (contact list); service discovery
  (disco).
- **Delivery:** Server-to-server federation with store-and-forward; Message
  Archive Management (MAM) provides history; offline messages are stored for
  disconnected users.
- **Offline:** Offline messages and the MAM archive are stored on the server.
- **Device change:** Multiple "resources" per account; OMEMO provides
  multi-device E2EE; historically multi-device E2EE was weak/optional.
- **Groups:** Multi-User Chat (MUC) rooms hosted by a server component; the newer
  MIX aims to improve multi-device group behavior.
- **Calls:** Jingle negotiates media sessions (VoIP/video), typically over
  ICE/WebRTC transports.
- **Pros:** Mature, standardized, extensible via XEPs; federated.
- **Cons:** Fragmented extension landscape; servers hold metadata and archives;
  E2EE (OMEMO) is optional rather than universal.
- **Ideas potentially useful for OUO:** Federation; separation of signaling
  (Jingle) from media; service discovery; the resource concept for
  multi-device.

---

## Briar

- **Permanent entity:** A local identity key pair; there are no servers.
- **User identification:** By public key; contacts are added via link/QR or
  nearby exchange.
- **User discovery:** No discovery service; contacts are added out-of-band.
  Internet contact uses Tor onion services.
- **Delivery:** Direct peer-to-peer over Tor, Bluetooth, or Wi-Fi; store-and-
  forward happens when devices sync. The optional "Briar Mailbox" is a
  self-hosted store-and-forward relay for when a contact is offline.
- **Offline:** Works offline over Bluetooth / local Wi-Fi; messages sync when
  connectivity is available; no infrastructure is required.
- **Device change:** Identity and data are local to the device; historically
  there is no multi-device and no account portability. `TODO / verify` current
  state.
- **Groups:** Private groups, forums, and blogs that sync among mutual contacts.
- **Calls:** `TODO / verify` — Briar's focus is messaging/sync; real-time calls
  are not a core historical feature.
- **Pros:** No servers; censorship resistant; offline mesh transports; Tor-based
  addressing.
- **Cons:** Direct sync generally needs both parties reachable (or a mailbox);
  no multi-device; higher latency and battery use.
- **Ideas potentially useful for OUO:** Tor onion-service addressing;
  offline/mesh transports (Bluetooth, Wi-Fi); a user-controlled mailbox as
  store-and-forward; contact-based sync.

---

## Tor

*(Anonymity/transport network, not a messenger — included as infrastructure.)*

- **Permanent entity:** For an onion service, a long-term identity key (v3 uses
  Ed25519), from which the `.onion` address is derived.
- **Identification:** The `.onion` address is a self-authenticating encoding of
  the service's public key.
- **Discovery:** Onion-service descriptors are published to a distributed hash
  ring of directory nodes (HSDirs); clients use introduction and rendezvous
  points to connect.
- **Delivery:** Traffic is routed through multi-hop circuits (typically three
  relays); onion services are reached via a rendezvous point.
- **Offline:** Not applicable (transport only); descriptors expire and are
  refreshed.
- **Device change:** Not applicable.
- **Groups:** Not applicable.
- **Calls:** Not applicable (can carry other protocols).
- **Pros:** Strong anonymity; self-authenticating addresses (address derived
  from key); NAT traversal via rendezvous without a public IP.
- **Cons:** Latency; complexity; provides no messaging or storage layer itself.
- **Ideas potentially useful for OUO:** Self-authenticating addresses (address =
  function of key); rendezvous for NAT traversal; a descriptor DHT for locating
  a service by its key — conceptually adjacent to route lookup.

---

## Tox

- **Permanent entity:** A long-term key pair, encoded as a Tox ID; the identity
  is a local key file.
- **User identification:** Tox ID (public key + a "nospam" value + checksum).
- **User discovery:** A distributed hash table (DHT) is used for peer discovery;
  bootstrap nodes let a client join the DHT; friend requests are sent to a Tox
  ID.
- **Delivery:** Direct peer-to-peer (UDP, with TCP fallback); "TCP relay" nodes
  assist NAT traversal. There is no store-and-forward.
- **Offline:** No offline messaging — the recipient must be online; messages are
  not queued for later. This is a well-known limitation.
- **Device change:** No multi-device; the identity is a local key file with no
  sync.
- **Groups:** Group chats exist; older group chats were unreliable, and newer
  "NGC" group chats were introduced to improve this. `TODO / verify` current
  status.
- **Calls:** Audio/video via ToxAV.
- **Pros:** Fully peer-to-peer; no central server; DHT + bootstrap discovery.
- **Cons:** No offline messages; no multi-device; the DHT exposes presence
  metadata; historical reliability issues.
- **Ideas potentially useful for OUO:** DHT-based peer discovery; the bootstrap-
  node concept for joining a network; TCP relays for NAT; Tox ID = key.

---

## Nostr

- **Permanent entity:** A key pair (secp256k1); the public key *is* the
  identity.
- **User identification:** The public key (hex, or `npub` bech32 encoding).
- **User discovery:** Via relays chosen by the user; NIP-05 maps a DNS-based
  `name@domain` identifier to a public key.
- **Delivery:** Clients publish signed "events" to multiple relays; recipients
  subscribe to relays to receive them. Direct messages historically used NIP-04
  (which leaks metadata); NIP-17 "gift-wrapped" DMs improve metadata privacy.
- **Offline:** Relays store events per their own retention policy; a client
  fetches them later. There is no delivery guarantee — sender and recipient must
  share at least one relay.
- **Device change:** The same private key can be imported anywhere, making
  multi-device trivial; there is no session state, so there is no native forward
  secrecy.
- **Groups:** NIP-28 public chat and NIP-29 relay-based groups exist; group
  support is still evolving. `TODO / verify` current status.
- **Calls:** Not native; `TODO / verify` any real-time-call extensions.
- **Pros:** Very simple; censorship resistant via multi-relay redundancy; key =
  identity; trivial multi-device.
- **Cons:** Historically weak DM privacy; no native forward secrecy; relays store
  data and see subscription metadata (which pubkeys talk/subscribe); spam.
- **Ideas potentially useful for OUO:** Publishing redundantly to multiple relays;
  key = identity; DNS-to-key mapping (NIP-05) as a discovery aid; gift-wrapping
  to hide message metadata.

---

## Cross-cutting observations (factual, non-deciding)

These are neutral observations of recurring patterns across the systems above.
They are **not** comparisons scored against OUO criteria (that is the next,
separate Comparison document) and they contain no decisions.

- **Identity anchor:** Several systems make the identity a key pair where the
  address is derived from the public key (Session, Tox, Nostr, Tor onion
  services). Others anchor identity to a server account (Matrix, XMPP) or a phone
  number (Signal).
- **Discovery:** Ranges from none/out-of-band (SimpleX, Briar) through DHT (Tox,
  Tor descriptors) to directory/DNS mappings (Matrix identity servers, Nostr
  NIP-05) and private contact discovery (Signal).
- **Offline delivery:** Provided by store-and-forward (Signal transient, Session
  swarms, SimpleX queues, XMPP/Matrix persistent archives, Briar mailbox) or
  absent entirely (Tox).
- **History ownership:** Some systems keep persistent history on servers
  (Matrix, XMPP MAM, Nostr relays); others keep it transient or client-side
  (Signal, SimpleX, Briar).
- **Metadata protection:** Approaches include sealed sender (Signal), onion
  routing (Session, Tor, Briar), no-identifier queues (SimpleX), and
  gift-wrapping (Nostr).

*(End of research. No RFC and no architectural decision follows from this
document. The next stage is a separate Comparison document.)*
