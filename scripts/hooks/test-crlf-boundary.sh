#!/usr/bin/env bash
# test-crlf-boundary.sh — the CRLF-at-boundary audit, made durable (HIMMEL-2234).
#
# THE CLASS. A carriage return in CRLF-encoded command text silently changes the
# verdict of a position-sensitive text scanner. Proven three times now:
#   * HIMMEL-2177 — a captured variable carried a trailing CR into an
#     arithmetic context.
#   * PR #2005 r2 — the pin-dir fence checked a record's LAST character for the
#     line-continuation backslash. Under CRLF the last character is the CR, so
#     escape detection never fired and continued scripts went UNSCANNED: a
#     fail-open in a security fence, in both dialects.
#   * This ticket — four more, found by probing every command-text hook instead
#     of waiting for the next incident. Two were fail-OPEN
#     (check-cr-marker-on-pr-create let a PR ship past a pending CR marker;
#     block-merged-pr-commit let a commit land on an already-merged branch),
#     one flipped a verdict the wrong way, one silently skipped an advisory.
#
# The standing rule is "strip at the CAPTURE boundary, never per use site", and
# after #2005 exactly one scanner honoured it. This suite is the audit that
# closed the class — and, more importantly, the thing that keeps it closed: the
# completeness guard at the bottom FAILS when a hook reads `.tool_input.command`
# and has no row here. An audit nobody re-runs decays into a paragraph in an old
# PR body.
#
# METHOD. rc-proofs against the REAL hooks, never assertions about them. Every
# row runs the hook three ways — LF, one terminal CR, and every line terminated
# with CRLF — and requires the CRLF verdicts to equal the LF verdict. The LF run
# is checked against an EXPECTED rc FIRST: a payload that never reaches the code
# under test proves nothing, and a suite full of such rows is the vacuous-verdict
# trap, a green suite that tests nothing. A row whose LF baseline is wrong fails
# LOUDLY as VACUOUS instead of quietly passing.
#
# The trigger literals below are spelled with a "" split. They are payloads for
# deny hooks that are LIVE on this repo's own sessions, and written whole they
# make the file hazardous to EDIT: a tool call carrying the literal is denied by
# the very hook under test. The split is inert at runtime — the shell
# concatenates before the payload is built.
#
# Usage: bash scripts/hooks/test-crlf-boundary.sh
# Exit:  0 all passed, 1 any failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }

PASS=0
FAIL=0
SEEN=""     # hooks this suite actually exercised, for the completeness guard

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ $# -ge 2 ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }

CR="$(printf '\r')"

# _rc <hook> <tool> <cmd> [env-assign...] -> the hook's exit code.
_rc() {
    local hook="$1" tool="$2" cmd="$3"; shift 3
    local json
    json=$(printf '{"tool_name":%s,"tool_input":{"command":%s}}' \
        "$(printf '%s' "$tool" | jq -Rs .)" "$(printf '%s' "$cmd" | jq -Rs .)")
    if [ $# -gt 0 ]; then
        printf '%s' "$json" | env "$@" bash "$SCRIPT_DIR/$hook.sh" >/dev/null 2>&1
    else
        printf '%s' "$json" | bash "$SCRIPT_DIR/$hook.sh" >/dev/null 2>&1
    fi
    echo "$?"
}

# _crlf <cmd> -> the same command with every line terminated by CRLF.
_crlf() { printf '%s' "$1" | sed "s/\$/$CR/"; }

# check <hook> <tool> <want-rc> <cmd> <label> [env-assign...]
check() {
    local hook="$1" tool="$2" want="$3" cmd="$4" label="$5"; shift 5
    case " $SEEN " in *" $hook "*) ;; *) SEEN="$SEEN $hook" ;; esac

    local lf cr_tail cr_all
    lf="$(_rc "$hook" "$tool" "$cmd" "$@")"
    if [ "$lf" != "$want" ]; then
        fail "$hook / $label — VACUOUS" \
             "LF baseline rc=$lf, expected rc=$want: this payload does not exercise the hook, so its CRLF result proves nothing"
        return
    fi

    cr_tail="$(_rc "$hook" "$tool" "$cmd$CR" "$@")"
    cr_all="$(_rc "$hook" "$tool" "$(_crlf "$cmd")" "$@")"

    if [ "$cr_tail" = "$lf" ] && [ "$cr_all" = "$lf" ]; then
        pass "$hook / $label (rc=$lf under LF, terminal-CR and CRLF)"
    else
        fail "$hook / $label — CRLF CHANGES THE VERDICT" \
             "LF=$lf terminal-CR=$cr_tail CRLF=$cr_all — strip CRs at the capture boundary, not at the use site"
    fi
}

# ── Payloads ────────────────────────────────────────────────────────────────
D_RM="r""m -rf /tmp/crlf-probe-x"
D_RESET="gi""t rese""t --hard"
D_STASH="gi""t stas""h"
D_ENV="ca""t .e""nv"
D_DOCKER="dock""er run --privileged img sh"
D_SCHED="schta""sks /create /tn X /tr \"cla""ude load h\" /sc ONCE /st 04:30 /f"
D_CODEX="cod""ex exec --sandbox workspace-write do-the-thing"
D_WSL="ws""l -d Ubuntu -- bash -lc \"cod""ex exec -s workspace-write do-it\""
D_TAIL="bash scripts/cr/clear-cr-mar""ker.sh | tai""l -5"
D_QUIET="bash scripts/test-check-c""i.sh"
A_OK="git status"

