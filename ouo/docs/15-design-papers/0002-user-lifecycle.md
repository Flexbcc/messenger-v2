# Design Paper: User Lifecycle

> **Status:** Draft
> **Last updated:** 2026-07-08
> **Document class:** Design Paper (scenario decomposition). **Not** an
> architecture, **not** an API, **not** an implementation, **not** a Decision,
> **not** an ADR, **not** a Specification.
> **Reviewer stance:** This document is authored in the *architectural reviewer*
> role. It proposes no architecture. It decomposes the user lifecycle into
> scenarios and surfaces the questions that must be answered before any
> specification can be written.
> **Prohibited here:** proposing solutions; drawing APIs; drawing network
> packets; describing JSON; describing cryptography; describing internal
> implementation.
> **Statement tags** (per
> [../00-overview/0008-documentation-standard.md](../00-overview/0008-documentation-standard.md)):
> every scenario field is an `OBSERVATION` describing the scenario; every
> question is a `QUESTION`. No `DECISION`, no `OPTION`-as-recommendation appears
> here. Where a scenario is constrained by an already-accepted principle, that
> principle is cross-referenced (P1–P7 in
> [../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md);
> node invariants in
> [../01-protocol/0100-node-taxonomy.md](../01-protocol/0100-node-taxonomy.md)).
> **Purpose note:** In this document the *quality of the questions matters more
> than any answer*. All architectural decisions of the project are expected to
> originate here.

## How to read a scenario

Each scenario contains, in order:

- **Summary** — what happens, in one or two sentences.
- **Preconditions** — the state of the world before the scenario.
- **Postconditions** — the state of the world after the scenario.
- **Entities involved** — which OUO entities participate (see Core Concepts).
- **Architectural concerns** — the tensions the scenario exposes (narrative).
- **Dependent specification documents** — which future specs this scenario will
  constrain.
- **Open Questions** — conceptual questions the scenario leaves open.
- **Architectural Questions** — the exhaustive checklist of questions that MUST
  be answered before this scenario can be specified.

---

## Scenario 0001 — First application launch

**Summary.** `OBSERVATION:` A person installs and opens OUO for the very first
time; they have no identity, no devices registered, and no network state.

**Preconditions.** `OBSERVATION:` No identity exists; no keys exist locally; the
device is not known to any node; the network is unknown to the client.

**Postconditions.** `OBSERVATION:` The user possesses a usable identity anchored
in cryptographic material, and at least one device is associated with it; the
client is in a state from which it can eventually reach the network.

**Entities involved.** `OBSERVATION:` User, Identity, Device, Device Identity
(and, conceptually, whatever the identity anchor turns out to be — unresolved in
[0001-identity-model.md](0001-identity-model.md)).

**Architectural concerns.** `OBSERVATION:` This scenario forces the identity
model question to the front: what is created on first launch, and what makes it
"the user". It also raises whether identity creation is purely local or requires
any network contact.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0401-registration.md](../04-client/0401-registration.md),
[../01-protocol/0101-user-identity.md](../01-protocol/0101-user-identity.md),
[../01-protocol/0102-device-identity.md](../01-protocol/0102-device-identity.md),
[../02-security/0205-identity-keys.md](../02-security/0205-identity-keys.md),
[../02-security/0204-device-keys.md](../02-security/0204-device-keys.md).

**Open Questions.** `QUESTION:` Is a user "created" locally, or "registered"
somewhere? Is there any concept of registration at all if servers own nothing
(P2/P5)?

**Architectural Questions.**
1. `QUESTION:` What exactly is generated at first launch (identity anchor,
   device key, both)?
2. `QUESTION:` Is first-launch identity creation fully offline, or does it
   require reaching any node?
3. `QUESTION:` Is there any human-facing identifier chosen at this point, or only
   cryptographic material?
4. `QUESTION:` Does the user need a recovery secret at creation, and must they be
   forced to record it before proceeding?
5. `QUESTION:` Can one installation hold multiple identities from the start?
6. `QUESTION:` What is the minimal state that must exist locally before the app
   is considered "set up"?
7. `QUESTION:` Is device identity derived from, or independent of, user identity
   at creation?

