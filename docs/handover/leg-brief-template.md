# Leg brief template

The document a console writes to dispatch one leg — one ticket, one worktree,
one PR. File it in the console's bucket as
`<PREFIX>-<ticket-slug>-leg<N>-<date>-RESUME.md`, and hand its path to
`console-kit/headed-arm-leg.sh` as the leg's handover doc.

A leg inherits **nothing** from the console's context. Everything it needs is
in this file: if it is not written here, it does not exist.

**v3 (HIMMEL-2830): the invariant rules moved out of the brief.** They live in
[`leg-preface.md`](leg-preface.md), which
`headed-arm-leg.sh --profile <name>` appends to the leg's system prompt
(`--append-system-prompt-file`). **No rule was dropped — every one of them
moved**, and the preface says so to the leg in its own words. What stays here
is the part that is different for every leg: who this leg is, what it is doing,
and what it must not touch. If you dispatch a leg **without** `--profile`, the
preface is not injected, so paste it into the brief yourself or the leg is
under-briefed.
Claudex briefs no longer paste the coordination paragraph: `--lane claudex`
always appends [`leg-preface-claudex.md`](leg-preface-claudex.md).

---

```markdown
---
resume_cwd: <absolute path to the leg's worktree>
template_version: 3
---

# <TICKET> — <one-line scope> — leg N<n> (<model>, <lane>), <date>

> **You are N<n>, <model>, in your own worktree `<worktree>` on branch
> `<branch>`, cut from `<base sha>`.** Your RETASK token is
> `<console letter>-N<n>-<hex>`; your console is **`<console session name>`**;
> your handover root is `<HANDOVER_DIR>` and the queue lock you must hold is on
> THIS document. Write its release token into your LIVE bullet exactly as
> `queue-lock.sh` prints it — in backticks, never bare in prose and never
> followed by punctuation — a bare token defeats the vault's anchored gitleaks
> allowlist and stalls the handover auto-commit (HIMMEL-2910, HIMMEL-2937).
> <Any per-leg deviation from the standing leg preface — a
> required bypass env var already set in your launching shell, a lane that is
> not native, a suite that must be run a particular way — goes here, in this
> paragraph, and nowhere else.>

> **Tier:** <opus|fable> — <one of the three sanctioned reasons: multi-step
> design; a FINDING the console could not verify at Sonnet; a Sonnet leg
> returned the work as above its tier.> <Omit this line entirely for a
> Sonnet or Haiku leg — `headed-arm-leg.sh` (HIMMEL-2976) refuses to launch
> an Opus or Fable model without it.>

> **Why (read the ticket first: `<the exact command that fetches it>`):**
> <two or three sentences: what the operator actually asked for, and what is
> deliberately NOT in scope. A leg that has to infer the why will widen the
> scope.>

> **Sources:** <every file, ticket and doc the leg should read, with absolute
> paths and what to take from each. Name what is private and must never reach
> the tree.>

> **Contract:**
> 1. LIVE; paste `git log -1 --format=%H` and the base-ancestor check.
> 2. <the deliverables, one numbered item each, named by path>
> 3. **Tests:** <the suite to write and the specific RED assertion to show
>    first; the impacted suites you already know about, by name.>
> 4. **Ship:** `<type>(<scope>): [<TICKET>] <subject>`, then the standing ship
>    sequence. Trailers go in the FIRST commit, token first after the colon:
>    `Platforms tested: <os>` and `Security reviewed: manual — <what you
>    checked>` (or `claude-code-security-review` / `pr-review-toolkit` /
>    `ad-hoc` in place of `manual`). The PR body carries one line
>    `leg-burn: calls= avg-ctx= first-turn= compactions=` from
>    `bash scripts/lanes/leg-burn.sh <your session name>`, run just before
>    opening the PR. <Anything else unusual: a PR body that must carry other
>    specific numbers, a public-CI wait, a second ticket to comment on but
>    leave open.>

> **Do not:** <the specific things THIS leg must not touch — adjacent files
> another leg owns, protocols that are out of scope, a script another leg
> owns, a probe that may be run only once.>

## Results (newest at the bottom)
```

---

## Why each part is load-bearing

| Part | What goes wrong without it |
|---|---|
| Base sha + ancestor check | A leg cut from the wrong base ships a PR that silently reverts a merge. |
| RETASK token | Any text reaching the leg could re-task it; the nonce is what makes a revision authentic. |
| Queue lock + release token | Two sessions edit one handover doc, and the later write wins silently. |
| Explicit do-nots | Scope widens into a neighbouring leg's files and the fan-out collides. |
| The standing preface | Every rule the brief no longer repeats — reporting, RETASK asymmetry, RED-first, trailers in the first commit, GO-gated merge, the fill ceiling. It is injected by `--profile`, so a brief that omits it AND the flag is a leg running on vibes. |
| Tier line (Opus/Fable only) | Without a trimmed, non-blank reason, `headed-arm-leg.sh` refuses the launch (HIMMEL-2976, CLAUDE.md: "raise effort before tier") — the tier choice must be logged structurally, not left to the console's judgement call each time. The gate does not yet validate the reason against the three sanctioned categories above (tracked as HIMMEL-2997); until then, the sanctioned-reason list is policy guidance the console and reviewers still enforce by eye. |

## What the console must also do (2026-09-13)

- (a) One plan task per leg, plus the stage-worker rule: run the context-fill
  probe after every completed step (ruling A1) — at ≥60 % fill, or on noticing
  a compaction, the leg commits what is done and hands off to a `b`-suffixed
  successor brief rather than continuing.
- (b) The console creates the leg's worktree before arming it, never after.
- (c) Holding for the console's `GO` ends the leg's turn — never a Bash sleep
  loop; a leg that blocks in one never wakes to receive it.
- (d) `/pr-check` runs at the exact head the leg reports in its `READY` line,
  not an earlier or later one.
