#!/usr/bin/env bash
# claude-headless.sh — the P1 chokepoint wrapper for `claude` `-p` dispatch
# (HIMMEL-2178, Chain 2a). ONE headless-claude invocation site; every other
# script that needs a headless worker calls this one instead of shelling out
# directly. Bash 3.2 safe.
#
# Load-bearing P0 findings this wrapper encodes (see
# scripts/probes/claude-p/RESULTS.md on feat/claude-p-probes, and the plan at
# handovers/yotamleo/himmel/specs/plan/claude-p-dispatch-substrate.md):
#   - Git Bash mangles a leading-slash prompt arg into a Windows path before
#     claude.exe sees it -> MSYS_NO_PATHCONV=1 around the invocation, always.
#   - A denied tool call can still exit 0 (rc reflects --max-turns exhaustion,
#     not the denial) -> permission_denials is parsed as a diagnostic, never
#     rc. The verdict on whether the dispatch "worked" comes from the
#     caller-declared ARTIFACT, checked after the session exits, never from
#     the JSON envelope alone.
#   - --json-schema needs --max-turns >= 2 or structured_output silently
#     comes back null.
# Registry: one JSON file per dispatch at $HOME/.himmel/registry/live/<id>.json
# (himmel-architecture-2026-08-28.md §3 — file-per-session, no shared-write
# store), written ONLY by this script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/kill-tree.sh
. "$SCRIPT_DIR/kill-tree.sh" || { echo "claude-headless.sh: cannot source $SCRIPT_DIR/kill-tree.sh" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: claude-headless.sh [options] < prompt-on-stdin, or --prompt-file <path>
  --role <name>             required — dispatch role (registry field)
  --ticket <id>              required — ticket ID (registry field)
  --worktree <path>          required — worktree the worker operates in (registry field)
  --artifact <path>          required — file/dir the wrapper checks for after exit
  --permission-mode <mode>   required — never 'bypassPermissions'
  --prompt-file <path>       prompt delivered on stdin (default: read stdin directly)
  --cwd <path>               dispatch cwd (default: --worktree)
  --max-turns <n>            default 2, must be >= 2
  --model <name>             optional model override
  --allowed-tools <spec>     optional --allowedTools value
  --settings <path>          optional --settings overlay path
  --json-schema-file <path>  optional --json-schema payload (file contents passed inline)
  -h, --help                 show this help

Env:
  HIMMEL_CLAUDE_BIN               claude binary/command (default: claude; tests inject a fake)
  HIMMEL_REGISTRY_DIR             registry root (default: $HOME/.himmel/registry)
  HIMMEL_DISPATCH_MAX_CONCURRENT  concurrency cap (default: 3)
  CADENCE_BANK_*                  forwarded to scripts/lib/bank-preflight.sh

On Windows/Git Bash: --worktree/--cwd/--artifact are checked with bash's own
file tests, which tolerate a POSIX-style /tmp/... path fine. But if your
PROMPT tells the model to write to that same path, use a Windows-form path
(cygpath -m) there — native claude.exe's Write tool was observed to resolve
a bare /tmp/... path unreliably (intermittently reports success without
writing), while the identical prompt with a Windows-form path did not.
USAGE
}

die() { echo "claude-headless.sh: $*" >&2; exit 1; }
need_arg() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 requires a value"; fi; }

ROLE=""; TICKET=""; WORKTREE=""; ARTIFACT=""; PERMISSION_MODE=""
PROMPT_FILE=""; CWD=""; MAX_TURNS="2"; MODEL=""; ALLOWED_TOOLS=""; SETTINGS=""
JSON_SCHEMA_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) need_arg "$@"; ROLE="$2"; shift 2 ;;
    --ticket) need_arg "$@"; TICKET="$2"; shift 2 ;;
    --worktree) need_arg "$@"; WORKTREE="$2"; shift 2 ;;
    --artifact) need_arg "$@"; ARTIFACT="$2"; shift 2 ;;
    --permission-mode) need_arg "$@"; PERMISSION_MODE="$2"; shift 2 ;;
    --prompt-file) need_arg "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --cwd) need_arg "$@"; CWD="$2"; shift 2 ;;
    --max-turns) need_arg "$@"; MAX_TURNS="$2"; shift 2 ;;
    --model) need_arg "$@"; MODEL="$2"; shift 2 ;;
    --allowed-tools) need_arg "$@"; ALLOWED_TOOLS="$2"; shift 2 ;;
    --settings) need_arg "$@"; SETTINGS="$2"; shift 2 ;;
    --json-schema-file) need_arg "$@"; JSON_SCHEMA_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$ROLE" ] || die "--role is required"