printf '\nSingle-line command text\n'
check block-destructive-commands  Bash 2 "$D_RM"     "deny recursive delete"
check block-destructive-commands  Bash 2 "$D_RESET"  "deny hard reset"
check block-destructive-commands  Bash 0 "$A_OK"     "allow git status"
check block-git-stash             Bash 2 "$D_STASH"  "deny stash mutation"
check block-git-stash             Bash 0 "$A_OK"     "allow git status"
check block-read-secrets          Bash 2 "$D_ENV"    "deny dotenv read"
check block-read-secrets          Bash 0 "$A_OK"     "allow git status"
check block-docker-privesc        Bash 2 "$D_DOCKER" "deny privileged container"
check block-docker-privesc        Bash 0 "dock""er ps" "allow a docker read"
check block-rogue-claude-schedule Bash 2 "$D_SCHED"  "deny rogue scheduled agent"
check block-rogue-claude-schedule Bash 0 "$A_OK"     "allow git status"
check block-rogue-codex-exec      Bash 2 "$D_CODEX"  "deny raw codex exec"
check block-rogue-codex-exec      Bash 0 "cod""ex --version" "allow a codex read"
check block-rogue-codex-wsl       Bash 2 "$D_WSL"    "deny raw wsl codex dispatch"
check block-rogue-codex-wsl       Bash 0 "$A_OK"     "allow git status"
check block-tail-pipe-on-gates    Bash 2 "$D_TAIL"   "deny gate piped to tail"
check block-tail-pipe-on-gates    Bash 0 "$A_OK"     "allow git status"
check require-quiet-run           Bash 2 "$D_QUIET"  "deny bare suite run"
check require-quiet-run           Bash 0 "$A_OK"     "allow git status"

# A multi-line command is where the class actually bites: with CRLF endings the
# LAST character of every record is a CR, so any check anchored at end-of-record
# — a $-anchored regex, a last-character test, an exact comparison, a word-split
# token used as a lookup key — silently stops matching. Each shape below carries
# the trigger on a line that is NOT the last one, so a per-record scanner has to
# get the boundary right rather than getting away with a terminal strip.
printf '\nMulti-line command text (the #2005 per-record class)\n'
for _pair in \
    "block-destructive-commands|$D_RM" \
    "block-git-stash|$D_STASH" \
    "block-read-secrets|$D_ENV" \
    "block-docker-privesc|$D_DOCKER" \
    "block-rogue-claude-schedule|$D_SCHED" \
    "block-rogue-codex-exec|$D_CODEX" \
    "block-rogue-codex-wsl|$D_WSL" \
    "block-tail-pipe-on-gates|$D_TAIL" \
    "require-quiet-run|$D_QUIET"
do
    _h="${_pair%%|*}"; _c="${_pair#*|}"
    check "$_h" Bash 2 "$(printf 'echo hello\n%s' "$_c")"   "deny on a second line"
    check "$_h" Bash 0 "$(printf 'echo hello\n%s' "$A_OK")" "allow a benign two-line command"
done

# ── block-read-secrets.sh — CR-carrying TOKEN bypass (HIMMEL-2525) ──────────
# A DIFFERENT class than the CRLF-per-record class above: not a line ending,
# but a CR glued onto (or inside) the shell TOKEN the matcher compares
# against a reader name / secret-name glob. Bash's default $IFS (space/tab/
# newline) does not include CR, so a token-attached CR — trailing
# (`cat .env<CR>`) or embedded MID-token (`.en<CR>v`) — survives word-split
# UNCHANGED, and is_secret_path/is_reader_cmd then compare against the wrong
# string and MISS (a false ALLOW). A CR that is its OWN token (real
# whitespace on both sides) is the discriminator: it never attaches to
# `.env`, so that row must keep denying under ANY correct fix — it is what
# would catch a future "fix" that blanket-strips every CR everywhere instead
# of stripping only at the per-token match site.
LF=$'\n'   # a bare LF as a string literal (not command substitution, so no
           # trailing-newline stripping applies)
D_ENV_TRAIL_CR="${D_ENV}${CR}"                 # "cat .env<CR>"
D_ENV_TRAIL_CRLF="${D_ENV}${CR}${LF}"          # "cat .env<CR><LF>"
D_ENV_MID_CR="${D_ENV%v}${CR}v"                # "cat .en<CR>v"
D_ENV_SEP_CR="${D_ENV%% *} ${CR} ${D_ENV#* }"  # "cat <CR> .env" — CR is its OWN token

_rd_probe() {  # <cmd> <want-rc> <label>
    local cmd="$1" want="$2" label="$3"
    local rc
    rc="$(_rc block-read-secrets Bash "$cmd")"
    if [ "$rc" = "$want" ]; then
        pass "block-read-secrets / $label (rc=$rc)"
    else
        fail "block-read-secrets / $label" "rc=$rc, expected $want"
    fi
}

