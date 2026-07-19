# Documentation Quality Standard

> **Status:** Approved
> **Last updated:** 2026-07-08

This standard governs **every** document in the OUO project. All existing and
future documents MUST comply.

## 1. Source of Truth

Documentation is the primary source of truth. Code implements the
documentation — never the reverse.

## 2. Fact vs Decision

Every substantive statement carries exactly one status tag. Tags are never
mixed within a single statement:

- **FACT** — a verified fact about existing technology.
- **OBSERVATION** — a neutral observation.
- **OPTION** — one possible implementation choice.
- **DECISION** — a final decision made by the project.
- **TODO** — insufficient information.
- **QUESTION** — an open architectural question.

Tags may be written inline (e.g. `FACT:`), as a leading label, or as a column
value in a matrix. A document must make each statement's status unambiguous.

## 3. Research documents

Research documents contain **no** decisions — ever, even when a decision seems
obvious. They use only FACT, OBSERVATION, TODO, and QUESTION.

## 4. RFC documents

An RFC describes only the decision that was made. An RFC contains no options,
no research, and no "could be done". It uses DECISION (and, where unavoidable,
TODO/QUESTION for genuinely deferred parts).

## 5. ADR documents

Every architectural decision has its own ADR. An ADR answers only one question:
**why this decision was made**. ADRs live in `docs/07-adr/`.

## 6. Versioning

Every document begins with a version block:

```
> **Status:** Draft | Review | Approved | Deprecated
> **Last updated:** YYYY-MM-DD
```

## 7. Cross references

Documents reference one another instead of duplicating text. No fact is written
in two places; the second place links to the first.

## 8. AI friendliness

Documentation MUST read identically to a human and to any AI (Claude, ChatGPT,
or others): explicit, unambiguous, self-contained per topic, and consistently
tagged per rule 2.

## 9. Assumptions

Any assumption MUST begin with the word **ASSUMPTION** and MUST NOT be presented
as a fact.

## 10. Breaking changes

Any change to already-accepted architecture MUST be marked **BREAKING CHANGE**
with a description of the reasons.

## Development pipeline

**BREAKING CHANGE (2026-07-08):** A **Foundation** stage is inserted between
Comparison and Decision. Reason: before any decision, the protocol needs a
conceptual system model answering "what is OUO?". "RFC" is written as
"Specification (RFC)" to match the stage's own wording; it is the same stage.

The order of development admits no exceptions:

```
Research  →  Comparison  →  Foundation  →  Decision  →  ADR  →  Specification (RFC)  →  Implementation
```

- **Research** — `docs/11-research/`. Facts only, no decisions (rule 3).
- **Comparison** — `docs/12-comparison/`. Compares researched approaches; makes
  no decisions.
- **Foundation** — `docs/14-foundation/`. Conceptual models of the protocol
  ("what exists", not "how"); makes no decisions.
- **Decision** — `docs/13-decisions/`. The author's explicit choice.
- **ADR** — `docs/07-adr/`. Why the decision was made (rule 5).
- **Specification (RFC)** — the specification of the decision (rule 4).
- **Implementation** — code conforming to the Specification (rule 1).

Related process definition:
[../11-research/00-methodology.md](../11-research/00-methodology.md).
