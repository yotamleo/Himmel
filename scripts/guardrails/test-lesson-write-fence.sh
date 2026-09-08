#!/usr/bin/env bash
# Hermetic smoke test for scripts/guardrails/lesson-write-fence.sh
# (HIMMEL-767 deliverable 3). Builds a temp git repo fixture with the
# repo-relative layout enforcement-paths.json's entries target, a copy of
# the real policy file, and drives both the CLI `check` mode and the
# PreToolUse hook mode (JSON on stdin) against it. Never touches the real
# repo, real HOME, or any real vault. Mirrors the test-graphify-fence.sh
# harness style (temp dirs, pass/fail counters, explicit bash invocation).
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
FENCE="$REPO_ROOT/scripts/guardrails/lesson-write-fence.sh"
REAL_POLICY="$REPO_ROOT/scripts/guardrails/enforcement-paths.json"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"

for f in "$FENCE" "$REAL_POLICY"; do
    if [ ! -f "$f" ]; then echo "FAIL: $f not found"; exit 1; fi
done

BASH_BIN="$(command -v bash)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# --- fixture workspace -------------------------------------------------------
WS="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$WS"' EXIT

REPO="$WS/repo"
mkdir -p "$REPO"
(
    fixture_enter_git_init_dir "$REPO" &&
        git init -q &&
        git config user.email t@example.com &&
        git config user.name test
) || exit 1
# Normalize REPO to git's OWN toplevel form: on Windows, `mktemp -d` yields an
# MSYS-mounted `/tmp/...` path while `git rev-parse --show-toplevel` always
# prints the drive-lettered Windows form (`C:/Users/...`) - the two strings
# name the same directory but do not normalize to each other lexically. Real
# hook payloads never straddle this split (cwd/file_path come from the same
# session in one consistent form); resolve it once here so every fixture path
# built from $REPO matches what the fence's own `git -C ... rev-parse
# --show-toplevel` call will report.
REPO="$(cd "$REPO" && git rev-parse --show-toplevel)"

mkdir -p \
    "$REPO/scripts/guardrails" "$REPO/scripts/hooks" "$REPO/scripts/lessons" \
    "$REPO/scripts/lanes" "$REPO/.claude" "$REPO/.codex" \
    "$REPO/marketplace/plugins/himmel-ops/hooks" \
    "$REPO/docs/internals" "$REPO/docs/foo" "$REPO/config"

: > "$REPO/scripts/guardrails/lib.sh"
: > "$REPO/scripts/guardrails/x.sh"
: > "$REPO/scripts/hooks/y.sh"
: > "$REPO/scripts/hooks/a.sh"
: > "$REPO/scripts/hooks/test-x.sh"
: > "$REPO/scripts/lessons/validate-lesson.mjs"
: > "$REPO/.claude/settings.json"
: > "$REPO/.claude/settings.local.json"
: > "$REPO/.pre-commit-config.yaml"
: > "$REPO/.gitleaks.toml"
: > "$REPO/.codex/codex-hook-adapter.sh"
: > "$REPO/scripts/backends.json"
: > "$REPO/marketplace/plugins/himmel-ops/hooks/hooks.json"
: > "$REPO/docs/foo/CLAUDE.md"
: > "$REPO/AGENTS.md"
: > "$REPO/CLAUDE.md"
: > "$REPO/docs/internals/x.md"
: > "$REPO/scripts/foo.sh"
: > "$REPO/scripts/lanes/lanes.json"
: > "$REPO/config/settings.json"
: > "$REPO/README.md"

HERMES="$WS/hermes"; mkdir -p "$HERMES"
: > "$HERMES/parity_guard.py"

NONREPO="$WS/nonrepo"; mkdir -p "$NONREPO"
: > "$NONREPO/CLAUDE.md"

POLICY_COPY="$WS/enforcement-paths.json"
cp "$REAL_POLICY" "$POLICY_COPY"

MISSING_POLICY="$WS/does-not-exist.json"
DIR_AS_POLICY="$WS/policy-is-a-dir"; mkdir -p "$DIR_AS_POLICY"

# --- helpers ------------------------------------------------------------------

# run_hook <expect: allow|deny> <name> <json> <loop:0|1> [policy]
run_hook() {
    local expect="$1" name="$2" json="$3" loop="$4" policy="${5:-$POLICY_COPY}"
    local out rc
    out=$(printf '%s' "$json" | env HIMMEL_LESSON_LOOP="$loop" LESSON_FENCE_POLICY="$policy" "$BASH_BIN" "$FENCE" 2>&1); rc=$?
    local ok=1
    if [ "$expect" = allow ]; then [ "$rc" -eq 0 ] || ok=0
    else [ "$rc" -eq 2 ] || ok=0; fi
    if [ "$ok" = 1 ]; then pass "$name"; else fail "$name (rc=$rc) out=$out"; fi
}