[ -n "$TICKET" ] || die "--ticket is required"
[ -n "$WORKTREE" ] || die "--worktree is required"
[ -n "$ARTIFACT" ] || die "--artifact is required"
[ -n "$PERMISSION_MODE" ] || die "--permission-mode is required"
[ "$PERMISSION_MODE" != "bypassPermissions" ] || die "--permission-mode bypassPermissions is refused; pick an explicit mode (default/plan/dontAsk/etc.)"
case "$MAX_TURNS" in *[!0-9]*|0|1) die "--max-turns must be an integer >= 2 (got '$MAX_TURNS')" ;; esac
[ -z "$PROMPT_FILE" ] || [ -r "$PROMPT_FILE" ] || die "--prompt-file not readable: $PROMPT_FILE"
[ -z "$JSON_SCHEMA_FILE" ] || [ -r "$JSON_SCHEMA_FILE" ] || die "--json-schema-file not readable: $JSON_SCHEMA_FILE"
[ -n "$CWD" ] || CWD="$WORKTREE"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v node >/dev/null 2>&1 || die "node is required"

# codex-1: the claude invocation runs as a BACKGROUND job (needed so the
# EXIT/INT/TERM trap is actually interruptible — see the invocation site
# below). A background job with no explicit stdin redirect gets /dev/null
# under `set -m`-off non-interactive bash, so the advertised "read stdin
# directly" mode (no --prompt-file) would silently deliver an EMPTY prompt
# once backgrounded. Read this script's own stdin into a file NOW, in the
# foreground, before anything is backgrounded — downstream always has a
# real PROMPT_FILE to redirect from either way.
PROMPT_FILE_IS_TEMP=0
if [ -z "$PROMPT_FILE" ]; then
  PROMPT_FILE="$(mktemp "${TMPDIR:-${TEMP:-/tmp}}/claude-headless-stdin.XXXXXX")"
  # codex-1 (CR round 8): the full finalize_on_exit trap isn't installed
  # until further down (after LIVE_DIR exists), so an interrupt during this
  # `cat` — which can block waiting on stdin — would leave this temp file
  # (potentially holding a partial/sensitive prompt) behind uncleaned.
  # A minimal early trap closes that window; the real trap below replaces it.
  # codex-1 (CR round 9): an INT/TERM trap that only removes the file and
  # does not exit lets bash fall through and CONTINUE the script past the
  # interrupted `cat` — dispatching with a deleted/partial prompt instead of
  # aborting. Exit with the same conventional codes finalize_on_exit uses.
  trap 'rm -f "$PROMPT_FILE"' EXIT
  trap 'rm -f "$PROMPT_FILE"; exit 130' INT
  trap 'rm -f "$PROMPT_FILE"; exit 143' TERM
  cat > "$PROMPT_FILE"
  PROMPT_FILE_IS_TEMP=1
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

count_active() {
  local dir="$1" n=0 f status
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    status="$(jq -r '.status // ""' "$f" 2>/dev/null)"
    case "$status" in dispatched|running) n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}

# --- registry (file-per-session, this script is the ONLY writer). Path
# computed now (a pure string op — no filesystem yet) so the trap below can
# reference LIVE_DIR/ADMISSION_LOCK; the actual mkdir happens AFTER the trap
# is registered (codex-4, final round: a failure here used to happen before
# the trap existed, leaking the just-materialized stdin temp file). ---
registry_dir() { printf '%s\n' "${HIMMEL_REGISTRY_DIR:-${HOME:-/tmp}/.himmel/registry}"; }
LIVE_DIR="$(registry_dir)/live"