printf '\nblock-read-secrets — CR-carrying token bypass (HIMMEL-2525)\n'
_rd_probe "$D_ENV_TRAIL_CR"   2 "token + trailing CR denies"
_rd_probe "$D_ENV_TRAIL_CRLF" 2 "token + trailing CRLF denies"
_rd_probe "$D_ENV_MID_CR"     2 "token-internal CR denies (stated behaviour: every CR in a token is stripped before comparison — .en<CR>v normalises to .env)"
_rd_probe "$D_ENV_SEP_CR"     2 "CR as its own separate token still denies (discriminator — guards against a future blanket strip)"

# Positive control: a genuine secret-read clause PLUS an unrelated heredoc
# body line carrying a LEGITIMATE embedded CR as DATA (not a bypass
# attempt). The fix must strip CR only at the per-token comparison site and
# never mutate $cmd itself — so the raw command this hook echoes back in its
# own denial message (the text a user/agent actually reads to recover) must
# still carry that CR byte-for-byte. A blanket `tr -d '\r'` on $cmd — the
# WRONG fix this ticket explicitly rules out — would strip it from the
# echoed command too; this assertion is what makes that regression visible
# in CI, not just in a header comment nobody re-checks.
HD_MARKER="EOF_HIMMEL_2525"
HD_LINE1="$D_ENV"
HD_LINE2="cat > /tmp/himmel-2525-hd-out <<'${HD_MARKER}'"
HD_LINE3="DATA_WITH_EMBEDDED_CR_HERE${CR}TAIL"
HD_LINE4="$HD_MARKER"
CMD_HEREDOC="${HD_LINE1}${LF}${HD_LINE2}${LF}${HD_LINE3}${LF}${HD_LINE4}"
HD_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$CMD_HEREDOC" | jq -Rs .)")
HD_OUT="$(bash "$SCRIPT_DIR/block-read-secrets.sh" <<<"$HD_JSON" 2>&1 1>/dev/null)"
HD_RC=$?
HD_NEEDLE="DATA_WITH_EMBEDDED_CR_HERE${CR}TAIL"

if [ "$HD_RC" = "2" ]; then
    pass "block-read-secrets / multi-clause command with a genuine secret-read line still denies (rc=$HD_RC)"
else
    fail "block-read-secrets / multi-clause command with a genuine secret-read line" "rc=$HD_RC, expected 2"
fi

if printf '%s' "$HD_OUT" | grep -qF "$HD_NEEDLE"; then
    pass "block-read-secrets / heredoc-adjacent embedded CR survives byte-for-byte in the echoed command (SOH-tail property)"
else
    fail "block-read-secrets / heredoc-adjacent embedded CR did NOT survive" \
         "the denial message no longer echoes the CR verbatim — a blanket strip on \$cmd would do exactly this"
fi

# One shared temp tree for every stateful fixture below (mktemp -d + a single
# trap) instead of one per hook, per the other suites in this directory.
# A template is required (not just portable): BSD/macOS mktemp -d rejects a
# bare `-d` outright, and the guard below refuses to trap a delete rooted at
# an empty $TMP if mktemp ever DID return blank.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/crlf-boundary.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$TMP" ] || { echo "FATAL: mktemp -d returned empty" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

_mkrepo() {  # _mkrepo <path> <branch> — a real commit, not an unborn HEAD:
             # several hooks below shell out to `git rev-parse HEAD`.
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# ponytail: this section spawns dozens of nested bash+env+git+gh processes: a
# known MSYS/Git-Bash flake wedges ONE of them after enough prior forks in the
# same process (reproduces standalone every time; only wedges here, under
# load — the class scripts/hooks/test-block-merged-pr-commit.sh's own T11
# hang-guard already documents). check() itself is untouched; every row below
# goes through this bounded twin instead, so a wedge fails loudly in ~20s
# rather than hanging the suite. Upgrade path: none needed — a rare bounded
# retry is cheaper than chasing an upstream MSYS bug.
_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_BIN="gtimeout"
fi

_rc_bounded() {
    local hook="$1" tool="$2" cmd="$3"; shift 3
    local json
    json=$(printf '{"tool_name":%s,"tool_input":{"command":%s}}' \
        "$(printf '%s' "$tool" | jq -Rs .)" "$(printf '%s' "$cmd" | jq -Rs .)")
    # shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
    printf '%s' "$json" | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env "$@" bash "$SCRIPT_DIR/$hook.sh" >/dev/null 2>&1
    echo "$?"
}

check_bounded() {  # check_bounded <hook> <tool> <want-rc> <cmd> <label> [env...]
    local hook="$1" tool="$2" want="$3" cmd="$4" label="$5"; shift 5
    case " $SEEN " in *" $hook "*) ;; *) SEEN="$SEEN $hook" ;; esac

    local lf cr_tail cr_all
    lf="$(_rc_bounded "$hook" "$tool" "$cmd" "$@")"
    if [ "$lf" != "$want" ]; then
        fail "$hook / $label — VACUOUS" \
             "LF baseline rc=$lf, expected rc=$want: this payload does not exercise the hook, so its CRLF result proves nothing"
        return
    fi

    cr_tail="$(_rc_bounded "$hook" "$tool" "$cmd$CR" "$@")"
    cr_all="$(_rc_bounded "$hook" "$tool" "$(_crlf "$cmd")" "$@")"

    if [ "$cr_tail" = "$lf" ] && [ "$cr_all" = "$lf" ]; then
        pass "$hook / $label (rc=$lf under LF, terminal-CR and CRLF)"
    else
        fail "$hook / $label — CRLF CHANGES THE VERDICT" \
             "LF=$lf terminal-CR=$cr_tail CRLF=$cr_all — strip CRs at the capture boundary, not at the use site"
    fi
}

