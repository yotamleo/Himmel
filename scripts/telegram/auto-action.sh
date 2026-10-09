#!/usr/bin/env bash
# auto-action.sh <op> <arg> <time> — privileged remote auto-action executor (HIMMEL-424 B2).
#
# The TRUSTED Telegram bridge invokes this DIRECTLY (argv array) after parsing a
# structured `/arm` command; the spawned `claude` agent is never in the trust path.
# This script owns the privileged half: resolve a ticket|path to a resume handover,
# then shell arm-resume.sh. It runs in the real himmel shell environment (.env,
# handover-path.sh, py-armor, schtasks) — "inherit the system".
#
# Exit-code namespace (kept DISTINCT from arm-resume's own rc space so a dedup/
# already-armed result doesn't collide with a resolution failure):
#   0  armed
#   1  bad input (missing args / bad time)
#   2  unknown op (closed op allow-list, defense-in-depth)
#   3  no resume handover / bad path / path outside handover_root
#   4  ambiguous (>1 genuine handover — never silently pick)
#   5  already armed (arm-resume dedup rc=3)
#   6  arm-resume failed (any other non-zero)
#
# merge-public (HIMMEL-1213) is a SEPARATE flow below the op allow-list check:
# it does NOT share arm-resume's rc space above — this script instead RELAYS
# merge-public-on-green.sh's own exit code verbatim (0 merged / 1 bad usage /
# 10-19 refusal codes; see that script's header) after validating PR/SHA shape
# here (bad shape -> 1, reusing arm-resume's "bad input" code since the two
# ops' rc spaces never co-occur within one invocation).
#
# Args ALWAYS land as the VALUE of `arm-resume --handover`, never a bare positional
# (so a path like `--force` can't be misread as a flag). Test seams:
# AUTO_ACTION_ARM_CMD overrides the arm command (default the real arm-resume.sh);
# AUTO_ACTION_MERGE_PUBLIC_CMD overrides the merge command (default the real
# merge-public-on-green.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OP="${1:-}"; ARG="${2:-}"; TIME="${3:-}"
if [ -z "$OP" ] || [ -z "$ARG" ] || [ -z "$TIME" ]; then
    echo "ERR auto-action: usage: auto-action.sh <op> <arg> <time>" >&2
    exit 1
fi

# Closed op allow-list (defense-in-depth vs the bridge parse layer).
case "$OP" in
    arm-resume|merge-public|launch-bypass-leg|cr-grant-delta) ;;
    station-status|revert-main|repin-hooks|launch-leg|cr-reset|close-wrapped|relaunch-console|restart-bridge|allow-rule)
        # HIMMEL-5047 break-glass ops: one executor owns them and their rc space.
        # The bot token and own-poller flag stay out of every child it starts.
        TELEGRAM_BOT_TOKEN="" TELEGRAM_OWN_POLLER="" bash "$SCRIPT_DIR/break-glass.sh" "$OP" "$ARG" "$TIME"
        exit $?
        ;;
    *) echo "ERR auto-action: unknown op: $OP" >&2; exit 2 ;;
esac

# merge-public (HIMMEL-1213): ARG carries the PR number, TIME carries the
# operator-approved head SHA — the `<op> <arg> <time>` shape is reused
# verbatim from arm-resume (see router.ts's MERGEPUB comment for why). Branch
# out to the merge chokepoint BEFORE any arm-resume-specific validation below:
# the HH:MM/smart/auto time check would reject a SHA outright, and a merge
# needs no handover_root resolution at all.
if [ "$OP" = "merge-public" ]; then
    PR="$ARG"; SHA="$TIME"
    case "$PR" in
        ''|*[!0-9]*) echo "ERR auto-action: bad PR number: '$PR'" >&2; exit 1 ;;
    esac
    # 12-hex floor (was 7): a 7-hex prefix is 28 bits and grindable by an agent
    # that can push public fix-commits (HIMMEL-1213 Fable gate-review). Anchored
    # `case` — NOT `grep -Eq '^…$'`, which passes if ANY line of a multi-line
    # value matches (audit-log line-injection vector). case matches the WHOLE
    # string, so an embedded newline lands a non-hex char and is rejected.
    case "$SHA" in
        *[!0-9a-f]*) echo "ERR auto-action: bad SHA (non-hex or multi-line): '$SHA'" >&2; exit 1 ;;
    esac
    if [ "${#SHA}" -lt 12 ] || [ "${#SHA}" -gt 40 ]; then
        echo "ERR auto-action: bad SHA (expected 12-40 lowercase hex chars): '$SHA'" >&2
        exit 1
    fi
    MERGE_CMD="${AUTO_ACTION_MERGE_PUBLIC_CMD:-bash $SCRIPT_DIR/../merge-public-on-green.sh}"
    # Strip the bot token (+ TELEGRAM_OWN_POLLER) from the child env, same as
    # the arm-resume path below — this chokepoint doesn't need them either.
    # DELIBERATELY do NOT strip CLAUDECODE (HIMMEL-1213 codex CR-1): it MUST
    # propagate to the chokepoint's gate 0. This script is itself reachable by an
    # agent (through the classifier, since HIMMEL-3402 removed the broad
    # `Bash(bash scripts/*)` allow-rule), so the ONLY thing
    # stopping an agent from laundering `auto-action.sh merge-public …` into a real
    # merge is CLAUDECODE reaching gate 0 and self-refusing there. The legitimate
    # bridge runs WITHOUT CLAUDECODE (it is not a Claude session), so it is
    # unaffected; a bridge accidentally launched inside a Claude session correctly
    # fails closed rather than merging. Unsetting it here would open that bypass.
    # MERGE_CMD is an intentional command+args split — word-splitting wanted.
    # shellcheck disable=SC2086
    out=$(TELEGRAM_BOT_TOKEN="" TELEGRAM_OWN_POLLER="" $MERGE_CMD "$PR" "$SHA" 2>&1)
    rc=$?
    printf '%s\n' "$out"
    exit "$rc"