---

## Scenario 0002 — Subsequent application launch

**Summary.** `OBSERVATION:` A returning user opens OUO on a device that already
holds their identity and local state.

**Preconditions.** `OBSERVATION:` Identity and device material exist locally;
prior conversation/queue state may exist on the client (the client holds the
primary queue, per the accepted node model).

**Postconditions.** `OBSERVATION:` The user is "logged in" to their local
identity and their prior state is available; the client is ready to
reconnect.

**Entities involved.** `OBSERVATION:` User, Identity, Device, Device Identity,
Conversation, Message.

**Architectural concerns.** `OBSERVATION:` What "login" means when identity is
local and self-owned; how local state is protected at rest between launches.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0402-login.md](../04-client/0402-login.md),
[../01-protocol/0101-user-identity.md](../01-protocol/0101-user-identity.md).

**Open Questions.** `QUESTION:` Is "login" a local unlock, a network
re-association, or both?

**Architectural Questions.**
1. `QUESTION:` Is local identity protected by a local secret (passphrase/biometric),
   and is that mandatory or optional?
2. `QUESTION:` What happens if local state is corrupt or partially lost but the
   identity key survives?
3. `QUESTION:` Does relaunch require any network step, or is it purely local?
4. `QUESTION:` How is the boundary between "identity present" and "session ready"
   defined?

---

## Scenario 0003 — Connecting to the network

**Summary.** `OBSERVATION:` The client, holding an identity, joins the OUO
network for the first time or after being disconnected.

**Preconditions.** `OBSERVATION:` A local identity exists; the client has no
current route published and may not know any live nodes.

**Postconditions.** `OBSERVATION:` The client has located usable service nodes
and is reachable/able to send; a current route to the user may be published.

**Entities involved.** `OBSERVATION:` Bootstrap Node, Witness Node, Route, Route
Record, Delivery Node, Relay, Network, Identity.

**Architectural concerns.** `OBSERVATION:` This is the first scenario that hits
the unresolved bootstrap-discovery problem (how the client finds a Bootstrap
Node at all) and route publication (self-signed Route Records, TTL).

**Dependent specification documents.** `OBSERVATION:`
[../03-network/0301-bootstrap.md](../03-network/0301-bootstrap.md),
[../03-network/0302-discovery.md](../03-network/0302-discovery.md),
[../01-protocol/0103-routing.md](../01-protocol/0103-routing.md),
[../01-protocol/0104-route-record.md](../01-protocol/0104-route-record.md),
[../01-protocol/0105-witness-network.md](../01-protocol/0105-witness-network.md).

**Open Questions.** `QUESTION:` How does a client obtain its first Bootstrap Node
without a pre-existing authority?

**Architectural Questions.**
1. `QUESTION:` How is the initial Bootstrap Node discovered (shipped list, DNS,
   manual, peer)?
2. `QUESTION:` Is the node list returned by bootstrap authenticated, and against
   what?
3. `QUESTION:` When does a client publish a Route Record, and to how many Witness
   Nodes?
4. `QUESTION:` What is the Route Record TTL and refresh cadence?
5. `QUESTION:` What does "reachable" mean for a client behind NAT — is a relay
   always required?
6. `QUESTION:` What is the failure behavior if no bootstrap/witness is reachable?
7. `QUESTION:` How is a poisoned bootstrap or witness response detected/mitigated?

---

## Scenario 0004 — Adding the first contact

**Summary.** `OBSERVATION:` The user establishes their first relationship with
another user.

**Preconditions.** `OBSERVATION:` The user has an identity and is (or can be)
connected; no contacts exist.

**Postconditions.** `OBSERVATION:` A verifiable reference to another user exists
locally; the two parties can be addressed to each other.

**Entities involved.** `OBSERVATION:` User, Identity, Contact, Route/Route
Record (to locate the other party), Witness Node.

**Architectural concerns.** `OBSERVATION:` Whether contact exchange is part of
OUO or an application concern is itself unresolved
([../14-foundation/0001-system-model.md](../14-foundation/0001-system-model.md));
how one user is found/verified without a global registry.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0106-contact-exchange.md](../01-protocol/0106-contact-exchange.md),
[../04-client/0404-contact-management.md](../04-client/0404-contact-management.md),
[../03-network/0302-discovery.md](../03-network/0302-discovery.md).

