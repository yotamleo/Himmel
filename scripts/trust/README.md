# scripts/trust — the R0 shadow ledger (HIMMEL-1529)

An append-only, hash-chained record of approval-shaped decisions. **Zero
behaviour change**: it emits no permission decision, so adding or removing it
moves nothing about how prompts flow. It only records.

## The number this exists to produce

**Approval-interrupts per week.** Nobody currently knows it, and it is the gate
on whether the rest of the trust programme is worth building. Below roughly ten
per week the small version is not the first increment — it is the end state, and
the graduated ladder should never be built.

```sh
node scripts/trust/shadow-ledger.mjs report
node scripts/trust/shadow-ledger.mjs report --days 7 --json
```

`report` refuses to state a weekly rate from a window shorter than a day. A
twenty-minute sample scaled up yields a confident six-figure number that is pure
artefact, and this is the one figure the programme is gated on.

### It also refuses when it cannot prove it was COLLECTING (HIMMEL-1547)

The observation window runs from the first record to **now**, deliberately —
measuring the spread between the first and last event is biased short at both
ends and inflates the rate. But that means every integrity signal the ledger
owns stays green while the recorder is simply **not running**: the window keeps
growing, the chain stays intact, no drops are recorded, and the published rate
decays smoothly toward zero. A dead collector does not look like a broken
instrument. It looks like good news — and "below ten per week" is the answer
that ends the programme.

So the collector asserts its own liveness. A seventh hook on `SessionStart`
writes one `heartbeat` row per session, carrying the **hook inventory** it found
wired at that moment. Two separate claims, because they fail separately:

| signal | proves | fails when |
|---|---|---|
| the heartbeat row exists | a recorder ran and could write | the hook is unwired, or node cannot spawn |
| `hook_inventory` is complete | the configuration named every verb | `notify` is removed — the ONLY producer of interrupt rows |

`report` publishes a rate only when at least one heartbeat falls inside the
window, every in-window heartbeat carried the full inventory, and no stretch of
the window — including from its start edge, and from the last heartbeat to now —
exceeds the **effective allowance** (below). Otherwise it prints `COLLECTION
UNPROVEN` and publishes nothing.

Two things it deliberately does **not** do:

- **It does not trim the window to fit.** An unproven window is refused whole.
  Capping at the last heartbeat would reintroduce the short-window bias by a
  different door, and that bias pushes the rate up.
- **It does not infer liveness from events.** A quiet week and a dead hook
  produce the same silence; that is the whole defect. A heartbeat proves
  liveness *without* implying activity, which is why it is a distinct row kind.

`HEARTBEAT_MAX_GAP_DAYS` is **7**, and it is a stated choice rather than a
derived one: the published figure is a rate per *week*, so a per-week rate must
not be computed over a window in which the collector went a full week unproven.
Shorter starts refusing on ordinary operator idleness; longer lets a stopped
recorder hide for more than one unit of the quantity being reported. Revisit it
with evidence about real session cadence.

### The allowance is bounded to the window, not just to seven days

The absolute cap above is not sufficient by itself. Adversarial review found —
and a direct probe confirmed — that it lets **one heartbeat anywhere in the
window** certify the whole window, as long as the window is no longer than the
cap: a collector dead for the entire week, with a single full-inventory
heartbeat in its last minute, satisfied `maxGapDays(7) <= HEARTBEAT_MAX_GAP_DAYS(7)`
and published a confident rate — the exact false-low number this instrument
exists to prevent, and the 1-to-7-day range is exactly where it lives during its
first week of operation.

So the allowance actually applied to a window is
`min(HEARTBEAT_MAX_GAP_DAYS, span_days × 0.5)` — no more than **half** the
window may go unaccounted for. A rule that lets the majority of the window go
unproven cannot tell a collecting window apart from a stopped one. For a 7-day
window that means 3.5 unproven days, not 7; the absolute cap only becomes the
binding constraint once the window is 14 days or wider. `report` prints the
effective figure (`allowed_gap_days` in `--json`), not the flat cap, in its
`⚠ COLLECTION` message — an operator told "allowed 7d" while the real bound was
3.5d cannot act on the message.

**`PROVEN` means "not obviously stopped", not "fully covered".** Even sitting
exactly at the limit, a published rate can still be understated by up to **2×**:
the unproven half of the window could hide events the proven half does not. That
residual is inherent to any gap-based liveness check and is stated here rather
than claimed away — treat a proven rate as a floor with a known, bounded error,
not as an exact count.

## Wiring

```sh
himmelctl trust on       # install the hook entries (seven, incl. the heartbeat)
himmelctl trust status   # report what is wired, change nothing
himmelctl trust off      # remove them
```

