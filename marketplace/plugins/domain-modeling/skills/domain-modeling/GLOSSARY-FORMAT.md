> **Vendored, pinned (HIMMEL-5498).** Source: `mattpocock/skills` commit
> `49dd158d1076134a641b33efb035946536778336`, `skills/engineering/domain-modeling/GLOSSARY-FORMAT.md`.
> MIT (`LICENSE` beside this file). Retargeted at `docs/glossary.md` and its table
> format; the multi-context `GLOSSARY-MAP.md` section is dropped. See `SKILL.md`.

# docs/glossary.md Format

## Structure

Terms live in the tables of `docs/glossary.md`, one row per term:

```md
| Term | Meaning |
|---|---|
| **Order** [purchase, transaction] | A one or two sentence description of the term. |
| **Invoice** [bill, payment request] | A request for payment sent to a customer after delivery. |
```

The bold headword is the canonical name. The brackets hold its aliases: other words for the same concept, which point at the canonical term and are never defined on their own row.

## Rules

- **One definition per term.** Search `docs/glossary.md` for the term and its aliases before adding a row. If it exists, edit that row; a second definition drifts.
- **Be opinionated.** When multiple words exist for the same concept, pick the best one and list the others as aliases in brackets.
- **Keep definitions tight.** One or two sentences max. Define what it IS, not what it does.
- **Only include terms specific to this project's context.** General programming concepts (timeouts, error types, utility patterns) don't belong even if the project uses them extensively. Before adding a term, ask: is this a concept unique to this context, or a general programming concept? Only the former belongs.
- **Group terms under subheadings** when natural clusters emerge. Match the existing sections of `docs/glossary.md` rather than inventing new ones.
- **Keep repo identifiers in code spans** (`/console`, `go.sh`); they are never renamed.
