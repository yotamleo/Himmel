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
> THIS document. <Any per-leg deviation from the standing leg preface — a
> required bypass env var already set in your launching shell, a lane that is
> not native, a suite that must be run a particular way — goes here, in this
> paragraph, and nowhere else.>

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
>    sequence. <Anything unusual: a PR body that must carry specific numbers, a
>    public-CI wait, a second ticket to comment on but leave open.>

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