# run_check_batch <cwd> <name1> <expect1> <path1> [<name2> <expect2> <path2> ...]
# HIMMEL-2169: batches N cases that were each their OWN hook-mode run_hook
# spawn into ONE `fence check <path>...` process, verifying each path's
# verdict line (printed in argument order, one per input path) against its
# expected allow|deny - same per-case pass/fail semantics as run_hook, minus
# N-1 process spawns. VALID ONLY for cases that are pure path-classification
# (Write/Edit/NotebookEdit/MultiEdit file_path/notebook_path shapes): check
# mode calls classify_target directly and has no env gate, but it NEVER calls
# evaluate_command - so a Bash/PowerShell command-string case (which exercises
# evaluate_command/_scan_redirects/_operand_targets) cannot be represented
# here and must stay a run_hook call.
#
# HIMMEL-2169 CR fix (codex-1, Important / codex-2, Suggestion): the earlier
# version only checked each line's verdict PREFIX, not its reported path, so
# a misassociated/misordered verdict line (`check` printing lines out of
# argument order, or repeating one) would still read as a pass - losing the
# per-case isolation the replaced individual run_hook spawns had. It also
# discarded the batch process's own exit code. Now checks BOTH: an extra
# "check-batch rc sanity" assertion per batch call (rc must be 2 iff any case
# in the batch expects deny, else 0), and each per-case line's path field
# (3rd tab-separated column) against the expected path, not just the verdict.
run_check_batch() {
    local cwd="$1"; shift
    local -a names=() expects=() paths=()
    while [ "$#" -gt 0 ]; do
        names+=("$1"); expects+=("$2"); paths+=("$3")
        shift 3
    done
    local n=${#paths[@]}
    local out rc
    out=$(cd "$cwd" && env LESSON_FENCE_POLICY="$POLICY_COPY" "$BASH_BIN" "$FENCE" check "${paths[@]}" 2>&1); rc=$?
    local -a lines=()
    while IFS= read -r _line; do lines+=("$_line"); done <<< "$out"
    local i=0 expect_deny=0
    while [ "$i" -lt "$n" ]; do
        [ "${expects[$i]}" = deny ] && expect_deny=1
        i=$((i+1))
    done
    local exp_rc=0; [ "$expect_deny" = 1 ] && exp_rc=2
    if [ "$rc" = "$exp_rc" ]; then
        pass "check-batch rc sanity (cwd=$cwd, n=$n)"
    else
        fail "check-batch rc sanity (cwd=$cwd, n=$n): got rc=$rc expected rc=$exp_rc out=$out"
    fi
    # CR fix (codex-2, round 4): the per-case loop below only ever examines
    # lines[0..n-1] - it never notices EXTRA trailing lines, so `check` mode
    # emitting a duplicate/unexpected trailing line (violating its
    # one-line-per-input contract) would pass silently. Verify the line count
    # matches exactly before trusting positional indexing.
    if [ "${#lines[@]}" = "$n" ]; then
        pass "check-batch line-count sanity (cwd=$cwd, n=$n)"
    else
        fail "check-batch line-count sanity (cwd=$cwd, n=$n): got ${#lines[@]} line(s), expected $n; out=$out"
    fi
    i=0
    while [ "$i" -lt "$n" ]; do
        local nm="${names[$i]}" exp="${expects[$i]}" path="${paths[$i]}" line="${lines[$i]:-}"
        local v c p extra
        # Strict 3-field parse (CR fix, codex-2, round 3): a prefix-only match
        # (verdict + one more tab) accepted a malformed 2-column line - e.g.
        # `deny\t<expected-path>` with the class field missing entirely - as
        # long as the trailing text happened to equal the expected path.
        # Reading into exactly 4 vars over the real `verdict\tclass\tpath`
        # contract requires all three fields present and nothing left over:
        # a short line leaves `p` empty, an over-long one leaves `extra`
        # non-empty, either denied here as malformed.
        IFS=$'\t' read -r v c p extra <<< "$line"
        if [ -z "$v" ] || [ -z "$c" ] || [ -z "$p" ] || [ -n "$extra" ]; then
            fail "$nm (malformed check-mode output line: [$line])"
        elif [ "$v" != "$exp" ]; then
            fail "$nm (verdict mismatch: got [$v] expected [$exp]) line=[$line] out=$out"
        elif [ "$p" != "$path" ]; then
            fail "$nm (verdict OK but path mismatch: line reported [$p], expected [$path]) out=$out"
        else
            pass "$nm"
        fi
        i=$((i+1))
    done
}

write_json() { # <path> <cwd>
    local p="$1" cwd="$2"
    p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
    cwd="${cwd//\\/\\\\}"; cwd="${cwd//\"/\\\"}"
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s","cwd":"%s"}}' "$p" "$cwd"
}
bash_json() { # <command> <cwd>
    local cmd="$1" cwd="$2"
    cmd="${cmd//\\/\\\\}"; cmd="${cmd//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s","cwd":"%s"}}' "$cmd" "$cwd"
}
pwsh_json() { # <command> <cwd>
    local cmd="$1" cwd="$2"
    cmd="${cmd//\\/\\\\}"; cmd="${cmd//\"/\\\"}"
    printf '{"tool_name":"PowerShell","tool_input":{"command":"%s","cwd":"%s"}}' "$cmd" "$cwd"
}
# apply_patch_json <patch-text> <cwd> - HIMMEL-2170: Codex's create/edit
# envelope. Unlike bash_json/pwsh_json, <patch-text> is genuinely multi-line
# (an "*** Add/Update/Delete File:" header line plus a diff body), so this
# also escapes embedded newlines as JSON `\n` (order matters: backslashes,
# then quotes, then newlines - the same order write_json/bash_json already
# use for their first two).
apply_patch_json() {
    local cmd="$1" cwd="$2"
    cmd="${cmd//\\/\\\\}"; cmd="${cmd//\"/\\\"}"; cmd="${cmd//$'\n'/\\n}"
    printf '{"tool_name":"apply_patch","tool_input":{"command":"%s","cwd":"%s"}}' "$cmd" "$cwd"
}

echo "== 1: inactive - settings.json Write payload -> exit 0 =="
run_hook allow "1: inactive settings.json Write -> exit0" \
    "$(write_json "$REPO/.claude/settings.json" "$REPO")" 0

echo "== 2: active Write - prefix classes deny =="
run_check_batch "$REPO" \
    "2: prefix deny scripts/guardrails/x.sh" deny "$REPO/scripts/guardrails/x.sh" \
    "2: prefix deny scripts/hooks/y.sh" deny "$REPO/scripts/hooks/y.sh" \
    "2: prefix deny scripts/lessons/validate-lesson.mjs" deny "$REPO/scripts/lessons/validate-lesson.mjs" \
    "2: prefix deny .claude/settings.json" deny "$REPO/.claude/settings.json" \
    "2: prefix deny .claude/settings.local.json" deny "$REPO/.claude/settings.local.json" \
    "2: prefix deny .pre-commit-config.yaml" deny "$REPO/.pre-commit-config.yaml" \
    "2: prefix deny .gitleaks.toml" deny "$REPO/.gitleaks.toml" \
    "2: prefix deny .codex/codex-hook-adapter.sh" deny "$REPO/.codex/codex-hook-adapter.sh" \
    "2: prefix deny scripts/backends.json" deny "$REPO/scripts/backends.json" \
    "2: prefix deny scripts/guardrails/newsub/x.sh" deny "$REPO/scripts/guardrails/newsub/x.sh"

