#!/usr/bin/env bash
# hook-smoke-demo.sh - HIMMEL-2000. End-to-end smoke of the PROJECT hook chain
# in BOTH harnesses, run against a disposable clone of the himmel checkout.
#
# WHY: every recent change to the hook plumbing (HIMMEL-1981/1982/1985/1987/1989)
# can break a session's hooks SILENTLY - a hook that no longer runs fails OPEN
# and nothing in the transcript says so. The unit suites cover each adapter in
# isolation; nothing proved that a REAL session still starts, runs a tool call
# and stops with zero hook failures. This is that proof, and it runs on a THROW-
# AWAY clone so a broken hook set can never touch the real checkout.
#
# Four legs (each independently skippable when its binary is absent):
#   codex-exec     `codex exec` with a trivial read-only prompt -> exit 0, DONE
#                  in the reply, and no hook-failure banner in stdout/stderr or
#                  the session rollout.
#   codex-replay   scripts/codex/probe-codex-hooks.ps1 -Replay against the demo
#                  dir -> 0 FAIL among PROJECT hooks. This is the positive
#                  control for the codex side: it actually EXECUTES every hook,
#                  so it distinguishes "clean" from "never fired".
#   claude-print   the claude CLI in print mode, same prompt -> same three
#                  assertions.
#   claude-replay  every .claude/settings.json PreToolUse hook that routes
#                  through run-hook-with-bash.js is fed a canned benign payload
#                  and must exit 0 - a 2 there is a guardrail blocking something
#                  benign, which is itself a break. Positive control for the
#                  Claude side / HIMMEL-1985 runner wiring.
#
# `--from <path>` points the clone at a WORKTREE instead of the primary, which
# is the main intended use: smoke a branch BEFORE it merges.
#
# TRUST BOUNDARY - read this before pointing --from anywhere. Running the hook
# chain IS the job, so every leg executes the hook commands of the checkout it
# was given, unsandboxed, on this host. The disposable clone protects the real
# CHECKOUT from a broken hook set; it is not a sandbox and never claimed to be
# one. Point --from only at a branch you would open interactively - the same
# bar as `cd`-ing into that worktree and starting a session there. The one
# place this script does refuse to trust the branch is the agent prompt: it
# tells the agent to read the runner-authored DEMO-PROJECT.md, never a tracked
# file, so branch content cannot be fed into a live turn as instructions.
#
# Scope: this is a SMOKE, not a suite. It proves the chain fires clean; it does
# NOT re-prove per-guardrail semantics (those have their own suites).
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

FROM="$REPO"
KEEP=0
LEG_TIMEOUT=180
RUN_CODEX=1
RUN_CLAUDE=1

usage() {
    cat <<'USAGE'
Usage: hook-smoke-demo.sh [--from <repo-or-worktree>] [--keep] [--timeout <sec>]
                          [--codex-only | --claude-only]

  --from PATH     Clone this checkout instead of the primary (smoke a branch
                  before it merges). Default: the repo this script lives in.
  --keep          Keep the demo dir for post-mortem (default: remove it).
  --timeout SEC   Per-agent-leg timeout (default 180).
  --codex-only    Skip the two Claude legs.
  --claude-only   Skip the two Codex legs.

Env:
  HOOK_SMOKE_REPLAY_TIMEOUT   per-hook bound for the claude-replay leg
                              (default 30, the largest timeout any
                              .claude/settings.json entry declares).

Exit: 0 all ran legs passed, 1 a leg FAILED, 2 a usage/setup error or a
      vacuous pass - nothing ran at all, or an agent leg ran without the
      replay leg that proves its hooks actually fired.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
        --keep) KEEP=1; shift ;;
        --timeout) LEG_TIMEOUT="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
        --codex-only) RUN_CLAUDE=0; shift ;;
        --claude-only) RUN_CODEX=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "hook-smoke-demo: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# Positive, not merely numeric: GNU `timeout 0` DISABLES the bound, so a 0 here