**Open Questions.** `QUESTION:` Is contact exchange in-band, out-of-band, or
both? Is discovery by a human-readable name in scope?

**Architectural Questions.**
1. `QUESTION:` How is another user identified for the purpose of adding them
   (key, hash, name, link, QR)?
2. `QUESTION:` Is there any directory/discovery, or is contact exchange strictly
   out-of-band?
3. `QUESTION:` How is the authenticity of the contact verified (safety-number
   equivalent)?
4. `QUESTION:` Is mutual consent required before two users become contacts?
5. `QUESTION:` What metadata does adding a contact expose, and to whom?
6. `QUESTION:` Is a contact bound to a user identity or to a specific device?

---

## Scenario 0005 — Creating the first conversation

**Summary.** `OBSERVATION:` The user starts their first conversation with an
existing contact.

**Preconditions.** `OBSERVATION:` At least one contact exists; no conversation
exists yet.

**Postconditions.** `OBSERVATION:` A conversation object exists locally for both
parties, ready to carry messages.

**Entities involved.** `OBSERVATION:` User, Contact, Conversation, Session,
Identity/Device Identity.

**Architectural concerns.** `OBSERVATION:` Whether a conversation exists before
the first message is sent; how conversation identity relates to participants;
where session establishment sits relative to conversation creation.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0405-message-flow.md](../04-client/0405-message-flow.md),
[../02-security/0203-x3dh.md](../02-security/0203-x3dh.md),
[../02-security/0202-double-ratchet.md](../02-security/0202-double-ratchet.md).

**Open Questions.** `QUESTION:` Is a conversation created explicitly, or does it
come into being implicitly with the first message?

**Architectural Questions.**
1. `QUESTION:` Does a conversation have an identifier, and is it derived from
   participants or assigned?
2. `QUESTION:` Is a session established at conversation creation or deferred to
   first send?
3. `QUESTION:` Must both parties be online to create a conversation, or can it be
   created unilaterally?
4. `QUESTION:` How does conversation creation interact with multi-device (does
   every device of each party learn of it)?

---

## Scenario 0006 — Sending the first message

**Summary.** `OBSERVATION:` The user sends their first message in a conversation.

**Preconditions.** `OBSERVATION:` A conversation (or the intent to create one)
exists; the recipient may be online or offline.

**Postconditions.** `OBSERVATION:` The message has left the sender's device and
entered the delivery path; the sender holds it in the primary (client) queue
until delivery is confirmed.

**Entities involved.** `OBSERVATION:` Message, Envelope, Packet, Conversation,
Route, Delivery Node, Relay, Storage, Witness Node.

**Architectural concerns.** `OBSERVATION:` The client-held primary queue vs
temporary server buffer boundary; how the sender finds the recipient's current
route; what a "sent" vs "delivered" state means.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0107-message-delivery.md](../01-protocol/0107-message-delivery.md),
[../01-protocol/0108-delivery-network.md](../01-protocol/0108-delivery-network.md),
[../01-protocol/0120-packet-format.md](../01-protocol/0120-packet-format.md),
[../04-client/0405-message-flow.md](../04-client/0405-message-flow.md).

**Open Questions.** `QUESTION:` What are the message states and who is
authoritative for each, given no server is a source of truth?

**Architectural Questions.**
1. `QUESTION:` How does the sender resolve the recipient's current route at send
   time?
2. `QUESTION:` What message states exist (queued, sent, stored, delivered, read)
   and how are transitions authenticated?
3. `QUESTION:` What happens when the recipient's route is stale or absent?
4. `QUESTION:` How long does the client retain a message in its primary queue?
5. `QUESTION:` Are delivery receipts required, and are they end-to-end?
6. `QUESTION:` What ordering guarantees (if any) apply to messages?

---

## Scenario 0007 — Receiving the first message

**Summary.** `OBSERVATION:` The user receives their first inbound message.

