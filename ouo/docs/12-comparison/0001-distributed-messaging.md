# Comparison: Distributed Messaging Systems

> **Status:** Draft
> **Last updated:** 2026-07-08
> **Document class:** Comparison. **Not** a decision, **not** an RFC.
> **Source:** Built **exclusively** from
> [../11-research/01-existing-systems/0001-distributed-messaging.md](../11-research/01-existing-systems/0001-distributed-messaging.md).
> No new facts are introduced here; see the research document for detail and for
> `TODO / verify` markers.

## Status of statements in this document

Every matrix cell is an **OBSERVATION** derived from a **FACT** recorded in the
research document, unless the cell is marked **TODO** (unverified in research).
This document compares only. It contains no OPTION, no DECISION, and no
recommendation. Ranking, scoring, and "best for OUO" judgements are explicitly
out of scope and belong to the later Decision stage.

Systems compared: Signal, Session, SimpleX, Matrix, XMPP, Briar, Tor, Tox,
Nostr. Tor is transport/anonymity infrastructure, not a messenger; cells that do
not apply are marked `N/A`.

## Matrix 1 — Identity & discovery

| System  | Permanent entity | User identification | User discovery |
| ------- | ---------------- | ------------------- | -------------- |
| Signal  | Long-term identity key pair; server account | Phone number (E.164), optional username | Private contact discovery (address book, enclave-assisted) |
| Session | Key pair; account = public key; recovery seed | Session ID (derived from public key) | Direct exchange of Session ID; no central directory |
| SimpleX | No global identity; per-contact keys/queues | No identifiers | Out-of-band invitation link/QR; no directory |
| Matrix  | Server account + per-device keys | `@localpart:homeserver` | Homeserver + optional identity servers; user directory |
| XMPP    | JID account on a server | `user@domain[/resource]` | Server; roster; service discovery |
| Briar   | Local identity key pair; no servers | Public key | Out-of-band (link/QR/nearby); Tor onion for internet |
| Tor     | Onion-service long-term key (Ed25519 v3) | `.onion` address = encoded public key | Descriptor DHT (HSDirs) + intro/rendezvous points |
| Tox     | Key pair; local key file | Tox ID (pubkey + nospam + checksum) | DHT peer discovery; bootstrap nodes |
| Nostr   | Key pair (secp256k1) | Public key (`npub`/hex) | Relays; NIP-05 DNS `name@domain` → pubkey |

## Matrix 2 — Delivery & offline

| System  | Delivery model | Offline delivery | History ownership |
| ------- | -------------- | ---------------- | ----------------- |
| Signal  | Centralized servers; sealed sender | Transient server queue, deleted after delivery | Transient (client-held) |
| Session | Onion routing over Oxen service nodes; per-account swarm | Swarm store-and-forward with TTL | Swarm-held with TTL |
| SimpleX | SMP relays hosting unidirectional queues | Relay holds queue until fetched, TTL | Transient (queue), client-side |
| Matrix  | Federation; room replicated as event DAG | Homeserver stores events persistently | Persistent on homeservers |
| XMPP    | S2S federation; store-and-forward; MAM | Offline messages + MAM archive on server | Persistent on server (MAM) |
| Briar   | Direct P2P (Tor/Bluetooth/Wi-Fi); optional Mailbox | Mesh sync when reachable; Mailbox relay | Client-side (per device) |
| Tor     | Multi-hop circuits; rendezvous | N/A (transport) | N/A |
| Tox     | Direct P2P (UDP/TCP); TCP relays for NAT | None — recipient must be online | Client-side; no queue |
| Nostr   | Publish signed events to multiple relays | Relays store per policy; no guarantee | Persistent on relays (per policy) |

## Matrix 3 — Devices, groups, calls

| System  | Device change / multi-device | Groups | Calls |
| ------- | ---------------------------- | ------ | ----- |
| Signal  | X3DH + Double Ratchet; Sesame linked devices; phone primary | Private groups (anonymous credentials) | 1:1 & group WebRTC; Signal TURN/SFU |
| Session | Restore from recovery seed; key sharing | Closed groups; open communities (SOGS) | 1:1 voice/video (WebRTC) |
| SimpleX | Local profile; DB export/import; desktop link — TODO details | Client-side pairwise membership; no server group | Audio/video (WebRTC) |
| Matrix  | Per-device keys; cross-signing; encrypted server key backup | Rooms (Megolm); 1:1 = 2-member room | 1:1 WebRTC; group via SFU/Element Call — TODO |
| XMPP    | Multiple resources; OMEMO multi-device | MUC rooms; newer MIX | Jingle over ICE/WebRTC |
| Briar   | Local data; historically no multi-device — TODO | Private groups, forums, blogs | TODO (not a core feature) |
| Tor     | N/A | N/A | N/A |
| Tox     | No multi-device; local key file | Group chats; newer NGC — TODO | ToxAV audio/video |
| Nostr   | Import private key anywhere; trivial multi-device; no forward secrecy | NIP-28 public chat; NIP-29 groups — TODO | Not native — TODO |

## Matrix 4 — Metadata protection technique(s)

| System  | Primary metadata-protection technique(s) |
| ------- | ---------------------------------------- |
| Signal  | Sealed sender; membership-hiding private groups |
| Session | Onion routing over service nodes |
| SimpleX | No identifiers; opaque per-contact queues |
| Matrix  | E2EE content only; homeservers see social-graph metadata |
| XMPP    | OMEMO for content; server sees metadata/archives |
| Briar   | Onion routing (Tor); no servers |
| Tor     | Onion routing; self-authenticating addresses |
| Tox     | P2P (no central server); DHT exposes presence |
| Nostr   | Gift-wrapped DMs (NIP-17); relays see subscription metadata |

## Comparison axes summary (observations only)

The following axes emerge from the matrices above. These are **OBSERVATION**s of
where systems differ; they are not scores and imply no preference.

- **Identity anchor:** key-derived address (Session, Tox, Nostr, Tor) vs server
  account (Matrix, XMPP) vs phone number (Signal) vs no identity (SimpleX).
- **Discovery mechanism:** out-of-band only (SimpleX, Briar) vs DHT (Tox, Tor)
  vs directory/DNS mapping (Matrix, Nostr NIP-05) vs private contact discovery
  (Signal).
- **Offline model:** transient server queue (Signal, SimpleX) vs decentralized
  store-and-forward with TTL (Session) vs persistent server history
  (Matrix, XMPP, Nostr relays) vs none (Tox) vs user-controlled mailbox/mesh
  (Briar).
- **History ownership:** transient/client-side (Signal, SimpleX, Briar) vs
  persistent server/relay (Matrix, XMPP, Nostr).
- **Multi-device:** ratchet + linked devices (Signal), key sharing / key import
  (Session, Nostr), per-device keys + cross-signing (Matrix, XMPP OMEMO), or
  none (Tox, historically Briar).
- **Metadata technique:** sealed sender, onion routing, no-identifier queues,
  gift-wrapping — distributed unevenly across systems.

*(End of comparison. No decision follows from this document. The next stage is
the Decision stage under `docs/13-decisions/`.)*