# would quietly turn a hung leg into an indefinite stall - the opposite of what
# a timeout flag is for.
case "$LEG_TIMEOUT" in ''|*[!0-9]*) LEG_TIMEOUT=0 ;; esac
[ "$LEG_TIMEOUT" -ge 1 ] 2>/dev/null || { echo "hook-smoke-demo: --timeout must be a positive integer" >&2; exit 2; }
# Per-hook bound for the claude-replay leg; 30s is the largest timeout any entry
# in .claude/settings.json declares. Overridable so the pinning suite can prove
# the bound without a 30s sleep.
REPLAY_TIMEOUT="${HOOK_SMOKE_REPLAY_TIMEOUT:-30}"
case "$REPLAY_TIMEOUT" in ''|*[!0-9]*) REPLAY_TIMEOUT=0 ;; esac
[ "$REPLAY_TIMEOUT" -ge 1 ] 2>/dev/null || { echo "hook-smoke-demo: HOOK_SMOKE_REPLAY_TIMEOUT must be a positive integer" >&2; exit 2; }
[ "$RUN_CODEX$RUN_CLAUDE" = "00" ] && { echo "hook-smoke-demo: --codex-only and --claude-only are mutually exclusive" >&2; exit 2; }
[ -n "$FROM" ] || { echo "hook-smoke-demo: --from needs a path" >&2; exit 2; }
[ -d "$FROM" ] || { echo "hook-smoke-demo: --from '$FROM' is not a directory" >&2; exit 2; }
# A worktree has .git as a FILE (a gitdir pointer); both shapes clone fine.
[ -e "$FROM/.git" ] || { echo "hook-smoke-demo: --from '$FROM' is not a git checkout" >&2; exit 2; }

# --- scratch root -----------------------------------------------------------
# TMPDIR is the Git-Bash-native POSIX path; %TEMP% is a Windows path that only
# a cygpath translation makes usable here. /tmp is the last resort.
SCRATCH="${TMPDIR:-}"
if [ -z "$SCRATCH" ] && [ -n "${TEMP:-}" ]; then
    if command -v cygpath >/dev/null 2>&1; then SCRATCH="$(cygpath -u "$TEMP" 2>/dev/null || true)"; else SCRATCH="$TEMP"; fi
fi
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || SCRATCH=/tmp
DEMO="$SCRATCH/himmel-hook-demo-$(date +%Y%m%d-%H%M%S)-$$"

# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap below
cleanup() {
    if [ "$KEEP" = "1" ]; then echo "hook-smoke-demo: demo kept at $DEMO"; return 0; fi
    [ -n "${DEMO:-}" ] && [ -d "$DEMO" ] || return 0
    # git marks the files in .git/objects read-only; on Windows a plain delete
    # leaves them behind. Make them writable first.
    chmod -R u+w "$DEMO" 2>/dev/null || true
    rm -r -f "$DEMO" 2>/dev/null || true
}
# Claim the path ATOMICALLY before arming the trap. Plain `mkdir` (never -p)
# fails if anything is already there, so the runner can only ever delete a
# directory it created itself - a timestamp+PID name is predictable enough to
# collide with a `--keep` leftover, and the trap would have removed it.
mkdir "$DEMO" 2>/dev/null || {
    echo "hook-smoke-demo: $DEMO already exists - refusing to reuse or remove it" >&2
    exit 2
}
trap cleanup EXIT

echo "hook-smoke-demo: cloning $FROM -> $DEMO"
# --no-hardlinks is the whole point of cloning: plain --local HARDLINKS the
# object files into the source repo's store, so a hook running in the demo could
# reach back and corrupt the real checkout - exactly the isolation this script
# claims. Copying costs a few seconds against a ~90s run. (--depth is silently
# ignored for local clones, so it is deliberately not passed.)
git clone --local --no-hardlinks --quiet "$FROM" "$DEMO" 2>&1 \
    || { echo "hook-smoke-demo: clone failed" >&2; exit 2; }

# The instruction files are branch-controlled and BOTH harnesses auto-load them,
# so under --from they are a direct channel from an untrusted branch into the
# agent's system prompt. They have nothing to do with the hook chain under test,
# so the demo simply does without them - EVERY one of them, repo-wide: the
# nested subtree CLAUDE.md files load as soon as the agent touches their
# directory, and CLAUDE.local.md / .claude/rules are auto-loaded too.
find "$DEMO" \( -name 'CLAUDE.md' -o -name 'CLAUDE.local.md' \
    -o -name 'AGENTS.md' -o -name 'AGENTS.local.md' \) -type f -delete 2>/dev/null || true
rm -r -f "$DEMO/.claude/rules" 2>/dev/null || true

