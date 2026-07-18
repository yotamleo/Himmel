#!/usr/bin/env bash
# Tests for cr/clear-cr-marker.sh — the HIMMEL-1064 CR-marker clearing
# chokepoint. The script has NO env seams for the ledger / check-ci / gh (gate
# integrity — a caller-pointed ledger would forge the very evidence the clear
# depends on). So each case builds a REAL temp git repo, copies the script tree
# into it ($tmp/scripts/cr/clear-cr-marker.sh + a stub $tmp/scripts/check-ci.sh)
# and puts a stub `gh` FIRST on PATH. The ledger + marker are written at the
# fixed paths under the temp repo's own .git, exactly as the real ones resolve.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEAR="$SCRIPT_DIR/clear-cr-marker.sh"
LEDGER_APPEND="$SCRIPT_DIR/ledger-append.sh"
CODEX_SKILL="$ROOT/.agents/skills/pr-check/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# make_repo — a temp git repo with one commit on branch `feat/x`.
# Sets the shared vars `tmp` and `sha` directly rather than echoing them
# whitespace-separated for `read` (coderabbit): a mktemp path containing a space
# would split across both values and corrupt the harness. Scripts here run on
# Windows Git Bash / macOS / Linux, where a spaced TMPDIR is entirely possible.
make_repo() {
    tmp=$(mktemp -d)
    (
        cd "$tmp" || exit 1
        git init -q -b main .
        git config user.email t@t.t; git config user.name t
        echo hi > f.txt
        git add f.txt
        git commit -qm "base"
        git checkout -qb feat/x
        echo more >> f.txt
        git commit -qam "work"
    ) >/dev/null 2>&1
    sha=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
    mkdir -p "$tmp/scripts/cr" "$tmp/bin"
    cp "$CLEAR" "$tmp/scripts/cr/clear-cr-marker.sh"
    cp "$LEDGER_APPEND" "$tmp/scripts/cr/ledger-append.sh"
}

# write_marker <tmp> <sha> [lane]
write_marker() {
    local tmp="$1" sha="$2" lane="${3:-full}"
    mkdir -p "$tmp/.git/cr-pending/feat"
    printf '2026-07-16T10:00:00+02:00 | %s | %s\n' "$sha" "$lane" > "$tmp/.git/cr-pending/feat/x"
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

# stub_check_ci <tmp> <rc>
stub_check_ci() {
    printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$1/scripts/check-ci.sh"
    chmod +x "$1/scripts/check-ci.sh"
}

# run_clear <tmp> <expected-rc> <name> [args...]
run_clear() {
    local tmp="$1" expected="$2" name="$3"; shift 3
    local rc=0 out
    out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-cr-marker.sh" "$@" 2>&1) || rc=$?
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
if grep -Fq 'bash scripts/cr/ledger-append.sh finding' "$CODEX_SKILL"; then pass; else
    fail "Codex skill records blocking findings in the CR ledger"
fi
if grep -Fq 'bash scripts/cr/ledger-append.sh avail' "$CODEX_SKILL"; then pass; else
    fail "Codex skill records critic availability in the CR ledger"
fi
# shellcheck disable=SC2016  # literal skill contract; do not expand $(...)
if grep -Fq 'head=$(git rev-parse HEAD)' "$CODEX_SKILL"; then pass; else
    fail "Codex skill records ledger evidence with the full HEAD SHA"
fi
# shellcheck disable=SC2016  # literal skill contract; do not expand $branch
if grep -Fq 'bash scripts/cr/clear-cr-marker.sh "$branch"' "$CODEX_SKILL"; then pass; else
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
# lines, so ordering tracks each command's FIRST occurrence; the --head "$head"
# binding is asserted separately below.)
# shellcheck disable=SC2016  # literal skill contract patterns; do not expand
contract_order_ok() {
    awk '
        !head  && /head=\$\(git rev-parse HEAD\)/          { head = NR }
        !find_ && /bash scripts\/cr\/ledger-append\.sh finding/ { find_ = NR }
        !avail && /bash scripts\/cr\/ledger-append\.sh avail/   { avail = NR }
        !clear && /bash scripts\/cr\/clear-cr-marker\.sh "\$branch"/ { clear = NR }
        END { exit !(head && find_ && avail && clear &&
                     head < find_ && head < avail &&
                     find_ < clear && avail < clear) }
    ' "$CODEX_SKILL"
}
if contract_order_ok; then pass; else
    fail "Codex skill records ledger evidence before marker clearing"
fi
# Each ledger-append command must bind --head "$head" within its OWN
# (multi-line) continuation block — not merely somewhere in the file (coderabbit
# r2). Walk each `ledger-append.sh <kind>` command to its end-of-continuation.
# shellcheck disable=SC2016  # literal skill contract patterns; do not expand
ledger_command_has_head() {
    awk -v kind="$1" '
        $0 ~ "bash scripts/cr/ledger-append\\.sh " kind {
            if (command) invalid = 1
            command = 1
            bound = 0
            seen = 1
        }
        command {
            if (index($0, "--head \"$head\"")) bound = 1
            if ($0 !~ /\\[[:space:]]*$/) {
                if (!bound) invalid = 1
                command = 0
            }
        }
        END { exit !(seen && !command && !invalid) }
    ' "$CODEX_SKILL"
}
if ledger_command_has_head finding && ledger_command_has_head avail; then
    pass
else
    fail "Codex skill binds each ledger evidence command to the full HEAD SHA"
fi

# 1. No marker at all → nothing to do, exit 0.
make_repo
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "no marker → exit 0"
rm -rf "$tmp"

# 2. Happy path, pre-PR: marker SHA == tip, a critic responded, no findings.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "pre-PR clean → exit 0"
if marker_exists "$tmp"; then fail "pre-PR clean: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 2b. The ledger's SHORT head must match the full tip (prefix match).
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:7}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "short-sha ledger head matches full tip → exit 0"
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
make_repo
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
elif ! printf '%s' "$_amb_err" | grep -q 'is ambiguous'; then
    fail "2d setup: '${_tip7}' failed to resolve but NOT from ambiguity — the collision shape was not reproduced (git said: ${_amb_err})"
else
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "$_tip7")"
    stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
    run_clear "$tmp" 14 "ambiguous ledger abbreviation does not certify the tip → exit 14"
    if marker_exists "$tmp"; then pass; else fail "ambiguous ledger head: marker must REMAIN"; fi
