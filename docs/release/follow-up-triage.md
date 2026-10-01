# Follow-up triage (HIMMEL-4034)

Every version spawns follow-ups: CR suggestions deferred, judge RESCOPEs,
residual gaps. This is the rule for where each one goes, so a version ships on
time without chasing perfection and without letting bad bugs or friction
through. The rule is measured, not final; the numbers below tune it.

## Classes

Every follow-up gets exactly one class when it is filed. The class is a Jira
label.

| Class | Label | Meaning | Goes to |
|---|---|---|---|
| escape | `fu-escape` | A user-visible bug, a fail-open on a guard or permission, data loss or corruption, or friction a user hits weekly. | The CURRENT version. Blocks its tag. |
| hardening | `fu-hardening` | A residual gap behind another layer, a rare edge, or test coverage. | The next trail version, subject to the cap. |
| polish | `fu-polish` | Wording, cosmetic, nice-to-have. | The backlog with no version. Closed after 3 versions untouched. |

An Important CR finding that matches `escape` is fixed in the PR, not deferred.
Anything else may be deferred, with a class.

## The cap

At most about 20 % of a version's load may be `fu-hardening` follow-ups
(`--cap-pct` in the report; load = the version's tickets that are not
follow-ups). Overflow rolls to the next trail version, or is dropped by an
explicit decision recorded on the ticket. It never slips silently.

## The class is required on a deferral

The CR ledger refuses a deferral without a class (nothing is written):

```bash
scripts/cr/ledger-append.sh finding ... --verdict deferred --deferred-to <TICKET> --fu-class <escape|hardening|polish> --reason "<why>"
scripts/cr/ledger-append.sh amend ... --set verdict=deferred --set deferred_to=<TICKET> --set fu_class=<escape|hardening|polish> --set "reason=<why>" --reason "<why>"
```

`review-round.sh defer` (the three-round cap path) records `polish`: it only
defers Suggestions. Deferring an Important always needs an explicit class.
Panel batch rows (`--batch-file`) are not enforced; they are not deferrals a
person classifies. The same class goes on the follow-up ticket as its label
(`fu-escape`, `fu-hardening` or `fu-polish`), and in the summary when filing.

## The per-version report

```bash
bash scripts/release/followup-report.sh --version v1.0.1c
```

Read-only. Prints, per fixVersion:

- follow-ups created and done per class, and follow-ups with no class yet
  (`unclassified-followups`, the backfill's input). **This count is an
  estimate:** an unlabelled ticket counts as a follow-up only when its summary
  contains `follow-up`, `followup`, `deferred` or `residual`, so a follow-up
  without those words is missed and an ordinary ticket with one is counted. An
  explicit marker (label or link type) is left to the HIMMEL-4045 backfill;
- the hardening share of the version's load against the cap (`ok` / `OVER`).
  Load is the version's tickets that are neither labelled nor keyword-matched
  as follow-ups, so the share is an estimate for the same reason;
- **claim B, "deferral lets bad bugs through"**: `slipped-escapes`, the count
  of `fu-escape` tickets also labelled `fu-slipped`. Whoever finds that a
  deferred follow-up later caused an incident, a red CI, a denial or operator
  friction adds `fu-slipped` to it and links the evidence on the ticket;
- **claim A, "perfection is too expensive"**: mean CR rounds and token sums per
  ticket, from the usage records (`scripts/usage/usage-read.sh`,
  [usage-records](../internals/usage-records.md)). It prints `claim-A
  unavailable` when no store exists yet; run `scripts/usage/usage-compute.sh`
  first.

Run it at tag time and paste the output on the version's release ticket. The
cap and the class bounds are tuned from those numbers.

## Not done here

Classifying the open follow-ups already in Jira (the one-shot backfill) is a
separate ticket; until it runs, `unclassified-followups` is the size of that
job.