fi

# A Telegram line never authorizes a hook-bypass launch, even when explicitly
# enabled and invoked without an agent marker (HIMMEL-4905).
if [ "$OP" = "launch-bypass-leg" ]; then
    echo "ERR auto-action: Telegram hook-bypass launch refused; start hook legs at the station" >&2
    exit 19
fi

# Operator-only post-cap fix grant. Never reset the full-round counter or
# consumed judge verdicts; the next review-round reads this .head + absent .delta.
if [ "$OP" = "cr-grant-delta" ]; then
    case "$ARG" in ''|*[!0-9]*) echo "ERR auto-action: bad PR number" >&2; exit 1 ;; esac
    case "$TIME" in ''|*[!0-9a-f]*) echo "ERR auto-action: bad reviewed SHA" >&2; exit 1 ;; esac
    [ "${#TIME}" -eq 40 ] || { echo "ERR auto-action: full reviewed SHA required" >&2; exit 1; }
    if [ -n "${CLAUDECODE:-}" ]; then
        echo "ERR auto-action: agent session cannot authorize cr-grant-delta" >&2
        exit 19
    fi
    PR_JSON=$(gh pr view "$ARG" --json headRefOid,headRefName,isCrossRepository 2>/dev/null) || exit 13
    PR_HEAD=$(printf '%s' "$PR_JSON" | jq -er '.headRefOid | select(type == "string")') || exit 13
    BRANCH=$(printf '%s' "$PR_JSON" | jq -er '.headRefName | select(type == "string")') || exit 13
    [ "$(printf '%s' "$PR_JSON" | jq -r '.isCrossRepository')" = "false" ] || exit 13
    git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || exit 1
    case "$PR_HEAD" in ''|*[!0-9a-f]*) exit 13 ;; esac
    [ "${#PR_HEAD}" -eq 40 ] || exit 13
    if [ "$TIME" = "$PR_HEAD" ] || ! git merge-base --is-ancestor "$TIME" "$PR_HEAD" 2>/dev/null; then
        echo "ERR auto-action: reviewed SHA is not a prior ancestor of the PR head" >&2
        exit 15
    fi
    COMMON=$(git rev-parse --path-format=absolute --git-common-dir) || exit 3
    COMMON=$(realpath "$COMMON") || exit 3
    STATE="$COMMON/cr-review-rounds/$BRANCH"
    LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"
    SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$LOCK_LIB" acquire-wait . "$BRANCH" telegram-cr-grant 10 300 >&2 || exit 6
    LOCK_OWNER=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status . "$BRANCH" || true)
    case "$LOCK_OWNER" in '{"pid":'*) ;; *) echo "ERR auto-action: unreadable counter lock owner" >&2; exit 6 ;; esac
    HEAD_TMP=""
    # shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
    release_grant_lock() {
        [ -z "$HEAD_TMP" ] || rm -f "$HEAD_TMP"
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" release-if-owner . "$BRANCH" "$LOCK_OWNER" >/dev/null 2>&1
    }
    trap release_grant_lock EXIT
    # Validate under the same lock as review-round, not before a waiting acquire.
    for SUFFIX in round head delta; do
        FILE="$STATE.$SUFFIX"
        if [ -e "$FILE" ] || [ -L "$FILE" ]; then
            [ -f "$FILE" ] && [ "$(realpath "$FILE")" = "$FILE" ] || exit 3
        elif [ "$SUFFIX" != "delta" ]; then
            echo "ERR auto-action: missing branch .$SUFFIX state" >&2
            exit 3
        fi
    done
    # Same branch/head/model and finding identity semantics as review-round's
    # ledger_query; here only a FIXED, never deferred/disproved, critic finding
    # authorizes the operator's narrower grant. An avail row is also required.
    if ! node - "$COMMON/cr-critic-scores.jsonl" "$BRANCH" "$TIME" "$STATE.delta" <<'NODE'
