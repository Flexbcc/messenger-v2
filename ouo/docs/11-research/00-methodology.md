# Research & Design Methodology

> **Status:** Approved
> **Last updated:** 2026-07-08
> **Document class:** Process definition.
> **Scope:** Defines how the OUO Protocol is designed. Applies to every new
> component before it may become an RFC.

## Design pipeline

**BREAKING CHANGE (2026-07-08, a):** The pipeline was revised so that dedicated
**Comparison** and **ADR** stages are explicit, and "Discussion" is no longer a
separate named stage (folded into Comparison and Decision). Reason: adoption of
the Documentation Quality Standard.

**BREAKING CHANGE (2026-07-08, b):** A **Foundation** stage is inserted between
Comparison and Decision, and the specification stage is written as
"Specification (RFC)". Reason: before any decision, the protocol needs a
conceptual system model ("what is OUO?"), authored in `docs/14-foundation/`.

Every new component of the OUO Protocol passes through this pipeline, in order:

```
Research  →  Comparison  →  Foundation  →  Decision  →  ADR  →  Specification (RFC)  →  Implementation
```

No stage may be skipped and there are no exceptions. In particular, a
Specification is **never** the first artifact for a component.

## Rules

1. **No decision without research.** We do not make architectural decisions
   before studying how existing systems solve the same problem.
2. **Every component follows the pipeline** above (Research → Comparison →
   Discussion → Decision → RFC → Implementation).
3. **RFC is never created first.** It appears only after a Decision, which
   itself follows Research, Comparison, and Discussion.
4. **Research documents contain no decisions.** A Research document only
   investigates: it records how existing systems and literature work. It
   contains no conclusions, no recommendations, and no proposed architecture.
5. **Comparison documents compare approaches.** A Comparison document places the
   researched approaches side by side against defined criteria. It may surface
   trade-offs but still does not decide.
6. **Decisions are made by the project's user (author).** The AI never makes an
   architectural decision on its own. When the AI reaches a decision point, it
   presents options and waits.

## Stage definitions

- **Research** — factual investigation of existing systems, academic work, and
  threats. Output lives under `docs/11-research/`. Facts only, no decisions.
- **Comparison** — structured side-by-side evaluation of the researched
  approaches against explicit criteria. Output lives under `docs/12-comparison/`.
  No decisions.
- **Foundation** — conceptual models of the protocol answering "what exists",
  not "how". Output lives under `docs/14-foundation/`. No decisions.
- **Design Paper** — an in-depth, decision-free exploration of a single problem
  (e.g. the identity model), surveying models and their trade-offs and ending in
  Open Questions for the author. Output lives under `docs/15-design-papers/`.
  Not a pipeline stage of its own; it feeds the Foundation and Decision stages.
  Makes no decisions and no recommendations.
- **Decision** — an explicit choice made by the author. Output lives under
  `docs/13-decisions/` and is recorded under **Approved** in the decision
  journal
  ([../00-overview/0007-project-status.md](../00-overview/0007-project-status.md)).
- **ADR** — records **why** a decision was made. Output lives under
  `docs/07-adr/`.
- **RFC** — the specification of the chosen approach, using the fixed 12-section
  document structure. Describes only the decision (no options, no research).
- **Implementation** — code that conforms to the RFC. The specification has
  priority over the implementation.

This ordering is fixed by the Documentation Quality Standard
([../00-overview/0008-documentation-standard.md](../00-overview/0008-documentation-standard.md)).

## Directory layout

```
docs/11-research/
├── 00-methodology.md        # this document
├── 01-existing-systems/     # research on deployed systems
├── 02-academic-papers/      # research on academic literature
├── 03-threats/              # research on threats and attacks
└── 04-notes/                # working research notes
```

## Relationship to other documents

- Terminology is governed by
  [../00-overview/0000-core-concepts.md](../00-overview/0000-core-concepts.md).
- Accepted decisions and open discussions are tracked in
  [../00-overview/0007-project-status.md](../00-overview/0007-project-status.md).
- Research documents may reference entities and open questions from those
  documents but must not resolve them.