echo "== 3: active Write - basename classes deny (any depth / outside repo) =="
run_check_batch "$REPO" \
    "3: hooks.json (nested, plugin tree)" deny "$REPO/marketplace/plugins/himmel-ops/hooks/hooks.json" \
    "3: CLAUDE.md nested under docs/foo" deny "$REPO/docs/foo/CLAUDE.md" \
    "3: AGENTS.md at repo root" deny "$REPO/AGENTS.md"
run_check_batch "$HERMES" \
    "3: parity_guard.py (outside repo, hermes tree)" deny "$HERMES/parity_guard.py"
run_check_batch "$NONREPO" \
    "3: CLAUDE.md outside any repo" deny "$NONREPO/CLAUDE.md"

echo "== 4: active Write - allows =="
run_check_batch "$REPO" \
    "4: scripts/foo.sh" allow "$REPO/scripts/foo.sh" \
    "4: docs/internals/x.md" allow "$REPO/docs/internals/x.md" \
    "4: scripts/lanes/lanes.json" allow "$REPO/scripts/lanes/lanes.json" \
    "4: settings.json NOT under .claude/" allow "$REPO/config/settings.json"

echo "== 5: Edit / NotebookEdit / MultiEdit payload shapes =="
run_hook deny "5: Edit file_path -> deny" \
    "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","cwd":"%s"}}' "$REPO/scripts/hooks/y.sh" "$REPO")" 1
run_hook deny "5: NotebookEdit notebook_path -> deny" \
    "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s","cwd":"%s"}}' "$REPO/scripts/guardrails/x.sh" "$REPO")" 1
run_hook deny "5: MultiEdit file_path -> deny" \
    "$(printf '{"tool_name":"MultiEdit","tool_input":{"file_path":"%s","cwd":"%s"}}' "$REPO/CLAUDE.md" "$REPO")" 1
run_hook allow "5: Edit file_path non-enforcement -> allow" \
    "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","cwd":"%s"}}' "$REPO/README.md" "$REPO")" 1
# CR fix (codex-1, round 4, HIMMEL-2169): sections 2/3/4's active-Write cases
# were all converted to check-mode batches, which never construct a
# `tool_name":"Write"` payload at all. Edit/NotebookEdit/MultiEdit above share
# the SAME hook-mode case arm (`Edit|Write|NotebookEdit|MultiEdit)`) as Write,
# so this canary is redundant for classify_target correctness - but it is NOT
# redundant for the dispatch itself: a regression that dropped "Write" from
# that pattern list (falling through to the default `exit 0`) would leave
# every active Write payload silently allowed, and nothing above would catch
# it. One retained active hook-mode Write case closes that gap.
#
# CR fix (codex-1, round 5): a DENY-only canary proves the Write dispatch can
# reach a deny, but not that it still ALLOWS a non-enforcement path - a
# regression that made the Write arm unconditionally deny (independent of
# classify_target's actual verdict) would pass this deny canary just as
# easily. Add the ALLOW half too, so the canary pair covers both directions.
run_hook deny "5: Write file_path -> deny (retains active Write-dispatch coverage)" \
    "$(write_json "$REPO/scripts/hooks/y.sh" "$REPO")" 1
run_hook allow "5: Write file_path non-enforcement -> allow (retains active Write-dispatch coverage)" \
    "$(write_json "$REPO/README.md" "$REPO")" 1