# Two per-run secrets the agent can only produce by ACTUALLY calling tools: the
# clone's short HEAD (a shell call) and a random token that exists nowhere but
# the runner-written file (a file read - Read, or a shell read; either fires the
# PreToolUse chain, which is what is under test, so the check deliberately does
# not care which tool was used). A reply carrying both proves tool calls
# happened, and that is what makes "no hook banner" mean anything - a model that
# just answers DONE fires no hooks at all.
SMOKE_SHA="$(git -C "$DEMO" rev-parse --short HEAD 2>/dev/null || true)"
# No sha means no shell-call proof for either agent leg. Fail here rather than
# quietly running with one of the two proofs disabled.
[ -n "$SMOKE_SHA" ] || { echo "hook-smoke-demo: cannot read HEAD in the clone" >&2; exit 2; }
SMOKE_TOKEN="smk-$(date +%s)-${RANDOM}${RANDOM}"

cat > "$DEMO/DEMO-PROJECT.md" <<EOF
# DEMO PROJECT - DISPOSABLE

Throwaway clone created by \`scripts/codex/hook-smoke-demo.sh\` (HIMMEL-2000) to
smoke the project hook chain. Source: \`$FROM\`. Nothing here is authoritative;
the runner deletes this directory unless it was given \`--keep\`.

Do not commit from here, do not arm anything from here.

SMOKE-TOKEN: $SMOKE_TOKEN
EOF

# --- make the side-effecting hooks inert ------------------------------------
# Documented opt-outs only - no invented knobs. Everything else is inert by
# construction: .env is gitignored, so the clone carries NO Jira/Telegram
# credentials at all, and scripts/jira/dist/ (an untracked build artifact) does
# not exist in the clone either.
#   HIMMEL_INITIATIVE/_OVERNIGHT  empty -> inject-initiative + jira-nudge legs off
#   HIMMEL_JIRA_NUDGE=0           jira-nudge-on-end.sh gate (default OFF anyway)
#   CLAUDE_END_SESSION_WIKI=0     end-session-wiki.sh documented env opt-out
#   AUTO_ARM_DISABLE=1            auto-arm-on-cap.sh kill switch - nothing this
#                                 demo does may ever arm a scheduled session
INERT_ENV=(
    HIMMEL_INITIATIVE=
    HIMMEL_INITIATIVE_OVERNIGHT=
    HIMMEL_OVERNIGHT=
    HIMMEL_JIRA_NUDGE=0
    CLAUDE_END_SESSION_WIKI=0
    AUTO_ARM_DISABLE=1
)

# Feature flags are not enough on their own: a hook that is broken - or newly
# side-effecting - can only reach Jira/Telegram/Obsidian if the CREDENTIAL is in
# its environment, so blank those too, along with the common cloud carriers. A
# PREFIX/SUFFIX rule rather than a list, for the reason
# scripts/lib/native-auth-pin.sh gives: an enumeration silently misses the next
# key someone adds.
#
# This is defence in depth against a hook that MISBEHAVES, not containment of a
# hostile branch: env is only one of many credential channels (CLI credential
# stores, config files, an inherited agent socket) and closing all of them is
# out of scope by design - see TRUST BOUNDARY at the top.
#
# CLAUDE_*/ANTHROPIC_* are deliberately excluded. Blanking CLAUDE_CODE_OAUTH_TOKEN
# would break the very lane the claude leg needs, and an EMPTY ANTHROPIC_API_KEY
# is itself a load-bearing routed-auth shape (native-auth-pin.sh) - that family
# is native_auth_pin_env's job, and it UNSETS rather than empties.
while IFS='=' read -r _name _; do
    case "$_name" in
        CLAUDE_*|ANTHROPIC_*) continue ;;
        TELEGRAM_*|JIRA_*|ATLASSIAN_*|OBSIDIAN_*|AWS_*|GOOGLE_*|GCP_*|AZURE_*|OPENAI_*\
        |*_TOKEN|*_API_KEY|*_SECRET|*_PASSWORD|*_CREDENTIALS|SSH_AUTH_SOCK)
            INERT_ENV+=("$_name=") ;;
    esac
done <<EOF
$(env 2>/dev/null)
EOF

# The file the agent is told to read is the one the RUNNER wrote, never a
# tracked file: README.md is branch-controlled, and under --from that is an
# untrusted branch writing text straight into a live agent turn. The shell
# command is `rev-parse`, not `log --oneline`, for the same reason in the other
# direction: a commit SUBJECT lands in the transcript, and in this repo a
# subject about hook failures would trip the banner scan.
PROMPT="Run exactly this shell command: git -C . rev-parse --short HEAD
Then read DEMO-PROJECT.md and find the line beginning with SMOKE-TOKEN:.
Then reply with exactly three words: DONE, the command's output, and the token."

# A hook-failure banner. A deliberate guardrail BLOCK also matches ("hook
# error: ... refused") and that is intentional: the prompt above is read-only
# and benign, so a guardrail firing on it is itself a break worth failing on.
BANNER_RE='hook (\(failed\)|failed|error|timed out)|hook timed out|hook exited with code|non-blocking status code'

# --- results table ----------------------------------------------------------
ROWS=()
FAILED=0
RAN=0

row() { # name result hooks failures seconds note
    ROWS+=("$1|$2|$3|$4|${5}s|${6:-}")
    [ "$2" = "FAIL" ] && FAILED=$((FAILED + 1))
    [ "$2" = "SKIP" ] || RAN=$((RAN + 1))
    return 0
}

# assert_agent_leg <name> <rc> <logfile> <reply-file> <seconds>
#                  [<extra-failures> <extra-note>]
#
# The DONE check reads the REPLY file only, never the log: the prompt itself
# ends in the word DONE, and both the codex transcript and the folded-in
# rollout echo the prompt back - a log-wide grep would pass on a turn that
# produced no answer at all.
assert_agent_leg() {
    _name=$1; _rc=$2; _log=$3; _reply=$4; _secs=$5
    _fails=0; _note=""
    if [ "$_rc" -ne 0 ]; then _fails=$((_fails + 1)); _note="exit $_rc"; fi
    # Whole word, and not negated: an unanchored substring search accepts
    # `UNDONE` and `NOT DONE` as a completed turn. Deliberately NOT an exact
    # "the reply is the single token DONE" match - what is under test is the
    # hook chain, and pinning a green smoke to a model's formatting habits
    # ("Completed: DONE") buys flakiness, not coverage.
    if ! grep -qE '(^|[^[:alnum:]_])DONE([^[:alnum:]_]|$)' "$_reply" 2>/dev/null \
        || grep -qiE '(^|[^[:alnum:]_])(not|never|un|cannot|failed)[[:space:]_-]*done' "$_reply" 2>/dev/null; then
        _fails=$((_fails + 1)); _note="${_note:+$_note; }no DONE in reply"
    fi
    # Tool-call proof. Without these two, DONE only says the model answered -
    # and a turn with no tool calls fires no PreToolUse hooks at all, so "no
    # banner" would be true of a run that tested nothing.
    if ! grep -q -F "$SMOKE_SHA" "$_reply" 2>/dev/null; then
        _fails=$((_fails + 1)); _note="${_note:+$_note; }no shell-call proof (HEAD sha absent)"
    fi
    if ! grep -q -F "$SMOKE_TOKEN" "$_reply" 2>/dev/null; then
        _fails=$((_fails + 1)); _note="${_note:+$_note; }no file-read proof (token absent)"
    fi
    if [ "${6:-0}" -gt 0 ]; then
        _fails=$((_fails + ${6:-0})); _note="${_note:+$_note; }${7:-extra failure}"
    fi
    # Case-insensitive: harnesses capitalise these banners inconsistently.
    _banners=$(grep -i -c -E "$BANNER_RE" "$_log" 2>/dev/null || true)
    case "$_banners" in ''|*[!0-9]*) _banners=0 ;; esac
    if [ "$_banners" -gt 0 ]; then
        _fails=$((_fails + 1)); _note="${_note:+$_note; }$_banners hook banner(s)"
    fi
    if [ "$_fails" -eq 0 ]; then row "$_name" PASS - 0 "$_secs" "$_note"
    else row "$_name" FAIL - "$_fails" "$_secs" "$_note"; fi
}

# ============================================================ codex-exec =====
if [ "$RUN_CODEX" = "1" ] && command -v codex >/dev/null 2>&1; then
    echo "hook-smoke-demo: codex-exec leg (timeout ${LEG_TIMEOUT}s)"
    CX_LOG="$DEMO/.smoke-codex.log"
    CX_REPLY="$DEMO/.smoke-codex-reply.txt"
    : > "$CX_REPLY"
    CX_START=$(date +%s)
    # --dangerously-bypass-hook-trust is REQUIRED, not a shortcut: Codex keys
    # hook trust to the ABSOLUTE hooks.json path (~/.codex/config.toml
    # [hooks.state.'<abs path>:<event>:<i>:<j>']), so a fresh clone at a fresh
    # path is untrusted and its hooks would silently NOT RUN - a vacuous pass,
    # the exact failure this smoke exists to catch. The hook source is one we
    # just cloned ourselves from the checkout under test, which is precisely
    # the "automation that already vets hook sources" the flag documents.
    # The sandbox stays read-only regardless.
    env "${INERT_ENV[@]}" timeout "$LEG_TIMEOUT" \
        codex exec --skip-git-repo-check -C "$DEMO" -s read-only \
        --dangerously-bypass-hook-trust -o "$CX_REPLY" "$PROMPT" \
        > "$CX_LOG" 2>&1
    CX_RC=$?
    CX_SECS=$(( $(date +%s) - CX_START ))
    # Codex renders hook-failure banners in the TUI; in non-interactive exec the
    # durable record is the session rollout. Fold OUR rollout into the same grep
    # target - identified by content, not by "newest file wins": a concurrent
    # codex session would otherwise hand us the wrong transcript and hide a real
    # banner. The demo dir's BASENAME is unique per run and appears in the
    # rollout's cwd, so it is the selector - the basename rather than the full
    # path because the rollout records the Windows form of it.
    CX_TAG="${DEMO##*/}"
    CX_ROLLS="$DEMO/.smoke-codex-rollouts.txt"
    : > "$CX_ROLLS"
    # CODEX_HOME relocates the whole codex state dir; hardcoding ~/.codex would
    # make every otherwise-clean run on such an install fail the rollout check.
    find "${CODEX_HOME:-$HOME/.codex}/sessions" -name '*.jsonl' -newermt "@$CX_START" 2>/dev/null \
    | while IFS= read -r _roll; do
        [ -r "$_roll" ] || continue
        grep -q -F "$CX_TAG" "$_roll" 2>/dev/null || continue
        cat "$_roll" >> "$CX_LOG" 2>/dev/null
        printf '%s\n' "$_roll" >> "$CX_ROLLS"
    done
    # The rollout is documented as the durable record of hook-failure banners in
    # non-interactive exec, so NOT finding ours is a failure, not a quiet skip:
    # it means the banner scan silently covered only stdout/stderr. If Codex ever
    # relocates or stops writing rollouts, this canary says so instead of
    # degrading to a weaker check nobody notices.
    CX_NROLL=$(grep -c . "$CX_ROLLS" 2>/dev/null || true)
    case "$CX_NROLL" in ''|*[!0-9]*) CX_NROLL=0 ;; esac
    if [ "$CX_NROLL" -gt 0 ]; then
        assert_agent_leg codex-exec "$CX_RC" "$CX_LOG" "$CX_REPLY" "$CX_SECS"
    else
        assert_agent_leg codex-exec "$CX_RC" "$CX_LOG" "$CX_REPLY" "$CX_SECS" 1 "no session rollout matched - banner scan covered stdout only"
    fi
elif [ "$RUN_CODEX" = "1" ]; then
    row codex-exec SKIP - 0 0 "codex not on PATH"
fi

# ========================================================== codex-replay =====
if [ "$RUN_CODEX" = "1" ] && command -v pwsh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "hook-smoke-demo: codex-replay leg"
    RP_LOG="$DEMO/.smoke-codex-replay.log"
    RP_JSON="$DEMO/.smoke-codex-replay.json"
    RP_START=$(date +%s)
    # pwsh needs Windows paths; $DEMO is the Git-Bash POSIX form.
    RP_DEMO_WIN="$DEMO"; RP_JSON_WIN="$RP_JSON"
    if command -v cygpath >/dev/null 2>&1; then
        RP_DEMO_WIN="$(cygpath -w "$DEMO")"
        RP_JSON_WIN="$(cygpath -w "$RP_JSON")"
    fi
    # -NoFail: the probe exits 1 on ANY FAIL row including PLUGIN hooks we do
    # not own (superpowers et al). The -Json dump below is the assertion, and it
    # is parsed rather than the two printed tables - both tables carry a
    # `project` column value, so a line grep would double-count them.
    # INERT_ENV matters MORE here than in the agent legs: -Replay executes the
    # Stop/SessionStart hooks too (jira-nudge-on-end, end-session-wiki,
    # auto-arm), and those are exactly the ones with outward side effects. The
    # probe copies the current process environment into each hook child, so the
    # prefix reaches them.
    env "${INERT_ENV[@]}" pwsh -NoProfile -File "$RP_DEMO_WIN\\scripts\\codex\\probe-codex-hooks.ps1" \
        -Project "$RP_DEMO_WIN" -Replay -NoFail -Json "$RP_JSON_WIN" > "$RP_LOG" 2>&1
    RP_SECS=$(( $(date +%s) - RP_START ))
    RP_HOOKS=$(jq -r '[.rows[]? | select(.source == "project")] | length' "$RP_JSON" 2>/dev/null || true)
    RP_RAN=$(jq -r '[.replayResults[]? | select(.source == "project")] | length' "$RP_JSON" 2>/dev/null || true)
    # A project hook fails the replay if the static lint flagged it FAIL:* or if
    # executing it for real returned anything but `ok` (rc=N / TIMEOUT).
    RP_FAIL=$(jq -r '
        ([.rows[]? | select(.source == "project") | .findings[]? | select(startswith("FAIL:"))] | length)
      + ([.replayResults[]? | select(.source == "project") | select(.result != "ok")] | length)' \
        "$RP_JSON" 2>/dev/null || true)
    RP_NOTE=$(jq -r '[.replayResults[]? | select(.source == "project") | select(.result != "ok") | .result] | unique | join(",")' "$RP_JSON" 2>/dev/null || true)
    case "$RP_FAIL" in ''|*[!0-9]*) RP_FAIL=0 ;; esac
    case "$RP_HOOKS" in ''|*[!0-9]*) RP_HOOKS=0 ;; esac
    case "$RP_RAN" in ''|*[!0-9]*) RP_RAN=0 ;; esac
    if [ "$RP_HOOKS" -eq 0 ]; then
        row codex-replay FAIL 0 1 "$RP_SECS" "probe enumerated no project hooks"
    elif [ "$RP_RAN" -lt "$RP_HOOKS" ]; then
        # Every enumerated project hook must have an EXECUTION result. A short
        # replayResults list means hooks were listed but never run, and an
        # unexecuted hook contributes zero failures - the vacuous pass this leg
        # exists to rule out.
        row codex-replay FAIL "$RP_HOOKS" $((RP_HOOKS - RP_RAN)) "$RP_SECS" "only $RP_RAN/$RP_HOOKS project hooks replayed"
    elif [ "$RP_FAIL" -eq 0 ]; then
        row codex-replay PASS "$RP_HOOKS" 0 "$RP_SECS" ""
    else
        row codex-replay FAIL "$RP_HOOKS" "$RP_FAIL" "$RP_SECS" "${RP_NOTE:-lint FAIL}"
    fi
elif [ "$RUN_CODEX" = "1" ]; then
    row codex-replay SKIP - 0 0 "pwsh or jq missing"
fi

# ========================================================= claude-print ======
if [ "$RUN_CLAUDE" = "1" ] && command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    BANK=$(bash "$REPO/scripts/lib/bank-preflight.sh" 2>/dev/null | tail -1)
    # Ambient proxy exports must not redirect this Max-plan launch
    # (HIMMEL-1867). FAIL CLOSED: an unpinned launch can be routed through a
    # local proxy - wrong auth, wrong billing, no error - so if the pin cannot
    # be applied the leg is SKIPPED rather than spent, never silently launched.
    PIN_OK=1
    # shellcheck source=scripts/lib/native-auth-pin.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/native-auth-pin.sh" 2>/dev/null || PIN_OK=0
    [ "$PIN_OK" = "1" ] && { native_auth_pin_env || PIN_OK=0; }
    if [ "$PIN_OK" != "1" ]; then
        row claude-print SKIP - 0 0 "native-auth pin unavailable"
    elif [ "$BANK" = "PROCEED" ] || [ "$BANK" = "BANK-UNKNOWN" ]; then
        echo "hook-smoke-demo: claude-print leg (bank=$BANK, timeout ${LEG_TIMEOUT}s)"
        CL_LOG="$DEMO/.smoke-claude.log"
        CL_START=$(date +%s)
        # The demo dir is a workspace Claude has never trusted, so it prints
        # "Ignoring N permissions.allow entries ... not been trusted" and runs
        # with NO allow-list. That makes this leg self-verifying: the only thing
        # left that can approve the `git rev-parse` call is auto-approve-safe-bash,
        # so a reply carrying the HEAD sha is itself proof the PreToolUse chain
        # fired. Do NOT "fix" the trust warning - it is the positive control.
        (
            cd "$DEMO" || exit 2
            # headless-claude-ok: hook-chain smoke demo (HIMMEL-2000); bank-gated above, --model haiku, one read-only turn
            env "${INERT_ENV[@]}" timeout "$LEG_TIMEOUT" claude -p "$PROMPT" \
                --model haiku --permission-mode default --output-format json
        ) > "$CL_LOG" 2>&1
        CL_RC=$?
        CL_SECS=$(( $(date +%s) - CL_START ))
        # The reply is the JSON result field, extracted - not the whole log,
        # which carries the prompt (and its trailing DONE) right back at us.
        # sed drops everything before the first `{`: the untrusted-workspace
        # notice is printed ahead of the JSON and would make jq bail.
        CL_REPLY="$DEMO/.smoke-claude-reply.txt"
        sed -n '/^{/,$p' "$CL_LOG" | jq -r '.result // empty' > "$CL_REPLY" 2>/dev/null \
            || : > "$CL_REPLY"
        assert_agent_leg claude-print "$CL_RC" "$CL_LOG" "$CL_REPLY" "$CL_SECS"
    else
        row claude-print SKIP - 0 0 "bank verdict $BANK"
    fi
elif [ "$RUN_CLAUDE" = "1" ]; then
    row claude-print SKIP - 0 0 "claude or jq missing"
fi

# ======================================================== claude-replay ======
# The Claude-side positive control. Scope is deliberate and asymmetric with the
# codex side: this leg replays the PreToolUse chain only - that is where every
# guardrail lives, and it is the one event whose payload can be synthesised
# without side effects (a Stop/SessionEnd replay would drive speak-reply and the
# wiki writer against a fabricated session). The OTHER Claude events are not
# untested: claude-print is a real session, so SessionStart, PostToolUse, Stop
# and SessionEnd all fire there for real and any failure banner is caught by the
# same scan. What this leg adds is determinism for the guardrail chain.
#
# Every PreToolUse hook that routes through run-hook-with-bash.js is handed a
# canned benign payload and must exit 0.
# ONLY 0: the payload is a read-only `git rev-parse`, and measured against the
# live hook set all 15 return 0, so a 2 here is a guardrail blocking something
# benign - the same break the agent legs fail on - and anything else (a crash, a
# missing runner, a broken $CLAUDE_PROJECT_DIR substitution) is the
# HIMMEL-1985-shaped one.
if [ "$RUN_CLAUDE" = "1" ] && command -v jq >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    echo "hook-smoke-demo: claude-replay leg"
    CR_START=$(date +%s)
    # Built with jq, not a heredoc: $DEMO can be a Windows path with backslashes
    # (the no-cygpath fallback), and those are escape sequences inside a JSON
    # string - a heredoc would hand every hook a malformed payload.
    CR_PAYLOAD="$DEMO/.smoke-claude-payload.json"
    jq -n --arg cwd "$DEMO" '{
        session_id: "hook-smoke-demo", transcript_path: "", cwd: $cwd,
        hook_event_name: "PreToolUse", tool_name: "Bash",
        tool_input: { command: "git -C . rev-parse --short HEAD", description: "read-only smoke" }
    }' > "$CR_PAYLOAD" 2>/dev/null || { echo "hook-smoke-demo: could not build the replay payload" >&2; exit 2; }
    CR_CMDS="$DEMO/.smoke-claude-hooks.txt"
    jq -r '.hooks.PreToolUse[]?.hooks[]?.command | select(. != null) | select(test("run-hook-with-bash"))' \
        "$DEMO/.claude/settings.json" > "$CR_CMDS" 2>/dev/null || : > "$CR_CMDS"
    CR_HOOKS=$(grep -c . "$CR_CMDS" 2>/dev/null || true)
    case "$CR_HOOKS" in ''|*[!0-9]*) CR_HOOKS=0 ;; esac
    # Subshell so the exported CLAUDE_PROJECT_DIR (the hook commands expand it
    # themselves) cannot leak past this leg; the failure tally comes back on fd 1.
    CR_NOTE=$(
        # cd into the demo, matching what the probe does on the codex side and
        # what a real session does: a hook that resolves a RELATIVE path would
        # otherwise inspect the caller's checkout instead of the throwaway one.
        cd "$DEMO" || { printf '1|could not enter the demo dir\n'; exit 0; }
        export CLAUDE_PROJECT_DIR="$DEMO"
        _f=0; _n=""
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            # bash -c under the same INERT_ENV prefix as the agent legs: these
            # are real guardrails, and a replayed hook must not be able to act
            # on live initiative/Jira/arm state inherited from the caller.
            # Bounded, because a hook that HANGS is one of the breaks this
            # smoke is looking for - unbounded, it would stall the runner
            # instead of reporting a failed leg. The default matches the largest
            # timeout any entry in .claude/settings.json declares.
            env "${INERT_ENV[@]}" timeout "$REPLAY_TIMEOUT" bash -c "$cmd" < "$CR_PAYLOAD" >/dev/null 2>&1
            _rc=$?
            case "$_rc" in
                0) ;;
                *) _f=$((_f + 1)); _n="${_n:+$_n }rc=$_rc" ;;
            esac
        done < "$CR_CMDS"
        printf '%s|%s\n' "$_f" "$_n"
    )
    CR_FAIL="${CR_NOTE%%|*}"
    CR_NOTE="${CR_NOTE#*|}"
    case "$CR_FAIL" in ''|*[!0-9]*) CR_FAIL=0 ;; esac
    CR_SECS=$(( $(date +%s) - CR_START ))
    if [ "$CR_HOOKS" -eq 0 ]; then
        row claude-replay FAIL 0 1 "$CR_SECS" "no run-hook-with-bash entries in settings.json"
    elif [ "$CR_FAIL" -eq 0 ]; then
        row claude-replay PASS "$CR_HOOKS" 0 "$CR_SECS" ""
    else
        row claude-replay FAIL "$CR_HOOKS" "$CR_FAIL" "$CR_SECS" "$CR_NOTE"
    fi
elif [ "$RUN_CLAUDE" = "1" ]; then
    row claude-replay SKIP - 0 0 "jq or node missing"
fi

# --- table ------------------------------------------------------------------
echo
echo "HOOK-CHAIN SMOKE - source: $FROM"
printf '%-15s %-7s %-7s %-9s %-7s %s\n' LEG RESULT HOOKS FAILURES TIME NOTE
for r in ${ROWS[@]+"${ROWS[@]}"}; do
    IFS='|' read -r n res h f t note <<EOF
$r
EOF
    printf '%-15s %-7s %-7s %-9s %-7s %s\n' "$n" "$res" "$h" "$f" "$t" "$note"
done
echo

if [ "$RAN" -eq 0 ]; then
    echo "hook-smoke-demo: NOTHING RAN - not a pass" >&2
    exit 2
fi

# An agent leg without its replay leg is not a result. `codex-exec` on its own
# says a turn finished with no banner - it cannot distinguish that from a hook
# set that never fired; the replay leg is what executes the hooks and proves
# they run. Same for claude-print / claude-replay.
leg_ran() {
    for _r in ${ROWS[@]+"${ROWS[@]}"}; do
        case "$_r" in
            "$1|SKIP|"*) return 1 ;;
            "$1|"*) return 0 ;;
        esac
    done
    return 1
}
require_control() {  # require_control <agent-leg> <replay-leg>
    leg_ran "$1" && ! leg_ran "$2" || return 0
    echo "hook-smoke-demo: $1 ran without its positive control $2 - not a pass" >&2
    exit 2
}
require_control codex-exec codex-replay
require_control claude-print claude-replay
if [ "$FAILED" -gt 0 ]; then
    echo "hook-smoke-demo: $FAILED leg(s) FAILED" >&2
    exit 1
fi
echo "hook-smoke-demo: all $RAN leg(s) clean"
exit 0
