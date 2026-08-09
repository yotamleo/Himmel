#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell/mcp__* — GLM-lane external-write deny.
#
# WHY (HIMMEL-654 session-9 tail, operator decision #1 — "harden BEFORE
# scaling the offload"): GLM workers (scripts/telegram/spawn-glm.ts) and
# claude-glm sessions run claude against api.z.ai, usually with
# --permission-mode bypassPermissions. Third-party lanes have NO auto-mode
# classifier and bypassPermissions removes the prompt layer, so the only
# control between a mis-prompted worker and an external write is the
# poisoned worktree pushurl — a tripwire, not a wall. This hook is the
# deterministic classifier SUBSTITUTE: on the GLM lane, hard-block
# push / PR / external-write shapes.
#
# Lane detection: ANTHROPIC_BASE_URL contains api.z.ai (set by
# scripts/telegram/glm-env.ts buildGlmEnv and the scripts/claude-glm{,.ps1}
# launcher family; inherited by hook processes). Non-GLM sessions exit 0 on
# the first case below — near-zero overhead, before the jq availability check.
#
# Blocked on-lane:
#   - ALL mcp__* tools EXCEPT the qmd KB carve-out (v1 chores are repo-local;
#     blanket beats a verb list; qmd KB reads are operator-allowed, COLLECTION-
#     SCOPED to "himmel" only — see below)
#   - git push; git remote set-url; git config …url (tripwire un-poisoning)
#   - the gh CLI EXCEPT the carve-out below — pr create/merge/edit/review/
#     comment/ready, api, repo, release, gist, … stay blocked (parent-session
#     actions)
#   - network CLIs: curl/wget/Invoke-WebRequest/Invoke-RestMethod/iwr/irm
#     (write-flag parsing is fragile post-lowercasing; chores are repo-local;
#     bun/npm installs remain allowed — dependency fetch, not external write)
#
# Allowed on-lane (operator policy 2026-07-03 — audited-action carve-out):
#   - the Jira CLI (scripts/jira/ path, or bare `jira`): writes are audited in
#     Jira history + recoverable, so GLM workers may update status/comments and
#     file followup tickets. Atlassian MCP stays blocked (mcp__* below) — Jira
#     routing is CLI-first (block-backend-tier enforces that in every session).
#   - the qmd KB (mcp__plugin_qmd_qmd__* tools): read-only knowledge-base
#     access, COLLECTION-SCOPED (HIMMEL-1239). qmd indexes salus (a PHI medical
#     vault) alongside himmel/luna/luna-curated with NO built-in isolation, so
#     a blanket allow would let the GLM lane egress PHI to api.z.ai via the qmd
#     MCP path even though egress-matrix.json hard-denies salus by file path.
#     v1 allow-list = {himmel} ONLY (widening it, e.g. adding luna-curated, is
#     a SEPARATE named operator decision):
#       - `query`: allowed only when tool_input.collections is a non-empty
#         array whose every entry is "himmel" — an absent/empty collections
#         filter falls back to the store's default collections (unknown from
#         the tool-call JSON, may include salus) and is denied as unscoped.
#       - `get` / `multi_get`: allowed only when every file/pattern segment is
#         a fully-qualified `qmd://himmel/...` virtual path. qmd's resolver
#         falls back to matching a bare/relative filename or a #docid against
#         EVERY collection in turn, so anything short of the qmd://<collection>
#         scheme cannot be positively attributed to one collection and is
#         denied fail-closed.
#       - `status` (and any other/future qmd tool): has no collection-scoping
#         input at all, so it is denied fail-closed too.
#   - gh issue <anything> (full issue surface — reads AND writes; cr-deferred
#     followups are gh issues, audited in GitHub + recoverable), plus read-only
#     PR/CI context: `gh pr view|diff|checks|status|list`, `gh run
#     view|list|watch`. Every other gh use stays blocked (counting arm below).
#
# Known limitations (accidental-shape guard, like block-read-secrets):
#   - any wrapper displacing the command from command position is missed:
#     env-prefixed `FOO=1 git push`, sudo/xargs/timeout wrappers, `git-push`,
#     and the `=`-joined global-flag form `git --git-dir=/x push` (missed too)
#   - in-process network is invisible to a command-text hook — bun/node
#     fetch, including bun-invoking the telegram bridge send path
#   - malformed/empty tool JSON -> allow (parity with sibling hooks; Claude
#     Code emits valid JSON)
#   - the gh carve-out counts command-position gh occurrences (total vs
#     allowed) and shares the wrapper gap above — a wrapper-displaced gh is
#     invisible to BOTH counts, so it is neither blocked nor credited as allowed
#   Accepted OVER-blocks (fail-closed direction, all test-pinned):
#   - newlines flatten to ';', so quoted prose whose LINE starts with a
#     blocked verb ("…\ngit push later") blocks; mid-line prose stays allowed
#   - an allowed `gh issue …` whose quoted body contains `;`/`|` followed by
#     another gh token ("--body 'step 1; gh pr merge later'") blocks (the
#     body token inflates the total count)
#   - global flags BEFORE a gh subcommand displace it from the allow anchor:
#     `gh -R o/r issue list` blocks; write flags AFTER the subcommand
#     (`gh issue list -R o/r`) — allowed
#   All backstopped by the poisoned pushurl tripwire + the parent CR gate —
#   those two remain the load-bearing controls; this hook is the in-session
#   deterministic layer.
#
# Exit codes: 0 allow; 2 block (stderr shown to the worker).
# Bypass: GLM_EXTERNAL_WRITES_OK=1 in the env of the shell that spawns the
# worker (spawn-glm caller / claude-glm launcher). Session-sticky.
#
# BYPASS SCOPE — where the trust boundary actually is (HIMMEL-1649 round 4,
# [codex-1]). "No on-disk content ever executes" is an ENFORCEMENT-mode
# property, not a global one. Under GLM_EXTERNAL_WRITES_OK the near-miss denies
# are skipped, so a MALFORMED helper command reaches the on-disk helper and runs
# it. That is the designed contract, not a gap: bypass mode IS the no-hook
# environment scripts/glm/append-outbox.sh exists for, and round 3 made that
# helper the LOCKSTEP implementation of the same fail-closed schema enforced
# here — so a malformed payload appends NOTHING in either mode. Only the
# executor differs: the hook on-lane, the lockstep helper under operator bypass.
# Hoisting the near-miss deny above the bypass exit would block operator
# debugging in a mode the operator explicitly opted into, in order to guard
# against a worker who under bypass can already do strictly more.
#
# WHAT THIS HOOK IS AND IS NOT A TRUST ROOT FOR (HIMMEL-1649 round 5,
# [codex-adv-1] — scoping a claim rounds 3/4 stated too broadly). The honest
# invariant is narrow:
#   - Under ENFORCEMENT the report verb is executed BY THIS HOOK, never by
#     on-disk helper content. That part holds.
#   - This hook's ABSENCE now fails closed IN A DISPATCHED WORKER: it is
#     registered --fail-closed-when HIMMEL_GLM_WORKER=1, a marker minted only by
#     buildGlmEnv (the orchestrator path), so DELETING it there no longer
#     silently exits 0. The marker is WORKER-NESS, not the provider: an
#     interactive GLM session legitimately has no himmel scripts/ tree, so a
#     missing hook is NORMAL there and keeps ordinary optional semantics.
#   - It is NOT proof against a worker REWRITING project-owned hook code. The
#     worker's own envelope reaches this file: the plugin registers the hook at
#     $CLAUDE_PROJECT_DIR/scripts/hooks/, which in a worker session is the
#     worker's worktree, and composeWorkerSettings grants Edit(<worktree>/**)
#     plus Bash(node *)/Bash(bash *). A worker that replaces this file with
#     `exit 0` neuters the guard for every later tool call.
# Closing THAT is an architecture change, not a hook edit — run the guard from
# a dispatcher-owned path outside worker Edit roots, or hash-verify it at
# invocation against a dispatcher-recorded digest. Tracked in HIMMEL-1666.
# Do not restate the broad "nothing worker-reachable can affect this guard"
# claim anywhere; it was never true of the hook file itself.
set -euo pipefail