`himmelctl trust on` targets the settings file of **the project you are standing
in**, not the himmel checkout, and prints that path before it acts. It is
idempotent, converges a duplicate entry to exactly one, repairs a hand-pasted
entry that lost its `timeout` (a command hook with no `timeout` defaults to
**600 s**, not 10), refuses to wire when the recorder is not at the resolved
path, refuses a hook shape it does not recognise rather than destroying it, and
writes atomically against a stale-snapshot check. See
[`wire-trust-hooks.mjs`](wire-trust-hooks.mjs) (HIMMEL-1551).

**Known interaction — HIMMEL-1552.** `scripts/hooks/wire-hook-bash.mjs`, the
other sanctioned writer of this file, freezes the hook inventory as a constant
and hard-fails on any event key it does not expect. A trust-wired settings file
therefore makes it refuse:

```text
hook inventory has unexpected event(s): PostToolUseFailure, PermissionDenied,
PermissionRequest, Notification
```

Nothing invokes that script today (verified across five chain legs — only its
own test references it), so the incompatibility is latent rather than blocking.
If you do need it, `himmelctl trust off` restores the file. The real fix is
own-only validation plus a lock shared by both writers, tracked in HIMMEL-1552.

### By hand, if you would rather not run the command

`Edit(**/.claude/settings.json)` is an explicit deny rule, so an agent cannot
wire this itself. Add these **seven** entries by hand — three appended to
existing arrays (`PreToolUse`, `PostToolUse`) or added as `Notification`, the
three outcome/permission keys HIMMEL-1539 added, and the `SessionStart`
heartbeat HIMMEL-1547 added. Nothing else changes, and each is a
new array element or a new top-level key rather than an edit to an existing one,
so it merges cleanly against in-flight hook-wiring branches.

`PreToolUse` — append at the end of the array:

```json
{
  "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [
    { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" pre", "timeout": 10 }
  ]
}
```

`PostToolUse` — append at the end of the array:

```json
{
  "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [
    { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" post", "timeout": 10 }
  ]
}
```

`Notification` — a new top-level hook key (settings.json has none today; the
himmel-ops plugin owns the existing Notification hook and is untouched):

```json
"Notification": [
  {
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" notify", "timeout": 10 }
    ]
  }
]
```

`PostToolUseFailure`, `PermissionDenied`, `PermissionRequest` — three more new
top-level keys (HIMMEL-1539). Without them a failed call and a denied call both
land in `unresolved`, which corrupts the outcome data by construction:

```json
"PostToolUseFailure": [
  {
    "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" postfail", "timeout": 10 }
    ]
  }
],
"PermissionDenied": [
  {
    "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" denied", "timeout": 10 }
    ]
  }
],
"PermissionRequest": [
  {
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" permreq", "timeout": 10 }
    ]
  }
]
```

`SessionStart` — the collector heartbeat (HIMMEL-1547). **No matcher**, so it
fires on every session source (`startup`, `resume`, `clear`, `compact`); a
matcher that misses one produces a gap the report then refuses a rate over.
Append to the array if the key already exists:

```json
"SessionStart": [
  {
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs\" heartbeat", "timeout": 10 }
    ]
  }
]
```

Skip this one and everything still records — but `report` will publish no
weekly rate at all, on purpose. It is the entry whose absence would otherwise be
silent.

**Matchers: two of the three carry one, `PermissionRequest` deliberately does
not.** Verified against the Claude Code hook reference — `PostToolUseFailure`,
`PermissionRequest` and `PermissionDenied` are all tool events whose matcher
filters on tool name, exactly like `PreToolUse`/`PostToolUse`. So `postfail` and
`denied` carry the same matcher as the `PostToolUse` block above. `permreq` is
left unmatched ON PURPOSE: an approval interrupt counts whatever tool raised it,
and that row carries no request payload to classify. The recorder also filters
internally (`postfail`/`denied` record only `RECORDED_TOOLS`), so the matcher is
belt-and-braces there rather than the only guard.

**`PermissionDenied` does NOT mean "every denial".** The hook reference is
explicit that it fires *when a tool call is denied by the auto mode classifier*.
A manual operator denial, a `deny` permission rule, and a `PreToolUse` block do
**not** raise it. The recorded verdict is therefore named
`denied_auto_classifier`, and `report` labels it *AUTO-MODE CLASSIFIER denials
ONLY* — those other denial sources still land in `unresolved`. Naming it plain
`denied` would have been the same mistake this whole ticket is about: a partial
signal wearing a name that reads as complete coverage.

