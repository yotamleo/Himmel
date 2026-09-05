#!/usr/bin/env bash
# Tests for cr/clear-cr-marker.sh — the HIMMEL-1064 CR-marker clearing
# chokepoint. The script has NO env seams for the ledger / check-ci / gh (gate
# integrity — a caller-pointed ledger would forge the very evidence the clear
# depends on). So each case builds a REAL temp git repo, copies the script tree
# into it ($tmp/scripts/cr/clear-cr-marker.sh + a stub $tmp/scripts/check-ci.sh)
# and puts a stub `gh` FIRST on PATH. The ledger + marker are written at the
# fixed paths under the temp repo's own .git, exactly as the real ones resolve.
set -uo pipefail

# HIMMEL-1495 — an --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent in test-check-ci.sh,
# generalized). clear-cr-marker.sh does not consult either var today, so this
# is defense-in-depth for the day a sourced lib reads one — the canary case
# below pins today's insensitivity.
unset ARMAUTOMERGE CR_MERGE_GATE_OK CR_REQUIRE_CROSS_MODEL

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEAR="$SCRIPT_DIR/clear-cr-marker.sh"
LEDGER_APPEND="$SCRIPT_DIR/ledger-append.sh"
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"
CODEX_SKILL="$ROOT/.agents/skills/pr-check/SKILL.md"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"
# HIMMEL-2544: case 2f's mutation control goes through the RED-control
# contract helper (HIMMEL-2518) rather than a hand-rolled comparison, so the
# mutant's exit status, its produced value and the SPECIFIC predicted wrong
# value are all asserted rather than merely "it differed from something".
# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/red-control.sh"