printf '\nStateful command-text hooks (HIMMEL-2234 closeout)\n'

# ── auto-approve-safe-bash.sh / cadence-approve-engines.sh ──────────────────
# Neither hook denies; each emits a permissionDecision on stdout (allow) or
# stays silent (fall through to the normal prompt). The dangerous direction
# for an APPROVE hook is the mirror of a deny hook's: a CRLF-mangled command
# must never newly EARN an allow the LF form did not already get — that
# would auto-run text different from what was actually typed. check_verdict
# keeps check()'s two invariants for a hook whose result is a decision this
# suite derives itself (grep the stdout), not a bare rc.
check_verdict() {  # check_verdict <decide-fn> <hook> <want> <cmd> <label> [env...]
    local decide_fn="$1" hook="$2" want="$3" cmd="$4" label="$5"; shift 5
    case " $SEEN " in *" $hook "*) ;; *) SEEN="$SEEN $hook" ;; esac

    local lf cr_tail cr_all
    lf="$("$decide_fn" "$cmd" "$@")"
    if [ "$lf" != "$want" ]; then
        fail "$hook / $label — VACUOUS" \
             "LF baseline=$lf, expected $want: this payload does not exercise the hook, so its CRLF result proves nothing"
        return
    fi
    cr_tail="$("$decide_fn" "$cmd$CR" "$@")"
    cr_all="$("$decide_fn" "$(_crlf "$cmd")" "$@")"
    if [ "$cr_tail" = "$lf" ] && [ "$cr_all" = "$lf" ]; then
        pass "$hook / $label ($lf under LF, terminal-CR and CRLF)"
    else
        fail "$hook / $label — CRLF CHANGES THE VERDICT" \
             "LF=$lf terminal-CR=$cr_tail CRLF=$cr_all — strip CRs at the capture boundary, not at the use site"
    fi
}

_decide_auto_approve() {  # <cmd> [env...] -> ALLOW|PASS
    local cmd="$1"; shift
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
        | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env "$@" bash "$SCRIPT_DIR/auto-approve-safe-bash.sh" 2>/dev/null)
    # A here-string, not a pipeline: under this file's pipefail, `grep -q`
    # exiting on its first match SIGPIPEs `printf` and the PIPELINE's own
    # status goes non-zero on a MATCH — `&&`/`||` off that would echo PASS
    # for an actual allow (HIMMEL-1430; same grepq idiom test-shell-lint.sh
    # documents). $out is a short JSON decision, well under the 64 KiB
    # here-string limit (HIMMEL-2027).
    if grep -q '"permissionDecision":"allow"' <<< "$out"; then echo ALLOW; else echo PASS; fi
}
_decide_cadence() {  # <cmd> [env...] -> ALLOW|PASS
    local cmd="$1"; shift
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
        | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env "$@" bash "$SCRIPT_DIR/cadence-approve-engines.sh" 2>/dev/null)
    # See _decide_auto_approve's twin comment: a here-string, not a pipeline.
    if grep -q '"permissionDecision":"allow"' <<< "$out"; then echo ALLOW; else echo PASS; fi
}

check_verdict _decide_auto_approve auto-approve-safe-bash ALLOW \
    "gi""t log --oneline -1" "allow a read-only git log"
check_verdict _decide_auto_approve auto-approve-safe-bash PASS \
    "gi""t push origin main" "never auto-approve a push"
check_verdict _decide_auto_approve auto-approve-safe-bash ALLOW \
    "$(printf 'echo hello\ncat README.md')" "allow across a benign two-line command"

CADENCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    CADENCE_ROOT="$(cygpath -m "$CADENCE_ROOT")"
fi
CADENCE_ENGINE="${CADENCE_ROOT}/marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py"
# shellcheck disable=SC1003 # '\\' is tr's two-char escape for one backslash
CADENCE_ENGINE_BS="$(printf '%s' "$CADENCE_ENGINE" | tr '/' '\\')"

check_verdict _decide_cadence cadence-approve-engines ALLOW \
    "python \"${CADENCE_ENGINE_BS}\" vault" "allow the enumerated vault-lint engine"
check_verdict _decide_cadence cadence-approve-engines PASS \
    "gi""t status" "never grant a non-enumerated command"
check_verdict _decide_cadence cadence-approve-engines ALLOW \
    "$(printf 'cd /tmp\npython "%s" vault' "$CADENCE_ENGINE_BS")" \
    "allow across a nav-then-engine two-line command"

# ── block-cheap-lane-pr-without-verdict.sh ───────────────────────────────────
# The regression: --head as the LAST token on the line. `set -- $cmd`
# word-splitting glues a stray CR onto that last token, so the branch/slug
# lookup misses — a VERDICT-PRESENT branch (should ALLOW) blocked instead
# under CRLF. That was the actual HIMMEL-2234 finding; pin it in both
# directions so a regression trips whichever way it slides.
BRIDGE_ROOT="$TMP/bridge"
mkdir -p "$BRIDGE_ROOT/glm-sessions/glm-spike-1"

