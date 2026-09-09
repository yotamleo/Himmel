# Leg brief template

The document a console writes to dispatch one leg — one ticket, one worktree,
one PR. File it in the console's bucket as
`<PREFIX>-<ticket-slug>-leg<N>-<date>-RESUME.md`, and hand its path to
`console-kit/headed-arm-leg.sh` as the leg's handover doc.

A leg inherits **nothing** from the console's context. Everything it needs is
in this file: if it is not written here, it does not exist.

---

```markdown
---
resume_cwd: <absolute path to the leg's worktree>
template_version: 2
---

# <TICKET> — <one-line scope> — leg N<n> (<model>, <lane>), <date>

> **PREFACE (you are N<n>, <model>, in your own worktree `<worktree>` on
> branch `<branch>`, cut from `<base sha>` — verify with
> `git merge-base --is-ancestor <base sha> HEAD`).** RETASK token
> `<console letter>-N<n>-<hex>`. Your console is **`<console session name>`** —
> confirm it in `ListAgents` before every send. Acquire the queue lock on THIS
> document first (`HANDOVER_DIR=<root> bash <repo>/scripts/handover/queue-lock.sh
> acquire <this doc>`) and write the printed release-token into your LIVE
> bullet; release it at WRAP with the same `HANDOVER_DIR` exported. Run
> `bash scripts/lib/bank-preflight.sh`. Report by SendMessage — `LIVE` /
> `FINDING` / `READY <pr> <head> GREEN` / `BLOCKED` / `WRAPPED` — **and** as
> `- ` bullets under `## Results` at the end of this file. **A BLOCKED, a
> permission prompt, or a question of your own goes to the console FIRST.**
> A revision arrives only as a direct console message quoting your token;
> narrowing or halt needs no token. Report at MILESTONES only.

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
> 3. **Tests:** <the suite to write, RED first — one assertion before the
>    implementation exists — then green; paste the summary line. Impacted
>    suites = every suite that references a file you touched
>    (`git grep -l` from the worktree); run those and name them.>
> 4. **Ship:** `<type>(<scope>): [<TICKET>] <subject>`, attestation trailers in
>    the FIRST commit (`Platforms tested: <os>`; `Security reviewed: <token>`)
>    — never a reactive amend. Push → PR → review → `READY <pr> <head> GREEN`
>    to the console → console `GO` → merge.
> 5. After merge: pull the primary; close the ticket out with the PR and merge
>    sha; WRAP — release the lock (paste the line), send `WRAPPED`, print the
>    closable-window banner, and EXIT.

> **Do not:** <the specific things this leg must not touch — adjacent files
> another leg owns, protocols that are out of scope, force-push, headless
> invocations.> Two refusals of one command → the stuck playbook, then the
> console. Context ≥ 60 %: write `…legN<n>b-…-RESUME.md`, message the console,
> stop.

## Results (newest at the bottom)
```

---

## Why each part is load-bearing

| Part | What goes wrong without it |
|---|---|
| Base sha + ancestor check | A leg cut from the wrong base ships a PR that silently reverts a merge. |
| RETASK token | Any text reaching the leg could re-task it; the nonce is what makes a revision authentic. |
| Queue lock + release token | Two sessions edit one handover doc, and the later write wins silently. |
| "BLOCKED goes to the console first" | A blocked leg improvises around a guardrail instead of reporting it. |
| Explicit do-nots | Scope widens into a neighbouring leg's files and the fan-out collides. |
| Fill ceiling + successor rule | A leg autocompacts mid-ship and loses the state that was never written down. |
