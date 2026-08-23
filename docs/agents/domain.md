# Domain Docs

How engineering skills should consume this repository's domain documentation.

## Before exploring

Read these files when they exist:

- `CONTEXT.md` at the repository root.
- `CONTEXT-MAP.md` if present, followed by each relevant context document.
- Relevant ADRs under `docs/adr/`.
- In a multi-context repository, relevant context-scoped ADRs.

If these files do not exist, proceed silently. Domain-modeling skills create them lazily when terminology or architectural decisions are resolved.

## Layout

This repository uses a single-context layout:

```text
/
|-- CONTEXT.md
|-- docs/
|   `-- adr/
`-- Sources/
```

## Vocabulary

Use terms defined in `CONTEXT.md` when naming domain concepts. Avoid synonyms that its glossary explicitly rejects. If a required concept is missing, reconsider whether the term belongs to the project or record the gap for domain modeling.

## ADR conflicts

Explicitly flag output that conflicts with an existing ADR instead of silently overriding the decision.