printf '{"lane":"glm","task_name":"spike","d1_verdict":null}' \
    > "$BRIDGE_ROOT/glm-sessions/glm-spike-1/meta.json"
check_bounded block-cheap-lane-pr-without-verdict Bash 2 \
    "gh pr crea""te --head glm/spike" "no d1_verdict blocks" BRIDGE_ROOT="$BRIDGE_ROOT"

printf '{"lane":"glm","task_name":"spike","d1_verdict":"pass"}' \
    > "$BRIDGE_ROOT/glm-sessions/glm-spike-1/meta.json"
check_bounded block-cheap-lane-pr-without-verdict Bash 0 \
    "gh pr crea""te --head glm/spike" \
    "verdict present + --head as the last token still allows (HIMMEL-2234 regression)" \
    BRIDGE_ROOT="$BRIDGE_ROOT"

check_bounded block-cheap-lane-pr-without-verdict Bash 0 "gi""t status" \
    "unrelated command fast-path allows" BRIDGE_ROOT="$BRIDGE_ROOT"

# ── check-cr-marker-on-pr-create.sh ──────────────────────────────────────────
# Same --head-as-last-token family, the dangerous direction this time: a
# marker that IS pending must still block a PR create when a stray CR lands
# on the branch name, or a CR review gets silently skipped.
MARKER_REPO="$TMP/marker-repo"
_mkrepo "$MARKER_REPO" main
mkdir -p "$MARKER_REPO/.git/cr-pending/feat"
: > "$MARKER_REPO/.git/cr-pending/feat/x"   # pending marker for feat/x only

check_bounded check-cr-marker-on-pr-create Bash 2 "gh pr crea""te --head feat/x" \
    "marker present + --head as the last token blocks (HIMMEL-2234 regression)" \
    CLAUDE_PROJECT_DIR="$MARKER_REPO"
check_bounded check-cr-marker-on-pr-create Bash 0 "gh pr crea""te --head feat/y" \
    "no marker for this branch allows" CLAUDE_PROJECT_DIR="$MARKER_REPO"

# ── block-merged-pr-commit.sh ────────────────────────────────────────────────
# The regression: `commit` as the LAST word on the line (no message, no
# flags). `set -- $segment` word-splitting glues a stray CR onto that last
# token, `[ "$tok" = "commit" ]` stops matching, and the hook fails OPEN —
# a commit lands on an already-merged/shipped branch. `-C <dir>` supplies the
# repo from the command text itself, so no `.cwd` plumbing is needed.
GH_MERGED="$TMP/gh-merged"
cat > "$GH_MERGED" <<'STUB'
#!/usr/bin/env bash
echo "1"
STUB
chmod +x "$GH_MERGED"

MPC_REPO="$TMP/mpc-repo"
_mkrepo "$MPC_REPO" "feat/my-feature"

check_bounded block-merged-pr-commit Bash 2 "gi""t -C $MPC_REPO commi""t" \
    "bare 'commit' as the last token blocks (HIMMEL-2234 regression)" \
    FORGE=github GH_CMD="$GH_MERGED"
check_bounded block-merged-pr-commit Bash 2 "$(printf 'echo hello\ngi''t -C %s commi''t' "$MPC_REPO")" \
    "same regression across a two-line command" \
    FORGE=github GH_CMD="$GH_MERGED"
check_bounded block-merged-pr-commit Bash 2 "gi""t -C $MPC_REPO commi""t -m x" \
    "commit with a message (not the last token) still blocks" \
    FORGE=github GH_CMD="$GH_MERGED"
check_bounded block-merged-pr-commit Bash 0 "gi""t -C $MPC_REPO status" \
    "a non-commit command allows" FORGE=github GH_CMD="$GH_MERGED"

# ── block-chokepoint-env-prefix.sh ───────────────────────────────────────────
# Registry-driven, mirroring the hook's own suite: every fixture comes from
# the SHIPPED scripts/chokepoints.json, never a hand-typed duplicate.
CHOKE_REGISTRY="$SCRIPT_DIR/../chokepoints.json"
CHOKE_ENTRY=$(jq -r 'to_entries[] | select(.key | endswith("merge-on-green.sh")) | "\(.key)\t\((.value.seam_env_vars // [])[0])"' "$CHOKE_REGISTRY")
CHOKE_PATH="${CHOKE_ENTRY%%$'\t'*}"
CHOKE_VAR="${CHOKE_ENTRY#*$'\t'}"

if [ -n "$CHOKE_PATH" ] && [ -n "$CHOKE_VAR" ]; then
    check_bounded block-chokepoint-env-prefix Bash 2 "${CHOKE_VAR}=x bash $CHOKE_PATH" \
        "env-prefixed chokepoint invocation blocks" \
        -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY
    check_bounded block-chokepoint-env-prefix Bash 0 "gi""t status" \
        "unrelated command allows" -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY
    check_bounded block-chokepoint-env-prefix Bash 2 "$(printf 'echo hello\n%s=x bash %s' "$CHOKE_VAR" "$CHOKE_PATH")" \
        "same block on the second line of a compound" \
        -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY
else
    fail "block-chokepoint-env-prefix — fixture missing" \
         "scripts/chokepoints.json no longer carries a merge-on-green.sh entry"