case "${ANTHROPIC_BASE_URL:-}" in
    *api.z.ai*) ;;
    *) exit 0 ;;
esac

# HIMMEL-1649 round 3 — the bypass is recorded as a FLAG, not an early exit.
# The report interceptor below is a SERVICE (the hook performs the outbox
# append); the push/gh/network classifiers are ENFORCEMENT.
# GLM_EXTERNAL_WRITES_OK disables ENFORCEMENT, never the SERVICE. Exiting here
# used to disable both, so a bypass session executed the on-disk helper — which
# only ever writes {text} — and silently downgraded every structured escalation
# to a text note that `adjudicate list` cannot see. The interceptor therefore
# runs first, and the bypass exit sits between it and the classifiers.
glm_bypass=0
[ "${GLM_EXTERNAL_WRITES_OK:-0}" = "1" ] && glm_bypass=1

# On-lane, a TOP-LEVEL errexit abort must BLOCK (exit 2), never slip through
# as a non-blocking exit 1 (only exit 2 denies in Claude Code). Scope honesty:
# the trap cannot see failures inside `if ... grep -q ...` condition contexts
# (errexit-exempt; a grep crashing on a fixed pattern is the only such shape —
# ~impossible in practice), and the malformed-JSON path deliberately stays
# fail-OPEN above per sibling-hook parity — this clamp covers everything else.
# shellcheck disable=SC2154  # rc is assigned by rc=$? inside the same trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if ! command -v jq >/dev/null 2>&1; then
    # Without jq the tool call cannot be parsed at all, so there is neither a
    # report to service nor a command to classify. A bypass session keeps its
    # historical escape hatch (this check used to sit BELOW the bypass exit);
    # a normal on-lane session still fails closed.
    [ "$glm_bypass" = 1 ] && exit 0
    echo "block-glm-external-writes: jq not on PATH — refusing to evaluate on the GLM lane; install jq" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