fi
rm -rf "$tmp"

# 2c. A too-short/garbage head must NOT match everything (the >=7 guard).
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" '{"kind":"avail","head":"x","model":"codex","status":"ok"}'
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "garbage 1-char ledger head does not match → exit 14"
if marker_exists "$tmp"; then pass; else fail "garbage head: marker must REMAIN"; fi
rm -rf "$tmp"

# 3. Stale marker: a commit landed after the review → refuse, keep the marker.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
(cd "$tmp" && echo x >> f.txt && git commit -qam "later work") >/dev/null 2>&1
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 13 "stale marker (HEAD moved) → exit 13"
if marker_exists "$tmp"; then pass; else fail "stale marker: marker must REMAIN"; fi
rm -rf "$tmp"

# 4. Zero responders = MISSING signal, not clean (the CodeRabbit rate-limit
# shape). An `unavailable` record alone must NOT clear the gate.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_bad "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "only 'unavailable' critics → exit 14 (missing != clean)"
if marker_exists "$tmp"; then pass; else fail "no responders: marker must REMAIN"; fi
rm -rf "$tmp"

# 4b. Empty ledger → no evidence /pr-check ever ran → refuse.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "empty ledger → exit 14"
rm -rf "$tmp"

# 4c. Ledger records exist but for a DIFFERENT sha → no evidence at this head.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "deadbeef")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "ledger evidence for another sha → exit 14"
rm -rf "$tmp"

# 4d. Codex skill integration: a clean panel writes an avail-ok row through
# ledger-append.sh, then the chokepoint clears the marker.
make_repo
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Codex clean panel appends avail-ok" avail \
    --branch feat/x --head "$sha" --model codex --status ok
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "Codex clean ledger evidence → exit 0"
if marker_exists "$tmp"; then fail "Codex clean path: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 4e. Codex skill integration: a recorded Important finding remains blocking
# even with a responder row, so the chokepoint refuses with exit 15.
make_repo
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
make_repo
write_marker "$tmp" "$sha"
append_ledger "$tmp" "Codex unavailable panel appends row" avail \
    --branch feat/x --head "$sha" --model codex --status unavailable
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "Codex no avail-ok evidence → exit 14"
if marker_exists "$tmp"; then pass; else fail "Codex no-responder path: marker must REMAIN"; fi
rm -rf "$tmp"

# 5. Blocking findings at this head → refuse.
for _sev in crit imp; do
    for _v in agreed conflict unaddressed; do
        make_repo
        write_marker "$tmp" "$sha"
        write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" "$_sev" "$_v")"
        stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
        run_clear "$tmp" 15 "$_sev finding verdict=$_v → exit 15"
        if marker_exists "$tmp"; then pass; else fail "$_sev/$_v: marker must REMAIN"; fi
        rm -rf "$tmp"
    done
done