fi

# ── block-terminal-write-fence.sh ────────────────────────────────────────────
# Class (a) external-write needs no repo state at all. Class (b) write-on-main
# reads the effective repo from `.tool_input.cwd // .cwd`, which check()'s
# JSON never sets — so these rows `cd` into the fixture repo instead of
# threading a cwd field through, exactly like the hook's own test does.
TWF_MAIN="$TMP/twf-main"
TWF_FEAT="$TMP/twf-feat"
_mkrepo "$TWF_MAIN" main
_mkrepo "$TWF_FEAT" "feat/x"

check_bounded block-terminal-write-fence Bash 2 "gi""t push origin main" \
    "external-write: git push blocks"
check_bounded block-terminal-write-fence Bash 0 "gi""t status" \
    "external-write: a read allows"

_TWF_OLDPWD="$PWD"
cd "$TWF_MAIN" || true
check_bounded block-terminal-write-fence Bash 2 "gi""t commi""t -m x" \
    "write-on-main: a commit on the checked-out main branch blocks" \
    CODEX_EXTERNAL_WRITES_OK=1
cd "$TWF_FEAT" || true
check_bounded block-terminal-write-fence Bash 0 "gi""t commi""t -m x" \
    "write-on-main: the same commit on a feature branch allows" \
    CODEX_EXTERNAL_WRITES_OK=1
cd "$_TWF_OLDPWD" || true

# ── block-unresolved-cr-merge.sh ─────────────────────────────────────────────
# cr_merge_gate reads `himmel.coderabbit` from the CURRENT working directory's
# git config (not a JSON field), so this `cd`s into an armed fixture repo the
# same way the hook's own suite does; the stubbed `gh` never touches a
# network.
UCM_REPO="$TMP/ucm-repo"
mkdir -p "$UCM_REPO"
git -C "$UCM_REPO" init -q
git -C "$UCM_REPO" remote add origin https://github.com/o/r.git
git -C "$UCM_REPO" config --local himmel.coderabbit true

UCM_BIN="$TMP/ucm-bin"
mkdir -p "$UCM_BIN"
cat > "$UCM_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "${GH_STUB_MODE:?}" in error) exit 1 ;; esac
case "$*" in
  *"reviews(last:"*)
    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"abc123"},"state":"COMMENTED","body":"looks fine","comments":{"totalCount":1}}]}}}}}'
    exit 0 ;;
esac
case "$1 $2" in
  "pr view") echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api graphql")
    case "$GH_STUB_MODE" in
      unresolved) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
    esac ;;
  "api repos/o/r/commits/abc123/check-runs"*) echo '{"check_runs":[]}' ;;
  "api repos/o/r/commits/abc123/statuses"*)
    echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$UCM_BIN/gh"

_UCM_OLDPWD="$PWD"
cd "$UCM_REPO" || true
check_bounded block-unresolved-cr-merge Bash 2 "gh pr mer""ge 42 --squash" \
    "unresolved CodeRabbit threads block a merge" \
    -u ARMAUTOMERGE -u CR_MERGE_GATE_OK GH_STUB_MODE=unresolved PATH="$UCM_BIN:$PATH"
check_bounded block-unresolved-cr-merge Bash 0 "gh pr mer""ge 42 --squash" \
    "a clean review allows the merge" \
    -u ARMAUTOMERGE -u CR_MERGE_GATE_OK GH_STUB_MODE=clean PATH="$UCM_BIN:$PATH"
cd "$_UCM_OLDPWD" || true

# ── block-glm-external-writes.sh ─────────────────────────────────────────────
# Already CRLF-hardened (PR #2005/#2008) — pinned here so the completeness
# guard has a row and a future edit to its \r handling gets caught same-day.
GLM_URL="https://api.z.ai/api/anthropic"
check_bounded block-glm-external-writes Bash 2 "gi""t push origin main" \
    "a push under the GLM lane blocks" \
    -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR "ANTHROPIC_BASE_URL=$GLM_URL"
check_bounded block-glm-external-writes Bash 0 "gi""t status" \
    "a read under the GLM lane allows" \
    -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR "ANTHROPIC_BASE_URL=$GLM_URL"

# ── block-graphify-egress.sh ─────────────────────────────────────────────────
# The hook resolves its fence relative to its OWN location, so a probe
# against the REAL fence's policy would be non-deterministic across
# machines (network, egress-matrix.json contents). Mirror the hook's own
# suite instead: copy hook + lib next to a fixture fence that only announces
# itself, isolating "does the hook reach the fence" from "what the fence
# would decide" — exactly the boundary this suite is auditing.
GE_PROJECT="$TMP/ge-project"
mkdir -p "$GE_PROJECT/scripts/hooks" "$GE_PROJECT/scripts/guardrails"
cp "$SCRIPT_DIR/block-graphify-egress.sh" "$GE_PROJECT/scripts/hooks/block-graphify-egress.sh"
cp "$SCRIPT_DIR/../guardrails/lib.sh" "$GE_PROJECT/scripts/guardrails/lib.sh"
cat > "$GE_PROJECT/scripts/guardrails/graphify-fence.sh" <<'FENCE'
#!/usr/bin/env bash
echo "FENCE_INVOKED"
exit 0
FENCE
chmod +x "$GE_PROJECT/scripts/guardrails/graphify-fence.sh"