`PermissionRequest` fires when a tool call **needs a permission decision** — and
that is not the same as a human being interrupted. In an armed or otherwise
unattended session the event still fires with nobody present; this programme
measured that directly (W0 probe P5: a hook returning `ask` hung for 902 s on a
dialog no one could answer). So `report` calls the figure permission-request
**events**, never a direct interrupt count — labelling it otherwise would
inflate the gate number exactly in the unattended runs this harness does most.

It is recorded and reported **alongside** the Notification-derived count, not
swapped in as the gate number: two independent estimators of one quantity are
how you find out which is right, and silently switching would replace a measured
figure with an unvalidated one while destroying the comparison that would have
settled it. HIMMEL-1539 raised this as a design input for HIMMEL-1530;
collecting both is what makes that decision evidence-based. `permission_mode` is
persisted on the row as the only interactivity-adjacent signal available — it is
**stored, not interpreted**, and no count splits on it until that distinction
can actually be shown.

The commands invoke `node` directly rather than `bash`, so they are not exposed
to the Windows bash-resolution failure behind HIMMEL-1516/1526 (bare `bash`
resolving to the system32 WSL stub or the zero-byte WindowsApps alias).
`$CLAUDE_PROJECT_DIR` is quoted, as every existing hook command in
`.claude/settings.json` quotes it: an unquoted expansion word-splits on a
project path containing a space, and the hook then fails open — losing
observations silently, which is the one failure mode a measurement tool must
not have.

`"timeout": 10` is not decoration. A command hook **defaults to 600 seconds**,
so a stalled home-directory syscall in the `PreToolUse` hook would hold every
matching tool call for ten minutes — which would make this a behaviour change,
and the whole claim of the ticket is that it is not one. Ten seconds is well
above the bounded lock budget and well below anything an operator would sit
through.

**What `unresolved` still means.** With all six blocks wired it is a call with no
terminal outcome observed — stranded or crashed. If the failure/denial keys are
NOT pasted, denials and failures fall back into it. The report cannot tell a
wired-and-quiet harness from an unwired one, so its wording keeps both readings.

**When the recorder loses an event, `report` says so.** Lock exhaustion and
failed appends are recorded to `drops.jsonl`, a file deliberately outside the
ledger's lock and hash chain — the events it holds are exactly the ones the
ledger could not hold. **Any recorded drop suppresses the weekly rate**, and
drops are deliberately NOT expired by timestamp — two review rounds showed a
clock cannot be trusted to expire a known loss (a non-string `ts` escaped the
window, and a backward clock step re-dated an in-window failure as old, both
restoring a confident rate over missing events). An abandoned torn tail
suppresses it too.

There is deliberately **no acknowledgement path that restores the rate**.
Deleting `drops.jsonl` does not make the lost event exist: the window still
covers a gap, so the rate would return over data known to be incomplete.
Restoring one honestly requires a durable `valid_since` checkpoint that moves
the observation window past the loss — tracked in **HIMMEL-1547**, together with
the collector-liveness heartbeat it shares machinery with. The hash chain can only attest rows that landed; it
is structurally blind to rows that never did, and before HIMMEL-1539 that
blindness produced an understated rate that looked exactly like a quiet week.

**The residual blind spot, stated rather than papered over.** `drops.jsonl`
lives on the same volume as the ledger, so a volume-wide failure — ENOSPC, inode
exhaustion, a directory permission change — can lose the ledger event *and* its
drop row together. Recovery then leaves a chain that validates cleanly over an
incomplete history. This is not fully solvable by a second file on the same
disk, so it is documented instead of claimed away. What IS handled: a health
channel that exists but cannot be READ (EACCES/EIO) counts as a drop and
suppresses the rate, rather than reading as "no drops" — unknown must never
present as clean. Set `HIMMEL_TRUST_LEDGER_DIR` to a volume you monitor if this
residual matters for your deployment.

## Where the ledger lives

`~/.claude/himmel/trust/ledger.jsonl`, overridable with
`HIMMEL_TRUST_LEDGER_DIR`. Outside the repo on purpose: it is machine-local
measurement, not source.

## Record shape

| field | meaning |
|---|---|
| `ts` | ISO timestamp |
| `kind` | `request` (PreToolUse) · `outcome` (PostToolUse) · `notification` (Notification) · `permission_request` (PermissionRequest) · `heartbeat` (SessionStart) |
| `ref` | joins a request to its outcome — the harness's `tool_use_id`, or a `d:`-prefixed derived hash when absent |
| `class` | verb × target-pattern, e.g. `bash:git push`, `write:.sh` |
| `target` / `target_hash` | coarse handle + sha256 of the full request |
| `requester_lane` / `lane_config_hash` | who asked, under which lane registry |
| `shadow_verdict` | the blind verdict — `allow` · `deny` · `abstain` |
| `actual_verdict` | `executed`, stamped by the later event |
| `notification_type` | recorded verbatim; classified at report time, not here |
| `hook_inventory` | heartbeat only — which ledger verbs were WIRED at session start; `null` when no settings file could be read |
| `prev_hash` / `hash` | the chain |