**Preconditions.** `OBSERVATION:` The user has a published route (or is otherwise
reachable); an inbound message is waiting or arriving.

**Postconditions.** `OBSERVATION:` The message is present and readable on at
least one of the user's devices; delivery is acknowledged as required.

**Entities involved.** `OBSERVATION:` Message, Envelope, Delivery Node, Storage,
Conversation, Device, Multi-device (all of the user's devices).

**Architectural concerns.** `OBSERVATION:` Fan-out to multiple devices; how a
buffered message is retrieved; when temporary storage may delete the message.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0107-message-delivery.md](../01-protocol/0107-message-delivery.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md),
[../04-client/0405-message-flow.md](../04-client/0405-message-flow.md).

**Open Questions.** `QUESTION:` When multiple devices exist, which device
acknowledges delivery and when may storage delete the message?

**Architectural Questions.**
1. `QUESTION:` How is an inbound message delivered to *all* of a user's devices?
2. `QUESTION:` When may a Storage Node delete a buffered message — on first
   device receipt, or on all-device receipt?
3. `QUESTION:` How does a device that was offline retrieve messages it missed?
4. `QUESTION:` How is duplicate delivery across devices reconciled?
5. `QUESTION:` What proves to the sender that delivery occurred without trusting a
   node?

---

## Scenario 0008 — Working offline

**Summary.** `OBSERVATION:` The user operates with no network connectivity.

**Preconditions.** `OBSERVATION:` Identity and local state exist; no network is
reachable.

**Postconditions.** `OBSERVATION:` Actions taken offline (composing, queueing)
are retained locally for later synchronization; nothing is lost.

**Entities involved.** `OBSERVATION:` Client, Message, Conversation, Local Node
(possibly), primary queue.

**Architectural concerns.** `OBSERVATION:` What is possible fully offline; the
role of a Local Node for LAN/offline exchange; local durability guarantees.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0409-offline-mode.md](../04-client/0409-offline-mode.md),
[../01-protocol/0113-local-node.md](../01-protocol/0113-local-node.md),
[../01-protocol/0122-failure-recovery.md](../01-protocol/0122-failure-recovery.md).

**Open Questions.** `QUESTION:` What subset of functionality is defined to work
with no internet (and does LAN-only exchange count as "offline")?

**Architectural Questions.**
1. `QUESTION:` What actions are permitted offline (compose, read, add contact via
   QR, LAN exchange)?
2. `QUESTION:` How long may messages sit in the local queue, and is there a cap?
3. `QUESTION:` Does LAN/offline exchange via a Local Node require prior online
   setup?
4. `QUESTION:` How is local state protected against loss/corruption while
   offline?
5. `QUESTION:` What happens to time-sensitive state (TTL of routes) accrued while
   offline?

---

## Scenario 0009 — Returning to the network

**Summary.** `OBSERVATION:` After being offline, the user reconnects.

**Preconditions.** `OBSERVATION:` The client has queued outbound actions and/or
missed inbound messages; its previously published route may have expired.

**Postconditions.** `OBSERVATION:` Queued outbound messages are delivered, missed
inbound messages are retrieved, and a fresh route is published as needed.

**Entities involved.** `OBSERVATION:` Witness Node, Route Record, Delivery Node,
Storage, Message, Multi-device.

**Architectural concerns.** `OBSERVATION:` Reconciliation and ordering after a
gap; re-publishing an expired route; deduplication with other devices that were
online.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0122-failure-recovery.md](../01-protocol/0122-failure-recovery.md),
[../01-protocol/0121-routing-rotation.md](../01-protocol/0121-routing-rotation.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md).

**Open Questions.** `QUESTION:` How is consistency restored when different
devices saw different subsets of messages during the gap?

**Architectural Questions.**
1. `QUESTION:` How does a client discover what it missed while offline?
2. `QUESTION:` How is message ordering reconstructed across a connectivity gap?
3. `QUESTION:` How is a stale/expired route detected and re-published?
4. `QUESTION:` How are duplicates suppressed when messages were also delivered to
   another device?
5. `QUESTION:` What is the recovery behavior if buffered messages already expired
   in Storage?

---