# --- admission lock (codex-2): count-then-write must be atomic, or two
# concurrent dispatches can both observe a count under the cap and both
# proceed, exceeding it. Held ONLY across the count+row-write below, never
# across the claude invocation itself — that would serialize dispatches
# entirely and defeat the point of a concurrency cap > 1.
ADMISSION_LOCK="$LIVE_DIR/.admission.lock"
LOCK_HELD=0
lock_acquire() {
  local tries=0 stale_checked=0 holder_pid
  while ! mkdir "$ADMISSION_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    # codex-4: a bare mkdir-lock with no owner record blocks EVERY future
    # dispatch forever if its holder crashes/SIGKILLs mid-section. Record the
    # holder's pid inside the lock dir (below); once retries stall, reclaim
    # the lock if that pid is no longer alive. Checked once per acquire, not
    # every retry, to avoid hammering `kill -0` in the common (briefly
    # contended, not stale) case.
    if [ "$tries" -eq 20 ] && [ "$stale_checked" = "0" ]; then
      stale_checked=1
      holder_pid="$(cat "$ADMISSION_LOCK/pid" 2>/dev/null || true)"
      # codex-3 (round 4): an EMPTY/unreadable pid file (the write below
      # failed, or the holder crashed before writing it) must also count as
      # reclaimable — requiring a non-empty holder_pid meant a lock that
      # never got a valid owner recorded could never be classified as
      # stale, blocking admission permanently.
      if [ -z "$holder_pid" ] || ! kill -0 "$holder_pid" 2>/dev/null; then
        echo "claude-headless.sh: admission lock held by dead/unrecorded pid '${holder_pid:-<none>}' — reclaiming stale lock" >&2
        # ponytail: rm -rf here is a plain check-then-act, not atomic against
        # a second process reclaiming (and re-acquiring) the SAME stale lock
        # in the same narrow window — a real but doubly-rare race (requires
        # a crash AND two concurrent reclaimers in the same ~100ms poll
        # tick). Upgrade path if this ever bites: a reclaim-intent marker
        # (mkdir a sibling dir as a lock-on-the-reclaim) before the rm -rf.
        rm -rf "$ADMISSION_LOCK" 2>/dev/null || true
        continue
      fi
    fi
    [ "$tries" -lt 200 ] || die "could not acquire dispatch admission lock: $ADMISSION_LOCK"
    sleep 0.1 2>/dev/null || sleep 1
  done
  printf '%s' "$$" > "$ADMISSION_LOCK/pid" 2>/dev/null || true
  LOCK_HELD=1
}
lock_release() {
  [ "$LOCK_HELD" = "1" ] || return 0
  rm -rf "$ADMISSION_LOCK" 2>/dev/null || true
  LOCK_HELD=0
}