# 6. A DISPROVED crit is not blocking (the runbook's adjudication rule).
make_repo
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" crit disproved)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "disproved crit is not blocking → exit 0"
rm -rf "$tmp"

# 6b. A Suggestion never blocks.
make_repo
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" "$(finding "${sha:0:8}" sug agreed)"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "sug finding does not block → exit 0"
rm -rf "$tmp"

# 7. POST-PR: a PR exists and check-ci is green → clear (operator, HIMMEL-1064).
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "post-PR + check-ci green → exit 0"
if marker_exists "$tmp"; then fail "post-PR green: marker should be GONE"; else pass; fi
rm -rf "$tmp"

# 7b. POST-PR: check-ci NOT green → refuse even though the ledger is clean.
# 3 = unresolved threads / changes requested, 1 = red CI, 2 = cannot evaluate.
for _rc in 1 2 3; do
    make_repo
    write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
    stub_gh "$tmp" 42; stub_check_ci "$tmp" "$_rc"
    run_clear "$tmp" 16 "post-PR + check-ci rc=$_rc → exit 16"
    if marker_exists "$tmp"; then pass; else fail "post-PR rc=$_rc: marker must REMAIN"; fi
    rm -rf "$tmp"
done

# 7c. POST-PR but check-ci.sh is missing → cannot certify CI → refuse.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42
run_clear "$tmp" 16 "post-PR + check-ci.sh absent → exit 16"
rm -rf "$tmp"

# 7d. gh FAILS for a non-"no PR" reason → PR state UNKNOWN → refuse (codex-1).
# Without this the gate FAILS OPEN: a transient gh outage looks like "no PR",
# skipping the post-PR CI check entirely and clearing the marker unverified.
make_repo
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
make_repo
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
make_repo
write_marker "$tmp" "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")" '{"kind":"finding","head":"trunc'
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 14 "malformed ledger record → exit 14"
if marker_exists "$tmp"; then pass; else fail "malformed ledger: marker must REMAIN"; fi
rm -rf "$tmp"

# 7h. A numeric branch name must NOT be resolved as a PR number (coderabbit).
# `gh pr view 42` would return PR #42 — a different PR whose CI would then
# certify this branch. The --head query is unambiguous; assert we pass --head.
make_repo
(cd "$tmp" && git branch -m feat/x 42) >/dev/null 2>&1
_numsha=$(git -C "$tmp" rev-parse --verify refs/heads/42)
mkdir -p "$tmp/.git/cr-pending"
printf '2026-07-16T10:00:00+02:00 | %s | full\n' "$_numsha" > "$tmp/.git/cr-pending/42"
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
make_repo
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
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" 42 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; stub_check_ci "$tmp" 0
run_clear "$tmp" 16 "PR head != certified SHA (CI green) → exit 16"
if marker_exists "$tmp"; then pass; else fail "PR head mismatch: marker must REMAIN"; fi
rm -rf "$tmp"

# 7i. Two open PRs for one head → ambiguous → refuse rather than guess.
make_repo
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
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
cat > "$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
# Simulate a push landing during the gate: marker now certifies a NEWER sha.
printf '2026-07-16T10:05:00+02:00 | %s | full\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$tmp/.git/cr-pending/feat/x"
echo ""
exit 0
STUB
chmod +x "$tmp/bin/gh"
stub_check_ci "$tmp" 0
run_clear "$tmp" 13 "marker rewritten mid-gate (concurrent push) → exit 13"
if marker_exists "$tmp"; then pass; else fail "raced marker: the NEW marker must REMAIN"; fi
rm -rf "$tmp"

# 8. --dry-run runs every gate but never clears.
make_repo
write_marker "$tmp" "$sha"; write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 0 "--dry-run passing gates → exit 0" --dry-run
if marker_exists "$tmp"; then pass; else fail "--dry-run must NOT clear the marker"; fi
rm -rf "$tmp"

# 9. Usage errors.
make_repo
stub_gh "$tmp" ""; stub_check_ci "$tmp" 0
run_clear "$tmp" 10 "unknown option → exit 10" --bogus
run_clear "$tmp" 10 "two branches → exit 10" feat/x feat/y
rm -rf "$tmp"

# 10. An explicit branch arg gates on THAT branch's tip, not cwd HEAD.
make_repo
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
    if printf '%s' "$help_out" | grep -qE "^ *${_code} +[a-z]"; then
        pass
    else
        fail "--help documents exit code ${_code}"
    fi
done
if printf '%s' "$help_out" | grep -q 'set -uo pipefail'; then
    fail "--help leaks the 'set -uo pipefail' code line"
else
    pass
fi

echo
echo "clear-cr-marker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
