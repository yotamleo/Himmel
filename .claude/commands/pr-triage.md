---
description: Lightweight 4-step PR triage gate (steipete) — decide if a PR is even worth a deep multi-agent CR before running /pr-check
argument-hint: [PR# or URL]
---

A **lightweight first-pass triage gate** (~10s of reasoning) run *before*
the heavy `/pr-check`. The question it answers is "is this PR even worth a
deep review?" — not "is this PR correct?". Adopted verbatim from
[@steipete](https://x.com/steipete)'s 4-step PR-review flow.

## The 4 steps (verbatim)

```
0) review <URL>                [the agent does its thing]
1) is the issue clear?
2) is this the best fix?
3) continue discussion, consider tradeoffs, usually rewrite PR
```

## Procedure for himmel

Given `$ARGUMENTS` (a PR number or URL; default to the current branch's PR):

0. **Pull the PR.** `gh pr view $ARGUMENTS --json title,body,files,additions,deletions`
   and `gh pr diff $ARGUMENTS`. Read the diff and the linked ticket.
1. **Is the issue clear?** Does the PR (or its ticket) state the problem it
   solves? If the *problem* is fuzzy, stop here — no amount of code review
   fixes an unclear goal. Push the PR back for a problem statement.
2. **Is this the best fix?** Is the approach the simplest one that solves the
   stated problem, or is there an obviously cheaper/cleaner path? A "yes, but"
   here is the highest-leverage moment — cheaper to redirect now than after CR.
3. **Tradeoffs / usually rewrite.** Name the tradeoffs the PR makes. steipete's
   observation: at this step you *usually rewrite the PR* rather than nitpix
   the existing diff. Decide the verdict below.

**Verdict** (report one line):
- `PROCEED` — issue clear + fix sound → run `/pr-check` for the deep CR.
- `REDIRECT` — approach wrong or issue unclear → comment the redirect, skip CR.
- `REWRITE` — fix the diff direction first, then re-triage.

## When to use this vs /pr-check

| | `/pr-triage` (this) | `/pr-check` |
|---|---|---|
| Cost | ~10s reasoning, one reader | minutes, multi-agent CR |
| Question | "worth a deep review?" | "is the code correct?" |
| Output | PROCEED / REDIRECT / REWRITE | findings + clears pre-push marker |
| Order | **first** | after a PROCEED |

`/pr-triage` is a cheap filter so `/pr-check`'s expensive multi-agent pass
only runs on PRs that survive the first gate. It does **not** clear the
pre-push CR marker — only `/pr-check` does.