## Scenario 0010 — Adding a second device

**Summary.** `OBSERVATION:` The user links an additional device to the same
identity.

**Preconditions.** `OBSERVATION:` One device holds the identity; a second device
has no identity yet.

**Postconditions.** `OBSERVATION:` Both devices act under the same user identity;
each may hold its own device identity; both can send/receive.

**Entities involved.** `OBSERVATION:` User, Identity, Device, Device Identity,
Multi-device, Home Node (optionally, for sync).

**Architectural concerns.** `OBSERVATION:` The unresolved user↔device identity
relationship (from the identity design paper); trust bootstrapping for a new
device; whether history is synced to the new device.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0403-device-linking.md](../04-client/0403-device-linking.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md),
[../02-security/0204-device-keys.md](../02-security/0204-device-keys.md),
[../01-protocol/0118-backup.md](../01-protocol/0118-backup.md).

**Open Questions.** `QUESTION:` Is the user identity a single root that attests
device keys, or something else — and how does a new device get authorized?

**Architectural Questions.**
1. `QUESTION:` How is a new device authorized (existing device present? recovery
   secret? both)?
2. `QUESTION:` Does the new device receive prior history, and from where (peer
   device, Home Node, backup)?
3. `QUESTION:` How do contacts learn that the user has a new device to deliver
   to?
4. `QUESTION:` What is the trust relationship between the user's own devices?
5. `QUESTION:` Can a device be linked without any online device present?
6. `QUESTION:` How is the new device reflected in route publication and delivery
   fan-out?

---

## Scenario 0011 — Replacing the phone

**Summary.** `OBSERVATION:` The user migrates from an old primary device to a new
one they still control.

**Preconditions.** `OBSERVATION:` The old device is available and holds the
identity; a new device is to take over.

**Postconditions.** `OBSERVATION:` The identity continues uninterrupted on the
new device; the old device may be retired.

**Entities involved.** `OBSERVATION:` User, Identity, Device, Device Identity,
Multi-device, Backup, Home Node (optionally).

**Architectural concerns.** `OBSERVATION:` Continuity of identity across a device
change (P1 requires the identity to survive); transfer vs re-derivation of
identity; history migration.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0403-device-linking.md](../04-client/0403-device-linking.md),
[../01-protocol/0118-backup.md](../01-protocol/0118-backup.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md).

**Open Questions.** `QUESTION:` Is "replace phone" the same as "add device then
remove device", or a distinct migration flow?

**Architectural Questions.**
1. `QUESTION:` Is the user identity transferred to the new device, or is the new
   device a fresh device identity under the same user root?
2. `QUESTION:` How is history moved (direct transfer, backup restore, Home Node
   sync)?
3. `QUESTION:` Is the old device's device identity revoked, and how do contacts
   learn this?
4. `QUESTION:` What happens if the old and new devices are never online at the
   same time?
5. `QUESTION:` Does replacement change anything visible to contacts (identity
   stability vs device change)?

---

## Scenario 0012 — Losing a device

**Summary.** `OBSERVATION:` A device is lost or stolen and is no longer under the
user's control.

**Preconditions.** `OBSERVATION:` The lost device held a device identity and
possibly local message state; the user may or may not have another device.

**Postconditions.** `OBSERVATION:` The lost device is (ideally) prevented from
continuing to act as the user; the user retains their identity via other means.

**Entities involved.** `OBSERVATION:` User, Identity, Device Identity,
Multi-device, Witness Node (route), post-compromise concerns.

**Architectural concerns.** `OBSERVATION:` Revocation without a central
authority; post-compromise security; what an attacker with the device can do;
recovery if the lost device was the only device.

**Dependent specification documents.** `OBSERVATION:`
[../02-security/0207-post-compromise-security.md](../02-security/0207-post-compromise-security.md),
[../02-security/0204-device-keys.md](../02-security/0204-device-keys.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md),
[../01-protocol/0122-failure-recovery.md](../01-protocol/0122-failure-recovery.md).

**Open Questions.** `QUESTION:` How is a device revoked when no node is a source
of truth for identity, and how do contacts learn to stop trusting it?

