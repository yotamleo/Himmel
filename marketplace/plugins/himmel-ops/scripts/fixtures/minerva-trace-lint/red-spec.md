# EXAMPLE-1 — settings dashboard: design spec

Synthetic RED fixture for minerva-trace-lint.sh (HIMMEL-4375). It reproduces the
shape of a real spec that shipped one fact as two findings: a surface-shaped
goal, a one-identity rule with no enumerated overlap, and a ticket-overlap table
in place of a fact-overlap table.

## 1. Goal

One local page where the user sees every config item and its health, and can
switch the safe items on and off.

## 2. Data model

Rows from overlapping sources get one identity: a cadence is one row, joining
its manifest item and its doctor rows as evidence, not three rows.

## 3. Consolidation

| Ticket | Overlap | Disposition |
|---|---|---|
| EXAMPLE-2 | secrets manifest | reuse as a feed source |
| EXAMPLE-3 | wiring inventory | fold into the feed |

## Alternatives considered

1. A static report page.

## Definition of done

- The page shows every item once.