# --- finalize-on-exit (codex-3): a dispatch is persisted as "dispatched"
# before launch. If this process dies before the terminal row is written
# (killed, crashed), that row would otherwise stay "dispatched" forever,
# permanently consuming a concurrency slot. Mark it "interrupted" instead —
# a real terminal state, so it stops counting as active. Full staleness
# detection for a HUNG-but-still-running worker (heartbeats/TTL reaping) is
# Chain 4's job (architecture doc §3); this only covers THIS process's own
# death, which needs no heartbeat.
#
# codex-1 follow-up: marking the row terminal is not enough on its own — the
# actual claude session runs as a BACKGROUND child (_LAUNCHED_CLAUDE_PID, set
# once the invocation below launches). If only the parent dies, that child
# keeps running untracked and can keep mutating the worktree after the
# concurrency slot is released. kill_tree (scripts/lib/kill-tree.sh, sourced
# above; same shape as dispatch-lane.sh's) takes the whole process tree down
# too.
TERMINAL_WRITTEN=0
PROMPT_CLEANED=0
FINAL_RC=""
_LAUNCHED_CLAUDE_PID=""
finalize_on_exit() {
  # codex-2 (final round, suggestion): a bare `local rc=$?` reads whatever
  # the LAST COMMAND before the signal happened to leave behind — a SIGTERM
  # arriving right after a successful command exits this whole script 0,
  # masking a real interruption. The INT/TERM trap entries below pass an
  # explicit conventional code (130/143); this function remembers the FIRST
  # code it was given (FINAL_RC) so the EXIT trap's own subsequent firing
  # (calling `exit` from within a signal trap re-fires the EXIT trap) exits
  # with the SAME code instead of recomputing a fresh, wrong `$?`.
  local rc="${1:-${FINAL_RC:-$?}}" _leaked_pid
  [ -n "$FINAL_RC" ] || FINAL_RC="$rc"
  lock_release
  if [ -n "${_LAUNCHED_CLAUDE_PID:-}" ] && kill -0 "$_LAUNCHED_CLAUDE_PID" 2>/dev/null; then
    kill_tree "$_LAUNCHED_CLAUDE_PID"
  else
    # codex-6 (HIMMEL-2514, CR round 3): `( ... ) &` and the very next line
    # (`_LAUNCHED_CLAUDE_PID=$!`) are two separate commands — bash runs
    # pending traps BETWEEN commands, so a SIGTERM/SIGINT landing in that
    # exact window fires this trap while the variable is still empty, and
    # the just-forked child would otherwise be left running untracked
    # (still free to mutate the worktree after the concurrency slot is
    # released — the very thing kill_tree exists to prevent). Still
    # strictly better than the pre-fix code, where the ambient value in
    # that same window was the SESSION pid, so the same race killed the
    # launching session; this closes the residual leak, not a regression.
    # `jobs -p` (this shell's own background job table) is the fallback,
    # not `ps` + a `$$`-children scan: it can never return the ambient
    # CLAUDE_PID, which is the whole bug HIMMEL-2514 is about, so it
    # cannot reintroduce an inherited-pid surface. On every genuine
    # pre-launch refusal path (bank-preflight, concurrency cap,
    # registry-row failure, bypassPermissions) no background job has ever
    # been started, so `jobs -p` is empty and this is a no-op — verified
    # empirically, both empty pre-launch and populated after a real `&`,
    # inside a non-interactive EXIT trap on this host. One pid per line;
    # do not assume there is only ever one.
    for _leaked_pid in $(jobs -p); do
      kill -0 "$_leaked_pid" 2>/dev/null && kill_tree "$_leaked_pid"
    done
  fi
  if [ -n "${ROW:-}" ] && [ "$TERMINAL_WRITTEN" != "1" ] && [ -f "$ROW" ]; then
    jq --arg status "interrupted" --arg terminal_at "$(now_iso)" \
      '.status = $status | .terminal_at = $terminal_at' "$ROW" > "$ROW.tmp" 2>/dev/null \
      && mv "$ROW.tmp" "$ROW" 2>/dev/null
    TERMINAL_WRITTEN=1
  fi
  # codex-5 (round 4, suggestion): the materialized stdin prompt (may carry
  # sensitive content) was only cleaned on the normal post-dispatch path — a
  # bank-preflight refusal, admission refusal, or interruption before that
  # point left it behind in the OS temp dir. Clean it here instead, on
  # every exit path, exactly once.
  if [ "${PROMPT_FILE_IS_TEMP:-0}" = "1" ] && [ "$PROMPT_CLEANED" != "1" ]; then
    rm -f "${PROMPT_FILE:-}" 2>/dev/null
    PROMPT_CLEANED=1
  fi
  # codex-3 (final round, suggestion): STDOUT_FILE/STDERR_FILE (assigned
  # later, once the invocation is assembled) can carry the model's raw
  # output and diagnostics — an interruption before their normal
  # post-invocation cleanup left them behind too. `${VAR:-}` is safe here
  # even before those variables are assigned (not yet reached this run);
  # rm -f on an empty/already-removed path is a harmless no-op, so this is
  # also safe to run again on the normal exit path.
  rm -f "${STDOUT_FILE:-}" "${STDERR_FILE:-}" 2>/dev/null
  exit "$FINAL_RC"
}
trap finalize_on_exit EXIT
trap 'finalize_on_exit 130' INT
trap 'finalize_on_exit 143' TERM

