# Design Roadmap

> **Status:** Open
> **Last updated:** 2026-07-08
> **Document class:** Architecture review — **design** roadmap (not a development
> roadmap). It orders the *open questions* that must be resolved before OUO can
> be considered a complete protocol. It schedules no code and makes no
> decisions.
> **Source:** [0001-global-open-questions.md](0001-global-open-questions.md).

## How to read this roadmap

`OBSERVATION:` Stages are ordered by *dependency*, not by importance or by
delivery date. A later stage cannot be soundly designed until the earlier stages
it depends on are resolved. Each question is referenced by its `Q-ID`; blocking
levels are in the source document.

`OBSERVATION:` The overriding dependency is Q-0032: the identity ↔ recovery ↔
backup ↔ trust bundle forms a cycle and must be resolved as a coherent whole in
Stage 1, before routing and delivery are designed.

---

## Stage 1 — Foundational identity & trust

*Rationale:* Everything downstream signs, targets, or protects "a user". Until
identity and the adversary/trust model are fixed, no routing, delivery, or
security property can be stated. This stage resolves the dependency cycle.

- Q-0001 — Identity anchor.
- Q-0002 — User ↔ Device identity relationship.
- Q-0003 — Recovery vs permanence.
- Q-0006 — Adversary model.
- Q-0007 — "No node reads content" as a formal invariant.
- Q-0009 — Trust between a user's own devices.
- Q-0032 — Resolve the identity/recovery/backup/trust bundle coherently.
- Q-0004 — Human-readable vs self-authenticating identity (enters here because it
  shapes both identity and later discovery).

*Depends on:* nothing. *Blocks:* Stages 2, 3, 4.

---

## Stage 2 — Reachability: routing, witness, discovery

*Rationale:* Once a user identity exists, the network must be able to *find and
reach* that user. This stage designs how users are located and how packets are
routed, including the network's abuse resistance and scaling.

- Q-0010 — Bootstrap discovery (cold-start paradox).
- Q-0011 — Route Record contents / TTL / replication.
- Q-0012 — Witness/route anti-abuse (poisoning, sybil, eclipse).
- Q-0013 — Witness lookup scaling.
- Q-0014 — Route rotation vs reachability.
- Q-0015 — Witness as de-facto reachability source of truth vs invariant 8.
- Q-0008 — Metadata observability of lookups (social-graph leakage).
- Q-0031 — Contact exchange / discovery boundary (in OUO or application?).

*Depends on:* Stage 1 (identity anchor, adversary model). *Blocks:* Stage 3.

---

## Stage 3 — Delivery, multi-device, backup, recovery

*Rationale:* With identity and reachability settled, design how messages are
actually delivered, survive offline gaps, reach all of a user's devices, and how
users recover and revoke devices.

- Q-0020 — Delivery guarantee when all sender devices are offline.
- Q-0021 — Storage deletion vs multi-device fan-out.
- Q-0022 — Ordering / cross-device consistency.
- Q-0023 — Receipt authenticity without a source of truth.
- Q-0024 — Deduplication.
- Q-0017 — Degradation semantics ("degrade, not break").
- Q-0025 — Backup model (tension with P2).
- Q-0026 — Device revocation propagation.
- Q-0027 — Identity deletion semantics.

*Depends on:* Stages 1 and 2. *Blocks:* Stage 4.

---

## Stage 4 — Rich features: media, calls, groups

*Rationale:* Higher-level capabilities that build on identity, reachability, and
delivery, and that introduce their own hard sub-problems (real-time media,
group consistency).

- Q-0028 — Media blob TTL vs long-lived references.
- Q-0029 — Real-time calls vs store-and-forward (and presence).
- Q-0030 — Group membership authority and key management.

*Depends on:* Stages 1–3.

---

## Stage 5 — Longevity: sustainability, metadata hardening, scaling, hygiene

*Rationale:* Properties required for a protocol that must last decades, plus the
cross-cutting concerns and documentation-integrity items that can be resolved in
parallel but should not block core design.

- Q-0018 — Node operator incentives / long-term sustainability.
- Q-0008 (continued) — Metadata-protection hardening beyond basic lookup privacy.
- Q-0013 (continued) — Network scaling and possible federation.
- Q-0016 — `Server` entity vs node taxonomy mapping.
- Q-0005 — Multiple identities per human.
- Q-0019 — Filename collision + terminology drift (documentation integrity).
- Q-0033 — Version-block compliance retrofit.

*Depends on:* informed by all prior stages; hygiene items (Q-0019, Q-0033) may be
done anytime.

---

## Dependency summary

`OBSERVATION:`

```
Stage 1 (Identity & Trust)
   │  resolves the identity ↔ recovery ↔ backup ↔ trust cycle (Q-0032)
   ▼
Stage 2 (Reachability: routing / witness / discovery)
   ▼
Stage 3 (Delivery / multi-device / backup / recovery)
   ▼
Stage 4 (Media / calls / groups)
   ▼
Stage 5 (Sustainability / metadata / scaling / hygiene)
```

`OBSERVATION:` Documentation-integrity items (Q-0019, Q-0033) and the
scope-boundary declaration (Q-0031, though placed in Stage 2 for design impact)
are independent enough to be addressed out of band.

*(End of design roadmap. No decisions, no development schedule, no
recommendations — only the order in which questions must be resolved.)*
