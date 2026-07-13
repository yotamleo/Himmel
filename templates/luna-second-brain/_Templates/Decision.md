---
type: decision
date: {{date}}
status: active
review_date:
reversibility: <reversible | irreversible>
outcome: pending
claim: "<what this decision asserts, one line — keep the value YAML-quoted>"
assumption: "<what must be true for the claim to hold, one line — keep the value YAML-quoted>"
tags:
  - decision
ai-first: true
---

# Decision: {{title}}

> **For future Claude:** <2-3 sentences — what was decided, why it mattered, and the single assumption it rides on. This is the note future-Claude pulls to ask "did this hold up?" at review time.>

## What Was Decided

<Clear, unambiguous statement of the decision. One sentence if possible.>

## Why

<The *actual* reasoning, not the after-the-fact justification. What pushed this over the line?>

## Alternatives Considered

<!-- What else was on the table and why each was rejected. -->
- <alternative> — rejected because <reason>
- <alternative> — rejected because <reason>

## The Critical Assumption

<The single belief this decision most depends on being true. (as of YYYY-MM) — confidence: `stated | high | medium | speculation`>

## What Success Looks Like

<Specific, observable outcome at the review date — written so future-you can check it objectively.>

## Early Warning Signs

<How to know this is going wrong *before* the review date.>

## Review Date

<YYYY-MM-DD — set a concrete date, e.g. +90 days.>

## Outcome

<!-- Filled in at review: was the critical assumption correct? Good decision given what was known *then* (not just whether it worked out)? What to apply next time. -->
_(pending review)_

## Related

<!-- Wikilinks mandatory: the project/area this decision serves, people accountable, sibling decisions, source clip if derived. -->
- [[<related note>]] — <one line: how it relates>
