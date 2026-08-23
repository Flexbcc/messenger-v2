# 0227 — Home Signed Peer Runtime

Status: implemented locally as opt-in; production activation pending deployment
credentials and diversity data.

## Goal

The legacy Home path asks one Discovery for a server-generated node list. That
path remains for migration, but it is not sufficient for the target trust
model. Signed peer runtime makes Home verify D1/D2/D3 evidence locally before a
Relay can enter fallback routing.

## Bootstrap inputs

Home requires:

- current Capability Authority state;
- a Discovery source-set document containing, for each allowed source, its
  root-signed Operational Certificate and quorum-signed `discovery`
  CapabilityCertificate;
- at least two Discovery origins;
- a private local selection seed path and persistent peer-state path.

The source-set protocol is `ouo-discovery-source-set/1` and is bound to an exact
authority epoch. Node Identity, Operational Certificate lifetime, validator
quorum and the `discovery` capability are revalidated locally. Merely listing a
NodeID in configuration is not sufficient.

## Refresh flow

1. Fetch bounded, paginated raw observations from configured D1/D2/D3 origins.
2. Validate the subject NodeAdvertisement and quorum CapabilityCertificate.
3. Validate every Discovery observation against the certified source set.
4. Require two distinct sources and reject subject/epoch conflicts.
5. Require the same independently observed Transport Certificate and validate
   it locally; a certificate split view removes the subject.
6. Run locally seeded guard/rotating/reserve selection and derive verified
   Storage/Media/TURN/Gateway sets from the same view.
7. Atomically persist the selected Relay state with a validity window bounded
   by five minutes and the earliest Advertisement, Observation, Operational,
   Capability or Transport expiry.

One unavailable Discovery does not abort collection from the others. Source
identity is deduplicated cryptographically, so replaying one source through
several origins does not satisfy the two-source rule.

## Local seed and state

The selection seed is 32 CSPRNG bytes, created with owner-only permissions. It
never comes from Discovery and is not logged. The same seed and epoch produce a
stable local ranking, so different Home nodes need not expose identical peer
sets.

State contains only selected NodeIDs/endpoints/diversity groups and is written
atomically with owner-only permissions. Guards survive partial rotations while
they remain eligible. Expired or malformed state is not loaded. Тот же
`valid_until` проверяется при каждом чтении in-memory active/reserve set: ошибка
refresh не продлевает старое состояние, и после пяти минут runtime возвращает
пустой signed set в enforce mode.

Active guards/rotating peers are tried first. Reserve peers are probed only when
all active signed peers fail, so a reserve does not silently become an active
connection merely because it has lower latency.

## Modes

- `off`: legacy behavior only; current default.
- `report`: prefer a valid signed set, fall back to the migration catalog when
  no signed set exists.
- `enforce`: never fall back to the unsigned catalog for Relay, Storage or
  Media selection;
  startup requires at least two Discovery origins.

The secure environment validator additionally requires authority/source-set
paths when `enforce` is selected.

## Residual risks

- authority/source-set rotation is file-driven and not yet automatically
  applied from AuthorityCheckpoint gossip on Home;
- deployment must provide real operator/ASN/subnet diversity groups; `unknown`
  intentionally causes a degraded selection;
- the cached state is a bounded availability bridge and может удерживать peer
  только до самого раннего подписанного expiry, но не бессрочно после отказа
  Discovery;
- the local loopback cluster keeps this feature off until real D1/D2/D3 source
  certificates are provisioned.
