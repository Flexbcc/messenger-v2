# Design Paper: Identity Model

> **Status:** Draft
> **Last updated:** 2026-07-08
> **Document class:** Design Paper. Explores a single problem in depth. **Not**
> Research, **not** Comparison, **not** Foundation, **not** a Decision, **not**
> an ADR, **not** a Specification.
> **Purpose:** To fully investigate the problem of user identity — *not* to
> propose a solution.
> **Prohibited here:** making decisions, proposing an OUO architecture, choosing
> a best option.
> **Statement tags** (per
> [../00-overview/0008-documentation-standard.md](../00-overview/0008-documentation-standard.md)):
> `FACT`, `OBSERVATION`, `QUESTION`, `TODO`. This paper introduces no `DECISION`
> and no `OPTION`-as-recommendation.
> **Related:** entities in
> [../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md);
> system model in
> [../14-foundation/0001-system-model.md](../14-foundation/0001-system-model.md);
> existing-system facts in
> [../11-research/01-existing-systems/0001-distributed-messaging.md](../11-research/01-existing-systems/0001-distributed-messaging.md).
> Facts about external systems are summarized here and detailed (with
> `TODO / verify` markers) in the research document; this paper does not
> duplicate them.

---

## 1. Conceptual questions

This section frames the problem. It answers nothing definitively; each framing
is an `OBSERVATION` of the problem space or a `QUESTION` for the author.

### What is a user?

`OBSERVATION:` Across systems, "user" is a *logical* participant — the party on
whose behalf communication happens — as opposed to any concrete endpoint. A user
may act through several devices and over time.

`QUESTION:` Is a "user" a single logical actor, or can one human hold several
independent identities that the model treats as unrelated users?

### What is an identity?

`OBSERVATION:` "Identity" is the thing that lets others recognize and
authenticate a user. In cryptographic systems it is anchored in key material; in
account systems it is anchored in a provider record. The identity is the
*answer to "who is this?"* that others can verify.

`QUESTION:` Is identity fundamentally *what you can prove with a key*, or *what a
naming/registry system asserts about you*? Different models answer differently.

### How does a user differ from a device?

`OBSERVATION:` A device is a concrete endpoint (phone, laptop) through which a
user acts; a user is the logical self behind possibly many devices. OUO already
separates these as distinct entities: `User`/`Identity` versus
`Device`/`Device Identity`
([../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md)).

`QUESTION:` Is the user identity a *separate* key from every device key (a root
that attests devices), or is one device's key the user identity (with others
subordinate)?

### What is permanent?

`OBSERVATION:` Candidates for "the permanent thing" seen in the wild: a key pair
(Nostr, Tox, Session), a provider account (Matrix, XMPP), a phone number
(Signal), or nothing global at all (SimpleX). The accepted OUO foundation states
that the user's cryptographic identity is the only permanent entity
(`DECISION` P1, cross-referenced, not decided here).

`QUESTION:` If the permanent anchor is a key, what happens when that key must
change? If it is *not* the raw key, what is it?

### What can change?

`OBSERVATION:` Commonly changeable: the set of devices, display name/handle,
routes, session keys, and — in some models — the underlying signing keys.

`QUESTION:` Which of these must be changeable *without* changing the user's
identity, and which are allowed to break it?

---

## 2. How existing systems anchor identity (summary)

`OBSERVATION:` Summarized from the research document (see cross-reference above):

- Key-derived identity: Session (Session ID from pubkey), Tox (Tox ID), Nostr
  (pubkey), Tor onion services (address encodes key).
- Provider-account identity: Matrix (`@user:homeserver`), XMPP (`user@domain`).
- Phone-number-anchored account: Signal.
- No global identity: SimpleX (per-contact connections only).

`OBSERVATION:` These map onto the abstract models catalogued next, which is the
core of this paper.

---

## 3. Identity models

Each model below is described with: Description, Advantages, Disadvantages,
Example usage, Systems that use it, Problems that arise. All advantages and
disadvantages are `OBSERVATION`s of trade-offs, not scores.

### 3.1 Identity = Account

**Description.** `OBSERVATION:` Identity is a record held by a provider (a
username/handle plus credentials). Authority is rooted in the provider; the
account is the source of truth for "who this is".

**Advantages.** `OBSERVATION:` Familiar UX; human-readable handles; built-in
recovery (password/PIN reset); easy discovery; supports moderation and
revocation by the provider.

**Disadvantages.** `OBSERVATION:` The provider is an authority and single source
of truth; centralization; the account can be seized, censored, or lost with the
provider; portability between providers is hard.

**Example usage.** `OBSERVATION:` Traditional web/app accounts, email-anchored
sign-in.