# codex-4 (final round, suggestion): the trap is now registered BEFORE this
# mkdir — previously it ran before the trap existed, so a failure here
# (die, below) exited without ever cleaning up the just-materialized stdin
# temp file above.
mkdir -p "$LIVE_DIR" || die "could not create registry dir: $LIVE_DIR"

# --- bank preflight (mandatory, before anything is dispatched) ---
BANK_VERDICT="$(CADENCE_BANK_LEG="${CADENCE_BANK_LEG:-claude-headless:$ROLE}" bash "$REPO_ROOT/scripts/lib/bank-preflight.sh")"
[ "$BANK_VERDICT" = "PROCEED" ] || die "bank preflight refused dispatch (verdict: $BANK_VERDICT); refusing to spend"

# --- capture the artifact's pre-dispatch state, so a stale pre-existing
# file/dir at the same path cannot pass the post-dispatch check (a failed or
# denied dispatch that touches nothing must not read as "completed" just
# because something was already sitting at that path). ---
# codex-2 (round 2): whole-second mtimes (`%s`) miss a pre-existing artifact
# rewritten within the SAME second — a real case for a fast dispatch. `%s.%N`
# (GNU date, which Git Bash ships) gives nanosecond resolution instead.
# codex-2 (round 3): for a pre-existing DIRECTORY, a file's own mtime is what
# advances when its content changes — the directory's own mtime does NOT
# (on NTFS and most filesystems, a directory's mtime only tracks entries
# being added/removed/renamed, not content changes to files already inside
# it). So compare the newest mtime among the files INSIDE the directory,
# not the directory entry itself.
# codex-1 (round 4): a directory containing only subdirectories (no regular
# files anywhere in its tree) yields no `find -type f` output at all, so the
# scan above returned empty — read by artifact_present() as "no baseline",
# which skips the freshness check entirely and lets an untouched pre-existing
# directory pass. Fall back to the directory's own mtime in that case (still
# catches entries being added/removed, even without a content-bearing file
# to compare).
# ponytail (codex-3, final round): the MAX-across-descendants approach means
# a pre-existing file with a bogus future-dated mtime (clock skew, a
# preserved timestamp from a git checkout, etc.) could dominate the max on
# both sides of the comparison and mask a genuine same-run update to a
# DIFFERENT, older file — a real gap, but it needs an already-abnormal
# precondition (a future timestamp already sitting in the tree) to matter.
# Upgrade path if this ever bites: content-hash the tree instead of trusting
# mtimes at all (sha over a sorted per-file digest list, same shape as
# scripts/statusline/check-hud-drift.sh's own drift hash) — more correct,
# meaningfully more expensive per check, not worth it until this is real.
artifact_mtime() {
  local path="$1" newest
  if [ -d "$path" ]; then
    newest="$(find "$path" -type f -exec date -r {} '+%s.%N' \; 2>/dev/null | sort -rn | head -1)"
    if [ -n "$newest" ]; then printf '%s' "$newest"; else date -r "$path" '+%s.%N' 2>/dev/null || true; fi
  else
    date -r "$path" '+%s.%N' 2>/dev/null || true
  fi
}
ARTIFACT_PRE_MTIME=""
if [ -e "$ARTIFACT" ]; then ARTIFACT_PRE_MTIME="$(artifact_mtime "$ARTIFACT")"; fi

# --- concurrency guard + dispatch-time row write (one admission-locked section) ---
CAP="${HIMMEL_DISPATCH_MAX_CONCURRENT:-3}"
# codex-3: an unvalidated CAP makes the `-ge` test below error (not a normal
# false) on a malformed value, and `if` reads a test's error the same as
# "false" — which FAIL-OPENS the cap (every dispatch proceeds, uncapped).
case "$CAP" in ''|*[!0-9]*) echo "claude-headless.sh: invalid HIMMEL_DISPATCH_MAX_CONCURRENT '$CAP', falling back to 3" >&2; CAP=3 ;; esac
lock_acquire
ACTIVE="$(count_active "$LIVE_DIR")"
if [ "$ACTIVE" -ge "$CAP" ]; then
  lock_release
  die "concurrency cap reached ($ACTIVE/$CAP active dispatches in $LIVE_DIR)"