echo "== 6: Bash/PowerShell write-shapes deny =="
run_hook deny "6: echo > scripts/hooks/a.sh" "$(bash_json "echo x > scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "6: sed -i .pre-commit-config.yaml" "$(bash_json "sed -i s/a/b/ .pre-commit-config.yaml" "$REPO")" 1
run_hook deny "6: cp /tmp/x CLAUDE.md (target)" "$(bash_json "cp /tmp/x CLAUDE.md" "$REPO")" 1
run_hook deny "6: rm scripts/guardrails/lib.sh" "$(bash_json "rm scripts/guardrails/lib.sh" "$REPO")" 1
run_hook deny "6: rm scripts/hooks/*.sh (glob survives set -f)" "$(bash_json "rm scripts/hooks/*.sh" "$REPO")" 1
run_hook deny "6: mv scripts/hooks/a.sh /tmp/elsewhere (source destroyed, not read)" \
    "$(bash_json "mv scripts/hooks/a.sh /tmp/elsewhere" "$REPO")" 1
run_hook deny "6: tee .claude/settings.json" "$(bash_json "tee .claude/settings.json" "$REPO")" 1
run_hook deny "6: chmod -x scripts/hooks/a.sh" "$(bash_json "chmod -x scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "6: install -m755 scripts/hooks/a.sh" "$(bash_json "install -m755 /tmp/x scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "6: dd of=scripts/guardrails/lib.sh" "$(bash_json "dd if=/tmp/x of=scripts/guardrails/lib.sh" "$REPO")" 1
run_hook deny "6: git config core.hooksPath /tmp/nohooks" "$(bash_json "git config core.hooksPath /tmp/nohooks" "$REPO")" 1
run_hook deny "6: git config --local core.hooksPath /tmp/nohooks" "$(bash_json "git config --local core.hooksPath /tmp/nohooks" "$REPO")" 1
run_hook deny "6: PowerShell Set-Content scripts/hooks/a.sh" "$(pwsh_json "Set-Content scripts/hooks/a.sh" "$REPO")" 1

echo "== 7: Bash read-shapes allow =="
run_hook allow "7: cat scripts/hooks/a.sh" "$(bash_json "cat scripts/hooks/a.sh" "$REPO")" 1
run_hook allow "7: grep -r foo scripts/guardrails/" "$(bash_json "grep -r foo scripts/guardrails/" "$REPO")" 1
run_hook allow "7: bash scripts/hooks/test-x.sh" "$(bash_json "bash scripts/hooks/test-x.sh" "$REPO")" 1
# round-4 verdict flip (documented, safe-direction): the old model carved
# cp's SOURCE out as a read; the round-4 inversion drops all per-verb
# source/target carve-outs (cp is not on the proven-read-only allow-list,
# so ALL its operands - including the source - are write-target candidates
# now). Use cat/grep to inspect an enforcement file instead of cp-ing it.
run_hook deny "7: cp scripts/guardrails/lib.sh /tmp/x (round-4: cp source no longer exempt)" "$(bash_json "cp scripts/guardrails/lib.sh /tmp/x" "$REPO")" 1
run_hook allow "7: git config --get core.hooksPath (read)" "$(bash_json "git config --get core.hooksPath" "$REPO")" 1

echo "== 8: Bash write to a non-enforcement path allows =="
run_hook allow "8: echo x > scripts/foo.txt" "$(bash_json "echo x > scripts/foo.txt" "$REPO")" 1
run_hook allow "8: mv /tmp/somefile docs/notes.md (both tokens non-enforcement)" \
    "$(bash_json "mv /tmp/somefile docs/notes.md" "$REPO")" 1

echo "== 9: check mode =="
# Absolute fixture paths (not relative + $PWD-anchoring): on this dev host
# mktemp's workspace resolves under Git-Bash's virtual /tmp mount, which has
# no single-letter-drive lexical translation back to the Windows form git
# itself prints for --show-toplevel (see the $REPO normalization above) - a
# relative-path + cd'd-$PWD test here would hit that same alias gap. Real
# dispatcher calls pass absolute paths anyway.
out=$(env LESSON_FENCE_POLICY="$POLICY_COPY" "$BASH_BIN" "$FENCE" check \
    "$REPO/scripts/hooks/a.sh" "$REPO/.claude/settings.json" "$REPO/README.md" 2>&1); rc=$?
if [ "$rc" -eq 2 ] \
    && grepq "$out" -E '^deny[[:space:]]+hooks[[:space:]]' \
    && grepq "$out" -E '^deny[[:space:]]+settings[[:space:]]' \
    && grepq "$out" -E '^allow[[:space:]]+-[[:space:]]'; then
    pass "9: mixed list -> per-line verdicts + exit 2"
else
    fail "9: mixed list rc=$rc out=$out"
fi

out=$(env LESSON_FENCE_POLICY="$POLICY_COPY" "$BASH_BIN" "$FENCE" check "$REPO/scripts/foo.sh" "$REPO/README.md" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "9: all-clear -> exit 0"; else fail "9: all-clear expected rc=0 got rc=$rc out=$out"; fi

out=$(env LESSON_FENCE_POLICY="$POLICY_COPY" "$BASH_BIN" "$FENCE" check 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "9: no args -> exit 2"; else fail "9: no args expected rc=2 got rc=$rc out=$out"; fi

echo "== 10: fail-closed =="
run_hook deny "10: missing policy while active -> deny" \
    "$(write_json "$REPO/.claude/settings.json" "$REPO")" 1 "$MISSING_POLICY"
run_hook deny "10: unreadable (dir) policy while active -> deny" \
    "$(write_json "$REPO/.claude/settings.json" "$REPO")" 1 "$DIR_AS_POLICY"
malformed='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO"'/.claude/settings.json"'
run_hook deny "10: malformed stdin JSON while active -> deny" "$malformed" 1
run_hook allow "10: missing policy while INACTIVE -> exit 0" \
    "$(write_json "$REPO/.claude/settings.json" "$REPO")" 0 "$MISSING_POLICY"
run_hook allow "10: malformed stdin JSON while INACTIVE -> exit 0" "$malformed" 0

echo "== 11: path forms =="
# MSYS /c/... form of an absolute path.
msys_form() {
    case "$1" in
        [A-Za-z]:/*)
            local drv; drv="$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')"
            printf '/%s%s' "$drv" "${1#?:}" ;;
        *) printf '%s' "$1" ;;
    esac
}
# $REPO is already git's own drive-lettered toplevel form (see the
# normalization note above); derive the MSYS form FROM it directly rather
# than round-tripping through `cd && pwd` (which resolves back to the
# MSYS-native view for anything under Git-Bash's virtual /tmp mount and
# would never exercise the drive-letter -> MSYS translation this test wants).
MSYS_TARGET="$(msys_form "$REPO")/scripts/hooks/y.sh"
BACKSLASH_TARGET="$REPO/scripts/hooks/y.sh"
BACKSLASH_TARGET="${BACKSLASH_TARGET//\//\\}"

# Drive-RELATIVE Windows form (codex-adv HIMMEL-808): C:scripts\hooks\y.sh
# with repo cwd means <repo>/scripts/hooks/y.sh on Windows — must deny on
# every host (the old [A-Za-z]:* arm classified it absolute and _normalize
# mangled it into a synthetic non-repo path -> allow).
# HIMMEL-2169: batched into ONE check-mode call (pure path-classification,
# all cwd=$REPO, all ABSOLUTE - no cwd-relative anchoring involved) - the
# mixed-case/traversal cases further below (originally after the 845 block)
# are folded in here too, since they share the same cwd and require no
# ordering relative to 845.
#
# The two DRIVE-RELATIVE cases stay run_hook spawns below (CR fix, codex-1):
# `_cross_drive_relative` checks the token's drive against the payload cwd's
# drive; when the base drive is undeterminable it fails closed to DENY (same
# final verdict as a correctly-resolved same-drive anchor), so batching them
# would have kept the assertion GREEN while silently testing the wrong code
# path - the cross-drive fallback instead of the HIMMEL-808 same-drive anchor
# these cases exist to verify. Same reasoning as the relative-path-anchored
# case below and the 845 same-drive pair further down: check mode anchors via
# the real process `$PWD`, and this fixture's mktemp workspace lives under
# Git-Bash's own virtual /tmp mount (see the "== 9:" comment above), whose
# `cd`-then-getcwd() round-trip does not reliably reproduce the drive-lettered
# $REPO form - only the fence's own `.tool_input.cwd` JSON field (hook mode)
# anchors these deterministically.
REPO11_ARGS=(
    "11: backslash form -> deny" deny "$BACKSLASH_TARGET"
    "11: mixed case final component -> deny" deny "$REPO/scripts/guardrails/X.SH"
    "11: .. traversal -> deny" deny "$REPO/scripts/x/../hooks/y.sh"
)
if [ "$MSYS_TARGET" != "$REPO/scripts/hooks/y.sh" ]; then
    run_check_batch "$REPO" "11: MSYS /c/... form -> deny" deny "$MSYS_TARGET" "${REPO11_ARGS[@]}"
else
    printf '  SKIP  MSYS /c/... form (no drive-letter form observed on this host)\n'
    run_check_batch "$REPO" "${REPO11_ARGS[@]}"
fi

run_hook deny "11: drive-relative backslash form -> deny" \
    "$(write_json 'C:scripts\hooks\y.sh' "$REPO")" 1
run_hook deny "11: drive-relative slash form -> deny" \
    "$(write_json 'C:scripts/hooks/y.sh' "$REPO")" 1

run_hook deny "11: relative path anchored to payload cwd -> deny" \
    "$(write_json "scripts/hooks/y.sh" "$REPO")" 1

# --- HIMMEL-845: CROSS-drive drive-relative fail-open -----------------------
# The HIMMEL-808 anchor above is exact ONLY when the payload cwd is on the
# token's drive. Windows keeps a SEPARATE cwd PER DRIVE (the hidden `=C:`/`=D:`
# env vars), so `Z:tail` from a C: cwd resolves under Z:'s own current
# directory - which this fence cannot read. Anchoring it to the C: cwd anyway
# produced a synthetic path that normalized to a NON-enforcement location and
# ALLOWED, while the real target could be an enforcement file. Must now fail
# closed on every host.
repo_drive() { case "$1" in [A-Za-z]:/*) printf '%s' "${1%%:*}" ;; *) printf '' ;; esac; }
REPO_DRIVE="$(repo_drive "$REPO")"
# A drive letter that is definitely NOT the repo's.
case "$(printf '%s' "$REPO_DRIVE" | tr '[:upper:]' '[:lower:]')" in
    z) OTHER_DRIVE=Y ;;
    *) OTHER_DRIVE=Z ;;
esac

# (845-1) THE fail-open regression. cwd is <repo>/docs, so the old cwd anchor
# yielded <repo>/docs/hooks/y.sh -> repo-relative `docs/hooks/y.sh`, which
# matches NO enforcement prefix -> ALLOW. The real Windows resolution is
# whatever Z:'s per-drive cwd is - e.g. <repo>/scripts, giving the enforcement
# file <repo>/scripts/hooks/y.sh. Unprovable -> deny.
#
# NOT batched (CR fix, codex-1, round 3): `_cross_drive_relative` denies both
# on a GENUINE token-drive-vs-base-drive mismatch AND when the base drive is
# undeterminable (fail-closed fallback) - same final verdict, different code
# path. Hook mode's JSON cwd field gives a deterministic, drive-lettered base
# (REPO_DRIVE), so the original test exercises the genuine-mismatch branch;
# under check mode's real $PWD (undeterminable on this fixture's Git-Bash
# virtual /tmp mount, per the "== 9:" comment above and the "11:" section),
# it would silently fall through to the undeterminable-fallback branch
# instead - passing without exercising the mismatch detection this HIMMEL-845
# fix specifically added. Same class of gap as the "11: drive-relative" pair.
run_hook deny "845: cross-drive drive-relative (was fail-OPEN) -> deny" \
    "$(write_json "${OTHER_DRIVE}:hooks/y.sh" "$REPO/docs")" 1
run_hook deny "845: cross-drive drive-relative, backslash form -> deny" \
    "$(write_json "${OTHER_DRIVE}:hooks\\y.sh" "$REPO/docs")" 1
# (845-2) Bash-mode parity: the same shape reached through a command operand.
# NOT batchable - check mode never calls evaluate_command, so a Bash command
# string can only be exercised through the real hook-mode spawn.
run_hook deny "845: cross-drive drive-relative in a Bash operand -> deny" \
    "$(bash_json "cp /tmp/payload ${OTHER_DRIVE}:hooks/y.sh" "$REPO/docs")" 1

# (845-3) A drive-ROOTED absolute (`Z:/...`) is cwd-INDEPENDENT and must NOT be
# swept up by the cross-drive deny - it still classifies normally (this one
# resolves inside no git repo, so it allows exactly as before the fix).
run_check_batch "$REPO" \
    "845: drive-ROOTED other-drive absolute is not cross-drive -> allow" allow "${OTHER_DRIVE}:/elsewhere/scripts/hooks/y.sh"

# (845-4) SAME-drive drive-relative must keep anchoring exactly as before (the
# deny half is covered by the two `11:` cases above; this is the ALLOW half,
# proving the fix did not over-close). Only meaningful where the cwd's drive is
# lexically determinable - i.e. a Windows/drive-lettered host. NOT batchable
# (relative-cwd-anchoring gap, same reasoning as the "11: relative path
# anchored" case above - the ALLOW half specifically depends on $PWD's drive
# being correctly detected post-cd, which this fixture's virtual /tmp mount
# does not reliably reproduce).
if [ -n "$REPO_DRIVE" ]; then
    run_hook allow "845: same-drive drive-relative non-enforcement -> allow" \
        "$(write_json "${REPO_DRIVE}:README.md" "$REPO")" 1
    run_hook deny "845: same-drive drive-relative enforcement path -> deny" \
        "$(write_json "${REPO_DRIVE}:scripts/hooks/y.sh" "$REPO")" 1
else
    printf '  SKIP  845: same-drive drive-relative (no drive-lettered cwd on this host)\n'
fi

# (845-5) check mode reports the cross-drive class per-path AND keeps scanning
# the rest of the argument list (the deny is a classification, not an abort).
out=$(cd "$REPO" && env LESSON_FENCE_POLICY="$POLICY_COPY" "$BASH_BIN" "$FENCE" check \
    "${OTHER_DRIVE}:hooks/y.sh" "$REPO/README.md" 2>&1); rc=$?
if [ "$rc" -eq 2 ] \
    && grepq "$out" -E '^deny[[:space:]]+cross-drive[[:space:]]' \
    && grepq "$out" -E '^allow[[:space:]]+-[[:space:]]'; then
    pass "845: check mode -> cross-drive verdict + scan continues + exit 2"
else
    fail "845: check mode cross-drive rc=$rc out=$out"
fi

echo "== 12: CR-bypass fixes (round 2) - git -c hooksPath / cp,install -t / PS inline params =="
run_hook deny "12: git config --unset core.hooksPath" \
    "$(bash_json "git config --unset core.hooksPath" "$REPO")" 1
run_hook deny "12: git -c core.hooksPath=... commit (one-shot override)" \
    "$(bash_json "git -c core.hooksPath=/tmp/nohooks commit -m x" "$REPO")" 1
run_hook deny "12: cp -t scripts/hooks /tmp/x (target-directory, short flag)" \
    "$(bash_json "cp -t scripts/hooks /tmp/x" "$REPO")" 1
run_hook deny "12: install --target-directory=scripts/hooks /tmp/x (attached form)" \
    "$(bash_json "install --target-directory=scripts/hooks /tmp/x" "$REPO")" 1
run_hook deny "12: install --target-directory scripts/hooks /tmp/x (space form)" \
    "$(bash_json "install --target-directory scripts/hooks /tmp/x" "$REPO")" 1
run_hook deny "12: PowerShell Set-Content -Path:scripts/hooks/a.sh -Value x (inline param)" \
    "$(pwsh_json "Set-Content -Path:scripts/hooks/a.sh -Value x" "$REPO")" 1

run_hook allow "12: git config --get-all core.hooksPath (read)" \
    "$(bash_json "git config --get-all core.hooksPath" "$REPO")" 1
run_hook allow "12: git -c user.name=x commit -m y (non-hooksPath -c)" \
    "$(bash_json "git -c user.name=x commit -m y" "$REPO")" 1
run_hook allow "12: cp -t /tmp/somedir /tmp/x (non-enforcement target dir)" \
    "$(bash_json "cp -t /tmp/somedir /tmp/x" "$REPO")" 1
run_hook allow "12: PowerShell Set-Content -Path:/tmp/x.txt -Value y (non-enforcement inline param)" \
    "$(pwsh_json "Set-Content -Path:/tmp/x.txt -Value y" "$REPO")" 1

echo "== 13: CR-bypass fixes (round 3) - PS fs cmdlets / bare operands / git include.path =="
run_hook deny "13: PowerShell Remove-Item scripts/hooks/a.sh" \
    "$(pwsh_json "Remove-Item scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "13: PowerShell Copy-Item /tmp/x -Destination scripts/hooks/a.sh" \
    "$(pwsh_json "Copy-Item /tmp/x -Destination scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "13: PowerShell Move-Item scripts/guardrails/lib.sh /tmp/x" \
    "$(pwsh_json "Move-Item scripts/guardrails/lib.sh /tmp/x" "$REPO")" 1
run_hook deny "13: PowerShell New-Item -Path:.claude/settings.json" \
    "$(pwsh_json "New-Item -Path:.claude/settings.json" "$REPO")" 1
run_hook deny "13: cp /tmp/x hooks (bare-token operand, cwd=scripts/)" \
    "$(bash_json "cp /tmp/x hooks" "$REPO/scripts")" 1
run_hook deny "13: git -c include.path=/tmp/evil.cfg commit -m x" \
    "$(bash_json "git -c include.path=/tmp/evil.cfg commit -m x" "$REPO")" 1
run_hook deny "13: git config --add include.path /tmp/evil.cfg" \
    "$(bash_json "git config --add include.path /tmp/evil.cfg" "$REPO")" 1

run_hook allow "13: PowerShell Copy-Item /tmp/a /tmp/b" \
    "$(pwsh_json "Copy-Item /tmp/a /tmp/b" "$REPO")" 1
run_hook allow "13: PowerShell Remove-Item /tmp/x.txt" \
    "$(pwsh_json "Remove-Item /tmp/x.txt" "$REPO")" 1
run_hook allow "13: cp /tmp/x notes (bare-token operand, cwd=docs/, non-enforcement)" \
    "$(bash_json "cp /tmp/x notes" "$REPO/docs")" 1
run_hook allow "13: git config --get include.path (read)" \
    "$(bash_json "git config --get include.path" "$REPO")" 1

echo "== 14: round-3b CR fixes - PS builtin aliases / quoted git keys / -Value over-deny =="
run_hook deny "14: PowerShell sc .claude/settings.json x (alias -> Set-Content)" \
    "$(pwsh_json "sc .claude/settings.json x" "$REPO")" 1
run_hook deny "14: PowerShell ni -Path:scripts/hooks/evil.sh (alias -> New-Item)" \
    "$(pwsh_json "ni -Path:scripts/hooks/evil.sh" "$REPO")" 1
run_hook deny "14: PowerShell del scripts/guardrails/lib.sh (alias -> Remove-Item)" \
    "$(pwsh_json "del scripts/guardrails/lib.sh" "$REPO")" 1
run_hook deny "14: PowerShell copy /tmp/x scripts/hooks/a.sh (alias -> Copy-Item)" \
    "$(pwsh_json "copy /tmp/x scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "14: git -c 'core.hooksPath=/tmp/nohooks' commit -m x (single-quoted key=value)" \
    "$(bash_json "git -c 'core.hooksPath=/tmp/nohooks' commit -m x" "$REPO")" 1
run_hook deny "14: git config \"core.hooksPath\" /tmp/x (double-quoted key)" \
    "$(bash_json "git config \"core.hooksPath\" /tmp/x" "$REPO")" 1

run_hook allow "14: PowerShell Set-Content /tmp/ok.txt -Value scripts/hooks/a.sh (content, not target)" \
    "$(pwsh_json "Set-Content /tmp/ok.txt -Value scripts/hooks/a.sh" "$REPO")" 1
run_hook allow "14: PowerShell sc /tmp/ok.txt y (alias, non-enforcement target)" \
    "$(pwsh_json "sc /tmp/ok.txt y" "$REPO")" 1
run_hook allow "14: PowerShell del /tmp/x.txt (alias, non-enforcement target)" \
    "$(pwsh_json "del /tmp/x.txt" "$REPO")" 1
run_hook allow "14: git config --get 'core.hooksPath' (quoted read carve-out)" \
    "$(bash_json "git config --get 'core.hooksPath'" "$REPO")" 1

echo "== 15: round-4 CR-bypass fixes - inverted allow-list (ends the deny-list treadmill) =="
run_hook deny "15: echo x>scripts/hooks/a.sh (glued redirect, no spaces)" \
    "$(bash_json "echo x>scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "15: printf x>>.claude/settings.json (glued append)" \
    "$(bash_json "printf x>>.claude/settings.json" "$REPO")" 1
run_hook deny "15: ln -sf /tmp/evil scripts/hooks/block-lesson-enforcement-writes.sh (unlisted verb)" \
    "$(bash_json "ln -sf /tmp/evil scripts/hooks/block-lesson-enforcement-writes.sh" "$REPO")" 1
run_hook deny "15: truncate -s 0 scripts/guardrails/enforcement-paths.json (unlisted verb)" \
    "$(bash_json "truncate -s 0 scripts/guardrails/enforcement-paths.json" "$REPO")" 1
run_hook deny "15: mkdir scripts/hooks/evil (unlisted verb)" \
    "$(bash_json "mkdir scripts/hooks/evil" "$REPO")" 1
run_hook deny "15: cp -tscripts/hooks /tmp/x (glued -t, no separator)" \
    "$(bash_json "cp -tscripts/hooks /tmp/x" "$REPO")" 1

run_hook allow "15: cat scripts/hooks/a.sh (read-only allow-list)" \
    "$(bash_json "cat scripts/hooks/a.sh" "$REPO")" 1
run_hook allow "15: grep -r x scripts/guardrails/ (read-only allow-list)" \
    "$(bash_json "grep -r x scripts/guardrails/" "$REPO")" 1
run_hook allow "15: bash scripts/hooks/test-x.sh (interpreter, read-only allow-list)" \
    "$(bash_json "bash scripts/hooks/test-x.sh" "$REPO")" 1
run_hook allow "15: git show HEAD:scripts/hooks/a.sh (git read verb)" \
    "$(bash_json "git show HEAD:scripts/hooks/a.sh" "$REPO")" 1
run_hook allow "15: sed s/a/b/ scripts/guardrails/lib.sh (plain sed = read, no -i)" \
    "$(bash_json "sed s/a/b/ scripts/guardrails/lib.sh" "$REPO")" 1
run_hook allow "15: wc -l .pre-commit-config.yaml (read-only allow-list)" \
    "$(bash_json "wc -l .pre-commit-config.yaml" "$REPO")" 1
run_hook allow "15: truncate -s0 /tmp/x (unlisted verb, non-enforcement target)" \
    "$(bash_json "truncate -s0 /tmp/x" "$REPO")" 1

echo "== 16: round-5 CR fixes - inline-eval scan / wrapped git routing / multi-digit fd / uppercase env =="
run_hook deny "16: python -c open(...,'w') (inline-eval, enforcement signal)" \
    "$(bash_json "python -c \"open('scripts/hooks/x.sh','w')\"" "$REPO")" 1
run_hook deny "16: node -e fs.writeFileSync(...) (inline-eval, enforcement signal)" \
    "$(bash_json "node -e \"fs.writeFileSync('scripts/guardrails/x.sh','x')\"" "$REPO")" 1
run_hook deny "16: command git -c core.hooksPath=... commit (wrapped git routing)" \
    "$(bash_json "command git -c core.hooksPath=/tmp/nohooks commit -m x" "$REPO")" 1
run_hook deny "16: env git config --add include.path ... (wrapped git routing)" \
    "$(bash_json "env git config --add include.path /tmp/e.cfg" "$REPO")" 1
run_hook deny "16: 10> scripts/hooks/a.sh (standalone multi-digit fd redirect)" \
    "$(bash_json "10> scripts/hooks/a.sh" "$REPO")" 1

run_hook allow "16: python -c print(1) (inline-eval, no enforcement signal)" \
    "$(bash_json "python -c \"print(1)\"" "$REPO")" 1
run_hook allow "16: bash scripts/hooks/test-x.sh (executing a script file, still exempt)" \
    "$(bash_json "bash scripts/hooks/test-x.sh" "$REPO")" 1
run_hook allow "16: FOO=1 cat scripts/hooks/a.sh (uppercase env + reader)" \
    "$(bash_json "FOO=1 cat scripts/hooks/a.sh" "$REPO")" 1
run_hook allow "16: BAR=2 BAZ=3 grep x scripts/guardrails/lib.sh (multiple uppercase env + reader)" \
    "$(bash_json "BAR=2 BAZ=3 grep x scripts/guardrails/lib.sh" "$REPO")" 1

echo "== 17: round-6 CR fix - >| / >& clause-split bypass (target stranded across ;|& split) =="
run_hook deny "17: echo x >| scripts/hooks/a.sh (noclobber-override write)" \
    "$(bash_json "echo x >| scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x >|scripts/hooks/a.sh (glued, no space)" \
    "$(bash_json "echo x >|scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x 1>| scripts/hooks/a.sh (fd-prefixed noclobber-override)" \
    "$(bash_json "echo x 1>| scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x >& scripts/hooks/a.sh (both-streams-to-FILE)" \
    "$(bash_json "echo x >& scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x >&scripts/hooks/a.sh (glued, no space)" \
    "$(bash_json "echo x >&scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x &>| scripts/hooks/a.sh (all three metachars)" \
    "$(bash_json "echo x &>| scripts/hooks/a.sh" "$REPO")" 1
run_hook deny "17: echo x >| .claude/settings.json (noclobber-override, settings)" \
    "$(bash_json "echo x >| .claude/settings.json" "$REPO")" 1

run_hook allow "17: echo x >| /tmp/ok.txt (noclobber-override, non-enforcement target)" \
    "$(bash_json "echo x >| /tmp/ok.txt" "$REPO")" 1
run_hook allow "17: cat foo 2>&1 (fd-dup, no file write)" \
    "$(bash_json "cat foo 2>&1" "$REPO")" 1
run_hook allow "17: echo x >& /tmp/ok.txt (both-streams-to-FILE, non-enforcement target)" \
    "$(bash_json "echo x >& /tmp/ok.txt" "$REPO")" 1

echo "== 18: round-7 CR fix - process substitution >(...) / <(...) with a read-only outer verb =="
run_hook deny "18: echo x > >(tee scripts/hooks/a.sh) (outer echo is read-only-exempt, inner tee writes)" \
    "$(bash_json "echo x > >(tee scripts/hooks/a.sh)" "$REPO")" 1
run_hook deny "18: cat foo > >(tee scripts/hooks/a.sh) (outer cat is read-only-exempt, inner tee writes)" \
    "$(bash_json "cat foo > >(tee scripts/hooks/a.sh)" "$REPO")" 1
run_hook deny "18: echo x 1> >(tee scripts/hooks/a.sh) (fd-prefixed redirect to procsub)" \
    "$(bash_json "echo x 1> >(tee scripts/hooks/a.sh)" "$REPO")" 1
run_hook deny "18: echo x > >(dd of=.claude/settings.json) (dd of= inside procsub)" \
    "$(bash_json "echo x > >(dd of=.claude/settings.json)" "$REPO")" 1
# NOTE: this one also reads an enforcement path via INPUT process substitution
# (<(cat scripts/guardrails/lib.sh)) - under the coarse substring gate that
# denies too (the scan can't tell input from output procsub, same
# over-blocking posture as the fence's own `<` treatment); a loop worker
# rarely needs to diff an enforcement file via procsub, so this is an
# accepted safe-direction cost, not a bug.
run_hook deny "18: diff <(cat scripts/guardrails/lib.sh) x > >(tee CLAUDE.md) (input procsub of enforcement path + output procsub writer)" \
    "$(bash_json "diff <(cat scripts/guardrails/lib.sh) x > >(tee CLAUDE.md)" "$REPO")" 1

run_hook allow "18: echo x > >(tee /tmp/ok.txt) (procsub, non-enforcement target)" \
    "$(bash_json "echo x > >(tee /tmp/ok.txt)" "$REPO")" 1
run_hook allow "18: echo hi > /tmp/ok.txt (no procsub at all)" \
    "$(bash_json "echo hi > /tmp/ok.txt" "$REPO")" 1
run_hook allow "18: cat scripts/hooks/a.sh (plain read, no procsub, still allowed)" \
    "$(bash_json "cat scripts/hooks/a.sh" "$REPO")" 1

echo "== 19: apply_patch (Codex create/edit envelope, HIMMEL-2170) =="
run_hook deny "19: Add File targeting a fenced path -> deny" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Add File: %s/scripts/hooks/y.sh\n+hi\n*** End Patch\n' "$REPO")" "$REPO")" 1
run_hook deny "19: Update File targeting a fenced path -> deny" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Update File: %s/scripts/guardrails/x.sh\n@@\n-a\n+b\n*** End Patch\n' "$REPO")" "$REPO")" 1
run_hook deny "19: Delete File targeting a fenced path -> deny" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Delete File: %s/.claude/settings.json\n*** End Patch\n' "$REPO")" "$REPO")" 1
run_hook allow "19: Add File targeting a non-fenced path -> allow" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Add File: %s/scripts/foo.sh\n+hi\n*** End Patch\n' "$REPO")" "$REPO")" 1
run_hook deny "19: malformed patch text (no Add/Update/Delete File line) -> deny (fail-closed under HIMMEL_LESSON_LOOP=1)" \
    "$(apply_patch_json "not a patch at all, no File: lines here" "$REPO")" 1
run_hook deny "19: multi-target, only ONE fenced -> deny" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Add File: %s/scripts/foo.sh\n+hi\n*** Update File: %s/scripts/hooks/y.sh\n@@\n-a\n+b\n*** End Patch\n' "$REPO" "$REPO")" "$REPO")" 1
run_hook allow "19: multi-target, ALL non-fenced -> allow" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Add File: %s/scripts/foo.sh\n+hi\n*** Add File: %s/README.md\n+hi\n*** End Patch\n' "$REPO" "$REPO")" "$REPO")" 1
run_hook allow "19: inactive (HIMMEL_LESSON_LOOP unset) -> exit 0 even for a fenced target" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Add File: %s/scripts/hooks/y.sh\n+hi\n*** End Patch\n' "$REPO")" "$REPO")" 0

# HIMMEL-2170 CR round 1: "*** Move to: " is an OPTIONAL line immediately
# following "*** Update File: " (verified against codex-rs/apply-patch/src/
# parser.rs, openai/codex@18b9e7fd9e3f6670cc4f300338e44050b2c301e4 -
# MOVE_TO_MARKER + the update_hunk/change_move grammar). An Update on an
# ALLOWED source must still deny if the MOVE DESTINATION is fenced.
run_hook deny "19: Update allowed-source + Move to fenced destination -> deny" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Update File: %s/scripts/foo.sh\n*** Move to: %s/scripts/hooks/y.sh\n@@\n-a\n+b\n*** End Patch\n' "$REPO" "$REPO")" "$REPO")" 1
run_hook allow "19: Update allowed-source + Move to allowed destination -> allow" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Update File: %s/scripts/foo.sh\n*** Move to: %s/README.md\n@@\n-a\n+b\n*** End Patch\n' "$REPO" "$REPO")" "$REPO")" 1

# CodeRabbit round (HIMMEL-2170): a Move-to that is NOT immediately preceded
# by an Update File line is malformed patch syntax per the grammar (Move-to
# is a sub-production of update_hunk only) - it must deny fail-closed, the
# SAME as any other unparseable apply_patch, not be silently classified as
# an ordinary target.
run_hook deny "19: standalone Move-to (no preceding Update File) -> deny (malformed, fail-closed)" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Move to: %s/scripts/foo.sh\n*** End Patch\n' "$REPO")" "$REPO")" 1
run_hook deny "19: Move-to after Delete File -> deny (malformed, fail-closed)" \
    "$(apply_patch_json "$(printf '*** Begin Patch\n*** Delete File: %s/scripts/foo.sh\n*** Move to: %s/scripts/bar.sh\n*** End Patch\n' "$REPO" "$REPO")" "$REPO")" 1

echo "== regression: real policy loads cleanly via check mode =="
out=$(cd "$REPO_ROOT" && "$BASH_BIN" "$FENCE" check scripts/hooks/x .claude/settings.json README.md 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i deny; then
    pass "real policy: live smoke shows 2 denies + exit 2"
else
    fail "real policy live smoke: rc=$rc out=$out"
fi

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
