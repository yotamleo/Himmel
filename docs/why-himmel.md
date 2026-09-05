# Why himmel

[`README.md`](../README.md) says what himmel is and
[`getting-started.md`](getting-started.md) gets it running. This page argues
the case: the failure modes that show up once you run Claude Code seriously,
and what himmel does about each — with the receipts.

If you are happy running Claude Code vanilla, you do not need any of this. It
earns its complexity at the point where you run more than one session at a
time, want work to continue while you sleep, or need context to survive a
session boundary.

---

## The five failure modes

### 1. The rule Claude forgot

You write "never commit directly to main" into a `CLAUDE.md`. It holds for a
week. Then a long session compacts, the instruction falls out of the live
window, and a commit lands on main.

Prose in a context window is a *probability*, not a constraint. The failure is
silent and you find it later.

**What himmel does:** the same rule becomes a hook that exits non-zero.
`block-edit-on-main.sh` runs before the Edit tool call, sees the branch, and
refuses. There is nothing to remember.

The escalation rule is explicit and is itself part of the design: *structural
beats instructional — the first drift is signal; on the second, escalate to a
hook, gate, or classifier, never to stronger prose.* The counts below are what
that policy produces over time.

| Layer | Count | Source of truth |
|---|---:|---|
| PreToolUse guardrail scripts (project scope) | 15 | `.claude/settings.json` |
| PreToolUse guards (himmel-ops plugin) | 9 | `marketplace/plugins/himmel-ops/hooks/hooks.json` |
| pre-commit gates | 37 | `.pre-commit-config.yaml` |
| pre-push gates | 11 | `.pre-commit-config.yaml` |
| commit-msg gates | 1 | `.pre-commit-config.yaml` |
| CI jobs | 10 | `.github/workflows/ci.yml` |

Re-derive these rather than trusting the table; the config files are the
inventory, and a written list drifts. Where each one fires and how to get past
it when it stops you legitimately:
[`internals/enforcement.md`](internals/enforcement.md) and
[`internals/stuck-playbook.md`](internals/stuck-playbook.md).

### 2. The gate that drifts away from the thing it guards

A gate that hand-maintains a list of what to block is a second copy of the
truth. Add a feature, forget the list, and the gate quietly stops covering it —
still green, no longer protecting anything.