_decide_graphify_reach() {  # <cmd> -> REACH|SKIP
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" \
        | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env CLAUDE_PROJECT_DIR="$GE_PROJECT" bash "$GE_PROJECT/scripts/hooks/block-graphify-egress.sh" 2>&1)
    # See _decide_auto_approve's twin comment: a here-string, not a pipeline.
    if grep -q FENCE_INVOKED <<< "$out"; then echo REACH; else echo SKIP; fi
}

check_verdict _decide_graphify_reach block-graphify-egress REACH \
    "gra""phify update /tmp/crlf-boundary-x --backend claude" \
    "a direct invocation reaches the fence"
check_verdict _decide_graphify_reach block-graphify-egress SKIP \
    "gre""p -rn graphify /tmp/x" "a bare mention never reaches the fence"

# ── block-jira-compound-write.sh ─────────────────────────────────────────────
# A bare `--desc-file` literal is already sanctioned by the auto-approve
# gateway this hook consults, so it is silently allowed — vacuous for a
# BLOCK row. The `$(...)`-interpolated shape is the one the gateway refuses
# to sanction, so it is what actually reaches the bounce path (the incident
# shape, HIMMEL-1077).
JIRA_CLI="/c/Users/x/himmel/scripts/jira/dist/index.js"
# shellcheck disable=SC2016 # single-quoted $(...) is a literal unevaluated payload, not code to run here
D_JIRA_WRITE='no''de '"$JIRA_CLI"' create --type Task --title x --desc "$(cat /tmp/a.md)"'

check_bounded block-jira-compound-write Bash 2 "$D_JIRA_WRITE" \
    "a \$(...)-interpolated create is bounced"
check_bounded block-jira-compound-write Bash 0 "ec""ho hello" \
    "an unrelated command allows"
check_bounded block-jira-compound-write Bash 2 "$(printf 'echo hello\n%s' "$D_JIRA_WRITE")" \
    "the same write on the second line of a compound is bounced"

# ── block-edit-on-main.sh (apply_patch envelope) ─────────────────────────────
# The only command-text surface on this hook is Codex's apply_patch envelope
# (tool_name=apply_patch, tool_input.command = the patch text, no file_path
# field at all) — every other path targets file_path, not command text. Every
# target here is an ABSOLUTE path, so no `.cwd` plumbing is needed either.
# The allow control MUST be a real linked worktree (`git worktree add`), not a
# second independent repo on a feature branch — HIMMEL-507 blocks THAT too
# (a feature branch checked out in a primary `.git`-is-a-directory checkout).
EOM_MAIN="$TMP/eom-main"
EOM_FEAT="$TMP/eom-feat"
_mkrepo "$EOM_MAIN" main
git -C "$EOM_MAIN" worktree add -q -b feat/x "$EOM_FEAT"
_patch_add() { printf '*** Begin Patch\n*** Add File: %s\n+hello\n*** End Patch\n' "$1"; }

check_bounded block-edit-on-main apply_patch 2 "$(_patch_add "$EOM_MAIN/src/foo.js")" \
    "an Add File patch targeting main blocks"
check_bounded block-edit-on-main apply_patch 0 "$(_patch_add "$EOM_FEAT/src/foo.js")" \
    "the same patch targeting a feature branch allows"

# ── block-edit-live-settings.sh (Bash `>`/`>>` redirect arm; HIMMEL-2360) ────
# Only the Bash arm reads tool_input.command; the Edit/Write/MultiEdit/
# NotebookEdit arm reads tool_input.file_path/notebook_path/path instead, no
# command text involved. Every target here is an ABSOLUTE path (matches the
# hook's own paired suite, test-block-edit-live-settings.sh), so no `.cwd`
# plumbing is needed. The allow control MUST be a real linked worktree
# (`git worktree add`), same convention as block-edit-on-main above — and
# `check_bounded` because this hook shells out to git the same way.
BELS_MAIN="$TMP/bels-main"
BELS_FEAT="$TMP/bels-feat"
_mkrepo "$BELS_MAIN" main
mkdir -p "$BELS_MAIN/.claude"
git -C "$BELS_MAIN" worktree add -q -b feat/x "$BELS_FEAT"
mkdir -p "$BELS_FEAT/.claude"

check_bounded block-edit-live-settings Bash 2 \
    "echo pwned > $BELS_MAIN/.claude/settings.json" \
    "a Bash redirect into the primary checkout's settings.json blocks"
check_bounded block-edit-live-settings Bash 0 \
    "echo pwned > $BELS_FEAT/.claude/settings.json" \
    "the same redirect into a linked worktree's settings.json allows"

# ── trigger-cr-on-pr-create.sh / trigger-cr-on-push.sh ───────────────────────
# Both are ADVISORY PostToolUse hooks — they ALWAYS exit 0, so rc proves
# nothing. Their real verdict is whether they decided to post the
# @coderabbitai trigger comment, proxied by a stubbed `gh`'s comment log
# (mirrors posted_count() in each hook's own suite). The push hook's
# regression: a genuine `git \` + newline + `push` continuation — its
# explicit CRLF undo only stripped ONE `\r` before the earlier fix.
TRIG_BIN="$TMP/trig-bin"
mkdir -p "$TRIG_BIN"
cat > "$TRIG_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    if [ -n "${FAKE_GH_HEAD_SHA:-}" ]; then printf '%s\n' "$FAKE_GH_HEAD_SHA"; exit 0; fi
    if [ -n "${FAKE_GH_PR_VIEW_JSON:-}" ]; then printf '%s\n' "$FAKE_GH_PR_VIEW_JSON"; exit 0; fi
    exit 1