# HIMMEL-1649 round 9 (CodeRabbit, Major): the SHELL tools this hook mediates
# are Bash AND PowerShell — hooks.json registers the matcher as
# "Bash|PowerShell|mcp__.*", and both carry their command text in
# .tool_input.command. Gating the report interceptor and the near-miss deny on
# Bash ALONE left a PowerShell helper invocation neither hook-executed nor
# denied: it fell through to the generic classifiers, which do not match
# append-outbox.sh, and so executed the on-disk helper IN ENFORCEMENT MODE.
# That contradicts this branch's own charter ("under enforcement the report
# verb is executed by the hook, never by on-disk content"), so it is fixed
# rather than deferred. Severity was bounded — the push/gh/network classifiers
# already covered PowerShell, and the fall-through ran the dispatcher-minted
# LOCKSTEP helper that fail-closes the same payloads, i.e. it degraded to the
# sanctioned GLM_EXTERNAL_WRITES_OK posture — but bounded is not correct.
# One predicate, used by BOTH guards, so they can never drift apart again.
tool_is_shell=0
case "$tool" in Bash|PowerShell) tool_is_shell=1 ;; esac

deny() {
    {
        echo "⛔ block-glm-external-writes: $1"
        echo "    This session runs on the GLM lane (ANTHROPIC_BASE_URL=api.z.ai), which has"
        echo "    no auto-mode classifier — external writes are hard-blocked (HIMMEL-654)."
        echo "    Deliver results as a committed branch diff + your session outbox summary;"
        echo "    the parent Claude session / operator pushes and opens PRs."
        echo "    Operator bypass: GLM_EXTERNAL_WRITES_OK=1 in the spawning shell."
    } >&2
    exit 2
}

# HIMMEL-1649 round 3: the report verb is EXECUTED BY THE HOOK, never by any
# on-disk content. On the exact report shape this hook decodes the payload,
# validates it, appends the record to the session outbox ITSELF, and then DENIES
# the Bash call. Deny-after-append is the semantics, and the success message
# below tells the worker its report landed so it does not retry.
#
# Why not an ALLOW of a session-dir script (the round-2 shape): pathname trust
# is the wrong shape. The worker holds Bash(node *)/Bash(bash *) and Edit on its
# own session dir, chmod is advisory on NTFS/Git-Bash, and a computed
# destination path defeats any command-text classifier — so NO worker-reachable
# file can be made trustworthy at execution time. The hook is the trust root, so
# the hook performs the write. Nothing on disk is executed through this path.
deny_recorded() {
    {
        echo "✅ block-glm-external-writes: guard recorded your report; the command is not"
        echo "    executed — no further action needed (HIMMEL-1649)."
        echo "    The hook appended the outbox record itself and then denied the Bash call"
        echo "    BY DESIGN. Your report IS saved. Do not retry, reword, or find another way."
    } >&2
    exit 2
}

# GLM_SESSION_DIR is minted by spawn-glm.ts in the dispatcher's parent process
# and inherited by the worker/hook; a per-tool-call env prefix cannot alter it.
# Validate that seam fail-closed here. append-outbox.sh keeps a self-contained
# copy of these predicates for the non-GLM-lane case where this hook is absent;
# on the GLM lane that file is never executed, so the two copies are parity for
# readers rather than a shared trust boundary — keep them lockstep anyway.
path_norm() {
    printf '%s' "$1" | tr '\134' '/'
}

valid_glm_session_dir() {
    local sd base parent parent_base
    sd=$(path_norm "${GLM_SESSION_DIR:-}")
    sd=${sd%/}
    [ -n "$sd" ] || return 1
    case "$sd" in /*|[A-Za-z]:/*) ;; *) return 1 ;; esac
    case "/$sd/" in */../*|*/./*) return 1 ;; esac
    base=${sd##*/}
    parent=${sd%/*}
    parent_base=${parent##*/}
    [ "$parent_base" = "glm-sessions" ] || return 1
    case "$base" in glm-*) ;; *) return 1 ;; esac
    [ -d "$sd" ] || return 1
    [ ! -L "$sd" ] || return 1
    GLM_SESSION_REAL=$(cd "$sd" 2>/dev/null && pwd -P) || return 1
    [ -n "$GLM_SESSION_REAL" ] || return 1
    # Node on Windows accepts C:/... paths, not Git Bash's /c/... spelling.
    # Prefer pwd -W there; Unix bash lacks it, so fall back to the physical
    # POSIX path (same convention append-outbox.sh uses).
    GLM_SESSION_NATIVE=$(cd "$sd" 2>/dev/null && pwd -W 2>/dev/null) || GLM_SESSION_NATIVE=""
    [ -n "$GLM_SESSION_NATIVE" ] || GLM_SESSION_NATIVE="$GLM_SESSION_REAL"
    return 0
}