Commands and file contents are **not** stored — only the coarse class and a
hash. A ledger that holds transcripts becomes an unread lake; this one holds
decisions and outcomes and points at sessions.

The subcommand half of a Bash class is kept only when the token itself is a
**known subcommand of a known family** (`git push`, `npm run`, `docker build`).
Validating the family is not enough: runner commands like `node`, `npx`, `bun`
and `dotnet` take a path or a package as their second token, so
`npx https://alice:TOKEN@github.com/acme/x` would have persisted a whole
credential-bearing URL. Validating the token means an unrecognised word — which
is exactly where secrets live — is always dropped. Runner families are absent
from the table entirely, and leading `VAR=val` assignments are stripped for the
same reason.

`report` also refuses to publish a rate over a **damaged ledger**. It counts
unreadable rows (an unterminated *final* line is a normal in-flight append; any
other is real damage) and verifies every chain link, because silently skipping a
torn row and then printing a confident number yields a plausible, understated
result with nothing to signal it. This is the read path using the chain, not
the standalone verification tooling the ticket defers — it is what makes that
deferral safe.

## Four things not to get wrong

**1. Blind means written before the prompt is routed.** The record is chained
and flushed by the same hook process, before it exits toward the permission
layer. If the operator could see the harness's guess while deciding, any
agreement rate would measure anchoring rather than competence — and the evidence
would be worthless in a way that is invisible when it is worthless. Never move
the write after the decision, and never surface `shadow_verdict` in an
operator-visible string. Note that a hook's `permissionDecisionReason` **is**
rendered verbatim in operator-visible UI; this hook emits no such field.

**2. Never `ask`.** Under `defaultMode: auto` nothing normally prompts, so a
silent hook is harmless — but a hook returning `ask` reintroduces the dialog
auto mode exists to remove, and in an armed session that dialog is unanswerable
and unbounded (measured: 902.5s, still blocked when killed; not an auto-deny).
This hook defers by emitting nothing at all, and a source-text test pins that
`permissionDecision`, `ask` and `hookSpecificOutput` appear nowhere in the file.

**3. Not every notification is an approval interrupt.** Notification also fires
for idle-wait timeouts and elicitation dialogs (see
`scripts/hooks/telegram-notification.sh`, which documents the same surface), so
counting them all would inflate the gate number. The hook records **every**
notification with its type and the classification happens in `report` — because
a hook-side filter fails in the dangerous direction: if the type vocabulary
ever changes, it would silently record nothing and the gate number would read
zero, indistinguishable from a genuinely quiet week. Filtering at report time
means an unrecognised type appears in the `other notifications` breakdown
instead of vanishing, and old rows can be reclassified without re-collecting.

**4. A missing outcome row is not a denial.** A Pre/Post pair alone cannot tell
denied from stranded from crashed, so `report` counts those rows as
`unresolved` and says so, rather than folding them into a denial count. The
`interrupt` rows are what make the gate number directly observable instead of
inferred.

## What the shadow verdict is, and is not

A small deterministic rule engine — **not** a model judgement, because a hook
cannot call a model and must not try. It answers a narrow question: is this
request provably safe, provably refused, or contested? Contested gets `abstain`,
which is the honest answer for exactly the cases a trust ladder would have to
adjudicate.

It deliberately does **not** re-implement `scripts/hooks/auto-approve-safe-bash.sh`.
That hook is the production gate and owns its own edge cases; a second copy here
would drift and the ledger would end up measuring the drift.

So: the **interrupt count is the product**. Agreement rate between shadow and
actual is a secondary output, is dominated by the abstain class, and `report`
prints that caveat next to the number.

## Deliberately deferred

Chain **verification** tooling and keyed signatures. Chained writes are one line
per record and cheap; a verifier is not needed while the threat model is model
drift and confusion rather than an adversary with filesystem access. Signing, if
it ever lands, is done by the launcher/hook process on behalf of the dispatch
identity — never by the agent, whose context is readable and exfiltratable.

Lane attribution is best-effort: no dispatcher exports a lane marker today, so
most rows read `primary`. It improves the day `spawn-*` export `HIMMEL_LANE`;
it is not guessed from cwd, because a worktree does not imply a lane.

## Tests

```sh
node --test "scripts/trust/tests/*.test.mjs"
```