fi
ID="$(node -e "process.stdout.write(require('crypto').randomUUID())")" || { lock_release; die "could not generate dispatch id"; }
ROW="$LIVE_DIR/$ID.json"
jq -n --arg id "$ID" --arg role "$ROLE" --arg worktree "$WORKTREE" --arg ticket "$TICKET" \
  --arg dispatched_at "$(now_iso)" --arg artifact "$ARTIFACT" \
  '{id:$id, role:$role, worktree:$worktree, ticket:$ticket, status:"dispatched",
    dispatched_at:$dispatched_at, terminal_at:null, artifact:$artifact,
    outcome:null, artifact_check:null}' > "$ROW.tmp" || { lock_release; die "could not write registry row: $ROW"; }
mv "$ROW.tmp" "$ROW" || { lock_release; die "could not write registry row: $ROW"; }
lock_release

# --- assemble and run the headless invocation ---
JSON_SCHEMA=""
if [ -n "$JSON_SCHEMA_FILE" ]; then JSON_SCHEMA="$(cat "$JSON_SCHEMA_FILE")"; fi

CLAUDE_BIN="${HIMMEL_CLAUDE_BIN:-claude}"
CMD=("$CLAUDE_BIN" -p --output-format json --permission-mode "$PERMISSION_MODE" --max-turns "$MAX_TURNS")
[ -z "$MODEL" ] || CMD+=(--model "$MODEL")
[ -z "$ALLOWED_TOOLS" ] || CMD+=(--allowedTools "$ALLOWED_TOOLS")
if [ -n "$SETTINGS" ]; then
  # codex-4: MSYS_NO_PATHCONV=1 (below) disables Git Bash's automatic
  # POSIX->Windows path rewrite for EVERY argv element, not just the prompt —
  # so an ordinary Git-Bash path (e.g. /c/Users/...) reaches claude.exe (a
  # native Windows binary) unconverted and it cannot find the file. Convert
  # explicitly (same idiom dispatch-lane.sh's normalize_path uses).
  if command -v cygpath >/dev/null 2>&1; then SETTINGS="$(cygpath -m "$SETTINGS")"; fi
  CMD+=(--settings "$SETTINGS")
fi
[ -z "$JSON_SCHEMA" ] || CMD+=(--json-schema "$JSON_SCHEMA")

STDERR_FILE="$(mktemp "${TMPDIR:-${TEMP:-/tmp}}/claude-headless-stderr.XXXXXX")"
STDOUT_FILE="$(mktemp "${TMPDIR:-${TEMP:-/tmp}}/claude-headless-stdout.XXXXXX")"

# headless-claude-ok: HIMMEL-2178 Chain 2a dispatch wrapper — the sanctioned
# chokepoint for headless `claude -p`; bank-preflight (above) + concurrency
# guard (above) + artifact-check (below) gate every call, and
# native_auth_pin_env (native-auth-pin.sh, HIMMEL-1867) strips any ambient
# ANTHROPIC_*/CLAUDE_CODE_USE_* proxy env right before the launch so this
# stays on native subscription auth. rc is diagnostic only (P0: a denial can
# exit 0) — the verdict comes from the artifact check, not this exit code.
#
# Launched as a background job + explicit `wait`, NOT `ENVELOPE="$(...)"`
# (codex-3 follow-up, verified empirically): bash defers this script's
# EXIT/INT/TERM trap while blocked inside a foreground command
# substitution's wait — a SIGTERM during the entire multi-second/minute
# claude session (the most likely time to be interrupted) never reached
# finalize_on_exit, leaving the dispatch row permanently "dispatched". A
# background job + `wait "$pid"` IS promptly interruptible.
# shellcheck disable=SC1091
( cd "$CWD" && . "$REPO_ROOT/scripts/lib/native-auth-pin.sh" && native_auth_pin_env && \
  MSYS_NO_PATHCONV=1 "${CMD[@]}" < "$PROMPT_FILE" \
  >"$STDOUT_FILE" 2>"$STDERR_FILE" ) &