session_metadata_ok=0
if valid_glm_session_dir; then session_metadata_ok=1; fi

if [ "$tool_is_shell" = 1 ]; then
    report_cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # shellcheck disable=SC2016  # literal inherited variable spelling is the exact command contract
    helper_var_cmd_re='^bash "\$GLM_SESSION_DIR/append-outbox\.sh" ([A-Za-z0-9_-]+)$'
    helper_path_cmd_re='^bash ([A-Za-z0-9_./:+-]+/append-outbox\.sh) ([A-Za-z0-9_-]+)$'
    report_shape_ok=0
    report_script=""
    report_payload=""

    if [[ "$report_cmd" =~ $helper_var_cmd_re ]]; then
        report_shape_ok=1
        report_payload=${BASH_REMATCH[1]}
    elif [[ "$report_cmd" =~ $helper_path_cmd_re ]]; then
        report_shape_ok=1
        report_script=${BASH_REMATCH[1]}
        report_payload=${BASH_REMATCH[2]}
    fi

    if [ "$report_shape_ok" = 1 ]; then
        if [ "${#report_payload}" -gt 16384 ]; then
            deny "the GLM outbox payload exceeds the 16384-character base64url cap (HIMMEL-1649)."
        fi
        if [ "$session_metadata_ok" != 1 ]; then
            deny "the GLM outbox helper requires a valid dispatcher-minted GLM_SESSION_DIR (HIMMEL-1649)."
        fi

        if [ -z "$report_script" ]; then
            report_script="$GLM_SESSION_REAL/append-outbox.sh"
        else
            report_script=$(path_norm "$report_script")
        fi
        report_script_base=${report_script##*/}
        report_script_dir=${report_script%/*}
        report_script_dir_real=$(cd "$report_script_dir" 2>/dev/null && pwd -P) || \
            deny "the GLM outbox helper path does not resolve inside the dispatcher-minted GLM_SESSION_DIR (HIMMEL-1649)."

        # The helper file's existence/mode is deliberately NOT checked: it is
        # never executed on this lane, so making the decision depend on it would
        # be trust theater. Only the command SHAPE and the session-dir identity
        # gate the record.
        if [ "$report_script_base" != "append-outbox.sh" ] \
           || [ "$report_script_dir_real" != "$GLM_SESSION_REAL" ]; then
            deny "the GLM outbox report path must name the dispatcher-minted GLM_SESSION_DIR/append-outbox.sh (HIMMEL-1649)."
        fi

        command -v node >/dev/null 2>&1 || \
            deny "the GLM outbox guard needs node on PATH to record the report (HIMMEL-1649)."

        report_outbox="$GLM_SESSION_NATIVE/outbox.jsonl"
        [ ! -L "$GLM_SESSION_REAL/outbox.jsonl" ] || \
            deny "refusing a symlinked GLM session outbox.jsonl (HIMMEL-1649)."

        # Fixed program, payload passed as argv DATA — never shell source.
        # Validation order is fail-closed throughout: a rejected payload appends
        # nothing and the Bash call is denied with the reason.
        report_err=$(node -e '
const fs = require("node:fs");
const payload = process.argv[1];
const outbox = process.argv[2];
let text;
try {
  if (payload.length % 4 === 1) throw new Error("invalid base64url length");
  const decoded = Buffer.from(payload, "base64url");
  if (decoded.toString("base64url") !== payload) throw new Error("non-canonical base64url");
  text = new TextDecoder("utf-8", { fatal: true }).decode(decoded);
} catch {
  console.error("payload is not canonical base64url UTF-8");
  process.exit(2);
}
let parsed = null;
let structured = false;
try {
  parsed = JSON.parse(text);
  structured = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
} catch {
  structured = false;
}
// HIMMEL-1649 round 3 (F2) — consecutive-duplicate suppression. The hook
// appends and then DENIES, which is indistinguishable from a retryable failure
// to any framework-level retry; and because a prompt-shaped escalation omits
// ts, every retry would be stamped afresh and become a DISTINCT pending
// escalation. Un-denying is not an option (it would re-open executing on-disk
// content), so idempotency lives here: a sha256 of the RAW decoded payload is
// persisted alongside each record as _sig — the digest, never the payload
// itself, so the same comparison costs nothing per record — and an identical
// payload arriving immediately after the previous one appends NOTHING while
// still reporting success. A retry storm converges to one row; the same note
// sent again LATER, after any different record, still lands.
// LIMITS — adjudication-blind BY DESIGN in v1, deferred to HIMMEL-1663
// (round 4, [codex-adv-r4-2], both halves premise-verified): the key is payload
// equality with the LAST row only, carrying no attempt identity, time bound,
// adjudication state, or lock. So (a) an escalation REFUSED in grants.jsonl and
// then re-raised VERBATIM is suppressed while the worker is still told
// "recorded" — the aggregator skips the closed row, leaving nothing pending;
// and (b) two concurrent invocations can both read the old signature and both
// append. Deferred deliberately: the (a) window is narrow (it holds only while
// the identical row remains LAST — any intervening record clears it) and every
// candidate fix reopens the contract above; (b) costs a duplicate row on a
// worker that issues Bash calls serially.
const rawSig = require("node:crypto").createHash("sha256").update(text, "utf8").digest("hex");
let lastSig = null;
// Round 4 [codex-adv-r4-1] — torn-tail boundary. If an earlier append was
// interrupted the file can end mid-line, and appending straight onto it would
// CONCATENATE the new JSON into that partial line: consumers
// (fleet-control/aggregator/escalations.ts jsonl()) skip the combined invalid
// line, while the worker is still told its report was recorded. Detect the
// missing terminator and separate the records. A torn tail also fails to parse,
// so it already yields lastSig=null and can never suppress this append.
let torn = false;
try {
  const prior = fs.readFileSync(outbox, "utf8");
  torn = prior.length > 0 && !prior.endsWith("\n");
  const lines = prior.split("\n").filter((l) => l.trim() !== "");
  if (lines.length > 0) {
    try { lastSig = JSON.parse(lines[lines.length - 1])._sig ?? null; } catch { lastSig = null; }
  }
} catch { lastSig = null; }
if (lastSig !== null && lastSig === rawSig) {
  process.exit(0);
}
let record;
if (structured) {
  const type = parsed.type;
  if (type !== "note" && type !== "escalation") {
    console.error("structured payload type must be note or escalation");
    process.exit(2);
  }
  const allowed = type === "escalation"
    ? ["type", "capability", "arm", "reason", "step", "ts"]
    : ["type", "text", "ts"];
  for (const key of Object.keys(parsed)) {
    if (!allowed.includes(key)) {
      console.error("unknown key in structured payload: " + key);
      process.exit(2);
    }
  }
  const required = type === "escalation"
    ? ["capability", "arm", "reason", "step"]
    : ["text"];
  for (const key of required) {
    if (typeof parsed[key] !== "string") {
      console.error("field must be a string: " + key);
      process.exit(2);
    }
  }
  if (parsed.ts !== undefined && typeof parsed.ts !== "string") {
    console.error("field must be a string: ts");
    process.exit(2);
  }
  record = parsed;
  if (typeof record.ts !== "string") record.ts = new Date().toISOString();
} else {
  record = { type: "note", text };
}
record._sig = rawSig;
try {
  fs.appendFileSync(outbox, (torn ? "\n" : "") + JSON.stringify(record) + "\n", "utf8");
} catch (error) {
  console.error("append failed: " + error.message);
  process.exit(2);
}
' -- "$report_payload" "$report_outbox" 2>&1) || \
            deny "the GLM outbox report was rejected: ${report_err:-invalid payload} (HIMMEL-1649)."

        deny_recorded
    fi

fi

# ---- end of the SERVICE half; everything below is ENFORCEMENT --------------
# The bypass lands HERE (HIMMEL-1649 round 3): a bypass session has already had
# its report intercepted, schema-validated and recorded by the block above with
# identical semantics, so it can no longer silently lose a structured
# escalation. What it skips is only the near-miss denies and the
# push/gh/network classifiers.
# Round 4 [codex-1] — the consequence, stated plainly: with the near-miss denies
# skipped, a MALFORMED helper command falls through to ordinary Bash handling
# and EXECUTES the on-disk helper. Designed, not leaked. The helper is the
# lockstep implementation of the schema validated above and fail-closes the very
# same payloads, so the property that survives is the one that matters — a
# malformed payload appends nothing — with the executor, not the guarantee,
# differing between the two modes. See the BYPASS SCOPE note in the header.
# Scope, round 5: "no on-disk content executes" is a claim about the HELPER,
# never about this file. A worker whose envelope includes the worktree can
# rewrite THIS hook — see the trust-root note in the header and HIMMEL-1666.
[ "$glm_bypass" = 1 ] && exit 0

if [ "$tool_is_shell" = 1 ]; then
    # Every helper mention outside the exact contract is a fail-closed near-miss,
    # never ordinary Bash handling: repo/sibling paths, env prefixes, quotes,
    # substitutions, separators, redirects, extra arguments, and write attempts.
    case "$report_cmd" in
        *append-outbox.sh*)
            deny "malformed GLM outbox helper command; use exactly: bash \"\$GLM_SESSION_DIR/append-outbox.sh\" <base64url> (HIMMEL-1649)." ;;
        node\ -e*appendFileSync*outbox.jsonl*)
            deny "the interpolated node -e outbox append is retired; use the fixed session-dir base64url helper (HIMMEL-1649)." ;;
    esac
fi

# qmd MCP collection fence (HIMMEL-1239). v1 allow-list: ONLY the "himmel"
# collection (non-sensitive, repo-local docs). Widening this list (e.g. adding
# luna-curated) is a SEPARATE named operator decision — do not add collections
# here without one. `qmd_himmel_scoped "<value>"` -> 0 iff the value is a
# fully-qualified qmd://himmel/... virtual path (see header comment above for
# why bare/relative paths and #docids are rejected instead of allowed).
qmd_himmel_scoped() {
    # Whole-STRING prefix match (CR round 5, HIMMEL-1239) — NOT grep's
    # per-line match. grep -qE '^...' anchors at the start of EACH LINE, so a
    # value with an embedded newline where any line starts with
    # qmd://himmel/ (e.g. "qmd://salus/x\nqmd://himmel/y") passed even though
    # the value itself starts with salus. Python's re.match (no MULTILINE)
    # anchors at the actual string start; this replicates that exactly via
    # parameter expansion (bash 3.2-safe, no grep/sed) — strip leading
    # whitespace, then a plain glob-prefix case match.
    _q="$1"
    _q="${_q#"${_q%%[![:space:]]*}"}"   # strip leading whitespace (\s* in the regex)
    case "$_q" in qmd://himmel/*) return 0 ;; *) return 1 ;; esac
}

case "$tool" in
    mcp__plugin_qmd_qmd__query)
        # Single authoritative jq validation (CodeRabbit PR #1353, HIMMEL-1239)
        # — do NOT round-trip collections through shell lines: the earlier
        # extract + `[ -z ]` + `grep -vxF` form let collections:["himmel",""]
        # through, because the empty entry collapses out of the newline-joined
        # jq -r output and command-substitution trailing-newline stripping, so
        # `qmd_bad` ended up empty and the deny never fired (an empty-string
        # collection can mean "all collections" to qmd — a PHI-egress path).
        # This one check subsumes: non-array (was CR round 1 codex-2),
        # unscoped/empty array, AND any non-"himmel"/blank entry — matches the
        # Python qmd_scope_reason() query branch exactly.
        if ! printf '%s' "$input" | jq -e '(.tool_input.collections) | (type=="array") and (length>0) and (all(.=="himmel"))' >/dev/null 2>&1; then
            deny "qmd query 'collections' must be a non-empty JSON array of only \"himmel\" on the GLM lane (HIMMEL-1239) — no blank/other entries."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__get)
        qmd_file=$(printf '%s' "$input" | jq -r '.tool_input.file // empty' 2>/dev/null || true)
        if [ -z "$qmd_file" ] || ! qmd_himmel_scoped "$qmd_file"; then
            deny "qmd get on the GLM lane requires a fully-qualified qmd://himmel/... path (v1 allow-list, HIMMEL-1239) — bare paths and #docids are cross-collection-ambiguous and denied fail-closed."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__multi_get)
        qmd_pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // empty' 2>/dev/null || true)
        if [ -z "$qmd_pattern" ]; then
            deny "qmd multi_get on the GLM lane requires a qmd://himmel/... pattern (HIMMEL-1239)."
        fi
        # Root-cause fix (CR round 4, HIMMEL-1239): this is the 4th finding
        # rooted in the same mismatch — bash word-splitting (the prior
        # `IFS=',' for qmd_seg in $qmd_pattern` loop) DROPS empty
        # comma-separated fields, so a trailing comma ("a.md,"), a leading
        # comma (",a.md"), and adjacent commas ("a,,b") all lost their empty
        # segment and passed despite containing one. Rather than patch the
        # split mechanism again, replace it: awk -F',' preserves empty fields
        # (NF counts them), making this PROVABLY equivalent to the Python
        # qmd_scope_reason() multi_get branch (`[s.strip() for s in
        # pattern.split(",")]` + a full-match check on every segment, denying
        # on any empty/non-"qmd://himmel/" segment). No IFS/set -f/for-loop
        # left to diverge from Python's split semantics.
        if ! printf '%s' "$qmd_pattern" | awk -F',' '{
                if (NF==0) exit 1
                for (i=1;i<=NF;i++) {
                    s=$i
                    gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
                    if (s !~ /^qmd:\/\/himmel\//) exit 1
                }
            }'; then
            deny "qmd multi_get on the GLM lane requires a non-empty comma list where EVERY segment is a fully-qualified qmd://himmel/... path (HIMMEL-1239) — no empty/blank segments."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__*)
        # status (no scoping input) and any other/future qmd tool: scope
        # cannot be positively determined from the tool-call JSON -> deny
        # fail-closed (HIMMEL-1239).
        deny "qmd tool '$tool' has no collection-scoping input the GLM lane can verify — denied fail-closed (HIMMEL-1239)."
        ;;
    mcp__*) deny "MCP tool '$tool' is blocked on the GLM lane." ;;
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Lower-case + flatten newlines TO ';' — a newline separates commands exactly
# like ';' does, so flattening to spaces (the sibling hooks' shape) UNDER-blocks:
# a two-line "gh pr view 1\ngh pr merge 1" would read as one command and the
# merge would slip through as an "argument". Flattening to ';' keeps command
# boundaries visible to the (^|[;&|(]) anchor. Cost (accepted, fail-closed): a
# quoted commit-message LINE that STARTS with a blocked verb ("…\ngit push
# later") now over-blocks — pinned by test; mid-line prose stays allowed.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

# Command-position matcher: start-of-command or right after ; & | ( —
# deliberately NOT space/quote, so prose inside a commit message ("… git push
# …") does not false-block. Env-prefixed `FOO=1 git push` is therefore missed:
# accepted limitation, tripwire-backstopped (see header).
#
# Occurrence counter (same command-position wrapper). grep -c counts
# LINES, and cmd_lc is flattened to one line, so -c undercounts a compound with
# two command-position matches — count PER-MATCH via grep -oE | wc -l instead.
# grep exits 1 on zero matches; `|| true` keeps that from tripping errexit
# inside the assignment's command substitution. $(( )) strips wc's whitespace.
count_cmd() {
    local n
    n=$(printf '%s' "$cmd_lc" | grep -oE "(^|[;&|(])[[:space:]]*($1)" | wc -l) || true
    printf '%s' "$((n))"
}

# --- Deny-arm count form + session grant-consult (escalation channel, HIMMEL-654) ---
# Each command-text deny arm is a total-vs-allowed COUNT (never an inline deny):
#   git-push / git-url / network — builtin allowed 0 (no carve-out);
#   gh — builtin allowed = the issue-ops + pr/run-reads carve-out (HIMMEL-675).
# The subcommand-position shapes below are unchanged from the pre-grant arms
# (push flag-tolerant; git-url = remote set-url OR config…url OR-ed into ONE
# count; gh carve-out; network CLIs). A per-session grant in
# ${GLM_SESSION_DIR}/grants.jsonl can widen ONE arm's allowed count by folding
# its pattern into a SINGLE alternation (never a sum — F1), TTL- and use-bounded,
# fail-closed: an unset/absent grants file or any invalid grant line leaves the
# arm at its builtin allowance and it still denies.
gp_shape='git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'
gu_shape='(git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url|git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[a-z-]+)*[[:space:]]+[^[:space:];&|]*url)'
gh_shape='gh([[:space:]]|$)'
gh_allow='gh[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))'
net_shape='(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)([[:space:]]|$)'

gp_total=$(count_cmd "$gp_shape"); gp_allowed=0
gu_total=$(count_cmd "$gu_shape"); gu_allowed=0
gh_total=$(count_cmd "$gh_shape"); gh_allowed=$(count_cmd "$gh_allow")
net_total=$(count_cmd "$net_shape"); net_allowed=0

# F9 fast path: every arm satisfied by builtins alone -> allow WITHOUT reading
# grants.jsonl, so a builtin-allowed command never consults or consumes a grant.
if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    exit 0
fi

# Some arm exceeds its builtin allowance -> consult per-session grants (fail-closed).
# gp_alt/gu_alt/gh_alt/net_alt accumulate valid grant patterns per arm ('|'-joined,
# no associative arrays); valid_grants accumulates "grant_id <pattern>" lines for
# the consumption-append pass. A grant is skipped (as if absent) if it is not a
# well-formed grant line, has an unknown arm, fails the deny-shape anchor / has an
# unbounded prefix, is expired, or is used up.
gp_alt=""; gu_alt=""; gh_alt=""; net_alt=""; valid_grants=""
grants_file="${GLM_SESSION_DIR:-}/grants.jsonl"
if [ -n "${GLM_SESSION_DIR:-}" ] && [ -f "$grants_file" ]; then
    # Read the ledger ONCE and parse from the in-memory copy so the per-line loop
    # never re-opens the file; the consumption append below is a separate, later
    # pipeline, so there is no read/write overlap on grants.jsonl.
    grants_data=$(cat "$grants_file")
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%S)
    while IFS= read -r gline; do
        [ -z "$gline" ] && continue
        gobj=$(printf '%s' "$gline" | jq -c 'select(.type=="grant")' 2>/dev/null) || continue
        [ -z "$gobj" ] && continue
        garm=$(printf '%s' "$gobj" | jq -r '.arm // empty' 2>/dev/null) || continue
        gpat=$(printf '%s' "$gobj" | jq -r '.pattern // empty' 2>/dev/null) || continue
        gmax=$(printf '%s' "$gobj" | jq -r '.max_uses // empty' 2>/dev/null) || continue
        gid=$(printf '%s' "$gobj" | jq -r '.grant_id // empty' 2>/dev/null) || continue
        gexp=$(printf '%s' "$gobj" | jq -r '.expires_at // empty' 2>/dev/null) || continue
        if [ -z "$garm" ] || [ -z "$gpat" ] || [ -z "$gmax" ] || [ -z "$gid" ] || [ -z "$gexp" ]; then continue; fi
        case "$garm" in git-push|git-url|gh|network) ;; *) continue ;; esac
        case "$gmax" in ''|*[!0-9]*) continue ;; esac
        [ "$gmax" -gt 0 ] || continue
        [ "${#gexp}" -ge 19 ] || continue
        if ! [[ "$now_iso" < "${gexp:0:19}" ]]; then continue; fi          # expired
        if printf '%s' "$gpat" | grep -qE '^\.[*+]'; then continue; fi      # unbounded prefix (F2)
        # per-arm deny-shape anchor (F8): reject a grant whose pattern is not
        # anchored on THIS arm's deny shape (a git-push grant must carry a push
        # token; a git-url grant a url token; gh/network the family verb).
        case "$garm" in
            gh)
                printf '%s' "$gpat" | grep -qE '^gh(\[\[:space:\]\]|[[:space:]])' || continue ;;
            network)
                printf '%s' "$gpat" | grep -qE '^\(?(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)' || continue ;;
            git-push)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE '(\[\[:space:\]\]|[[:space:]]|\|\)|\+)push' || continue ;;
            git-url)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE 'url' || continue ;;
        esac
        gused=$(printf '%s\n' "$grants_data" | grep -c "\"type\":\"consumption\",\"grant_id\":\"$gid\"" || true)
        gused=${gused:-0}
        [ "$gused" -lt "$gmax" ] || continue                                # exhausted
        case "$garm" in
            git-push) gp_alt="${gp_alt:+$gp_alt|}$gpat" ;;
            git-url)  gu_alt="${gu_alt:+$gu_alt|}$gpat" ;;
            gh)       gh_alt="${gh_alt:+$gh_alt|}$gpat" ;;
            network)  net_alt="${net_alt:+$net_alt|}$gpat" ;;
        esac
        valid_grants="${valid_grants}${gid} ${gpat}
"
    done <<< "$grants_data"
fi

# Recompute each still-failing arm's allowed as ONE alternation (builtin|grant)
# — never a sum (F1). Arms with no builtin carve-out omit the builtin term.
if [ -n "$gp_alt" ]; then gp_allowed=$(count_cmd "$gp_alt"); fi
if [ -n "$gu_alt" ]; then gu_allowed=$(count_cmd "$gu_alt"); fi
if [ -n "$gh_alt" ]; then gh_allowed=$(count_cmd "($gh_allow)|($gh_alt)"); fi
if [ -n "$net_alt" ]; then net_allowed=$(count_cmd "$net_alt"); fi

if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    # Honored: append one consumption line per valid grant whose pattern matched
    # this command (append-only — existing lines are never rewritten).
    con_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s' "$valid_grants" | while read -r vgid vpat; do
        [ -z "$vgid" ] && continue
        if [ "$(count_cmd "$vpat")" -gt 0 ]; then
            printf '{"type":"consumption","grant_id":"%s","ts":"%s"}\n' "$vgid" "$con_ts" >> "$grants_file"
        fi
    done
    exit 0
fi

# Still over allowance after grants -> deny the offending arm (message per arm).
if [ "$gp_total" -gt "$gp_allowed" ]; then
    deny "git push is blocked on the GLM lane (commit locally; the parent session pushes)."
fi
if [ "$gu_total" -gt "$gu_allowed" ]; then
    deny "rewriting git remote/push URLs is blocked on the GLM lane (the pushurl tripwire stays poisoned)."
fi
if [ "$gh_total" -gt "$gh_allowed" ]; then
    deny "gh is limited on the GLM lane: issue ops + pr/run reads; PR mutations belong to the parent session."
fi
if [ "$net_total" -gt "$net_allowed" ]; then
    deny "network CLIs are blocked on the GLM lane (chores are repo-local)."
fi

exit 0