**Architectural Questions.**
1. `QUESTION:` How is a lost device's device identity revoked, and by whom?
2. `QUESTION:` How is revocation propagated to contacts and to nodes?
3. `QUESTION:` What can an attacker holding the device read or send before/after
   revocation?
4. `QUESTION:` If the lost device was the *only* device, is recovery possible at
   all, and how?
5. `QUESTION:` Does losing a device ever force a change of the user identity
   itself?
6. `QUESTION:` How does local-at-rest protection (Scenario 0002) bound the damage?

---

## Scenario 0013 — Removing a device

**Summary.** `OBSERVATION:` The user deliberately de-authorizes a device they
still control (or control remotely).

**Preconditions.** `OBSERVATION:` The device is currently authorized under the
user identity; at least one other device or recovery path exists.

**Postconditions.** `OBSERVATION:` The removed device can no longer act as the
user; other devices are unaffected.

**Entities involved.** `OBSERVATION:` User, Identity, Device Identity,
Multi-device, Witness Node/route, Delivery fan-out.

**Architectural concerns.** `OBSERVATION:` Difference between voluntary removal
(Scenario 0013) and loss (Scenario 0012); clean revocation; effect on delivery
fan-out and route publication.

**Dependent specification documents.** `OBSERVATION:`
[../04-client/0403-device-linking.md](../04-client/0403-device-linking.md),
[../01-protocol/0119-multi-device.md](../01-protocol/0119-multi-device.md),
[../02-security/0204-device-keys.md](../02-security/0204-device-keys.md).

**Open Questions.** `QUESTION:` Is device removal authoritative from any single
device, and how is a conflicting "un-removal" prevented?

**Architectural Questions.**
1. `QUESTION:` Which device(s) are authorized to remove another device?
2. `QUESTION:` How is removal propagated and made non-reversible by the removed
   device?
3. `QUESTION:` How does removal change delivery fan-out and route publication?
4. `QUESTION:` What happens to messages already buffered for the removed device?
5. `QUESTION:` How is removal distinguished from loss at the protocol level, if at
   all?

---

## Scenario 0014 — Creating your own node

**Summary.** `OBSERVATION:` The user stands up their own node (as an optional
mode) to serve themselves.

**Preconditions.** `OBSERVATION:` The user has an identity; they now operate
infrastructure (a Private/Home/Local node per the taxonomy).

**Postconditions.** `OBSERVATION:` The user's client can use their own node for
some roles; the user is not *required* to (running a node is optional per the
node invariants).

**Entities involved.** `OBSERVATION:` User, Home Node, Private Node, Local Node,
Relay/Delivery/Storage/Witness/Media roles, Network.

**Architectural concerns.** `OBSERVATION:` How a client is configured to prefer
its own node; how the node reaches the wider network (uplink); trust placed in a
self-owned node vs the invariant that no node owns identity.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0110-home-node.md](../01-protocol/0110-home-node.md),
[../01-protocol/0115-private-node.md](../01-protocol/0115-private-node.md),
[../01-protocol/0113-local-node.md](../01-protocol/0113-local-node.md),
[../05-server/0500-overview.md](../05-server/0500-overview.md).

**Open Questions.** `QUESTION:` What does a client gain by running its own node,
and how does it interoperate with public infrastructure?

**Architectural Questions.**
1. `QUESTION:` How does a client discover/trust/configure its own node?
2. `QUESTION:` Which roles can a self-owned node play, and how is that advertised?
3. `QUESTION:` How does a private/self node reach the public network (uplink,
   relay)?
4. `QUESTION:` Does using one's own node change any privacy/metadata properties?
5. `QUESTION:` What happens to the user when their own node is down (degradation
   path)?

---

## Scenario 0015 — Connecting to a corporate node

**Summary.** `OBSERVATION:` The user joins infrastructure operated by an
organization.

**Preconditions.** `OBSERVATION:` The user has an identity; an organization
operates a Corporate Node that they are to use.

**Postconditions.** `OBSERVATION:` The user's client uses the corporate node for
some roles, without the corporate node breaking E2EE (per the taxonomy
constraint).