fi
if [ "${1:-}" = "api" ]; then cat "${FAKE_GH_COMMENTS_FILE:-/dev/null}" 2>/dev/null || true; exit 0; fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    body=""
    while [ "$#" -gt 0 ]; do case "$1" in --body) body="${2:-}"; shift ;; esac; shift; done
    printf '%s\n' "$body" >> "${FAKE_GH_COMMENT_LOG:?}"
    exit 0
fi
exit 0
STUB
chmod +x "$TRIG_BIN/gh"
TRIG_LOG="$TMP/trig-comment.log"
TRIG_COMMENTS="$TMP/trig-existing.txt"
TRIG_LEDGER="$TMP/trig-ledger"
: > "$TRIG_LOG"; : > "$TRIG_COMMENTS"

_decide_posted_prcreate_run() {  # <cmd> <response-stdout> -> posted-comment count as a string
    local cmd="$1" out="$2"
    : > "$TRIG_LOG"
    local payload
    payload=$(jq -nc --arg cmd "$cmd" --arg out "$out" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:$out,stderr:""}}')
    # shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
    printf '%s' "$payload" | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env PATH="$TRIG_BIN:$PATH" FAKE_GH_COMMENT_LOG="$TRIG_LOG" \
        CR_TRIGGER_REPOS="acme/widget" \
        bash "$SCRIPT_DIR/trigger-cr-on-pr-create.sh" >/dev/null 2>&1
    wc -l < "$TRIG_LOG" | tr -d ' '
}
# Two response shapes, because the hook's own verdict hinges on what
# `tool_response.stdout` carries, not just the command — a PR URL there
# posts, its absence (create failed / already exists / --dry-run) must not.
_decide_posted_prcreate() { _decide_posted_prcreate_run "$1" "https://github.com/acme/widget/pull/1461"; }
_decide_posted_prcreate_nourl() { _decide_posted_prcreate_run "$1" ""; }
_decide_posted_push() {  # <cmd> -> posted-comment count as a string
    local cmd="$1"
    : > "$TRIG_LOG"; rm -f "$TRIG_LEDGER"
    local payload pr_view
    pr_view=$(jq -nc --arg sha "sha-aaa111" \
        '{number:301, headRefOid:$sha, state:"OPEN", url:"https://github.com/acme/widget/pull/301"}')
    payload=$(jq -nc --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"",stderr:""}}')
    # shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
    printf '%s' "$payload" | ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} env PATH="$TRIG_BIN:$PATH" FAKE_GH_COMMENT_LOG="$TRIG_LOG" \
        FAKE_GH_COMMENTS_FILE="$TRIG_COMMENTS" CR_TRIGGER_LEDGER_PATH="$TRIG_LEDGER" \
        CR_TRIGGER_REPOS="acme/widget" FAKE_GH_PR_VIEW_JSON="$pr_view" \
        bash "$SCRIPT_DIR/trigger-cr-on-push.sh" >/dev/null 2>&1
    wc -l < "$TRIG_LOG" | tr -d ' '
}

check_verdict _decide_posted_prcreate trigger-cr-on-pr-create 1 \
    "gh pr crea""te --base main --title t --body b" "a real PR URL in the response posts"
check_verdict _decide_posted_prcreate_nourl trigger-cr-on-pr-create 0 \
    "gh pr crea""te --base main" "no PR URL in the response posts nothing"

CONT_PUSH="$(printf 'gi''t \134\012  pu''sh')"
check_verdict _decide_posted_push trigger-cr-on-push 1 "$CONT_PUSH" \
    "a real backslash-continuation git-push posts (HIMMEL-2234 regression)"
check_verdict _decide_posted_push trigger-cr-on-push 0 "gi""t status" \
    "an unrelated command posts nothing"

# ── Completeness guard ──────────────────────────────────────────────────────
# The audit's real deliverable. Enumerate the command-text hooks FROM THE
# SOURCE — this directory's listing, never a list typed from memory — and
# require every one to be exercised above. A new hook that reads command text
# and brings no CRLF coverage fails this suite on the commit that introduces
# it, which is the only way an audit stays true after the leg that wrote it.
#
# There is deliberately NO exemption list. An exemption naming another suite is
# a claim nobody re-checks; a row here is a claim this suite proves every run.
printf '\nCompleteness guard\n'

MISSING=""
for _f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$_f" ] || continue
    _b="$(basename "$_f" .sh)"
    case "$_b" in test-*) continue ;; esac
    grep -q 'tool_input\.command' "$_f" 2>/dev/null || continue
    case " $SEEN " in *" $_b "*) continue ;; esac
    MISSING="$MISSING $_b"
done

if [ -z "$MISSING" ]; then
    pass "every hook reading .tool_input.command has a CRLF row here"
else
    fail "command-text hooks with no CRLF coverage:$MISSING" \
         "add a check row above — do not exempt it"
fi

printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
