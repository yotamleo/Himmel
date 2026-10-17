---
name: domain-modeling
description: Sharpen the project domain model. Use when discussing codebase terminology or editing docs/glossary.md.
---

> **Vendored, pinned to a commit (HIMMEL-5498).** Source: `mattpocock/skills`,
> commit `49dd158d1076134a641b33efb035946536778336`, path
> `skills/engineering/domain-modeling/` (`SKILL.md`, `GLOSSARY-FORMAT.md`),
> fetched 2026-10-16. License: MIT, (c) 2026 Matt Pocock (`LICENSE` beside this file).
> **Deviations from upstream:** (1) output retargeted from a root `GLOSSARY.md` to
> himmel's `docs/glossary.md`, in its own table format (one definition per term,
> an alias points at the canonical term); (2) the multi-context `GLOSSARY-MAP.md`
> structure and the ADR guidance are dropped (`ADR-FORMAT.md` is not vendored,
> himmel keeps decision records in the state repo); (3) frontmatter `description`
> trimmed to match; (4) this header. Re-sync by diffing against the pinned path.

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is the *active* discipline: challenging terms, inventing edge-case scenarios, and writing the glossary down the moment terms crystallise. (Merely *reading* `docs/glossary.md` for vocabulary is not this skill: that's a one-line habit any skill can do. This skill is for when you're changing the model, not just consuming it.)

## File structure

himmel has a single context: `docs/glossary.md`. It is the one definition site for the fleet and harness vocabulary; everything else links to it instead of restating a definition. Create no other glossary file.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `docs/glossary.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y. Which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account': do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible. Which is right?"

### Update docs/glossary.md inline

When a term is resolved, update `docs/glossary.md` right there. Don't batch these up: capture them as they happen. Use the format in [GLOSSARY-FORMAT.md](./GLOSSARY-FORMAT.md). Search the glossary for the term and its aliases first: one definition per term, never a second row.

`docs/glossary.md` should be totally devoid of implementation details. Do not treat it as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.