**Entities involved.** `OBSERVATION:` User, Identity, Corporate Node (managed
variant of Home/Local/Public/Private), Group/organization membership.

**Architectural concerns.** `OBSERVATION:` What controls an organization may
apply without violating E2EE; whether identity remains user-owned when using
corporate infrastructure; onboarding/offboarding of organizational users.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0110-home-node.md](../01-protocol/0110-home-node.md),
[../05-server/0500-overview.md](../05-server/0500-overview.md),
[../02-security/0210-metadata-protection.md](../02-security/0210-metadata-protection.md).

**Open Questions.** `QUESTION:` Where is the exact line between organizational
policy/management and E2EE-preserving guarantees?

**Architectural Questions.**
1. `QUESTION:` How does a user attach to a corporate node, and can they use it and
   public nodes simultaneously?
2. `QUESTION:` What may a corporate operator control (routing, retention,
   membership) without reading content?
3. `QUESTION:` Does the user's identity remain user-owned and portable off the
   corporate node?
4. `QUESTION:` What happens on offboarding — what does the organization retain or
   lose access to?
5. `QUESTION:` What metadata does the corporate node necessarily observe?

---

## Scenario 0016 — Full identity deletion

**Summary.** `OBSERVATION:` The user permanently destroys their identity and
associated state.

**Preconditions.** `OBSERVATION:` An identity exists across one or more devices
and possibly nodes; the user wishes it gone.

**Postconditions.** `OBSERVATION:` The identity is no longer usable; local state
is destroyed; residual state on infrastructure eventually disappears (bounded by
TTLs), acknowledging that servers hold nothing permanently.

**Entities involved.** `OBSERVATION:` User, Identity, Device Identity, Route
Record, Storage/Media Storage (temporary residue), Contacts (of others).

**Architectural concerns.** `OBSERVATION:` What "deletion" can even mean in a
system with no central owner; what the user can and cannot delete (their own
state vs copies held by contacts); tombstoning so others learn the identity is
gone.

**Dependent specification documents.** `OBSERVATION:`
[../01-protocol/0122-failure-recovery.md](../01-protocol/0122-failure-recovery.md),
[../02-security/0210-metadata-protection.md](../02-security/0210-metadata-protection.md),
[../01-protocol/0104-route-record.md](../01-protocol/0104-route-record.md).

**Open Questions.** `QUESTION:` Since messages belong to participants (P2), what
does deletion guarantee about copies already held by others?

**Architectural Questions.**
1. `QUESTION:` What exactly is deleted (local state, published routes, buffered
   messages) and what is beyond the user's reach?
2. `QUESTION:` Is there a "tombstone" so contacts and nodes learn the identity is
   retired?
3. `QUESTION:` How is deletion authorized, and can it be done from one device for
   all?
4. `QUESTION:` What residual metadata may persist, and for how long (TTL bounds)?
5. `QUESTION:` Can an identifier be re-registered by someone else after deletion,
   and is that a risk?
6. `QUESTION:` Is deletion distinguishable from going permanently offline, from a
   contact's perspective?

---

## Cross-scenario architectural questions

`QUESTION:` These questions recur across scenarios and must be resolved
consistently, not per-scenario:

1. `QUESTION:` The user↔device identity relationship (single root vs multi-device
   root) underlies Scenarios 0001, 0010, 0011, 0012, 0013 — it must be answered
   once, coherently. See [0001-identity-model.md](0001-identity-model.md).
2. `QUESTION:` Revocation and post-compromise handling recur in 0011, 0012, 0013,
   0016.
3. `QUESTION:` Multi-device delivery fan-out and deduplication recur in 0006,
   0007, 0009, 0010, 0013.
4. `QUESTION:` Route publication/refresh/TTL recurs in 0003, 0006, 0009, 0016.
5. `QUESTION:` Recovery (with and without a surviving device) recurs in 0011,
   0012, 0016.
6. `QUESTION:` The scope boundary "is X part of OUO or the application?" recurs
   for contacts (0004), discovery (0004), and offline UX (0008).

*(End of Design Paper. No decisions, no recommendations, no RFC, no ADR. Only
scenarios and questions.)*
