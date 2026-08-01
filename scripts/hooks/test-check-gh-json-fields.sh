#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-gh-json-fields.sh (HIMMEL-1288).
#
# The regression this locks: `gh pr view --json headRefSha` (no such
# field) must FAIL LOUDLY here at commit time, instead of shipping and
# surfacing later as a generic "cannot evaluate" that hides a guarded
# path never running.
#
# Uses a `gh` stub on PATH so the suite is hermetic — no real gh, no
# network, and the field lists are fixed rather than tracking whatever
# gh version the machine happens to have.
#
# File-scoped: the test cases are single-quoted shell FIXTURES fed to the
# gate as file content. Their `$pr` / `$FIELDS` must stay literal — one
# of the cases exists precisely to prove an unexpanded `--json "$FIELDS"`
# is skipped — so SC2016 is the intended shape here, not a bug.
# shellcheck disable=SC2016
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }


HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/check-gh-json-fields.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# --- gh stub -------------------------------------------------------------
# Mirrors real gh: an unknown field goes to STDERR as "Unknown JSON field"
# + "Available fields:" + an indented list, exit 1. `gh api` supports no
# --json at all, so it must not print a field list.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_CALL_LOG:-}" ] && echo "$1 $2" >>"$GH_CALL_LOG"
sub="$1 $2"
case "$sub" in
    "pr view"|"pr list")
        echo 'Unknown JSON field: "x"' >&2
        echo 'Available fields:' >&2
        printf '  %s\n' baseRefName headRefName headRefOid number reviews state url >&2
        exit 1 ;;
    "repo view")
        echo 'Unknown JSON field: "x"' >&2
        echo 'Available fields:' >&2
        printf '  %s\n' isPrivate nameWithOwner >&2
        exit 1 ;;
    *)
        echo 'unknown command' >&2
        exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