const fs = require("fs");
const [file, branch, head, deltaFile] = process.argv.slice(2);
let deltaTo = "";
if (fs.existsSync(deltaFile)) {
  try {
    const pair = fs.readFileSync(deltaFile, "utf8").trim().split(/\s+/);
    if (pair.length < 3 || !pair.slice(0, 2).every(h => /^[0-9a-f]{40}$/.test(h))) process.exit(1);
    deltaTo = pair[1];
  } catch { process.exit(1); }
}
let lines;
try { lines = fs.readFileSync(file, "utf8").split("\n"); } catch { process.exit(1); }
// Exact 40-hex only (HIMMEL-4879): a short prefix row is not a review of this sha.
const exact = (h, sha) => typeof h === "string" && /^[0-9a-f]{40}$/.test(h) && h === sha;
const at = (h) => exact(h, head);
const critic = (m) => typeof m === "string" && !["claude", "claude-floor", "codex-adv"].includes(m);
const key = (o) => [String(o.finding_id), o.artifact || "diff", o.perspective || "off"].join("\u001f");
const verdicts = new Map(), settled = new Set();
let reviewed = false, spent = deltaTo === "";
const note = (id, v) => { verdicts.set(id, v); if (["deferred", "disproved"].includes(v)) settled.add(id); };
for (const line of lines) {
  let o; try { o = JSON.parse(line); } catch { continue; }
  // Legacy branchless amendments apply to every branch; the current sole
  // writer always stamps a branch, so scoped amendments follow the legacy rows.
  if (!o || (o.branch !== branch && !(o.kind === "amend" && !o.branch))) continue;
  if (o.kind === "avail" && o.status === "ok" && critic(o.model)) {
    if (at(o.head)) reviewed = true;
    if (exact(o.head, deltaTo)) spent = true;
  }
  if (o.kind === "finding" && critic(o.model) && at(o.head)) note(key(o), String(o.verdict || ""));
  if (o.kind === "amend" && at(o.target_head) && verdicts.has(key(o)) && typeof o.set?.verdict === "string") note(key(o), o.set.verdict);
}
process.exit(spent && reviewed && [...verdicts].some(([id, v]) => v === "fixed" && !settled.has(id)) ? 0 : 1);
NODE
    then
        echo "ERR auto-action: no critic-reviewed head with a fixed finding on this branch" >&2
        exit 4
    fi
    # Re-query under the counter lock: do not mutate against an outdated PR head.
    FRESH=$(gh pr view "$ARG" --json headRefOid,headRefName,isCrossRepository 2>/dev/null) || exit 13
    [ "$FRESH" = "$PR_JSON" ] || { echo "ERR auto-action: PR head moved" >&2; exit 15; }
    STAMP="$(date +%Y%m%dT%H%M%S).$$"
    for SUFFIX in head delta; do
        FILE="$STATE.$SUFFIX"
        if [ -e "$FILE" ]; then
            BACKUP="$FILE.$STAMP"
            (set -C; cat "$FILE" > "$BACKUP") || exit 6
            echo "backup=$BACKUP"
        fi
    done
    CURRENT_OWNER=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status . "$BRANCH" || true)
    [ "$CURRENT_OWNER" = "$LOCK_OWNER" ] || { echo "ERR auto-action: counter lock changed owner" >&2; exit 6; }
    HEAD_TMP=$(mktemp "$STATE.head.grant.XXXXXXXX") || exit 6
    printf '%s\n' "$TIME" > "$HEAD_TMP" && mv -f "$HEAD_TMP" "$STATE.head" || exit 6
    HEAD_TMP=""
    if [ -e "$STATE.delta" ]; then rm "$STATE.delta" || exit 6; fi
    echo "reviewed=$TIME"
    exit 0
fi

# --- arm-resume path (below) ---
# Validate time FIRST (identical regex to arm-resume's HH:MM, so the early reject
# can't diverge from the real validator).
case "$TIME" in
    smart|auto) ;;
    *)
        if ! printf '%s' "$TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
            echo "ERR auto-action: bad time '$TIME' (expected HH:MM, 'auto', or 'smart')" >&2
            exit 1
        fi
        ;;
esac