**What himmel does:** where possible, gates derive their input from the thing
they guard. The hook that blocks Jira MCP calls when a local CLI verb exists
does not carry a list of verbs — it runs the CLI's own
`--list-commands` and blocks exactly what the CLI implements. Adding a verb
tightens the gate on its own; removing one loosens it. Same idea in the
`commands-catalog-drift` gate (the catalog's Description column is regenerated
from each command's own frontmatter and a divergent hand-edit is refused) and
`guardrail-matrices` (the egress policy JSON is the only copy, and both its
tests and its consumers are checked against it).

### 3. Context that dies with the session

A session ends. The next one starts cold: what shipped, what was tried and
rejected, why the obvious approach does not work. Re-explaining that is the
single largest recurring cost of agentic development, and paraphrasing it
loses exactly the *why*.

**What himmel does:** handover state is plain markdown in a directory you own,
written at session end and read at session start. Not a summary of the
session — the ship state: ticket, branch, worktree, what is committed vs.
dirty, unresolved review findings, the remaining ordered steps.

It is deliberately **not** a memory backend. Nothing extracts your files into
a separate store that gets queried instead of the source. The local search
index over the same markdown is a derived, drop-and-rebuild view that always
returns a pointer back to the real file. You can read the memory, correct it
by hand, and diff it — see
[`internals/handover-system.md`](internals/handover-system.md) and the
architecture view in [`architecture.md`](architecture.md#2-the-handover-system).

### 4. Two agents, one artifact

Run several sessions in parallel and coordination becomes the bug. Two armed
sessions pick up the same queue; both dispatch; both ship. Coordinating that
with a shared markdown file and a convention fails in the obvious way — the
convention is prose, and prose does not lock.

**What himmel does:** one writer per queue, enforced.
`scripts/handover/queue-lock.sh` takes a lock that is a *directory* (`mkdir` is
atomic, with no check-then-create window, and it works on NTFS under Git Bash).
`acquire` prints a release token; `release` and `heartbeat` refuse without it,
so a stale or wrong session cannot delete a live lock.

That script exists because prose coordination failed three ways in one night —
duplicate dispatch, duplicate shipping, and a coordination-by-append race. The
incident is recorded in the script's own header, which is where an escalation
of this kind belongs.

The same discipline covers delegation: many readers, one writer, never parallel
writes at a shared artifact; every dispatch names its model explicitly; and a
revision to a running agent arrives only as a direct message carrying an
echoed nonce — never inside a tool result, which is attacker-reachable text.
See [`internals/retask-channel.md`](internals/retask-channel.md).

### 5. Monitoring that lies, then pages you

Instrumentation that guesses is worse than none. A session that crashes never
writes its "session ended" record — so a naive reader reports it as still
running, forever. And a scrape that times out marks its target down, stales
every series, resolves the alert, then re-fires it on the next good scrape.

**What himmel does:** the exporter is a pure reader — it never writes a
ledger, never mutates state, never starts or kills a process, and omits a
metric family entirely when its substrate is absent. Missing data stays
missing rather than being invented.

Liveness is decided by the *reader*, from transcript mtime, precisely because
the record that never gets written is the informative one. An expired unpaired
row is split by whether its process is confirmed dead: `abandoned` (real
hygiene information, but nothing is hung and nobody can act — so it must not
page) versus `stalled` (everything else).

The flap above is not hypothetical: it produced 53 Telegram pages in one
night. The fix was measurement, not a threshold guess — the exporter's render
genuinely takes ~6.6 s average and ~9.9 s peak, against a 10 s default
timeout, so the scrape timeout went to 30 s. The reasoning is written into
`scripts/observability/prometheus.yml` next to the value it justifies.

---

## What that buys you

- **Unattended runs that survive their own interruptions.** A scoped ticket
  runs end to end — branch, build, self-review, PR — and on approaching a
  usage cap, a watchdog schedules an OS-level relaunch so the run resumes
  instead of dying.
- **Review before merge, not after.** Push writes a review-owed marker; the PR
  gate refuses while it exists; a clean multi-agent review clears it. The
  merge gate additionally requires CI green *and* zero unresolved threads.
- **Small context by construction.** A local CLI instead of an always-loaded
  MCP server, an output-summarizing proxy for noisy commands, and a hard byte
  budget on the always-on instruction file (12,288 bytes, enforced by a
  pre-commit gate — an instruction file that grows without limit is a tax on
  every single call).
- **Cross-platform, including the awkward one.** Linux, macOS, and Windows Git
  Bash, with the platform traps already handled and attested per change.

---

## What it costs

Worth stating plainly, because the trade is real:

- **Gates fire on you too.** `.pre-commit-config.yaml` registers 49 gate ids
  across the three git stages (37 pre-commit, 11 pre-push, 1 commit-msg), and
  some of them will stop a change you believe is fine. That is the design working, and the recovery path is
  documented — but it is friction, every day.
- **Setup is not one command for the full stack.** The portable core adopts
  into an existing repo in one command; the observability stack, the Telegram
  bridge, and the vault tooling are each separate, optional bring-ups.
- **It assumes a PR-gated, ticket-tracked workflow.** If you commit to main by
  design, most of the value here is aimed at a problem you do not have.
- **The harness is opinionated about where knowledge lives.** Reference docs
  in the repo, internal specs out of it, memory as readable markdown. Fighting
  that costs more than adopting it.

---

## The provenance argument

Every mechanism above is traceable. himmel's changelog carries 1,067 distinct
ticket references and 1,752 distinct pull-request references, and the repo
holds 399 shell test suites plus 10 CI jobs over them. Nearly every guardrail in the
enforcement table was added *after* a specific failure, and the ticket that
motivated it is in the script's header.

That is the actual claim being made here — not that this harness is correct in
the abstract, but that each of its constraints is a recorded failure that was
paid for once and then made structurally impossible to repeat.

Start at [`getting-started.md`](getting-started.md); the wiring is in
[`architecture.md`](architecture.md).