check() {
    # check <name> <expected-rc> <file-content>
    name="$1"; want="$2"; body="$3"
    f="$TMP/case.md"
    printf '%s\n' "$body" >"$f"
    out=$(cd "$TMP" && bash "$GATE" case.md 2>&1)
    got=$?
    if [ "$got" -eq "$want" ]; then
        echo "ok   — $name"
        pass=$((pass + 1))
    else
        echo "FAIL — $name (want rc=$want, got rc=$got)"
        printf '%s\n' "$out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

# The actual HIMMEL-1288 bug, verbatim in shape.
check "headRefSha is rejected" 1 \
    '    head=$(gh pr view "$pr" --repo "$REPO" --json headRefSha -q .headRefSha)'

# The fix must pass.
check "headRefOid is accepted" 0 \
    '    head=$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid)'

# HIMMEL-1326: backslash continuation splits `gh` and `--json` across two
# physical lines, so the per-physical-line grep saw neither half and the
# bogus field shipped. The gate must join them into one logical command.
# Fixtures are built with a heredoc so the backslash-newline is a REAL
# continuation (a `printf '...\n...'` would keep it on one physical line,
# match cleanly, and mask the bug — the trap the previous session hit).
invalid_cont=$(cat <<'EOF'
gh pr view "$pr" --repo "$REPO" \
    --json headRefSha -q .headRefSha
EOF
)
check "backslash-continued bogus field is rejected" 1 "$invalid_cont"

valid_cont=$(cat <<'EOF'
gh pr view "$pr" --repo "$REPO" \
    --json headRefOid -q .headRefOid
EOF
)
check "backslash-continued real field is accepted" 0 "$valid_cont"

# The join must concatenate with NO separator, exactly as the shell removes the
# `\`+newline PAIR: `headRef\` + `Oid` is the single token `headRefOid`. Joining
# with a space would split it into `headRef` and `Oid` and reject valid code —
# a false positive, which is worse for a lint than the miss it replaces.
split_token=$(cat <<'EOF'
gh pr view "$pr" --repo "$REPO" --json headRef\
Oid -q .headRefOid
EOF
)
check "field token split across the continuation is accepted" 0 "$split_token"

# ...and the same split must NOT launder a bogus field past the gate.
split_token_bad=$(cat <<'EOF'
gh pr view "$pr" --repo "$REPO" --json headRef\
Sha -q .headRefSha
EOF
)
check "field token split across the continuation is still validated" 1 "$split_token_bad"

# Multi-field CSV: one bad name among good ones still fails.
check "bad field inside a CSV is rejected" 1 \
    'gh pr list --head "$b" --state open --json number,headRefSha'

check "all-good CSV is accepted" 0 \
    'gh pr list --head "$b" --state open --json number,headRefOid'

# Field sets are per-subcommand: a valid `pr view` field is not a valid
# `repo view` field, and the gate must not pool them.
check "field valid elsewhere is rejected for this subcommand" 1 \
    'gh repo view --json headRefOid'

check "correct subcommand field is accepted" 0 \
    'gh repo view --json nameWithOwner,isPrivate'

# Subcommands with no --json support are not this gate's business.
check "subcommand without --json support is skipped" 0 \
    'gh api graphql --json whatever'

# Non-literal field lists are skipped rather than guessed at.
check "variable field list is skipped" 0 \
    'gh pr view --json "$FIELDS"'

# A file with no gh calls at all is trivially clean.
check "unrelated file is clean" 0 \
    'nothing to see here'

# Missing gh must skip (rc 0), not block every commit on a lint. Invoke
# bash by absolute path — the emptied PATH cannot resolve `bash` itself.
BASH_ABS=$(command -v bash)
printf '%s\n' 'gh pr view --json headRefSha' >"$TMP/case.md"
out=$(cd "$TMP" && PATH="/nonexistent" "$BASH_ABS" "$GATE" case.md 2>&1); got=$?
if [ "$got" -eq 0 ] && grepq "$out" 'skipping'; then
    echo "ok   — missing gh skips loudly"
    pass=$((pass + 1))
else
    echo "FAIL — missing gh should skip with rc=0 (got rc=$got)"
    fail=$((fail + 1))
fi

# The gate and its own test carry bogus fields as fixtures — they must be
# exempt by repo-relative path, or this suite could never be committed.
mkdir -p "$TMP/scripts/hooks"
printf '%s\n' 'gh pr view --json headRefSha' >"$TMP/scripts/hooks/check-gh-json-fields.sh"
cp "$TMP/scripts/hooks/check-gh-json-fields.sh" "$TMP/scripts/hooks/test-check-gh-json-fields.sh"
if (cd "$TMP" && bash "$GATE" scripts/hooks/check-gh-json-fields.sh scripts/hooks/test-check-gh-json-fields.sh >/dev/null 2>&1); then
    echo "ok   — gate + its test are self-exempt"
    pass=$((pass + 1))
else
    echo "FAIL — gate + its test should be self-exempt"
    fail=$((fail + 1))
fi

# The per-subcommand field list is cached, so gh is probed ONCE per
# distinct subcommand no matter how many lines reference it. Returning
# the list through `$(fields_for …)` instead of a global would run the
# function in a subshell and discard every cache write — the cache would
# look present in the source and never hit.
printf '%s\n' \
    'gh pr view --json headRefOid' \
    'gh pr view --json number' \
    'gh pr view --json state' \
    'gh repo view --json isPrivate' >"$TMP/case.md"
: >"$TMP/gh.log"
(cd "$TMP" && GH_CALL_LOG="$TMP/gh.log" bash "$GATE" case.md >/dev/null 2>&1)
probes=$(sort -u "$TMP/gh.log" | wc -l | tr -d ' ')
calls=$(wc -l <"$TMP/gh.log" | tr -d ' ')
if [ "$calls" -eq "$probes" ] && [ "$calls" -eq 2 ]; then
    echo "ok   — field lists are cached (one gh probe per subcommand)"
    pass=$((pass + 1))
else
    echo "FAIL — expected 2 gh probes (pr view, repo view), got $calls"
    fail=$((fail + 1))
fi

echo
echo "check-gh-json-fields: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