# HIMMEL-2514: deliberately NOT named CLAUDE_PID — an interactive Claude Code
# session exports its OWN pid into every subprocess under that exact name, so
# any pre-launch refusal (bank-preflight, concurrency cap, a registry-row
# write failure) would have finalize_on_exit read the ambient value and
# kill_tree the session that launched this wrapper, not the child it spawned.
_LAUNCHED_CLAUDE_PID=$!
wait "$_LAUNCHED_CLAUDE_PID"
RC=$?
ENVELOPE="$(cat "$STDOUT_FILE" 2>/dev/null)"
rm -f "$STDOUT_FILE"
# (temp prompt file cleanup moved into finalize_on_exit — see codex-5 round 4)

# codex-5: structured_output (the --json-schema-file contract) was being
# read off the envelope and then discarded — a caller that asked for a
# schema-conformant result had no way to get it back. Carry it through.
if OUTCOME="$(printf '%s' "$ENVELOPE" | jq -c --argjson rc "$RC" \
    '{rc:$rc, is_error:.is_error, permission_denials:(.permission_denials // []), num_turns:(.num_turns // null), session_id:(.session_id // null), structured_output:(.structured_output // null)}' 2>/dev/null)" \
  && [ -n "$OUTCOME" ]; then
  :
else
  OUTCOME="$(jq -n --argjson rc "$RC" --rawfile stderr "$STDERR_FILE" \
    '{rc:$rc, is_error:true, permission_denials:[], num_turns:null, session_id:null, structured_output:null, parse_error:"invalid or empty JSON envelope", stderr_tail:($stderr | .[-500:])}')"
fi
rm -f "$STDERR_FILE"

# --- artifact check: the verdict comes from the artifact, never rc/envelope.
# A path that existed BEFORE dispatch only counts if its mtime advanced
# during this run (codex-1) — otherwise a stale leftover from an earlier
# run, or an unrelated pre-existing file, would trivially pass. ---
artifact_present() {
  local path="$1" pre_mtime="$2" post_mtime
  if [ -d "$path" ]; then
    [ -n "$(ls -A "$path" 2>/dev/null)" ] || return 1
  elif [ -f "$path" ]; then
    [ -s "$path" ] || return 1
  else
    return 1
  fi
  [ -n "$pre_mtime" ] || return 0
  post_mtime="$(artifact_mtime "$path")"
  [ -n "$post_mtime" ] || return 1
  awk -v a="$post_mtime" -v b="$pre_mtime" 'BEGIN{exit !(a>b)}'
}
if artifact_present "$ARTIFACT" "$ARTIFACT_PRE_MTIME"; then
  ARTIFACT_VERDICT="pass"; STATUS="completed"
else
  ARTIFACT_VERDICT="fail"; STATUS="artifact-missing"
fi
ARTIFACT_CHECK="$(jq -n --arg path "$ARTIFACT" --arg verdict "$ARTIFACT_VERDICT" --arg checked_at "$(now_iso)" \
  '{path:$path, verdict:$verdict, checked_at:$checked_at}')"

# --- write the terminal row (same file, this script is still the only writer) ---
jq --arg status "$STATUS" --arg terminal_at "$(now_iso)" --argjson outcome "$OUTCOME" --argjson artifact_check "$ARTIFACT_CHECK" \
  '.status = $status | .terminal_at = $terminal_at | .outcome = $outcome | .artifact_check = $artifact_check' \
  "$ROW" > "$ROW.tmp" || die "could not write terminal registry row: $ROW"
mv "$ROW.tmp" "$ROW" || die "could not write terminal registry row: $ROW"
TERMINAL_WRITTEN=1

echo "claude-headless.sh: id=$ID status=$STATUS artifact_check=$ARTIFACT_VERDICT registry=$ROW" >&2
[ "$STATUS" = "completed" ]