PASS=0
FAIL=0
LAST_CLEAR_OUT=""
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# build_repo_template — HIMMEL-2120: builds the make_repo() fixture tree ONCE
# into REPO_TEMPLATE instead of re-running the full git init/commit/push
# sequence per call (~99 call sites). Micro-A/B (5 reps): build-from-scratch
# 37.8s vs template-copy 2.0s — the copy path wins by ~18x, so make_repo()
# below just cp -r's this template. Byte-for-byte the same build the old
# per-call make_repo() did (git sequence + the three dirs + the three cp's).
REPO_TEMPLATE=""
build_repo_template() {
    REPO_TEMPLATE=$(fixture_mktemp_dir) || return 1
    (
        fixture_enter_git_init_dir "$REPO_TEMPLATE" || exit 1
        git init -q -b main .
        git config user.email t@t.t; git config user.name t
        echo hi > f.txt
        git add f.txt
        git commit -qm "base"
        git checkout -qb feat/x
        echo more >> f.txt
        git commit -qam "work"
        git init -q --bare .git/test-origin.git
        git remote add origin .git/test-origin.git
        git push -q -u origin feat/x
    ) >/dev/null 2>&1 || { rm -rf "$REPO_TEMPLATE"; return 1; }
    # HIMMEL-2120 CR: this file is `set -uo pipefail` (no -e by house style), so
    # each of these must be guarded explicitly — an unguarded failure here would
    # let the function return 0 with a half-built template (e.g. no TEMPLATE_SHA,
    # or scripts/cr missing) that every make_repo() copy would then silently share.
    TEMPLATE_SHA=$(git -C "$REPO_TEMPLATE" rev-parse --verify refs/heads/feat/x) \
        || { echo "FAIL: rev-parse refs/heads/feat/x failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    mkdir -p "$REPO_TEMPLATE/scripts/cr" "$REPO_TEMPLATE/scripts/lib" "$REPO_TEMPLATE/bin" \
        || { echo "FAIL: mkdir of template scaffold dirs failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    cp "$CLEAR" "$REPO_TEMPLATE/scripts/cr/clear-cr-marker.sh" \
        || { echo "FAIL: cp clear-cr-marker.sh into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    cp "$LEDGER_APPEND" "$REPO_TEMPLATE/scripts/cr/ledger-append.sh" \
        || { echo "FAIL: cp ledger-append.sh into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    # HIMMEL-1558: the copied tree must carry the branch-lock lib the clear
    # path now takes around its read-validate-delete section — the script
    # refuses without it, so a missing copy would fail every case at once.
    cp "$LOCK_LIB" "$REPO_TEMPLATE/scripts/lib/shared-branch-lock.sh" \
        || { echo "FAIL: cp shared-branch-lock.sh into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
}
trap '[ -n "$REPO_TEMPLATE" ] && rm -rf "$REPO_TEMPLATE"' EXIT
build_repo_template || { echo "FAIL: could not build repo template fixture" >&2; exit 1; }

# make_repo — a temp git repo with one commit on branch `feat/x`, copied from
# REPO_TEMPLATE (built once above) rather than rebuilt per call. Sets the
# shared vars `tmp` and `sha` directly rather than echoing them
# whitespace-separated for `read` (coderabbit): a mktemp path containing a space
# would split across both values and corrupt the harness. Scripts here run on
# Windows Git Bash / macOS / Linux, where a spaced TMPDIR is entirely possible.
make_repo() {
    tmp=$(fixture_mktemp_dir) || return 1
    cp -r "$REPO_TEMPLATE"/. "$tmp"/ || { rm -rf "$tmp"; return 1; }
    sha="$TEMPLATE_SHA"
}

# write_marker <tmp> <sha> [lane] [endpoint] [base]
# 7-field format (HIMMEL-1540 identity contract): endpoint defaults to the
# repo-relative URL of make_repo's real test-origin bare (clear-cr-marker runs
# with cwd=$tmp, so ls-remote resolves it); base defaults to the repo's main.
write_marker() {
    local tmp="$1" sha="$2" lane="${3:-full}" endpoint="${4:-.git/test-origin.git}" base="${5:-}"
    if [ -z "$base" ]; then
        base=$(git -C "$tmp" rev-parse --verify refs/heads/main 2>/dev/null || echo deadbeef)
    fi
    mkdir -p "$tmp/.git/cr-pending/feat"
    printf '2026-07-16T10:00:00+02:00 | %s | %s | origin | refs/heads/feat/x | %s | %s\n' "$sha" "$lane" "$endpoint" "$base" > "$tmp/.git/cr-pending/feat/x"
}

# write_ledger <tmp> <jsonl-lines...>
write_ledger() {
    local tmp="$1"; shift
    : > "$tmp/.git/cr-critic-scores.jsonl"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$tmp/.git/cr-critic-scores.jsonl"; done
}

avail_ok()   { printf '{"kind":"avail","head":"%s","model":"codex","status":"ok"}' "$1"; }
avail_bad()  { printf '{"kind":"avail","head":"%s","model":"coderabbit","status":"unavailable"}' "$1"; }
# HIMMEL-1224 — the Claude-only floor evidence: a self-review avail row with
# model "claude", the ONLY avail row a zero-external-critic adopter produces.
avail_ok_claude() { printf '{"kind":"avail","head":"%s","model":"claude","status":"ok"}' "$1"; }
# avail_reason <head> <model> <status> [reason] — HIMMEL-2128: a non-Claude
# avail row carrying an optional --reason (HIMMEL-1176 failure classification),
# the shape CR_FLOOR_FALLBACK=claude-only reads to judge verified exhaustion.
avail_reason() {
    local head="$1" model="$2" status="$3" reason="${4:-}"
    if [ -n "$reason" ]; then
        printf '{"kind":"avail","head":"%s","model":"%s","status":"%s","reason":"%s"}' "$head" "$model" "$status" "$reason"
    else
        printf '{"kind":"avail","head":"%s","model":"%s","status":"%s"}' "$head" "$model" "$status"
    fi
}
finding()    { printf '{"kind":"finding","head":"%s","model":"codex","finding_id":"codex-1","severity":"%s","file":"a.sh","line":1,"verdict":"%s"}' "$1" "$2" "$3"; }

# stub_gh <tmp> <pr-number-or-empty> [head-sha]
# Empty pr => the genuine "no PR yet" shape. NOTE the shape is `gh pr list --head`,
# NOT `gh pr view`: a head query with no match SUCCEEDS with empty output. (An
# rc=1 "no pull requests found" is the `pr view` shape — this gate no longer
# uses it, because a positional lookup would resolve a numeric branch to a PR
# number.) A real auth/network failure is a DIFFERENT shape — see stub_gh_broken.
#
# The gate now asks for `number,headRefOid`, so the stub emits the real
# `<number> <full-sha>` pair. head-sha defaults to the branch tip (the normal
# pushed-PR state); pass a different SHA for the mismatch case.
stub_gh() {
    local tmp="$1" pr="${2:-}" head="${3:-${sha:-}}"
    if [ -z "$pr" ]; then
        cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fail closed unless the lookup is an explicit --head query — a positional
# `gh pr view <branch>` must never satisfy these tests (coderabbit).
for a in "$@"; do [ "$a" = "--head" ] && exit 0; done
echo "positional PR lookup used" >&2
exit 1
STUB
    else
        cat > "$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--head" ] && { echo "$pr $head"; exit 0; }; done
echo "positional PR lookup used" >&2
exit 1
STUB
    fi
    chmod +x "$tmp/bin/gh"
}

# stub_gh_broken <tmp> — gh fails for a reason that is NOT "no PR" (auth
# expired, network, API 500). The PR state is UNKNOWN, so the gate must refuse
# rather than fall through to the pre-PR path (codex-1).
stub_gh_broken() {
    cat > "$1/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "HTTP 401: Bad credentials" >&2
exit 1
STUB
    chmod +x "$1/bin/gh"
}

# stub_check_ci <tmp> <rc> [stdout]
stub_check_ci() {
    printf '#!/usr/bin/env bash\n' > "$1/scripts/check-ci.sh"
    if [ -n "${3:-}" ]; then printf "printf '%%s\\n' %q\n" "$3" >> "$1/scripts/check-ci.sh"; fi
    printf 'exit %s\n' "$2" >> "$1/scripts/check-ci.sh"
    chmod +x "$1/scripts/check-ci.sh"
}

# run_clear <tmp> <expected-rc> <name> [args...]
run_clear() {
    local tmp="$1" expected="$2" name="$3"; shift 3
    local rc=0 out
    out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-cr-marker.sh" "$@" 2>&1) || rc=$?
    LAST_CLEAR_OUT="$out"
    if [ "$rc" -eq "$expected" ]; then pass; else
        fail "$name (expected rc=$expected, got $rc)"; echo "    out: $out" >&2
    fi
}

# append_ledger <tmp> <name> <kind+args...>
append_ledger() {
    local tmp="$1" name="$2"; shift 2
    local rc=0 out
    out=$(cd "$tmp" && bash "$tmp/scripts/cr/ledger-append.sh" "$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then pass; else
        fail "$name (ledger append rc=$rc)"; echo "    out: $out" >&2
    fi
}

marker_exists() { [ -f "$1/.git/cr-pending/feat/x" ]; }

echo "== clear-cr-marker.sh tests =="

# Codex /pr-check contract: ledger evidence must precede the sanctioned clear
# chokepoint, and the skill must not self-declare clean with a bare marker rm.
#
# HIMMEL-2226 — the skill now resolves `himmel_dir=$(git rev-parse --show-toplevel)`
# and spells every himmel script as "$himmel_dir/scripts/cr/<name>.sh", i.e. the
# closing quote lands AFTER `.sh`, which silently un-matched the pre-2226
# `<name>.sh <subcommand>` patterns. What the contract is actually about is
# WHICH script runs with WHICH subcommand, never how the path was spelled, so
# these patterns accept the quoted-var form, an absolute literal and a bare
# relative path alike — and still fail if the invocation disappears.
#
# HIMMEL-2321 — the blocking-finding evidence verb is now `amend`, not
# `finding`, and that is the contract change these patterns track. The
# PRODUCERS (critic-panel.sh, coderabbit-review.sh, codex-adv-harvest.sh)
# self-write each finding row with the reviewer's own file/line/text, so the
# skill's job shrank to recording a verdict on a row that already exists —
# an id and a closed-vocabulary word, carrying no reviewer-authored byte
# through a shell fence. What these three assertions are actually about is
# unchanged: blocking-finding evidence reaches the ledger, it does so BEFORE
# the clear chokepoint, and each such command binds the full HEAD SHA. Only
# the subcommand that carries it moved.
# shellcheck disable=SC2016  # ERE fragment; $ is an anchor, do not expand
skill_invocation_re() {
    printf 'bash [^[:space:]]*%s\\.sh"?[[:space:]]+%s([[:space:]]|$)' "$1" "$2"
}
if grep -Eq "$(skill_invocation_re ledger-append amend)" "$CODEX_SKILL"; then pass; else
    fail "Codex skill records blocking findings in the CR ledger"
fi
if grep -Eq "$(skill_invocation_re ledger-append avail)" "$CODEX_SKILL"; then pass; else
    fail "Codex skill records critic availability in the CR ledger"
fi
# HIMMEL-2343: the full HEAD SHA is no longer captured into a shell variable —
# PR #2050/HIMMEL-2226 rewrote the runbook from shell-variable form to
# SUBSTITUTED-LITERAL form, because a Codex fence inherits no variables
# between blocks (each fenced block is a separate process, confirmed by
# HIMMEL-2314) — so `head=$(...)` never survives to a later block anyway. Step
# 0 calls scripts/cr/pr-check-context.sh, and the runbook's prose instructs
# carrying its printed `head=` line forward as the SUBSTITUTED LITERAL
# `<head>` into every later block. Pin all three links of that chain — the
# context call, the prose that instructs carrying `head=` forward as `<head>`,
# and at least one `--head <head>` binding — so swapping in a fresh
# `git rev-parse HEAD` (or any other `head=` capture) or dropping the binding
# still fails here.
# shellcheck disable=SC2016  # literal markdown backticks in the quoted prose; not command substitution
if grep -Eq 'bash [^[:space:]]*pr-check-context\.sh"?' "$CODEX_SKILL" \
    && grep -Fq -- 'substituted literal `<branch>` / `<head>` / `<marker>`' "$CODEX_SKILL" \
    && grep -Fq -- '--head <head>' "$CODEX_SKILL"; then pass; else
    fail "Codex skill records ledger evidence with the full HEAD SHA"
fi
# HIMMEL-2343: the clear invocation is now spelled with the substituted
# literal `'<branch>'`, not the shell variable `"$branch"` (same fence-block
# rationale as above).
if grep -Eq "$(skill_invocation_re clear-cr-marker "'<branch>'")" "$CODEX_SKILL"; then pass; else
    fail "Codex skill routes marker clearing through clear-cr-marker.sh"
fi
# shellcheck disable=SC2016  # literal forbidden contract; do not expand $marker
if grep -Eq '(^|[;&|])[[:space:]]*(if[[:space:]]+)?!?[[:space:]]*rm([[:space:]]|$)[^;&|]*(\$marker|\$\{marker\})' "$CODEX_SKILL"; then
    fail "Codex skill must not clear its CR marker with direct rm"
else
    pass
fi

# Ordering contract (coderabbit-2, HIMMEL-1171): the skill must document the
# HEAD capture + ledger evidence (finding + avail) BEFORE it invokes the
# sanctioned clear chokepoint — guards against a future reorder that would
# clear before recording evidence. (The ledger-append calls span multiple
# lines, so ordering tracks each command's FIRST occurrence; the --head <head>
# binding is asserted separately below.) HIMMEL-2343: the `head` anchor is now
# the pr-check-context.sh invocation itself — that IS the capture point in
# literal-form (there is no `head=...` shell assignment left to anchor on).
contract_order_ok() {
    # Only lines with NO backtick count as the executable contract (codex-1 on
    # PR #2086): every anchor below matches on TEXT, so a prose sentence that
    # merely mentions one of these commands could satisfy an ordering
    # constraint the real, executable step never satisfies -- e.g. a future
    # paragraph above step 0 saying "run `bash .../pr-check-context.sh` first"
    # would become the `head` anchor and let a genuine reorder of the step-0
    # command past the ledger appends still pass. In this file's runbooks the
    # executable steps live in INDENTED code blocks (no backticks) while every
    # prose mention is markdown inline code (backticked), so excluding
    # backticked lines separates the two exactly. Fail-closed by construction:
    # if the shape ever changes so no unbackticked line matches, the anchor is
    # simply never set and contract_order_ok returns FALSE.
    awk '
        /`/ { next }
        !head  && /bash [^[:space:]]*pr-check-context\.sh"?/                { head = NR }
        !find_ && /bash [^[:space:]]*ledger-append\.sh"?[[:space:]]+amend/   { find_ = NR }
        !avail && /bash [^[:space:]]*ledger-append\.sh"?[[:space:]]+avail/   { avail = NR }
        !clear && /bash [^[:space:]]*clear-cr-marker\.sh"?[[:space:]]+.?<branch>/ { clear = NR }
        END { exit !(head && find_ && avail && clear &&
                     head < find_ && head < avail &&
                     find_ < clear && avail < clear) }
    ' "$CODEX_SKILL"
}
if contract_order_ok; then pass; else
    fail "Codex skill records ledger evidence before marker clearing"
fi
# Each ledger-append command must bind --head <head> within its OWN
# (multi-line) continuation block — not merely somewhere in the file (coderabbit
# r2). Walk each `ledger-append.sh <kind>` command to its end-of-continuation.
# HIMMEL-2343: the bound literal is now `<head>`, not `"$head"` — same
# fence-block rationale as the assertions above.
# shellcheck disable=SC2016  # awk field refs ($0) below; do not expand
ledger_command_has_head() {
    awk -v kind="$1" '
        $0 ~ "bash [^[:space:]]*ledger-append\\.sh\"?[[:space:]]+" kind {
            if (command) invalid = 1
            command = 1
            bound = 0
            seen = 1
        }
        command {
            if (index($0, "--head <head>")) bound = 1
            if ($0 !~ /\\[[:space:]]*$/) {
                if (!bound) invalid = 1
                command = 0
            }
        }
        END { exit !(seen && !command && !invalid) }
    ' "$CODEX_SKILL"
}
if ledger_command_has_head amend && ledger_command_has_head avail; then
    pass
else
    fail "Codex skill binds each ledger evidence command to the full HEAD SHA"
fi

# 1. No marker at all → nothing to do, exit 0.
make_repo || exit 1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "no marker → exit 0"
rm -rf "$tmp"

# 2. Happy path, pre-PR: marker SHA == tip, a critic responded, no findings.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "pre-PR clean → exit 0"
if marker_exists "$tmp"; then fail "pre-PR clean: marker should be GONE"; else pass; fi
if grepq "$LAST_CLEAR_OUT" 'stale-marker-superseded-by-ledger-at-tip'; then
    fail "fresh marker clear must use the ordinary audit path"
else
    pass
fi
rm -rf "$tmp"

# 2b. The ledger's SHORT head must match the full tip (prefix match).
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:7}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "short-sha ledger head matches full tip → exit 0"
rm -rf "$tmp"

# stub_git_log_lsremote_argv <tmp> — records the exact argv of every
# `ls-remote` invocation to a file, then execs the real git so the flow
# proceeds normally. Used to pin the `--` separator (HIMMEL-2077): without it,
# a marker_endpoint value crafted to start with `-` is parsed as an ls-remote
# OPTION instead of the repository argument.
stub_git_log_lsremote_argv() {
    local tmp="$1" real
    real=$(command -v git)
    cat > "$tmp/bin/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ls-remote" ]; then
    printf '%s\n' "\$*" >> "$tmp/.lsremote-argv"
fi
exec "$real" "\$@"
STUB
    chmod +x "$tmp/bin/git"
}

# 2b1. HIMMEL-2077: `git ls-remote --heads` must invoke with a `--` separator
# before the endpoint/ref positionals, so a marker_endpoint on-disk value that
# happens to start with `-` cannot be parsed as an ls-remote OPTION.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
stub_git_log_lsremote_argv "$tmp"
run_clear "$tmp" 0 "HIMMEL-2077 fixture: ordinary clear still succeeds with the argv-logging git shim"
lsremote_argv="$(cat "$tmp/.lsremote-argv" 2>/dev/null || true)"
if [ -n "$lsremote_argv" ] && grepq "$lsremote_argv" -F -- '--heads -- '; then
    pass "ls-remote invoked with -- before the positionals"
else
    fail "ls-remote missing the -- separator before positionals: ${lsremote_argv:-<no argv log>}"
fi
rm -rf "$tmp"

# 2b2. HIMMEL-2020: critic-panel writes raw finding rows at the full SHA, while
# a runbook using a short HEAD used to append the adjudicated verdict under a
# parallel short key. The short verdict append must normalize onto the full-key
# finding, so the disproved panel candidate stops blocking the marker.
make_repo || exit 1
_short=$(git -C "$tmp" rev-parse --short "$sha")
write_marker "$tmp" "$sha"
append_ledger "$tmp" "panel raw finding at full head" finding \
    --branch feat/x --head "$sha" --model codex --id codex-1 \
    --severity imp --file scripts/example.sh --line 7 --verdict ""
append_ledger "$tmp" "adjudicated verdict append at short head" finding \
    --branch feat/x --head "$_short" --model codex --id codex-1 \
    --severity imp --file scripts/example.sh --line 7 --verdict disproved
append_ledger "$tmp" "responder at short head normalizes" avail \
    --branch feat/x --head "$_short" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "full panel row plus short disproved verdict clears → exit 0"
if marker_exists "$tmp"; then fail "full+short verdict normalization: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 2d. A ledger head that only ABBREVIATES ambiguously must NOT certify the tip.
# This is finding (b) from public #468: the shipped gate matched ledger heads by
# string prefix, so a record written for a DIFFERENT commit whose abbreviation
# collides with the tip satisfied gates 3/4 — evidence for one commit clearing
# the marker of another.
#
# A real 7-char collision cannot be brute-forced in a test, so we produce the
# state a collision CREATES: a prefix git itself calls ambiguous. Copying an
# existing commit object to a filename sharing the tip's first 7 chars gives the
# prefix two commit candidates ("error: short object ID <x> is ambiguous"), which
# is exactly what the ledger head would hit in the real case. Resolve-then-compare
# yields no match => 14. Prefix matching yields a CLEARED marker => 0.
make_repo || exit 1
_tip7="${sha:0:7}"
_other=$(git -C "$tmp" rev-parse --verify "refs/heads/feat/x^")
cp "$tmp/.git/objects/${_other:0:2}/${_other:2}" \
   "$tmp/.git/objects/${sha:0:2}/${sha:2:5}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Guard: assert the setup really produced AMBIGUITY, else this test passes
# vacuously (a test that cannot fail is worse than no test). A non-zero
# rev-parse alone is not enough (coderabbit): it would also cover a setup that
# broke for an unrelated reason, and the exit-14 assertion below would then be
# testing something other than the collision shape this case exists for. Require
# git's own ambiguity diagnostic. LC_ALL=C pins the message; `2>&1 >/dev/null`
# captures stderr ONLY (order matters — stderr to the capture, stdout dropped),
# and --quiet is omitted so the diagnostic is actually emitted.
_amb_err=$(LC_ALL=C git -C "$tmp" rev-parse --verify "${_tip7}^{commit}" 2>&1 >/dev/null)
_amb_rc=$?
if [ "$_amb_rc" -eq 0 ]; then
    fail "2d setup: '${_tip7}' still resolves — the ambiguity was not created"
elif ! grepq "$_amb_err" 'is ambiguous'; then
    fail "2d setup: '${_tip7}' failed to resolve but NOT from ambiguity — the collision shape was not reproduced (git said: ${_amb_err})"
else
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "$_tip7")"
    stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
    run_clear "$tmp" 14 "ambiguous ledger abbreviation does not certify the tip → exit 14"
    if marker_exists "$tmp"; then pass; else fail "ambiguous ledger head: marker must REMAIN"; fi
fi
rm -rf "$tmp"

# 2c. A too-short/garbage head must NOT match everything (the >=7 guard).
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" '{"kind":"avail","head":"x","model":"codex","status":"ok"}'
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "garbage 1-char ledger head does not match → exit 14"
if marker_exists "$tmp"; then pass; else fail "garbage head: marker must REMAIN"; fi
rm -rf "$tmp"

# 2e. A short head naming a DIFFERENT, resolvable commit must not certify the
# tip (HIMMEL-2190). This is the shape ~every historical row in the real,
# append-only ledger has, and the one the prefix pre-filter short-circuits: the
# head resolves fine, it is simply not this commit. The verdict must be
# identical to what resolve-then-compare produced before the filter existed
# (refuse, 14) — the filter is a performance guard, never a decision. Paired
# with case 1's "short-sha ledger head matches full tip" (a short head that IS a
# prefix must still resolve and still clear) and with 2d (a prefix that is
# AMBIGUOUS must still resolve to nothing and still refuse), this pins all three
# arms of atHead.
make_repo || exit 1
_other=$(git -C "$tmp" rev-parse --verify "refs/heads/feat/x^")
_other8="${_other:0:8}"
# Guard against a vacuous pass: the case only exercises the pre-filter if the
# other head really is (a) resolvable and (b) NOT a prefix of the tip. A first-
# byte collision would silently turn this into a re-run of 2d.
if [ "${sha:0:8}" = "$_other8" ]; then
    fail "2e setup: '$_other8' collides with the tip prefix — non-prefix shape not reproduced"
elif ! git -C "$tmp" rev-parse --verify --quiet "${_other8}^{commit}" >/dev/null 2>&1; then
    fail "2e setup: '$_other8' does not resolve — the resolvable-other-commit shape was not reproduced"
else
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "$_other8")"
    stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
    run_clear "$tmp" 14 "short ledger head at a DIFFERENT commit does not certify the tip → exit 14"
    if marker_exists "$tmp"; then pass; else fail "short head at other commit: marker must REMAIN"; fi
fi
rm -rf "$tmp"

# _audit_reason <captured-stdout> — the refusal reason out of
# clear-cr-marker.sh's own audit line. audit() writes "<ts> clear-cr-marker
# REFUSED reason=<r> ..." to STDOUT (the transcript); diagnostics go to stderr.
# Case 2f asserts on this reason because the mutant and the shipped script must
# refuse for the SAME reason: the HIMMEL-2190 pre-filter is a performance
# guard, never a decision. That invariance is the half of the evidence that
# makes the resolve() spawn the ONLY discriminator between the two arms
# (HIMMEL-2544).
_audit_reason() {
    printf '%s\n' "$1" \
        | sed -n 's/.*clear-cr-marker REFUSED reason=\([^ ]*\).*/\1/p' \
        | sed -n '1p'
}

# 2f. HIMMEL-2190 prefix pre-filter, MUTATION test (HIMMEL-2029, GitHub issue
# #2010 deferred CodeRabbit finding: "the new regression test checks only the
# unchanged refusal verdict, so it would still pass if the prefix pre-filter
# were removed"). 2e above pins the VERDICT the filter must never change, but
# resolve()-then-compare produces the SAME exit-14 refusal with or without the
# filter, so 2e alone cannot tell whether the filter still runs. This case adds
# the missing half: prove the filter actually SKIPS the resolve() git spawn for
# a non-prefix head on the shipped script (unmutated arm), then build a mutant
# copy of clear-cr-marker.sh with the ONE filter line removed and prove that
# mutant (a) still refuses with the SAME verdict — the filter is a performance
# guard, never a decision — while (b) NOW spawning the resolve() call the
# filter used to skip. Arm (b) is the property that goes RED if the real
# filter is ever deleted; 2e's verdict-only assertion cannot see that at all.
#
# HIMMEL-2544: arm (b) is now stated as a single RED-control CONTRACT assertion
# (scripts/lib/red-control.sh, HIMMEL-2518) instead of three hand-rolled
# comparisons. The contract asserts the mutant RAN (rc=14, same refusal), that
# it PRODUCED a value, and that the value is the SPECIFIC predicted wrong one —
# `reason=<same> marker=present resolve_spawned=yes`. The audited refusal
# reason is deliberately part of the observed value: it is the INVARIANCE half
# of the evidence (the pre-filter must not change the verdict), so a mutant
# that refused for some OTHER reason is reported as wrong-mutation rather than
# silently credited with the spawn it caused. Both predicted values are derived
# from the unmutated arm above, never hardcoded.
#
# Instrumented via GIT_TRACE, not a PATH shim: clear-cr-marker.sh's resolve()
# runs `git rev-parse ...` from inside an embedded `node -e` script via
# child_process.execFileSync("git", ...), with no shell. On native Windows
# that spawn resolves "git" straight to the real .exe on PATH — the loader
# only auto-appends ".exe", never the shell's PATHEXT list, so a PATH-shimmed
# *extensionless* script (the shape stub_git_log_lsremote_argv above uses for
# BASH-invoked git calls) is invisible to it, and Node refuses to spawn a
# `.cmd`/`.bat` shim at all without `shell:true`. git's own GIT_TRACE facility
# sidesteps both: the real git binary honors it, execFileSync's child inherits
# it like any other env var, and it needs no executable stub at all.
make_repo || exit 1
_other=$(git -C "$tmp" rev-parse --verify "refs/heads/feat/x^")
_other8="${_other:0:8}"
# Same two setup guards as 2e above — still needed here for the same reason.
if [ "${sha:0:8}" = "$_other8" ]; then
    fail "2f setup: '$_other8' collides with the tip prefix — non-prefix shape not reproduced"
elif ! git -C "$tmp" rev-parse --verify --quiet "${_other8}^{commit}" >/dev/null 2>&1; then
    fail "2f setup: '$_other8' does not resolve — the resolvable-other-commit shape was not reproduced"
else
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "$_other8")"
    stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
    # The exact resolve() invocation atHead makes for this head — git's own
    # trace quotes it (single-quoted: the args contain `{`/`}`).
    _resolve_needle="rev-parse --verify --quiet '${_other8}^{commit}'"

    # Unmutated arm: the shipped script. stdout (the audit transcript) is
    # captured SEPARATELY from stderr now — the audited refusal reason feeds
    # the RED control's predicted values below and must not be polluted by
    # diagnostics; stderr is still surfaced in every failure message here.
    rm -f "$tmp/.git-trace.log"
    _rc=0
    _errfile="$tmp/.2f-unmutated.err"
    _out=$(cd "$tmp" && GIT_TRACE="$tmp/.git-trace.log" bash "$tmp/scripts/cr/clear-cr-marker.sh" 2>"$_errfile") || _rc=$?
    _err=$(cat "$_errfile" 2>/dev/null)
    if [ "$_rc" -eq 14 ]; then pass; else fail "2f unmutated: expected refusal rc=14, got $_rc ($_out — stderr: $_err)"; fi
    if marker_exists "$tmp"; then pass; else fail "2f unmutated: marker must REMAIN (stderr: $_err)"; fi
    # THREE arms, not two (HIMMEL-2544). The old two-arm form treated a MISSING
    # or EMPTY trace log as proof the filter skipped the spawn — absence of
    # evidence scored as evidence, the same vacuity class the RED-control
    # contract exists to refuse. The unmutated run always spawns other git
    # calls, so a non-empty trace is the normal case and an empty one means the
    # instrumentation, not the filter, is what failed.
    _trace_unmutated=""
    [ -s "$tmp/.git-trace.log" ] && _trace_unmutated=$(cat "$tmp/.git-trace.log")
    if [ -z "$_trace_unmutated" ]; then
        _resolve_unmutated="no-trace"
        fail "2f unmutated: GIT_TRACE wrote no trace to $tmp/.git-trace.log — the 'the pre-filter skipped the resolve() spawn' conclusion would rest on an ABSENT trace, which proves nothing either way"
    elif grepq "$_trace_unmutated" -F -- "$_resolve_needle"; then
        _resolve_unmutated="yes"
        fail "2f unmutated: the prefix pre-filter did not skip the resolve() spawn for the non-prefix head — it is not actually filtering"
    else
        _resolve_unmutated="no"
        pass
    fi
    _reason_unmutated=$(_audit_reason "$_out")

    # Build the mutant: byte-identical except the ONE HIMMEL-2190 pre-filter
    # line is removed. Verify the mutation actually applied (present before,
    # absent after, and the diff is exactly that one line) before trusting the
    # result — a no-op edit here would let this whole case pass vacuously,
    # mirroring the 2d/2e setup guards above.
    _prefilter_line='      if (!e.FULL_SHA.startsWith(h)) return false;'
    awk -v line="$_prefilter_line" '$0 != line' "$tmp/scripts/cr/clear-cr-marker.sh" > "$tmp/scripts/cr/clear-cr-marker.mutant.sh"
    _pre_count=$(grep -Fc -- "$_prefilter_line" "$tmp/scripts/cr/clear-cr-marker.sh")
    _post_count=$(grep -Fc -- "$_prefilter_line" "$tmp/scripts/cr/clear-cr-marker.mutant.sh")
    _diff_lines=$(diff "$tmp/scripts/cr/clear-cr-marker.sh" "$tmp/scripts/cr/clear-cr-marker.mutant.sh" | grep -c '^[<>]')
    if [ -z "$_reason_unmutated" ]; then
        fail "2f setup: the unmutated arm audited no REFUSED reason (stdout: $_out) — an empty reason would silently weaken BOTH predicted values of the RED control below"
    elif [ "$_pre_count" -ge 1 ] && [ "$_post_count" -eq 0 ] && [ "$_diff_lines" -eq 1 ]; then
        rm -f "$tmp/.git-trace.log"
        # The helper's stderr capture lands in $tmp, which this case already
        # `rm -rf`s below.
        # shellcheck disable=SC2034  # read by the sourced red-control.sh
        RED_CONTROL_TMPDIR="$tmp"
        red_control_run --cwd "$tmp" --env GIT_TRACE="$tmp/.git-trace.log" \
            -- bash "$tmp/scripts/cr/clear-cr-marker.mutant.sh"
        # Same three arms as the unmutated side: `no-trace` must NOT collapse
        # into `no`, or a mutant whose instrumentation silently failed would
        # read as "the spawn did not happen".
        _trace_mutant=""
        [ -s "$tmp/.git-trace.log" ] && _trace_mutant=$(cat "$tmp/.git-trace.log")
        if [ -z "$_trace_mutant" ]; then
            _resolve_mutant="no-trace"
        elif grepq "$_trace_mutant" -F -- "$_resolve_needle"; then
            _resolve_mutant="yes"
        else
            _resolve_mutant="no"
        fi
        _marker_mutant=absent
        marker_exists "$tmp" && _marker_mutant=present
        if red_control_assert --label "2f" --expect-rc 14 \
            --observed     "reason=$(_audit_reason "$RED_CONTROL_OUT") marker=$_marker_mutant resolve_spawned=$_resolve_mutant" \
            --expect-wrong "reason=$_reason_unmutated marker=present resolve_spawned=yes" \
            --correct      "reason=$_reason_unmutated marker=present resolve_spawned=$_resolve_unmutated" \
            --note "removing the HIMMEL-2190 prefix pre-filter forces the resolve() git spawn the filter used to skip, while the verdict is unchanged (same audited refusal reason, marker still present, same rc=14) — GitHub #2010"
        then
            pass
        else
            fail "2f mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
    else
        fail "2f setup: mutation of the prefix pre-filter line was not reproduced cleanly (pre=$_pre_count post=$_post_count diff_lines=$_diff_lines)"
    fi
    rm -f "$tmp/scripts/cr/clear-cr-marker.mutant.sh" "$tmp/.git-trace.log"
fi
rm -rf "$tmp"

# 3. Remote at A + local/ledger at B must refuse. `gh pr create --head feat/x`
# opens from the REMOTE ref and does not push, so local evidence for B must never
# clear a marker while origin still proposes A.
make_repo || exit 1
write_marker "$tmp" "$sha"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later reviewed work") >/dev/null 2>&1
_tip=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_ledger "$tmp" "$(avail_ok "${_tip:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "remote at A + local reviewed B → exit 16"
if marker_exists "$tmp"; then pass; else fail "remote/local mismatch: marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'REFUSED reason=remote-head-mismatch'; then
    pass
else
    fail "remote/local mismatch refusal must identify the remote head binding"
fi
rm -rf "$tmp"

# 3a2. Legacy 3-field marker (pre-HIMMEL-1540 writer, no remote binding at
# all) -> refuse with reason=unbound-marker-remote, and the remedy text must
# name the up-to-date-push trap + empty-commit recovery (HIMMEL-2104 fix
# direction 3 — the safety net for unbound paths fix directions 1/2 don't
# reach, e.g. a marker written before this fix shipped).
make_repo || exit 1
mkdir -p "$tmp/.git/cr-pending/feat"
printf '2026-07-16T10:00:00+02:00 | %s | full\n' "$sha" > "$tmp/.git/cr-pending/feat/x"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "3-field marker without remote binding → exit 16"
if marker_exists "$tmp"; then pass; else fail "unbound-remote marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'REFUSED reason=unbound-marker-remote'; then
    pass
else
    fail "3-field marker refusal must carry reason=unbound-marker-remote, not a generic failure"
fi
if grepq "$LAST_CLEAR_OUT" 'HIMMEL-2104'; then
    pass
else
    fail "unbound-marker-remote remedy must name the HIMMEL-2104 up-to-date trap + empty-commit recovery"
fi
rm -rf "$tmp"

# 3b. Pre-endpoint 5-field marker (older writer) → refuse with the SPECIFIC
# unbound-endpoint reason, never rc alone (HIMMEL-1554): remint by re-push.
make_repo || exit 1
mkdir -p "$tmp/.git/cr-pending/feat"
printf '2026-07-16T10:00:00+02:00 | %s | full | origin | refs/heads/feat/x\n' "$sha" > "$tmp/.git/cr-pending/feat/x"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "5-field marker without endpoint+base → exit 16"
if marker_exists "$tmp"; then pass; else fail "unbound-endpoint marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'REFUSED reason=unbound-marker-endpoint'; then
    pass
else
    fail "5-field marker refusal must carry reason=unbound-marker-endpoint, not a generic failure"
fi
if grepq "$LAST_CLEAR_OUT" 'HIMMEL-2104'; then
    pass
else
    fail "unbound-marker-endpoint remedy must name the HIMMEL-2104 up-to-date trap + empty-commit recovery"
fi
rm -rf "$tmp"

# 3c. Alias mutated AFTER the push (this repo's lane tooling repoints
# remote.origin.url/pushurl as a quarantine mechanism): the marker's recorded
# ENDPOINT must be consulted, so clearance still SUCCEEDS while the alias is
# dead. The pre-HIMMEL-1540 alias-resolving code fails remote-head-unreadable
# here — the discriminating direction for finding B.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
git -C "$tmp" remote set-url origin "$tmp/nonexistent.git"
run_clear "$tmp" 0 "mutated alias + intact endpoint → exit 0 (endpoint consulted, not alias)"
if marker_exists "$tmp"; then fail "endpoint-verified clear: marker should be GONE despite dead alias"; else pass; fi
rm -rf "$tmp"

# 3d. Fetch/push divergence: the marker's endpoint names the repo the push
# actually targeted, whose head is OLDER than the tip; the alias still resolves
# to the up-to-date test-origin. Alias-resolving code would clear; the endpoint
# head must refuse with remote-head-mismatch naming the endpoint.
make_repo || exit 1
_old=$(git -C "$tmp" rev-parse --verify "refs/heads/feat/x^")
(cd "$tmp" && git init -q --bare .git/test-pushdest.git && git push -q .git/test-pushdest.git "$_old:refs/heads/feat/x") >/dev/null 2>&1
write_marker "$tmp" "$sha" full .git/test-pushdest.git
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "endpoint head differs though alias head matches → exit 16"
if marker_exists "$tmp"; then pass; else fail "endpoint-mismatch marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'reason=remote-head-mismatch' &&
   grepq "$LAST_CLEAR_OUT" 'test-pushdest'; then
    pass
else
    fail "endpoint-mismatch refusal must name the ENDPOINT it checked (not the alias)"
fi
rm -rf "$tmp"

# 3a. Once the actual remote is at the ledger-certified current tip, a stale
# full-lane marker may still clear through the explicit ledger-backed fallback.
make_repo || exit 1
write_marker "$tmp" "$sha"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later reviewed work" && git push -q origin feat/x) >/dev/null 2>&1
_tip=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_ledger "$tmp" "$(avail_ok "${_tip:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "stale marker + pushed clean ledger tip → exit 0"
if marker_exists "$tmp"; then fail "stale marker + pushed clean tip: marker should be GONE"; else pass; fi
if grepq "$LAST_CLEAR_OUT" 'WARNING: marker certifies' &&
   grepq "$LAST_CLEAR_OUT" 'CLEARED reason=stale-marker-superseded-by-ledger-at-tip'; then
    pass
else
    fail "stale-marker clearance must warn and audit the ledger-backed fallback" "$LAST_CLEAR_OUT"
fi
rm -rf "$tmp"

# 3a. A stale docs-audit marker must never clear on lane-less ledger evidence at
# the newer tip. The docs lane was selected from the old marker BEFORE this gate,
# and avail rows do not record which lane reviewed the code. Refuse repeatedly
# until a new push remints the marker and reclassifies the current diff.
make_repo || exit 1
write_marker "$tmp" "$sha" docs-audit
(cd "$tmp" && printf 'code\n' > code.sh && git add code.sh && git commit -qm "later code work" && git push -q origin feat/x) >/dev/null 2>&1
_tip=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_ledger "$tmp" "$(avail_ok "${_tip:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "stale docs-audit marker + code at tip cannot clear through docs lane → exit 14"
if marker_exists "$tmp"; then pass; else fail "stale docs lane: marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'REFUSED reason=stale-docs-lane-untrusted'; then
    pass
else
    fail "stale docs lane refusal must identify the untrusted lane"
fi
run_clear "$tmp" 14 "repeating clear without a remint still refuses stale docs lane → exit 14"
if marker_exists "$tmp"; then pass; else fail "repeated stale docs clear: marker must REMAIN"; fi
rm -rf "$tmp"

# 3b. Stale marker + NO responders at the current tip still refuses. Evidence at
# the old marker SHA must not certify the new code.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later unreviewed work" && git push -q origin feat/x) >/dev/null 2>&1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "stale marker + no responders at tip → exit 14"
if marker_exists "$tmp"; then pass; else fail "stale marker without tip evidence: marker must REMAIN"; fi
rm -rf "$tmp"

# 3c. Stale marker + a responder AND an unresolved blocker at the current tip
# still refuses at gate 4; the fallback is not a bypass.
make_repo || exit 1
write_marker "$tmp" "$sha"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later blocked work" && git push -q origin feat/x) >/dev/null 2>&1
_tip=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_ledger "$tmp" "$(avail_ok "${_tip:0:8}")" "$(finding "${_tip:0:8}" imp agreed)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "stale marker + blocking finding at tip → exit 15"
if marker_exists "$tmp"; then pass; else fail "stale marker with tip blocker: marker must REMAIN"; fi
rm -rf "$tmp"

# 4. Zero responders = MISSING signal, not clean (the CodeRabbit rate-limit
# shape). An `unavailable` record alone must NOT clear the gate.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_bad "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "only 'unavailable' critics → exit 14 (missing != clean)"
if marker_exists "$tmp"; then pass; else fail "no responders: marker must REMAIN"; fi
rm -rf "$tmp"

# 4b. Empty ledger → no evidence /pr-check ever ran → refuse.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "empty ledger → exit 14"
rm -rf "$tmp"

# 4c. Ledger records exist but for a DIFFERENT sha → no evidence at this head.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "deadbeef")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "ledger evidence for another sha → exit 14"
rm -rf "$tmp"

# 4d. Codex skill integration: a clean panel writes an avail-ok row through
# ledger-append.sh, then the chokepoint clears the marker.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Codex clean panel appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "Codex clean ledger evidence → exit 0"
if marker_exists "$tmp"; then fail "Codex clean path: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4e. Codex skill integration: a recorded Important finding remains blocking
# even with a responder row, so the chokepoint refuses with exit 15.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Codex blocker appends finding" finding \
    --branch feat/x --head "$sha" --model codex --id codex-1 \
    --severity imp --file scripts/example.sh --line 7 --verdict agreed
append_ledger "$tmp" "Codex blocker appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "Codex blocking ledger finding → exit 15"
if marker_exists "$tmp"; then pass; else fail "Codex blocker path: marker must REMAIN"; fi
rm -rf "$tmp"

# 4f. Codex skill integration: unavailable-only evidence is not a response, so
# the chokepoint refuses with exit 14 and retains the marker.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Codex unavailable panel appends row" avail \
    --branch feat/x --head "$sha" --model codex --status unavailable
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "Codex no avail-ok evidence → exit 14"
if marker_exists "$tmp"; then pass; else fail "Codex no-responder path: marker must REMAIN"; fi
rm -rf "$tmp"

# 4f-1/4f-2. HIMMEL-1613 incident fixture: a critic (glm) that TIMED OUT on
# run 1 and SUCCEEDED on run 2 at the SAME head used to have its run-2
# avail-ok silently dropped by ledger-append.sh's flat (head,model) dedup,
# permanently wedging this gate at that SHA. ledger-append.sh now
# monotone-supersedes (unavailable -> ok appends); this exercises the real
# writer via append_ledger, then asserts the chokepoint reads the resulting
# ledger correctly.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "glm times out on run 1" avail \
    --branch feat/x --head "$sha" --model glm --status unavailable
append_ledger "$tmp" "glm succeeds on run 2 at the SAME head" avail \
    --branch feat/x --head "$sha" --model glm --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "HIMMEL-1613: avail unavailable-then-ok at the same head clears"
if marker_exists "$tmp"; then fail "HIMMEL-1613 fixture: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# HIMMEL-1640 variant: the supersession identity is (head, model) ONLY, so an
# unavailable -> ok recovery supersedes even when the two readings came back on
# DIFFERENT artifacts (a critic timed out probing the diff, then succeeded
# probing the spec at the same head). The writer appends the ok across the
# artifact change and the chokepoint reads the effective ok -> marker clears.
# Stale unavailable evidence must not survive a recovery that merely changed arms.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "glm unavailable probing the diff arm" avail \
    --branch feat/x --head "$sha" --model glm --status unavailable --artifact diff
append_ledger "$tmp" "glm ok probing the spec arm at the SAME head" avail \
    --branch feat/x --head "$sha" --model glm --status ok --artifact spec
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "HIMMEL-1640: avail unavailable-then-ok across artifacts clears"
if marker_exists "$tmp"; then fail "HIMMEL-1640 fixture: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# Negative: once a critic has recorded ok, a LATER unavailable attempt for the
# same head must never un-clear the gate — ledger-append.sh refuses to write
# the downgrade, so a branch that already cleared cannot be wedged retroactively
# by a subsequent flaky/rate-limited re-run.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "glm succeeds first" avail \
    --branch feat/x --head "$sha" --model glm --status ok
append_ledger "$tmp" "glm later attempt times out (must not downgrade)" avail \
    --branch feat/x --head "$sha" --model glm --status unavailable
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "HIMMEL-1613: a later ok->unavailable attempt does not un-clear"
if marker_exists "$tmp"; then fail "HIMMEL-1613 negative: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4g-4j. Claude-only floor / availability escape hatch (HIMMEL-1224). The gate
# must be adopter-portable: a config with ZERO external critics (no codex / glm /
# CodeRabbit) still clears on the session's own diff review, recorded as
# `avail --model claude --status ok`. The floor opens for lane ABSENCE, never for
# a lane that ATTEMPTED and failed (that records `unavailable`, HIMMEL-1126). The
# failed-lane-as-SOLE-evidence → exit 14 shape is already covered by tests 4 / 4f
# (coderabbit / codex `unavailable`-only); the cases here add the claude-floor
# story on top of it.

# 4g. Claude-only floor is sufficient evidence: a single `avail claude ok` row
# (written through the REAL ledger-append path /pr-check step 4.5 uses) with zero
# findings clears the marker — the zero-external-critic adopter path.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Claude floor appends avail-ok" avail \
    --branch feat/x --head "$sha" --model claude --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "Claude-only floor (avail claude ok, no findings) → exit 0"
if marker_exists "$tmp"; then fail "Claude floor clear path: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4h. A configured external lane that ATTEMPTED and FAILED records `unavailable`,
# but that MISSING signal does not retain the marker when the Claude floor
# covered the HEAD — fail-open because the failed lane is not the SOLE evidence.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_bad "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "Claude floor + failed external lane (unavailable) → exit 0"
if marker_exists "$tmp"; then fail "Claude floor + failed lane: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4j. The floor itself is fail-closed on a blocker: a Claude self-review that
# RESPONDED (avail ok) AND recorded a blocking finding stays closed (exit 15) —
# a review happening is not the same as a review being clean (HIMMEL-1126).
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Claude floor blocker appends finding" finding \
    --branch feat/x --head "$sha" --model claude --id claude-1 \
    --severity crit --file scripts/example.sh --line 7 --verdict agreed
append_ledger "$tmp" "Claude floor blocker appends avail-ok" avail \
    --branch feat/x --head "$sha" --model claude --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "Claude floor with a blocking finding → exit 15"
if marker_exists "$tmp"; then pass; else fail "Claude floor blocker: marker must REMAIN"; fi
rm -rf "$tmp"

# 4k-4o. Opt-in cross-model floor (HIMMEL-1237, CR_REQUIRE_CROSS_MODEL). When set,
# the Claude self-review floor alone is NOT a sufficient responder — a NON-claude
# critic must have recorded `avail ... ok` at this SHA. Default off keeps the
# HIMMEL-1224 adopter behaviour (a claude-only floor clears — covered by 4g).
# The test copy has no scripts/lib/load-dotenv.sh, so the script's .env load is a
# no-op and the process env set here is authoritative.
export CR_REQUIRE_CROSS_MODEL=1

# 4k. Required-on + ONLY the Claude floor responded → cross-model missing →
# exit 14, marker REMAINS. This is the operator's "claude alone is not enough".
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
run_clear "$tmp" 14 "cross-model required + claude-only floor → exit 14"
if marker_exists "$tmp"; then pass; else fail "cross-model required, claude-only: marker must REMAIN"; fi
rm -rf "$tmp"

# 4l. Required-on + Claude floor + an EXTERNAL responder (codex ok) → cross-model
# met → exit 0, marker GONE.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "cross-model required + claude + codex ok → exit 0"
if marker_exists "$tmp"; then fail "cross-model met: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4l2. HIMMEL-2026: a CURRENT docs-audit marker is allowed to clear under the
# opt-in cross-model floor when the docs-audit lane recorded Claude AND a
# non-Claude responder at the FULL head SHA. This guards the lane-specific
# shape the /pr-check docs-audit runbook must now produce.
make_repo || exit 1
write_marker "$tmp" "$sha" docs-audit
append_ledger "$tmp" "docs-audit appends claude avail-ok at full sha" avail \
    --branch feat/x --head "$sha" --model claude --status ok
append_ledger "$tmp" "docs-audit appends codex avail-ok at full sha" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "docs-audit + CR_REQUIRE_CROSS_MODEL + claude+codex ok at full sha → exit 0"
if marker_exists "$tmp"; then fail "docs-audit cross-model met: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4l3. HIMMEL-2026 inverse: the same docs-audit marker remains closed when the
# lane records only Claude, because CR_REQUIRE_CROSS_MODEL requires a non-Claude
# `avail ... ok` responder even on docs-only diffs.
make_repo || exit 1
write_marker "$tmp" "$sha" docs-audit
append_ledger "$tmp" "docs-audit appends claude-only avail-ok at full sha" avail \
    --branch feat/x --head "$sha" --model claude --status ok
run_clear "$tmp" 14 "docs-audit + CR_REQUIRE_CROSS_MODEL + claude-only at full sha → exit 14"
if marker_exists "$tmp"; then pass; else fail "docs-audit claude-only: marker must REMAIN"; fi
rm -rf "$tmp"

# 4m. Required-on + Claude floor + an external lane that ATTEMPTED and FAILED
# (coderabbit unavailable) → still no non-claude OK row → exit 14, marker REMAINS.
# The key case: a failed cross-model lane is NOT papered over by the floor here.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_bad "${sha:0:8}")"
run_clear "$tmp" 14 "cross-model required + claude + failed external → exit 14"
if marker_exists "$tmp"; then pass; else fail "cross-model required, failed external: marker must REMAIN"; fi
rm -rf "$tmp"

# 4n. Required-on + an external responder ALONE (codex ok, no claude row) →
# cross-model met → exit 0, marker GONE (the requirement is >=1 non-claude, not
# "claude PLUS one").
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "cross-model required + external-only responder → exit 0"
if marker_exists "$tmp"; then fail "external-only responder: marker should be GONE"; else pass; fi
rm -rf "$tmp"

unset CR_REQUIRE_CROSS_MODEL

# 4o. Truthy guard: CR_REQUIRE_CROSS_MODEL=0 means OFF (not "any non-empty = on"),
# so a claude-only floor still clears — a `=0` in .env must not silently gate.
export CR_REQUIRE_CROSS_MODEL=0
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "CR_REQUIRE_CROSS_MODEL=0 is OFF → claude-only floor clears"
if marker_exists "$tmp"; then fail "flag=0 (off): marker should be GONE"; else pass; fi
rm -rf "$tmp"
unset CR_REQUIRE_CROSS_MODEL

# 4p. Production .env bridge (glm-1 CR suggestion). Cases 4k-4o set the flag via
# the PROCESS env; the flag's REAL entry point is clear-cr-marker.sh sourcing
# scripts/lib/load-dotenv.sh and reading CR_REQUIRE_CROSS_MODEL from the primary
# checkout's .env. Exercise THAT path: copy the real load-dotenv.sh into the temp
# script tree, write the temp repo's .env, and leave the process env UNSET (4o
# unset it) so the .env is the sole source. A .env-only flag + claude-only floor
# must gate (exit 14) — which can only happen if the bridge actually read .env.
make_repo || exit 1
mkdir -p "$tmp/scripts/lib"
cp "$SCRIPT_DIR/../lib/load-dotenv.sh" "$tmp/scripts/lib/load-dotenv.sh"
printf 'CR_REQUIRE_CROSS_MODEL=1\n' > "$tmp/.env"
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
run_clear "$tmp" 14 ".env bridge (no process-env): flag read from .env + claude-only floor → exit 14"
if marker_exists "$tmp"; then pass; else fail ".env bridge: marker must REMAIN"; fi
rm -rf "$tmp"

# 4r. Malformed/legacy avail row with NO model field must not satisfy the
# cross-model requirement (codex-1/glm-2 CR round). `o.model && o.model !==
# "claude"` requires a NAMED external critic; a bare `!== "claude"` would JS-match
# a missing model (undefined !== "claude" is true) and let a model-less `avail ok`
# clear the gate without any external review. Flag on + claude floor + a model-less
# ok row → still 0 non-claude → exit 14 (fail closed).
export CR_REQUIRE_CROSS_MODEL=1
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(printf '{"kind":"avail","head":"%s","status":"ok"}' "${sha:0:8}")"
run_clear "$tmp" 14 "model-less avail ok does not satisfy cross-model → exit 14"
if marker_exists "$tmp"; then pass; else fail "model-less avail: marker must REMAIN"; fi
rm -rf "$tmp"
unset CR_REQUIRE_CROSS_MODEL

# 4s. Normalisation guard (coderabbit-1/2): a whitespace-padded, mis-cased
# " Claude " model is the floor, not cross-model evidence — the model check
# trims AND lowercases before comparing. Flag on + claude floor + an avail-ok row
# with model " Claude " → still 0 non-claude → exit 14.
export CR_REQUIRE_CROSS_MODEL=1
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(printf '{"kind":"avail","head":"%s","model":" Claude ","status":"ok"}' "${sha:0:8}")"
run_clear "$tmp" 14 "whitespace/mis-cased Claude is not cross-model → exit 14"
if marker_exists "$tmp"; then pass; else fail "whitespace/mis-cased Claude: marker must REMAIN"; fi
rm -rf "$tmp"
unset CR_REQUIRE_CROSS_MODEL

# 4t. Process-env precedence over .env (coderabbit App). load_dotenv preserves an
# already-set process var (load-dotenv.sh:71 exports only when unset), so a
# process CR_REQUIRE_CROSS_MODEL=0 WINS over a .env CR_REQUIRE_CROSS_MODEL=1 — the
# gate stays OFF and the claude-only floor clears (exit 0). Exercises the real
# .env bridge; also guards that the thread-1 fail-closed load never fires on a
# normal readable .env.
make_repo || exit 1
mkdir -p "$tmp/scripts/lib"
cp "$SCRIPT_DIR/../lib/load-dotenv.sh" "$tmp/scripts/lib/load-dotenv.sh"
printf 'CR_REQUIRE_CROSS_MODEL=1\n' > "$tmp/.env"
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
export CR_REQUIRE_CROSS_MODEL=0
run_clear "$tmp" 0 "process-env 0 overrides .env 1 → claude-only floor clears → exit 0"
if marker_exists "$tmp"; then fail "process-env precedence: marker should be GONE"; else pass; fi
unset CR_REQUIRE_CROSS_MODEL
rm -rf "$tmp"

# 4u. Whitespace-padded flag value (coderabbit App): ' true ' from .env/env must
# still enable the gate — the truthy check trims before matching, so a padded
# value cannot silently disable an intended opt-in. Padded flag + claude-only
# floor → gate ON → exit 14.
export CR_REQUIRE_CROSS_MODEL=' true '
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
run_clear "$tmp" 14 "padded ' true ' flag still enables the gate → exit 14"
if marker_exists "$tmp"; then pass; else fail "padded truthy flag: marker must REMAIN"; fi
rm -rf "$tmp"
unset CR_REQUIRE_CROSS_MODEL

# 4v. Fail-closed on .env LOAD failure (coderabbit App thread 1 / glm-1). If
# load_dotenv returns non-zero (a genuine .env read failure — permission/race),
# clear-cr-marker must REFUSE (exit 14), never fall through to
# require_cross_model=0 and clear WITHOUT the configured cross-model evidence.
# Portably simulate the read failure with a stub load-dotenv.sh that returns 1
# (chmod-based unreadable-file tests are unreliable on Git Bash/Windows). An
# external responder is present so that, absent the fail-closed, the marker WOULD
# clear — proving the refuse comes from the load failure, not a missing responder.
make_repo || exit 1
mkdir -p "$tmp/scripts/lib"
printf '#!/usr/bin/env bash\nload_dotenv() { return 1; }\n' > "$tmp/scripts/lib/load-dotenv.sh"
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
run_clear "$tmp" 14 "load_dotenv failure → fail-closed refuse → exit 14"
if marker_exists "$tmp"; then pass; else fail "load failure: marker must REMAIN"; fi
rm -rf "$tmp"

# 5. Blocking findings at this head → refuse.
for _sev in crit imp; do
    for _v in agreed conflict unaddressed; do
        make_repo || exit 1
        write_marker "$tmp" "$sha"
        write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" "$_sev" "$_v")"
        stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
        run_clear "$tmp" 15 "$_sev finding verdict=$_v → exit 15"
        if marker_exists "$tmp"; then pass; else fail "$_sev/$_v: marker must REMAIN"; fi
        rm -rf "$tmp"
    done
done

# 6. A DISPROVED crit is not blocking (the runbook's adjudication rule).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" crit disproved)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "disproved crit is not blocking → exit 0"
rm -rf "$tmp"

# 6a-1. HIMMEL-1294 — an `amend` supersede record is APPLIED before gate 4
# judges. Incident 1: a blocking imp recorded honestly wedged the branch, and
# re-appending at a lower severity silently no-op'd, so the only escapes were a
# hand-edit of the JSONL or an operator. The amend must actually take effect
# here, or the verb is theatre.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp agreed)" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"severity":"sug"},"reason":"out of diff"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "amend severity imp->sug unblocks gate 4 → exit 0"
rm -rf "$tmp"

# 6a-2. Incident 2: the finding was keyed to the head that FIXES it instead of
# the head it was raised against. An amend that re-keys `head` must move the
# finding OFF this head entirely.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp agreed)" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"head":"deadbeef"},"reason":"raised against deadbeef, mis-keyed"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "amend re-keying head moves the finding off this SHA → exit 0"
rm -rf "$tmp"

# 6a-3. An amend must not be a universal unblock: one that leaves the finding
# blocking still blocks.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp agreed)" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"file":"b.sh"},"reason":"wrong file"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "an amend that does not clear the finding still blocks → exit 15"
rm -rf "$tmp"

# 6a-4. An amend record is metadata, not review evidence — it must never count
# toward the gate-3 responder floor.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"severity":"sug"},"reason":"x"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "an amend alone is not a responder → exit 14"
rm -rf "$tmp"

# 6c. HIMMEL-1294 — a TRACKED deferral clears gate 4. Before this the only
# mechanical exits for an honest out-of-diff crit|imp were a downgrade to sug or
# a false `disproved`, so the gate pushed an honest session toward mis-recording.
deferred_finding() { printf '{"kind":"finding","head":"%s","model":"codex","finding_id":"codex-1","severity":"imp","file":"a.sh","line":1,"verdict":"deferred","deferred_to":"%s","reason":"%s"}' "$1" "$2" "$3"; }
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(deferred_finding "${sha:0:8}" HIMMEL-1293 "pre-existing, already public")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "tracked deferral (ticket + reason) is not blocking → exit 0"
rm -rf "$tmp"

# 6d. …but a deferral is only honest if it is TRACKED. A bare `deferred`, or one
# missing either half of the evidence, must STILL block — otherwise the verdict
# is just a cheaper lie than `disproved`.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp deferred)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "bare deferred with no ticket still blocks → exit 15"
rm -rf "$tmp"

make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(deferred_finding "${sha:0:8}" HIMMEL-1293 "")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "deferral with a ticket but no reason still blocks → exit 15"
rm -rf "$tmp"

make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(deferred_finding "${sha:0:8}" "not-a-ticket" "why")" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "deferral with a malformed ticket key still blocks → exit 15"
rm -rf "$tmp"

# 6e. glm-3 — deferring an ALREADY-RECORDED finding through amend must actually
# clear gate 4. The gate reads the FINDING-level reason, so an amend that sets
# only verdict+ticket leaves it blocking; this is the end-to-end shape the
# gate's own error message prints, so if it does not work the hint is a trap.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp agreed)" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-1293","reason":"pre-existing, already public"},"reason":"deferred after review"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "amend to a TRACKED deferral clears gate 4 → exit 0"
rm -rf "$tmp"

# …and the half-done version must NOT clear: verdict+ticket with no
# finding-level reason is exactly the dead end glm-3 found.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" imp agreed)" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-1293"},"reason":"deferred after review"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "amend deferral without a finding-level reason still blocks → exit 15"
rm -rf "$tmp"

# 6f. codex-1 — the ticket-key check must be an anchored regex, not a glob.
# `HI-1x` passes a `[A-Z][A-Z0-9]*-[0-9]*` glob and must still block here.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(deferred_finding "${sha:0:8}" "HI-1x" "why")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "ticket key with a trailing non-digit still blocks → exit 15"
rm -rf "$tmp"

# 6g. HIMMEL-1327/HIMMEL-2020 — the blocking-findings deferral hint may use the
# tip's short form, and the printed command must WORK when run. New writes
# normalize to full SHA keys; legacy rows may still be short. This captures the
# PRINTED hint and RUNS it end-to-end (substituting only its placeholders), not a
# hand-written equivalent.
make_repo || exit 1
# Pass a short head the way old /pr-check did; ledger-append normalizes the row,
# and the hint's short --head normalizes back to the same full key.
_short=$(git -C "$tmp" rev-parse --short "$sha")
write_marker "$tmp" "$sha"
append_ledger "$tmp" "blocker at short head" finding \
    --branch feat/x --head "$_short" --model codex --id codex-1 \
    --severity imp --file scripts/example.sh --line 7 --verdict agreed
append_ledger "$tmp" "responder at short head" avail \
    --branch feat/x --head "$_short" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
_rc=0
out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-cr-marker.sh" 2>&1) || _rc=$?
if [ "$_rc" -eq 15 ]; then pass; else fail "blocking finding → exit 15 (got $_rc): $out"; fi
# Capture the printed amend hint and the --head it carries.
hint=$(printf '%s\n' "$out" | grep 'ledger-append.sh amend' | sed 's/^[[:space:]]*//')
if [ -n "$hint" ]; then pass; else fail "no amend hint printed"; fi
hint_head=$(printf '%s' "$hint" | sed -n 's/.*--head \([^ ]*\).*/\1/p')
# The crux: the hint's abbreviated head is accepted by ledger-append and
# resolves to the full key used for current rows.
if [ "$hint_head" = "$_short" ]; then pass; else fail "hint --head is an unambiguous short form (got '$hint_head', expected '$_short')"; fi
if [ -n "$hint_head" ] && [ "$hint_head" != "$sha" ]; then pass; else fail "hint --head should stay abbreviated for readability"; fi
# Run the PRINTED hint end-to-end: substitute its placeholders and execute it
# verbatim. The relative `scripts/cr/ledger-append.sh` resolves from $tmp, where
# make_repo copied the script tree — so this exercises the real amend path with
# the hint's own --head value.
cmd="$hint"
cmd=${cmd//<finding-id>/codex-1}
cmd=${cmd//<TICKET>/HIMMEL-1327}
cmd=${cmd//<why it is out of scope here>/pre-existing}
_amend_rc=0
_amend_out=$(cd "$tmp" && bash -c "$cmd" 2>&1) || _amend_rc=$?
if [ "$_amend_rc" -eq 0 ]; then pass; else fail "printed amend hint runs end-to-end (rc=$_amend_rc): $_amend_out"; fi
# And it must actually have amended the target: re-running the gate now clears
# (the finding is a tracked deferral, no longer blocking) — exit 0, marker GONE.
# A hint whose --head never matched would have left the finding blocking (exit 15).
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
_clear_rc=0
(cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-cr-marker.sh" >/dev/null 2>&1) || _clear_rc=$?
if [ "$_clear_rc" -eq 0 ]; then pass; else fail "after running the printed hint, the finding is deferred and the gate clears (got $_clear_rc)"; fi
if marker_exists "$tmp"; then fail "after the printed amend, the marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 6b. A Suggestion never blocks.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" sug agreed)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "sug finding does not block → exit 0"
rm -rf "$tmp"

# 7. POST-PR: a PR exists and check-ci is green → clear (operator, HIMMEL-1064).
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "post-PR + check-ci green → exit 0"
if marker_exists "$tmp"; then fail "post-PR green: marker should be GONE"; else pass; fi
_green_audit=$(cat "$tmp/.git/clear-cr-marker.log")
if grepq "$_green_audit" 'carry=freshness-panel'; then
    fail "ordinary green clear must not gain a freshness carry annotation"
else
    pass
fi
rm -rf "$tmp"

# 7a. POST-PR: a successful freshness-panel carry is displayed live and its
# provenance is copied into the durable CLEARED audit line.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42
stub_check_ci "$tmp" 0 "check-ci: FRESHNESS panel carry stale_anchor=shaOLD head=$sha PR #42; threads resolved; carried responders=1 models=codex (HIMMEL-1718)."
run_clear "$tmp" 0 "post-PR + freshness panel carry → exit 0"
if marker_exists "$tmp"; then fail "freshness carry: marker should be GONE"; else pass; fi
if grepq "$LAST_CLEAR_OUT" 'FRESHNESS panel carry stale_anchor=shaOLD'; then pass; else
    fail "freshness carry stdout remains visible through tee"
fi
_carry_audit=$(cat "$tmp/.git/clear-cr-marker.log")
if grepq "$_carry_audit" 'CLEARED.*carry=freshness-panel stale_anchor=shaOLD responders=1 models=codex'; then
    pass
else
    fail "freshness carry provenance is recorded on the CLEARED audit line"
fi
rm -rf "$tmp"

# 7b. POST-PR: check-ci NOT green → refuse even though the ledger is clean.
# 3 = unresolved threads / changes requested, 1 = red CI, 2 = cannot evaluate.
for _rc in 1 2 3; do
    make_repo || exit 1
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
    stub_gh "$tmp" 42; stub_check_ci "$tmp" "$_rc"
    run_clear "$tmp" 16 "post-PR + check-ci rc=$_rc → exit 16"
    if marker_exists "$tmp"; then pass; else fail "post-PR rc=$_rc: marker must REMAIN"; fi
    rm -rf "$tmp"
done

# 7c. POST-PR but check-ci.sh is missing → cannot certify CI → refuse.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42
run_clear "$tmp" 16 "post-PR + check-ci.sh absent → exit 16"
rm -rf "$tmp"

# 7d. gh FAILS for a non-"no PR" reason → PR state UNKNOWN → refuse (codex-1).
# Without this the gate FAILS OPEN: a transient gh outage looks like "no PR",
# skipping the post-PR CI check entirely and clearing the marker unverified.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh_broken "$tmp"; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "gh auth/network failure → exit 16 (not treated as no-PR)"
if marker_exists "$tmp"; then pass; else fail "gh failure: marker must REMAIN"; fi
rm -rf "$tmp"

# 7e. gh absent entirely → cannot determine PR state → refuse (codex-1).
# run_clear prepends $tmp/bin to the REAL PATH, so deleting the stub would still
# find the system gh. Build a minimal PATH holding only git+node's own dirs. If
# gh happens to live alongside them, SKIP loudly rather than pass vacuously — a
# test that cannot fail is worse than no test.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_check_ci "$tmp" 0
# Include every tool the script legitimately uses BEFORE the gh check (awk to
# parse the marker, date/rm for the audit) — omitting them makes the script fail
# earlier for an unrelated reason (exit 12) and the assertion would be testing
# the harness, not the gate.
_min_path="$(dirname "$(command -v git)"):$(dirname "$(command -v node)")"
for _t in awk date rm sed grep; do
    _min_path="$_min_path:$(dirname "$(command -v "$_t")")"
done
if PATH="$_min_path" command -v gh >/dev/null 2>&1; then
    echo "  SKIP: gh shares a dir with git/node — cannot simulate an absent gh here" >&2
else
    # Resolve bash ABSOLUTELY — under the minimal PATH the interpreter itself
    # would not be found (rc 127), which is not the refusal we are asserting.
    _bash=$(command -v bash)
    _rc=0
    (cd "$tmp" && PATH="$_min_path" "$_bash" "$tmp/scripts/cr/clear-cr-marker.sh" 2>&1) >/dev/null || _rc=$?
    if [ "$_rc" -eq 11 ]; then pass; else fail "gh not on PATH → exit 11 (got $_rc)"; fi
    if marker_exists "$tmp"; then pass; else fail "gh absent: marker must REMAIN"; fi

    # 7f. ...but with NO marker, gh is never needed: the documented no-op must
    # still exit 0 without gh (codex-1 round 2). Requiring gh up-front broke this.
    rm -f "$tmp/.git/cr-pending/feat/x"
    _rc2=0
    (cd "$tmp" && PATH="$_min_path" "$_bash" "$tmp/scripts/cr/clear-cr-marker.sh" 2>&1) >/dev/null || _rc2=$?
    if [ "$_rc2" -eq 0 ]; then pass; else fail "no marker + no gh → exit 0 no-op (got $_rc2)"; fi
fi
rm -rf "$tmp"

# 7g. A malformed ledger record => UNKNOWN verdict => refuse (coderabbit).
# The dangerous shape: a readable `avail ok` beside a CORRUPTED finding line.
# Skipping the bad line would clear the marker having never evaluated it.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" '{"kind":"finding","head":"trunc'
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "malformed ledger record → exit 14"
if marker_exists "$tmp"; then pass; else fail "malformed ledger: marker must REMAIN"; fi
rm -rf "$tmp"

# 7h. A numeric branch name must NOT be resolved as a PR number (coderabbit).
# `gh pr view 42` would return PR #42 — a different PR whose CI would then
# certify this branch. The --head query is unambiguous; assert we pass --head.
make_repo || exit 1
(cd "$tmp" && git branch -m feat/x 42 && git push -q origin refs/heads/42:refs/heads/42) >/dev/null 2>&1
_numsha=$(git -C "$tmp" rev-parse --verify refs/heads/42)
mkdir -p "$tmp/.git/cr-pending"
_numbase=$(git -C "$tmp" rev-parse --verify refs/heads/main)
printf '2026-07-16T10:00:00+02:00 | %s | full | origin | refs/heads/42 | .git/test-origin.git | %s\n' "$_numsha" "$_numbase" > "$tmp/.git/cr-pending/42"
write_ledger "$tmp" "$(avail_ok "${_numsha:0:8}")"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fail closed unless invoked with an explicit --head query (never positional).
for a in "$@"; do [ "$a" = "--head" ] && { echo ""; exit 0; }; done
echo "positional PR lookup used — a numeric branch would hit the wrong PR" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"
stub_check_ci "$tmp" 0
_rc=0
out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-cr-marker.sh" 42 2>&1) || _rc=$?
if [ "$_rc" -eq 0 ]; then pass; else fail "numeric branch uses --head lookup (rc=$_rc: $out)"; fi
if [ -f "$tmp/.git/cr-pending/42" ]; then fail "numeric branch: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 7h2. A SUCCESSFUL gh call returning unexpected text must NOT be filtered down
# to "no PR" (coderabbit round 2). Stripping non-numeric lines would silently
# take the pre-PR path and skip check-ci — a fail-open on garbage output.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "Warning: something unexpected"
exit 0
STUB
chmod +x "$tmp/bin/gh"
stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "gh returns unexpected text (rc 0) → exit 16, not no-PR"
if marker_exists "$tmp"; then pass; else fail "garbage PR lookup: marker must REMAIN"; fi
rm -rf "$tmp"

# 7i2. POST-PR: the PR head is NOT the certified SHA → refuse (finding (a),
# public #468). check-ci.sh evaluates the PR HEAD, so a GREEN PR sitting at a
# different commit would otherwise satisfy gate 5 for code the review never
# covered. check-ci is stubbed green precisely to prove the head binding — not
# CI — is what refuses.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "PR head != certified SHA (CI green) → exit 16"
if marker_exists "$tmp"; then pass; else fail "PR head mismatch: marker must REMAIN"; fi
rm -rf "$tmp"

# 7i. Two open PRs for one head → ambiguous → refuse rather than guess.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
cat > "$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
printf '41 %s\n42 %s\n' "$sha" "$sha"
exit 0
STUB
chmod +x "$tmp/bin/gh"
stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "two open PRs for the head → exit 16 (ambiguous)"
if marker_exists "$tmp"; then pass; else fail "ambiguous PRs: marker must REMAIN"; fi
rm -rf "$tmp"

# 7j. TOCTOU: the marker is rewritten WHILE the gates run (a concurrent push).
# The final re-validation must refuse — deleting the new marker would open
# `gh pr create` for a SHA no critic reviewed. The stub gh rewrites the marker
# mid-run, standing in for check-cr-before-push.sh landing a push.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
cat > "$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
# Simulate a push landing during the gate: marker now certifies a NEWER sha.
printf '2026-07-16T10:05:00+02:00 | %s | full | origin | refs/heads/feat/x\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$tmp/.git/cr-pending/feat/x"
echo ""
exit 0
STUB
chmod +x "$tmp/bin/gh"
stub_check_ci "$tmp" 0
run_clear "$tmp" 13 "marker rewritten mid-gate (concurrent push) → exit 13"
if marker_exists "$tmp"; then pass; else fail "raced marker: the NEW marker must REMAIN"; fi
rm -rf "$tmp"

# 8. --dry-run runs every gate but never clears.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "--dry-run passing gates → exit 0" --dry-run
if marker_exists "$tmp"; then pass; else fail "--dry-run must NOT clear the marker"; fi
rm -rf "$tmp"

# 9. Usage errors.
make_repo || exit 1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 10 "unknown option → exit 10" --bogus
run_clear "$tmp" 10 "two branches → exit 10" feat/x feat/y
rm -rf "$tmp"

# 10. An explicit branch arg gates on THAT branch's tip, not cwd HEAD.
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
(cd "$tmp" && git checkout -q main) >/dev/null 2>&1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "explicit branch arg from another branch → exit 0" feat/x
if marker_exists "$tmp"; then fail "explicit branch: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 11. --help exits 0 and documents every exit code (the HIMMEL-1042 lesson:
# an anchored range, so a header edit cannot truncate the reference).
help_out=$(bash "$CLEAR" --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ]; then pass; else fail "--help exits 0 (got $help_rc)"; fi
for _code in 0 10 11 12 13 14 15 16; do
    if grepq "$help_out" -E "^ *${_code} +[a-z]"; then
        pass
    else
        fail "--help documents exit code ${_code}"
    fi
done
if grepq "$help_out" 'set -uo pipefail'; then
    fail "--help leaks the 'set -uo pipefail' code line"
else
    pass
fi

# HIMMEL-1495 hermeticity canary. clear-cr-marker.sh does not consult the
# armed-session bypass env (ARMAUTOMERGE/CR_MERGE_GATE_OK), so a block fixture
# STILL blocks (exit 14, no responders at the current tip) with both exported
# into the suite's env — pinning that insensitivity so a future change wiring
# either var into the clear chokepoint fails HERE (clears an unreviewed marker)
# rather than failing open. The startup unset above is the matching defense-in-depth.
export ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1
make_repo || exit 1
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later work" && git push -q origin feat/x) >/dev/null 2>&1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "armed bypass env does not clear stale marker without tip evidence (HIMMEL-1495)"
if marker_exists "$tmp"; then pass; else fail "armed-env stale marker: marker must REMAIN"; fi
rm -rf "$tmp"
unset ARMAUTOMERGE CR_MERGE_GATE_OK

# HIMMEL-1715. A ledger row can be stamped with a branch+head whose diff does
# not contain the file the finding is about, and the resulting refusal used to
# be indistinguishable from a legitimate one. make_repo's feat/x touches ONLY
# f.txt, so a finding on scripts/handover/merge-on-green.sh (the real 2026-08-10
# shape: a docs-only branch wedged by an Important about that file) is provably
# out of this head's diff. The gate must STILL refuse — the note is diagnostic,
# never a bypass — but must now say WHY the evidence does not belong here.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "out-of-diff blocker appends finding" finding \
    --branch feat/x --head "$sha" --model codex --id codex-1 \
    --severity imp --file scripts/handover/merge-on-green.sh --line 478
append_ledger "$tmp" "out-of-diff blocker appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "out-of-diff blocking finding still refuses → exit 15"
if grepq "$LAST_CLEAR_OUT" -F 'PROVENANCE (HIMMEL-1715)'; then pass; else
    fail "out-of-diff blocker: refusal must carry the PROVENANCE note: $LAST_CLEAR_OUT"; fi
if grepq "$LAST_CLEAR_OUT" -F 'codex-1[scripts/handover/merge-on-green.sh]'; then pass; else
    fail "out-of-diff blocker: PROVENANCE note must name the finding and its file: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "out-of-diff blocker: marker must REMAIN"; fi
rm -rf "$tmp"

# The other half, and the one that keeps the note honest: a blocking finding
# about a file the branch DOES touch is a legitimate refusal and must NOT be
# smeared as misattributed. A note that fired on every refusal would teach the
# reader to defer real findings.
make_repo || exit 1
write_marker "$tmp" "$sha"
append_ledger "$tmp" "in-diff blocker appends finding" finding \
    --branch feat/x --head "$sha" --model codex --id codex-1 \
    --severity imp --file f.txt --line 1
append_ledger "$tmp" "in-diff blocker appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "in-diff blocking finding still refuses → exit 15"
if grepq "$LAST_CLEAR_OUT" -F 'PROVENANCE'; then
    fail "in-diff blocker: must NOT be flagged as out-of-diff: $LAST_CLEAR_OUT"
else pass; fi
rm -rf "$tmp"

# HIMMEL-1715 CR round 1. Our contract: a blocking finding on a file the branch
# DOES touch is never flagged out-of-diff, whatever its name looks like. The
# fixture uses an awkward (non-ASCII) name because that is where the comparison
# used to break; a backslash/tab name exercises the same path but cannot be
# created on Windows, so it would skip on the primary dev platform.
make_repo || exit 1
_weird=$(printf 'caf\303\251.sh')
(cd "$tmp" && printf 'x\n' > "$_weird" && git add -A && git commit -qm weird \
    && git push -q origin feat/x) >/dev/null 2>&1
sha=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_marker "$tmp" "$sha"
append_ledger "$tmp" "quoted-path blocker appends finding" finding \
    --branch feat/x --head "$sha" --model codex --id codex-1 \
    --severity imp --file "$_weird" --line 1
append_ledger "$tmp" "quoted-path blocker appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 15 "quoted-path blocking finding still refuses → exit 15"
if grepq "$LAST_CLEAR_OUT" -F 'PROVENANCE'; then
    fail "quoted-path blocker: an IN-diff path git must quote was falsely flagged out-of-diff: $LAST_CLEAR_OUT"
else pass; fi
rm -rf "$tmp"

# ── HIMMEL-1558: the marker lock + the LANE half of the re-validation ───────
# The marker has exactly two writers — this script and check-cr-before-push.sh
# — and the gates between the first read and the unlink take minutes. These
# cases pin the mutual exclusion and the lane comparison. Every one asserts the
# specific REFUSAL REASON, never a bare non-zero rc (HIMMEL-1554): fail-closed
# bugs and fail-closed features produce identical exit codes.

# marker_lock_dir <tmp> — the branch's lock dir under the CR-marker namespace,
# or empty when the branch is unlocked. The directory NAME is the lock lib's
# business (it slugs the branch), so it is discovered by glob rather than
# re-derived here.
marker_lock_dir() {
    local d
    for d in "$1/.git/himmel-cr-marker"/*.lock; do
        if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
    done
    return 0
}

# stub_gh_repush <tmp> <lane> <sha> — a `gh` stub that REWRITES the marker
# before answering, i.e. a push landing while the gates run. gate 5 calls gh
# after the marker was read and before the final re-validation, so this is the
# real mid-gate window rather than a simulation of one.
stub_gh_repush() {
    local tmp="$1" lane="$2" newsha="$3" base
    base=$(git -C "$tmp" rev-parse --verify refs/heads/main 2>/dev/null || echo deadbeef)
    cat > "$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
printf '2026-07-16T10:30:00+02:00 | %s | %s | origin | refs/heads/feat/x | %s | %s\n' \
    "$newsha" "$lane" ".git/test-origin.git" "$base" > "$tmp/.git/cr-pending/feat/x"
for a in "\$@"; do [ "\$a" = "--head" ] && exit 0; done
echo "positional PR lookup used" >&2
exit 1
STUB
    chmod +x "$tmp/bin/gh"
}

# L1. The lane is reminted full -> docs-audit mid-gate. The stale-marker
# fallback reads the lane BEFORE the gates, so without this comparison the
# docs-audit refusal it owes is never applied to the marker actually deleted.
make_repo || exit 1
write_marker "$tmp" "$sha" full
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_check_ci "$tmp" 0
stub_gh_repush "$tmp" docs-audit "$sha"
run_clear "$tmp" 13 "lane reminted docs-audit mid-gate → exit 13"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=raced-lane-changed'; then pass; else
    fail "mid-gate lane change must refuse with reason=raced-lane-changed: $LAST_CLEAR_OUT"; fi
if grepq "$LAST_CLEAR_OUT" -F "'full' -> 'docs-audit'"; then pass; else
    fail "mid-gate lane refusal must NAME both lanes: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "lane-raced marker must REMAIN"; fi
rm -rf "$tmp"

# L2. The other half: a mid-gate SHA remint is refused NAMING the sha it
# refused on, not merely with a non-zero rc.
make_repo || exit 1
_prev=$(git -C "$tmp" rev-parse --verify "refs/heads/feat/x^")
write_marker "$tmp" "$sha" full
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_check_ci "$tmp" 0
stub_gh_repush "$tmp" full "$_prev"
run_clear "$tmp" 13 "marker SHA rewritten mid-gate → exit 13"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=raced-during-gate'; then pass; else
    fail "mid-gate SHA remint must refuse with reason=raced-during-gate: $LAST_CLEAR_OUT"; fi
if grepq "$LAST_CLEAR_OUT" -F "${_prev:0:8}"; then pass; else
    fail "mid-gate SHA refusal must NAME the SHA that replaced the certified one: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "sha-raced marker must REMAIN"; fi
rm -rf "$tmp"

# L3. A concurrent writer HOLDS the lock: the clear waits its bound, then
# refuses loudly (it must never delete a marker another writer is replacing).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$tmp/scripts/lib/shared-branch-lock.sh" \
    acquire "$tmp" feat/x pre-push-writer >/dev/null 2>&1
export CR_MARKER_LOCK_WAIT_SECONDS=1
run_clear "$tmp" 13 "held marker lock → waits its bound, then exit 13"
unset CR_MARKER_LOCK_WAIT_SECONDS
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=marker-lock-busy'; then pass; else
    fail "a held marker lock must refuse with reason=marker-lock-busy: $LAST_CLEAR_OUT"; fi
if grepq "$LAST_CLEAR_OUT" -F 'pre-push-writer'; then pass; else
    fail "the busy refusal must NAME the holder (owner.json), not just time out: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "lock-busy: marker must REMAIN"; fi
rm -rf "$tmp"

# L4. A STALE lock (its holder died) must not wedge the branch forever: the
# TTL reclaims it, the clear proceeds, and the lock is released on the way out.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$tmp/scripts/lib/shared-branch-lock.sh" \
    acquire "$tmp" feat/x dead-writer >/dev/null 2>&1
printf '{"pid":1,"lane":"dead-writer","branch":"feat/x","acquired_at":"2026-01-01T00:00:00Z","acquired_epoch":%s}\n' \
    "$(( $(date +%s) - 4000 ))" > "$(marker_lock_dir "$tmp")/owner.json"
run_clear "$tmp" 0 "stale marker lock is reclaimed → exit 0"
if grepq "$LAST_CLEAR_OUT" -F 'RECLAIMING a stale lock'; then pass; else
    fail "reclaiming a stale lock must leave a loud trail: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then fail "stale-lock reclaim: marker should be CLEARED"; else pass; fi
if [ -d "$(marker_lock_dir "$tmp")" ]; then
    fail "the marker lock must be released after a successful clear"
else pass; fi
rm -rf "$tmp"

# L5. No lock lib => no mutual exclusion. Refuse rather than fall back to the
# racy re-read: this is the gate whose failure opens `gh pr create`.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
rm -f "$tmp/scripts/lib/shared-branch-lock.sh"
run_clear "$tmp" 11 "missing branch-lock lib → exit 11"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=no-marker-lock-lib'; then pass; else
    fail "a missing lock lib must refuse with reason=no-marker-lock-lib: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "no-lock-lib: marker must REMAIN"; fi
rm -rf "$tmp"

# stub_git_steal_lock <tmp> — a `git` shim that hands the marker lock to
# another writer on the SECOND ls-remote, i.e. exactly inside the locked
# critical section (gate 2 makes the first call, the final re-validation the
# second). Everything else passes straight through to the real git. This is the
# TTL's own cost: a critical section that outruns the TTL can be reclaimed
# under the run that holds it.
stub_git_steal_lock() {
    local tmp="$1" real
    real=$(command -v git)
    cat > "$tmp/bin/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ls-remote" ]; then
    n=0
    [ -f "$tmp/.lsremote-n" ] && n=\$(cat "$tmp/.lsremote-n")
    n=\$((n + 1))
    echo "\$n" > "$tmp/.lsremote-n"
    if [ "\$n" -ge 2 ]; then
        for d in "$tmp/.git/himmel-cr-marker"/*.lock; do
            [ -d "\$d" ] || continue
            printf '{"pid":424242,"lane":"other-writer","branch":"feat/x","acquired_at":"2026-01-01T00:00:00Z","acquired_epoch":1}\n' > "\$d/owner.json"
        done
    fi
fi
exec "$real" "\$@"
STUB
    chmod +x "$tmp/bin/git"
}

# L6. The lock is reclaimed WHILE this run holds it: exclusion is gone, so the
# unlink must not happen — and the new holder's lock must not be released by
# the run that lost it.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
stub_git_steal_lock "$tmp"
run_clear "$tmp" 13 "marker lock reclaimed mid-section → exit 13"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=marker-lock-lost'; then pass; else
    fail "losing the lock mid-section must refuse with reason=marker-lock-lost: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "lock-lost: marker must REMAIN"; fi
if [ -d "$(marker_lock_dir "$tmp")" ]; then pass; else
    fail "the run that LOST the lock must not release the new holder's lock"; fi
rm -rf "$tmp"

# stub_git_repush_marker <tmp> <sha> — like stub_git_steal_lock, but it
# rewrites the MARKER on the second ls-remote: a re-push landing after every
# field re-validation has already passed, in the last gap before the unlink.
# Same SHA and lane, so every field comparison still matches and only the
# certificate's own bytes differ — which is precisely what the claim-then-
# delete check exists to catch.
stub_git_repush_marker() {
    local tmp="$1" newsha="$2" real base
    real=$(command -v git)
    base=$(git -C "$tmp" rev-parse --verify refs/heads/main 2>/dev/null || echo deadbeef)
    cat > "$tmp/bin/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ls-remote" ]; then
    n=0
    [ -f "$tmp/.lsremote-n" ] && n=\$(cat "$tmp/.lsremote-n")
    n=\$((n + 1))
    echo "\$n" > "$tmp/.lsremote-n"
    if [ "\$n" -ge 2 ]; then
        printf '2026-07-16T11:45:00+02:00 | %s | full | origin | refs/heads/feat/x | %s | %s\n' \
            "$newsha" ".git/test-origin.git" "$base" > "$tmp/.git/cr-pending/feat/x"
    fi
fi
exec "$real" "\$@"
STUB
    chmod +x "$tmp/bin/git"
}

# L7. The marker is rewritten in the LAST gap — after the final re-validation,
# before the unlink. No lock closes that gap (a holder starved past the TTL
# loses the lock between the two), so the unlink claims the file by rename and
# deletes only the bytes it validated. The re-pushed marker must survive.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
stub_git_repush_marker "$tmp" "$sha"
run_clear "$tmp" 13 "marker rewritten after the final check → exit 13"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=marker-content-changed'; then pass; else
    fail "a marker rewritten in the last gap must refuse with reason=marker-content-changed: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else
    fail "the re-pushed marker must SURVIVE — deleting it is the bug this ticket exists to close"; fi
if grepq "$(cat "$tmp/.git/cr-pending/feat/x")" -F '11:45:00'; then pass; else
    fail "the surviving marker must be the RE-PUSHED one, not the stale certificate restored over it"; fi
rm -rf "$tmp"

# stub_lock_lib_empty_owner <tmp> — the REAL lock lib, plus one mutation: every
# successful acquire leaves a ZERO-BYTE owner.json. That is a state acquire
# itself produces (it creates the file by redirect and, by design, keeps rc 0
# when the printf fails — a full disk), and it cannot be provoked from outside,
# because the write lives INSIDE acquire. `cat` then yields nothing, so the
# holder record every ownership check compares against is EMPTY.
stub_lock_lib_empty_owner() {
    local tmp="$1"
    cp "$LOCK_LIB" "$tmp/scripts/lib/shared-branch-lock-real.sh"
    cat > "$tmp/scripts/lib/shared-branch-lock.sh" <<STUB
#!/usr/bin/env bash
rc=0
bash "$tmp/scripts/lib/shared-branch-lock-real.sh" "\$@" || rc=\$?
if [ "\$rc" -eq 0 ] && { [ "\$1" = "acquire" ] || [ "\$1" = "acquire-wait" ]; }; then
    for d in "$tmp/.git/himmel-cr-marker"/*.lock; do
        [ -d "\$d" ] && : > "\$d/owner.json"
    done
fi
exit \$rc
STUB
}

# L8. The acquire succeeded but its holder record is EMPTY (HIMMEL-1994). The
# pre-unlink re-check compares that record against itself, so "" == "" would
# PASS for any holder — including a replacement one — and the release would
# then have no record to be conditional on, i.e. an unconditional rm of a
# possibly LIVE lock. Refuse instead: nothing unlinked, lock left alone.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
stub_lock_lib_empty_owner "$tmp"
run_clear "$tmp" 13 "empty holder record after acquire → exit 13"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=marker-lock-owner-unreadable'; then pass; else
    fail "an unreadable holder record must refuse with reason=marker-lock-owner-unreadable: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else
    fail "empty holder record: the marker must REMAIN (nothing may be unlinked without proven exclusion)"; fi
if [ -d "$(marker_lock_dir "$tmp")" ]; then pass; else
    fail "empty holder record: the lock must be LEFT ALONE — with no record it cannot be told from a replacement holder's"; fi
# The lock is left behind, so the refusal owes a recovery command that actually
# works: the namespace must be a PREFIX of the release, not a parenthetical
# after it (a copy-paste of that would release the DEFAULT namespace's lock).
if grepq "$LAST_CLEAR_OUT" -F 'SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash scripts/lib/shared-branch-lock.sh release'; then pass; else
    fail "the refusal must name a copy-pasteable namespaced release: $LAST_CLEAR_OUT"; fi
rm -rf "$tmp"

# ── HIMMEL-2035 T4 SC5: foreign-repo fence ──────────────────────────────────
# clear-cr-marker.sh has NO env seams by design (file header) — it resolves
# marker/lock/log paths via `git rev-parse --git-common-dir` off cwd alone, so
# it already operates on whichever repo the caller's cwd sits in; no --repo
# flag was added. Prove it two ways with this suite's OWN make_repo fixture
# (a genuinely foreign temp repo, not the himmel checkout): a clean clear at
# its own tip, and a refusal at a stale head — and confirm NEITHER run leaves
# a mark on himmel's own git-common-dir artifacts (cr-pending/,
# clear-cr-marker.log). NOT covered here (codex CR round): the
# himmel-cr-marker/ lock namespace — a lock is acquired-then-released WITHIN
# one clear-cr-marker.sh invocation, so a post-run absence check would pass
# whether or not the run ever touched himmel's namespace mid-flight; proving
# that needs an in-flight probe (like the OTHER lock tests in this file use),
# out of scope for a no-touch fence.
HIMMEL_GITDIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"

# The no-touch assertion must be CONCURRENCY-SAFE. himmel's own cr-pending/,
# clear-cr-marker.log and himmel-cr-marker/ are LIVE shared state: any other
# session in this checkout (a parallel /pr-check, another worktree's push) can
# legitimately add a marker or append a log line while this suite runs. A
# whole-directory hash comparison would then fail for a reason that has
# nothing to do with the code under test — a spurious red on the merge gate,
# which is worse than no fence at all.
#
# So assert the PRECISE property instead: the foreign-repo runs below must
# leave nothing ABOUT THE FIXTURE in himmel's git dir. Unrelated concurrent
# entries are ignored; a leaked fixture marker or a log line naming the
# fixture path is caught exactly.
list_pending() {
    if [ -d "$HIMMEL_GITDIR/cr-pending" ]; then
        ( cd "$HIMMEL_GITDIR/cr-pending" && find . -type f | sort )
    fi
}
BEFORE_PENDING_LIST="$(list_pending)"
BEFORE_LOG_LINES=0
[ -f "$HIMMEL_GITDIR/clear-cr-marker.log" ] && \
    BEFORE_LOG_LINES=$(wc -l < "$HIMMEL_GITDIR/clear-cr-marker.log")

# B1: clean clear at the fixture's own real tip (mirrors case 2 above).
make_repo || exit 1
FIXTURE_PATHS="$tmp"
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "foreign-repo clean clear at own tip → exit 0"
if marker_exists "$tmp"; then fail "foreign-repo clean clear: marker should be GONE"; else pass; fi
# Positive half of the no-touch pair: the audit trail landed in the FIXTURE.
FIXTURE_LOG_SEEN=""
[ -f "$tmp/.git/clear-cr-marker.log" ] && FIXTURE_LOG_SEEN=1
rm -rf "$tmp"

# B2: refuse at a STALE head — the marker certifies an earlier sha, the branch
# has since moved, and nothing at the new tip supersedes it (mirrors case 3b
# above, the minimal reproduction of "refuse").
make_repo || exit 1
FIXTURE_PATHS="$FIXTURE_PATHS
$tmp"
write_marker "$tmp" "$sha"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later unreviewed work" && git push -q origin feat/x) >/dev/null 2>&1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "foreign-repo refuse at stale head → exit 14"
if marker_exists "$tmp"; then pass; else fail "foreign-repo stale head: marker must REMAIN"; fi
rm -rf "$tmp"

# (a) No cr-pending entry that this run ADDED may name the fixture branch.
# Entries added by a concurrent session are ignored on purpose — see the
# concurrency note above.
added_pending=$(printf '%s\n' "$(list_pending)" | grep -Fxv -f <(printf '%s\n' "$BEFORE_PENDING_LIST") 2>/dev/null || true)
leaked=$(printf '%s\n' "$added_pending" | grep -E '(^|/)feat/x$' || true)
if [ -z "$leaked" ]; then pass; else
    fail "the foreign-repo run leaked a marker into himmel's own cr-pending/: $leaked"; fi

# (b) No clear-cr-marker.log line APPENDED by this run may name a fixture path
# — the log is himmel's, and a foreign clear must never be recorded in it.
if [ -f "$HIMMEL_GITDIR/clear-cr-marker.log" ]; then
    appended=$(tail -n "+$((BEFORE_LOG_LINES + 1))" "$HIMMEL_GITDIR/clear-cr-marker.log" 2>/dev/null || true)
else
    appended=""
fi
log_leak=""
while IFS= read -r fx; do
    [ -n "$fx" ] || continue
    case "$appended" in *"$fx"*) log_leak="$fx" ;; esac
done <<EOF
$FIXTURE_PATHS
EOF
if [ -z "$log_leak" ]; then pass; else
    fail "the foreign-repo run appended a line naming the fixture ($log_leak) to himmel's own clear-cr-marker.log"; fi

# (c) The fixture's OWN log must exist — positive evidence the audit trail
# landed in the reviewed repo. Concurrency-immune, and it is the half that
# actually proves cwd selected the repo.
if [ -n "$FIXTURE_LOG_SEEN" ]; then pass; else
    fail "the foreign-repo clear wrote no clear-cr-marker.log inside the fixture"; fi

# 8. Unadjudicated findings at the current head (HIMMEL-2067, gate 4b). Gate 4
# never blocks on `sug`, so a suggestion could be left with verdict:"" forever
# and the marker would still clear — this closes that gap.

# 8a. A sug finding with NO verdict at the tip must refuse (exit 14), name the
# finding id in the refusal, and leave the marker in place.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" sug "")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "sug finding with no verdict at tip -> exit 14"
if grepq "$LAST_CLEAR_OUT" -F 'REFUSED reason=unadjudicated-findings'; then pass; else
    fail "unadjudicated sug must refuse with reason=unadjudicated-findings: $LAST_CLEAR_OUT"; fi
if grepq "$LAST_CLEAR_OUT" -F 'codex-1'; then pass; else
    fail "the refusal must name the unadjudicated finding id: $LAST_CLEAR_OUT"; fi
if marker_exists "$tmp"; then pass; else fail "unadjudicated sug: marker must REMAIN"; fi
rm -rf "$tmp"

# 8b. The SAME finding, now with --verdict disproved recorded -> clears as
# before (gate 4b is satisfied once a decision exists, whatever it is).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" sug disproved)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "sug finding with verdict=disproved clears -> exit 0"
if marker_exists "$tmp"; then fail "adjudicated sug: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 8c. A sug finding recorded with NO verdict, whose verdict is then supplied by
# a later `amend` row -> clears. Proves amends are applied BEFORE the null
# check, same as gate 4.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" sug "")" \
  "$(printf '{"kind":"amend","target_head":"%s","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"adjudicated after CR"}' "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "amend supplies the missing verdict -> exit 0"
if marker_exists "$tmp"; then fail "amend-adjudicated sug: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 8d. An unadjudicated finding recorded at a SUPERSEDED head (not the current
# tip) must NOT block -- only the current head is gated.
make_repo || exit 1
(cd "$tmp" && echo x >> f.txt && git commit -qam "later reviewed work" && git push -q origin feat/x) >/dev/null 2>&1
_tip=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
write_marker "$tmp" "$_tip"
write_ledger "$tmp" "$(finding "${sha:0:8}" sug "")" "$(avail_ok "${_tip:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "unadjudicated finding on a superseded head does not block -> exit 0"
if marker_exists "$tmp"; then fail "superseded-head unadjudicated: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 5a-5e. HIMMEL-2128 — CR_FLOOR_FALLBACK=claude-only gate-3b escape. All five
# cases require cross-model (else gate 3b never runs) and a Claude avail-ok row
# (the floor). The fallback fires ONLY when every non-Claude lane that recorded
# ANY avail row at this head is unavailable with a VERIFIED-exhaustion reason
# (quota/rate-limit) — never on silence, timeout, an unclassified rc, or a
# mix where even one lane is not exhaustion-classed.
export CR_REQUIRE_CROSS_MODEL=1

# 5a. codex unavailable reason=quota + claude ok + knob set -> clears (exit 0).
export CR_FLOOR_FALLBACK=claude-only
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_reason "${sha:0:8}" codex unavailable quota)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "5a CR_FLOOR_FALLBACK=claude-only + codex quota-exhausted + claude ok -> exit 0"
if marker_exists "$tmp"; then fail "5a floor-fallback accepted: marker should be GONE"; else pass; fi
if grepq "$LAST_CLEAR_OUT" 'FLOOR-FALLBACK\|claude-only'; then pass; else
    fail "5a floor-fallback acceptance must be named in the output"
fi
rm -rf "$tmp"
unset CR_FLOOR_FALLBACK

# 5b. Same ledger, knob UNSET -> exit 14 (unchanged default refusal).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_reason "${sha:0:8}" codex unavailable quota)"
run_clear "$tmp" 14 "5b same ledger, CR_FLOOR_FALLBACK unset -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5b fallback unset: marker must REMAIN"; fi
rm -rf "$tmp"

# 5c. codex unavailable with NO reason + knob set -> exit 14 (unclassified
# exhaustion is not verified exhaustion).
export CR_FLOOR_FALLBACK=claude-only
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_reason "${sha:0:8}" codex unavailable)"
run_clear "$tmp" 14 "5c codex unavailable with no reason + knob set -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5c no-reason unavailable: marker must REMAIN"; fi
rm -rf "$tmp"

# 5d. codex unavailable reason=timeout + knob set -> exit 14 (timeout is not a
# verified-exhaustion class — a failing lane is usually OUR config).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" "$(avail_reason "${sha:0:8}" codex unavailable timeout)"
run_clear "$tmp" 14 "5d codex unavailable reason=timeout + knob set -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5d reason=timeout: marker must REMAIN"; fi
rm -rf "$tmp"

# 5e. Two non-Claude lanes, one reason=quota one reason=config + knob set ->
# exit 14 (ALL must be exhaustion-classed, not just one).
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" \
    "$(avail_reason "${sha:0:8}" codex unavailable quota)" \
    "$(avail_reason "${sha:0:8}" glm unavailable config)"
run_clear "$tmp" 14 "5e one exhausted + one config-broken non-Claude lane + knob set -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5e mixed exhaustion: marker must REMAIN"; fi
rm -rf "$tmp"

# 5f. Silence is not exhaustion: ONLY a claude avail-ok row, ZERO non-Claude
# avail rows at all (none recorded, none attempted) + knob set -> exit 14, the
# ORDINARY no-cross-model message, NOT FLOOR-FALLBACK (pins
# nonClaudeAvailModels.length > 0 — a lane that never even ran is not
# "verified exhausted").
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")"
run_clear "$tmp" 14 "5f claude-only, zero non-Claude avail rows + knob set -> exit 14 (silence != exhaustion)"
if marker_exists "$tmp"; then pass; else fail "5f silence: marker must REMAIN"; fi
if grepq "$LAST_CLEAR_OUT" 'FLOOR-FALLBACK'; then
    fail "5f must NOT report a floor-fallback acceptance — no lane ever ran"
else
    pass
fi
if grepq "$LAST_CLEAR_OUT" 'no non-Claude'; then pass; else
    fail "5f must print the ordinary no-cross-model refusal message"
fi
rm -rf "$tmp"

# 5g. Genuine last-write-wins: TWO raw avail lines for the SAME non-Claude
# model at the SAME head — unavailable(quota) then unavailable(config) — must
# resolve to the LAST (config) reading, not the first. config is not an
# exhaustion class, so this refuses (exit 14) even though an earlier line at
# this exact head said quota. Pins the JS Map overwrite semantics directly via
# raw JSONL synthesis, independent of ledger-append.sh's own write-time dedup.
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" \
    "$(avail_reason "${sha:0:8}" codex unavailable quota)" \
    "$(avail_reason "${sha:0:8}" codex unavailable config)"
run_clear "$tmp" 14 "5g last-write-wins: unavailable(quota) then unavailable(config) -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5g last-write-wins: marker must REMAIN"; fi
rm -rf "$tmp"

# 5h (HIMMEL-2129, HIMMEL-2128 follow-up). critic-panel.sh now records a
# non-Claude avail row for a critic THIS RUN deselected (tier filter exclusion
# or the HIMMEL-1950 keep-one cap) instead of leaving silence — see
# scripts/cr/critic-panel.sh's _tier_excluded_raw/_keepone_dropped_raw. Pin
# that its literal reason vocabulary (reason=tier-excluded,
# reason=keep-one-skipped) is NOT exhaustion-classed here, same as any other
# non-exhaustion reason (5c-5g): one exhausted lane + one deselected-but-
# available lane + knob set -> still refuses (exit 14).
export CR_FLOOR_FALLBACK=claude-only
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" \
    "$(avail_reason "${sha:0:8}" codex unavailable quota)" \
    "$(avail_reason "${sha:0:8}" glm unavailable tier-excluded)"
run_clear "$tmp" 14 "5h one exhausted + one deselected (reason=tier-excluded) non-Claude lane + knob set -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5h deselected-but-available lane: marker must REMAIN"; fi
rm -rf "$tmp"
unset CR_FLOOR_FALLBACK

# 5i (codex-2 CR round, HIMMEL-2129): same pin as 5h for the OTHER new reason
# string critic-panel.sh's HIMMEL-1950 keep-one cap emits
# (reason=keep-one-skipped) -- 5h only exercised reason=tier-excluded, so a
# regression narrowing EXHAUSTION_REASONS' complement to just that one string
# would have slipped through unnoticed.
export CR_FLOOR_FALLBACK=claude-only
make_repo || exit 1
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok_claude "${sha:0:8}")" \
    "$(avail_reason "${sha:0:8}" codex unavailable quota)" \
    "$(avail_reason "${sha:0:8}" glm unavailable keep-one-skipped)"
run_clear "$tmp" 14 "5i one exhausted + one deselected (reason=keep-one-skipped) non-Claude lane + knob set -> exit 14"
if marker_exists "$tmp"; then pass; else fail "5i deselected-but-available lane: marker must REMAIN"; fi
rm -rf "$tmp"
unset CR_FLOOR_FALLBACK

unset CR_REQUIRE_CROSS_MODEL

echo
echo "clear-cr-marker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