# HIMMEL-4420: handover_root reads only the live env; feed it the .env HANDOVER_DIR first.
# shellcheck disable=SC1091
if . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# Resolve the handover root via the shared resolver (subtree hard rule: never
# hardcode ./handovers/ — source handover-path.sh + call handover_root).
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
if ! ROOT=$(handover_root); then
    echo "ERR auto-action: handover_root unresolved (set HANDOVER_DIR or create handovers/)" >&2
    exit 3
fi
ROOT=$(realpath "$ROOT" 2>/dev/null) || ROOT=$(cd "$ROOT" && pwd)

RESOLVED=""
if printf '%s' "$ARG" | grep -Eq '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    # Ticket: case-insensitive match (files are lowercase, the arg is upper),
    # EXCLUDE anything under a specs/ path (design/plan docs are not resume
    # targets), then PREFER files carrying `type: handover` frontmatter.
    _matches=()
    while IFS= read -r _f; do
        [ -n "$_f" ] && _matches+=("$_f")
    done < <(find "$ROOT" -type f -iname "*$ARG*.md" 2>/dev/null | grep -v '/specs/' | sort)
    if [ "${#_matches[@]}" -eq 0 ]; then
        echo "ERR auto-action: no resume handover for $ARG" >&2
        exit 3
    fi
    _preferred=()
    for _f in "${_matches[@]}"; do
        if head -20 "$_f" 2>/dev/null | grep -qiE '^type:[[:space:]]*handover[[:space:]]*$'; then
            _preferred+=("$_f")
        fi
    done
    _pool=("${_matches[@]}")
    [ "${#_preferred[@]}" -gt 0 ] && _pool=("${_preferred[@]}")
    if [ "${#_pool[@]}" -gt 1 ]; then
        # Never silently pick among genuine handovers — list basenames and refuse.
        _list=""
        for _f in "${_pool[@]}"; do _list="${_list:+$_list, }$(basename "$_f")"; done
        echo "$_list" >&2
        exit 4
    fi
    RESOLVED="${_pool[0]}"
else
    # Path: must exist AND canonicalize UNDER handover_root (containment, fix I3 —
    # blocks /etc/passwd and ../../x, which arm-resume would otherwise read
    # resume_cwd/resume_worktree frontmatter from). Fail closed if realpath is
    # unavailable (can't verify containment).
    if [ ! -e "$ARG" ]; then
        echo "ERR auto-action: path not found: $ARG" >&2
        exit 3
    fi
    if ! _real=$(realpath "$ARG" 2>/dev/null) || [ -z "$_real" ]; then
        echo "ERR auto-action: could not canonicalize path (containment unverifiable): $ARG" >&2
        exit 3
    fi
    case "$_real" in
        "$ROOT"/*) RESOLVED="$_real" ;;
        *) echo "ERR auto-action: path outside handover_root: $ARG" >&2; exit 3 ;;
    esac
fi

# Machine-readable line the bridge parses for the audit + reply.
echo "resolved=$(basename "$RESOLVED")"

# Invoke arm-resume.sh with the resolved handover as the --handover VALUE. Strip the
# bot token (and TELEGRAM_OWN_POLLER) from the child env (M3 — arm doesn't need them).
# Default per-handover dedup; no --force, no --dedup-any (remote arms can't force/clobber).
# HIMMEL-1475: an explicit HH:MM rides --long-gap — a HUMAN typing a far time on
# Telegram IS the explicit choice the long-gap guard exists to force (the guard
# targets the ORCHESTRATOR silently defaulting to a far park, not a typed one).
# smart/auto are system-computed sentinels the guard exempts by design, so they
# keep the bare call shape.
ARM_CMD="${AUTO_ACTION_ARM_CMD:-bash $SCRIPT_DIR/../handover/arm-resume.sh}"
case "$TIME" in
    smart|auto) ARM_LONG_GAP="" ;;
    *)          ARM_LONG_GAP="--long-gap" ;;
esac
# ARM_CMD / ARM_LONG_GAP are an intentional command+args split — word-splitting wanted.
# shellcheck disable=SC2086
out=$(TELEGRAM_BOT_TOKEN="" TELEGRAM_OWN_POLLER="" $ARM_CMD --handover "$RESOLVED" --time "$TIME" $ARM_LONG_GAP 2>&1)
arm_rc=$?

case "$arm_rc" in
    0) exit 0 ;;
    3) echo "ERR auto-action: already armed for $(basename "$RESOLVED")" >&2; exit 5 ;;
    # rc=9 should not occur once --long-gap rides along on the HH:MM branch above,
    # but keep the honest text if it ever does (mapped to the generic failure exit).
    9) echo "ERR auto-action: arm-resume refused the long gap (rc=9): $(printf '%s' "$out" | tail -1)" >&2; exit 6 ;;
    *) echo "ERR auto-action: arm-resume failed (rc=$arm_rc): $(printf '%s' "$out" | tail -1)" >&2; exit 6 ;;
esac
