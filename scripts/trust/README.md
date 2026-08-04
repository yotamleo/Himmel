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

## Wiring (operator action — `.claude/settings.json` is deny-listed to agents)

`Edit(**/.claude/settings.json)` is an explicit deny rule, so an agent cannot
wire this itself. Add these three entries by hand. Nothing else changes, and
each is a new array element rather than an edit to an existing one, so it
merges cleanly against in-flight hook-wiring branches.

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

**One thing this wiring does NOT observe.** `PostToolUseFailure` and
`PermissionDenied` are real hook events carrying `tool_use_id`, and they are not
wired here, so a failed call and a denied call both land in `unresolved` rather
than as distinct outcomes. That is a known limitation of R0, not an oversight —
tracked in HIMMEL-1539, together with the recorder-health gaps. Read the
`unresolved` count with that in mind.

## Where the ledger lives

`~/.claude/himmel/trust/ledger.jsonl`, overridable with
`HIMMEL_TRUST_LEDGER_DIR`. Outside the repo on purpose: it is machine-local
measurement, not source.

## Record shape

| field | meaning |
|---|---|
| `ts` | ISO timestamp |
| `kind` | `request` (PreToolUse) · `outcome` (PostToolUse) · `notification` (Notification) |
| `ref` | joins a request to its outcome — the harness's `tool_use_id`, or a `d:`-prefixed derived hash when absent |
| `class` | verb × target-pattern, e.g. `bash:git push`, `write:.sh` |
| `target` / `target_hash` | coarse handle + sha256 of the full request |
| `requester_lane` / `lane_config_hash` | who asked, under which lane registry |
| `shadow_verdict` | the blind verdict — `allow` · `deny` · `abstain` |
| `actual_verdict` | `executed`, stamped by the later event |
| `notification_type` | recorded verbatim; classified at report time, not here |
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
