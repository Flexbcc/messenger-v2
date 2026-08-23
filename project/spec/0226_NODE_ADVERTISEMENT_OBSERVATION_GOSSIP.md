# 0226 — NodeAdvertisement Observation Gossip

Status: implemented locally, deployment disabled by default.

## Purpose

A peer candidate must not become eligible because one Discovery returned an
unsigned row. A candidate is derived from three independently verifiable
objects:

1. `NodeAdvertisement`, signed by the subject Operational Key;
2. `CapabilityCertificate`, signed by the current validator quorum;
3. `AdvertisementObservation`, signed by a currently certified Discovery.
4. `TransportCertificate`, signed by the subject Node Root and independently
   revalidated by every observing Discovery.

Discovery distributes these objects; it does not create the subject identity,
endpoint or capability.

## Observation object

Protocol: `ouo-node-advertisement-observation/1`.

Signed fields:

- `observation_id` — canonical UUID;
- `source_node_id` — self-certifying NodeID of the Discovery source;
- `subject_node_id`;
- `advertisement_epoch`;
- `advertisement_hash` — SHA-256 of canonical JSON of the complete signed
  advertisement;
- `observed_at`, `expires_at`;
- protocol/object versions.

The operational signature uses the domain
`OUO/NODE_ADVERTISEMENT_OBSERVATION/v1`. Lifetime is at most ten minutes;
validation allows at most two minutes of clock skew.

## Source authorization

A valid signature proves only who made an observation. Before accepting it,
the receiver also requires:

- a valid source Node Identity and unexpired Operational Certificate;
- local `trusted` enrollment state;
- a current quorum-valid CapabilityCertificate containing `discovery`.

The source credential set is external input to the aggregator. A source cannot
self-assert that it is Discovery.

## Aggregation

The initial policy requires at least two distinct trusted Discovery sources for
the same `(subject_node_id, advertisement_epoch, advertisement_hash)`.

- only the highest observed advertisement epoch for a subject is emitted;
- differing hashes for the same subject and epoch are conflict evidence and
  exclude the subject fail closed;
- one source signing two different hashes for the same subject/epoch is
  equivocation evidence;
- only `wss://` or `https://` endpoints enter the peer selector;
- capabilities are the intersection of independently supplied, quorum-valid
  CapabilityCertificates;
- level and capability epoch use the conservative minimum;
- output is marked `validated=true`, includes `observed_by[]` and signed
  Advertisement, Operational Certificate and Capability Certificate deadlines
  used to bound downstream peer caches;
- selector view includes the signed Operational Certificate and conservative
  per-key minimum capability quotas; consumers locally validate the certificate
  before accepting its request-signing public key;
- privacy-transport output additionally requires an identical, currently valid
  Transport Certificate from the same minimum number of Discovery sources;
  certificate disagreement excludes the subject as a conflict.

Operator/ASN/subnet diversity is deliberately not inferred from a Discovery
claim. Deployment supplies `diversity_group`; absent data becomes `unknown` and
the existing selector degrades instead of bypassing its caps.

## Discovery API

- `GET /registry/node-advertisements/gossip` returns fresh locally signed
  observations of locally verified advertisements, with bounded pagination;
- `POST /registry/node-advertisements/gossip` validates and persists one item;
- `GET /registry/node-advertisements/observations` returns active stored
  evidence for audit/client aggregation;
- `GET /registry/node-advertisements/peer-view` returns selector-ready
  candidates, conflicts and validation counters.

Pull gossip is opt-in through `NODE_ADVERTISEMENT_GOSSIP_*`. Each response is
limited to 100 items, polling to ten pages, stored active observations to 500
per source and aggregate input to 1000.

## Persistence and replay

The persistent key is `(source_node_id, subject_node_id,
advertisement_epoch)`. A refreshed identical claim replaces its short-lived
observation. A different advertisement hash for that key is rejected as a
conflict. Expired observations do not contribute to a peer view.

## Residual risks

- two Discovery sources can be one operator; deployment diversity is still
  required;
- the initial two-source rule is a configurable availability/security tradeoff;
- gossip supplies peer candidates but does not yet activate Home/Relay runtime
  peer rotation;
- IP/ASN/operator attestations are not cryptographic independence proofs.