**Systems.** `FACT:` XMPP (JID on a server), Matrix (`@user:homeserver`), Signal
(phone-number account on Signal's servers).

**Problems that arise.** `OBSERVATION:` Directly conflicts with the accepted OUO
principle that no node owns the user and that servers are not a source of truth
(P2/P5); identity dies with the provider; provider lock-in.

### 3.2 Identity = Public Key

**Description.** `OBSERVATION:` The identity *is* the public key of a long-term
key pair. "You are your key"; the identifier is self-authenticating.

**Advantages.** `OBSERVATION:` Self-sovereign, no provider; self-authenticating
(the identifier verifies signatures directly); portable; no naming authority
required.

**Disadvantages.** `OBSERVATION:` Not human-readable; no built-in recovery
(losing the key loses the identity); rotating the key changes the identity; long
identifiers; no external revocation authority.

**Example usage.** `OBSERVATION:` Key-as-identity messaging and social protocols.

**Systems.** `FACT:` Nostr (pubkey), Tox (Tox ID = pubkey), Session (Session ID
derived from pubkey), Tor v3 (address encodes the key).

**Problems that arise.** `OBSERVATION:` Key rotation and recovery; phishing via
lookalike keys; lack of human-friendly naming; long-term cryptographic agility
(e.g. post-quantum migration).

### 3.3 Identity = Hash(Public Key)

**Description.** `OBSERVATION:` The identifier is a hash/fingerprint of the
public key (shorter, fixed length); the full key is revealed and verified on
connection.

**Advantages.** `OBSERVATION:` Shorter identifiers; still self-authenticating
(the presented key must hash to the identifier); some algorithm agility (the
hash hides the key type); the key is not exposed until needed.

**Disadvantages.** `OBSERVATION:` Still not human-readable; recovery/rotation
unchanged from the raw-key model; the actual key must be fetched/verified out of
band; truncation trades length against collision resistance; a signature cannot
be verified from the identifier alone.

**Example usage.** `OBSERVATION:` Address-as-key-hash schemes.

**Systems.** `FACT:` Bitcoin addresses (hash of pubkey), PGP fingerprints,
libp2p/IPFS PeerID (multihash of pubkey), Tor v2 (hash of key; deprecated).

**Problems that arise.** `OBSERVATION:` Extra indirection to obtain the key
before verification; truncation-length trade-offs; rotation/recovery still
unsolved.

### 3.4 Identity = Random UUID

**Description.** `OBSERVATION:` The identity is a random opaque identifier with
no cryptographic relationship to any key; keys are bound to the UUID separately.

**Advantages.** `OBSERVATION:` Cheap and uniform; decoupled from keys (keys can
rotate without changing the identifier); the key is never embedded in the
identifier.

**Disadvantages.** `OBSERVATION:` Not self-authenticating — a separate authority
or registry must bind identifier↔key; open to squatting; requires trust in the
binding; no inherent verification from the identifier.

**Example usage.** `OBSERVATION:` Internal/system identifiers; opaque handles
bound to accounts.

**Systems.** `FACT:` Widely used as internal identifiers. `OBSERVATION:` Rarely
used *alone* as a public, verifiable identity anchor; e.g. SimpleX uses random
queue identifiers but deliberately has no user identity at all.

**Problems that arise.** `OBSERVATION:` The identifier↔key binding reintroduces
a source of truth (registry/authority), which is in tension with a
decentralized model unless the binding is itself signed.

### 3.5 Identity = Certificate

**Description.** `OBSERVATION:` Identity is a signed certificate binding a
name/attributes to a public key, issued by a certificate authority or
self-signed, with a chain of trust.

**Advantages.** `OBSERVATION:` Binds a human-readable name (and attributes) to a
key; supports revocation (CRL/OCSP), expiry, delegation, and reissue for
rotation.

**Disadvantages.** `OBSERVATION:` Requires a PKI/CA authority; operational
complexity; revocation distribution infrastructure; CA compromise is a systemic
risk; certificate expiry management.

**Example usage.** `OBSERVATION:` TLS/X.509, S/MIME, client certificates,
enterprise systems.

**Systems.** `FACT:` The TLS/X.509 ecosystem, S/MIME. `OBSERVATION:` Some
enterprise and federated systems; verifiable credentials in SSI are
conceptually adjacent.

**Problems that arise.** `OBSERVATION:` "Who is the CA?" in a decentralized
setting; centralization vs web-of-trust; revocation availability and freshness.

### 3.6 Identity = DID (Decentralized Identity)

**Description.** `OBSERVATION:` A W3C Decentralized Identifier — a URI of the
form `did:method:id` that resolves to a DID Document containing public keys,
verification methods, and service endpoints. The "method" determines how it
resolves (self-contained, DNS-based, ledger-anchored, etc.). Supports key
rotation and multiple keys while keeping a stable identifier.

**Advantages.** `OBSERVATION:` Standardized; decouples a stable identifier from
rotating keys; supports multiple keys and service endpoints; integrates with
verifiable credentials; method flexibility (from self-contained `did:key` to
ledger-anchored methods).

**Disadvantages.** `OBSERVATION:` Complexity; resolution depends on
method-specific infrastructure (ledger, registry, or DNS); some methods
reintroduce centralization or cost; interop/maturity concerns; verbose
identifiers.

**Example usage.** `OBSERVATION:` Self-sovereign identity, decentralized social.

**Systems.** `FACT:` `did:key`, `did:web`, `did:ion` (Sidetree over Bitcoin),
Sovrin; `OBSERVATION:` Bluesky/ATProto uses DIDs (`did:plc`, `did:web`) as
account identifiers. `TODO / verify` current method landscape details.

**Problems that arise.** `OBSERVATION:` Trust and availability of resolution;
method fragmentation; anchoring cost/latency; recovery of a lost controlling
key remains hard.

### 3.7 Identity = Multi-device Identity

**Description.** `OBSERVATION:` A user identity that spans multiple devices, each
holding its own device key, all bound under a user-level identity (for example a
user root key that attests device keys, or mutual cross-signing among a user's
devices). Explicitly distinguishes user from device.

**Advantages.** `OBSERVATION:` Matches reality (people use many devices); device
compromise is contained; devices can be revoked; no single device is
authoritative over the user; aligns with OUO's existing `User`/`Device`
separation.

**Disadvantages.** `OBSERVATION:` Complexity of attestation/cross-signing;
synchronizing trust state across devices; revocation propagation latency;
recovery when all devices are lost; trust bootstrapping when a new device joins;
group-messaging key management (e.g. sender-key/ratchet schemes) becomes more
involved.

**Example usage.** `OBSERVATION:` Modern E2EE messengers with linked devices.

**Systems.** `FACT:` Signal (Sesame + linked devices), Matrix (cross-signing +
per-device keys), XMPP OMEMO (per-device keys).

**Problems that arise.** `OBSERVATION:` Initial device-linking trust; recovery;
revocation latency; key transparency/consistency across a user's devices.

`OBSERVATION:` This model is not mutually exclusive with the others: a
multi-device identity still needs an anchor for the user root (which could be a
public key, a hash, a certificate, or a DID), so it composes with §3.1–§3.6
rather than replacing them.

---

## 4. Cross-cutting tensions (observations only)

`OBSERVATION:` Recurring tensions visible across the models, stated without
resolution:

- **Human-readable vs self-authenticating.** Names need an authority; keys are
  self-authenticating but unreadable.
- **Stable identifier vs rotating keys.** Raw-key identity breaks on rotation;
  UUID/DID/certificate decouple the two at the cost of a binding mechanism.
- **Recovery vs sovereignty.** Provider accounts recover easily but concede
  authority; self-sovereign keys keep authority but make recovery hard.
- **Revocation.** Authority-based models revoke cleanly; keyless-authority models
  must invent revocation (rotation, tombstones, transparency logs).
- **Decentralization vs binding trust.** Any human-readable or UUID binding
  reintroduces a party that asserts the binding.

---

## Open Questions

`QUESTION:` The following must be answered by the project's author before an
identity architecture decision can be made. This paper deliberately leaves them
open.

1. Must an OUO identity be **human-readable**, or is a cryptographic identifier
   acceptable (with naming layered separately)?
2. Is **account recovery** (recovering identity after losing key material) a
   hard requirement, a best-effort feature, or explicitly out of scope?
3. Must a user's identity **survive key rotation** unchanged, or is changing the
   key allowed to change the identity?
4. Is a **stable identifier decoupled from keys** required (implying a binding
   mechanism), or is "identifier = key/hash" acceptable?
5. Is the user root a **single key**, or is the user identity fundamentally a
   **multi-device** construct from the start (root attesting device keys)?
6. What **revocation** model is required (device revocation, identity
   revocation, compromise handling), and who distributes revocations given no
   node is a source of truth?
7. How does a **new device join** an existing identity, and what trust is
   required to authorize it?
8. What is the required relationship between the existing entities `Identity`
   and `Device Identity`
   ([../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md))?
9. Is any **naming/discovery** binding (e.g. DNS-to-key like NIP-05, or a
   directory) in scope for identity, or strictly an application concern
   (open in the system model boundary,
   [../14-foundation/0001-system-model.md](../14-foundation/0001-system-model.md))?
10. Are **cryptographic-agility / post-quantum** migration requirements in scope
    for the identity anchor now, or deferred?
11. May a single human hold **multiple unlinkable identities**, and must the
    model support that explicitly?
12. What **metadata/privacy** properties must the identifier itself have (e.g.
    must it avoid being a stable cross-service tracking handle)?

*(End of Design Paper. No conclusions, no recommendations, no RFC, no Decision.)*
