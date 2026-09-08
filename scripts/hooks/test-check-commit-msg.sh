#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-commit-msg.sh (HIMMEL-1483).
# Exercises default-off compatibility, strict Jira/custom patterns, and exemptions.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-commit-msg.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"
R=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$R"' EXIT
git -C "$R" init -q
git -C "$R" config user.email t@t
git -C "$R" config user.name t
MSG="$R/COMMIT_MSG"

run_gate() {
  local message="$1"
  shift
  printf '%s\n' "$message" > "$MSG"
  ( cd "$R" && env -u TICKET_ID_REQUIRED -u TICKET_ID_PATTERN \
      -u TICKET_ID_EXEMPT_AUTHORS -u TICKET_ID_AUTHOR -u TICKET_ID_TRUSTED_AUTHOR -u JIRA_PROJECT_KEY \
      "$@" bash "$SCRIPT" "$MSG" )
}

failures=0
expect_rc() {
  local name="$1" want="$2" message="$3"
  shift 3
  local rc=0
  run_gate "$message" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (rc=%s, want %s)\n' "$name" "$rc" "$want"
    failures=$((failures + 1))
  fi
}

# HIMMEL-2442: the gate is ON by default, and with no ticket system configured
# the pattern is himmel's own `#N` enumeration. (a)-(d) are the ticket's
# acceptance cases; (a) is the exact control that PASSED on the HIMMEL-2432
# Ubuntu guest before this change.
expect_rc "default ON rejects a ticketless message (adopter defaults)" 1 "chore: no ticket id here"
expect_rc "default ON accepts #N" 0 "chore: [#12] wire the thing"
# CR2: the default #N pattern must not match inside a longer token, and must
# still accept every shape the rejection message tells adopters to use.
expect_rc "default ON rejects #N inside a longer token (CSS colour)" 1 \
  "chore: use #123abc for the border"
expect_rc "default ON accepts a bracketed #N" 0 "chore: [#12] wire the thing"
expect_rc "default ON accepts a trailing-colon #N" 0 "chore: #12: wire the thing"
expect_rc "default ON accepts a bare #N at end of subject" 0 "chore: wire the thing #12"
expect_rc "Jira posture does not accept bare #N" 1 "chore: [#12] wire the thing" \
  JIRA_PROJECT_KEY=HIMMEL
expect_rc "Jira posture accepts PROJECT-N without TICKET_ID_REQUIRED" 0 \
  "chore: HIMMEL-2442 wire the thing" JIRA_PROJECT_KEY=HIMMEL
expect_rc "explicit opt-out keeps ticket optional" 0 "feat: add feature" TICKET_ID_REQUIRED=0
# CR3 twin parity: the .ps1's `switch -Regex` is case-insensitive by default, so
# these spellings MUST resolve the same way in both hooks. The same cases exist
# in test-check-commit-msg.ps1.
expect_rc "mixed-case False opts out (twin parity)" 0 "feat: add feature" TICKET_ID_REQUIRED=False
expect_rc "mixed-case True still requires a ticket (twin parity)" 1 "feat: add feature" \
  TICKET_ID_REQUIRED=True
# The discriminating arm: before normalization EVERY mixed-case spelling was
# rejected as invalid config, so the two cases above were rc=1 for the wrong
# reason. This one is rc=1 pre-change and rc=0 post-change.
expect_rc "mixed-case True accepts a ticketed message (twin parity)" 0 "feat: [#12] add feature" \
  TICKET_ID_REQUIRED=True
expect_rc "an unrecognised TICKET_ID_REQUIRED fails closed" 1 "feat: [#12] add feature" \
  TICKET_ID_REQUIRED=maybe
expect_rc "malformed conventional commit still rejects" 1 "not conventional"
# Positive control: a garbage message is rejected in EVERY posture, so a rejection
# above is a ticket verdict rather than the shape check firing for both arms.
expect_rc "garbage rejected under explicit opt-out" 1 "not conventional" TICKET_ID_REQUIRED=0
expect_rc "garbage rejected under Jira posture" 1 "not conventional" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "strict Jira mode rejects missing ticket" 1 "feat: add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "strict Jira mode accepts PROJECT-N" 0 "feat: ACME-42 add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "custom regex supports no-Jira #N tickets" 0 "fix: close #73" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_PATTERN=#[0-9]+'
# HIMMEL-2442: no configured pattern is no longer a configuration error — it is
# the `#N` posture, so a ticketless message still fails, and an #N one passes.
expect_rc "no configured pattern falls back to #N and rejects" 1 "feat: add feature" \
  TICKET_ID_REQUIRED=1
expect_rc "no configured pattern falls back to #N and accepts" 0 "feat: [#7] add feature" \
  TICKET_ID_REQUIRED=1
expect_rc "invalid custom regex fails closed" 1 "feat: [ add feature" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_PATTERN=['
expect_rc "fake merge subject is not exempt" 1 "Merge branch 'main'" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "bare revert subject is not exempt" 1 'Revert "feat: add feature"' \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
# HIMMEL-1483 CR1: the revert exemption now requires the reverted hash to
# resolve to a real commit (git cat-file -e). Seed one and use its SHA for the
# positive case; a fabricated hash must fall through and be rejected in strict.
git -C "$R" commit -q --allow-empty -m "feat: add feature"
REVERTED_SHA=$(git -C "$R" rev-parse HEAD)
expect_rc "Git-generated revert of a real commit is exempt" 0 \
  "Revert \"feat: add feature\"

This reverts commit ${REVERTED_SHA}." \
  TICKET_ID_REQUIRED=1
expect_rc "fabricated-hash revert shape falls through and is rejected" 1 \
  $'Revert "feat: add feature"\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.' \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME

BASE_BRANCH=$(git -C "$R" symbolic-ref --short HEAD)
printf 'base\n' > "$R/file"
git -C "$R" add file
git -C "$R" commit -q -m base
git -C "$R" checkout -q -b side
printf 'side\n' > "$R/file"
git -C "$R" commit -q -am side
git -C "$R" checkout -q "$BASE_BRANCH"
printf 'main\n' > "$R/file"
git -C "$R" commit -q -am main
git -C "$R" merge side >/dev/null 2>&1 || true
expect_rc "real merge is exempt" 0 "Merge branch 'side'" TICKET_ID_REQUIRED=1
git -C "$R" merge --abort

expect_rc "dependabot author is exempt locally" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]'
expect_rc "trusted human blocks spoofed bot author" 1 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME 'TICKET_ID_AUTHOR=dependabot[bot]' TICKET_ID_TRUSTED_AUTHOR=human
expect_rc "trusted bot and bot author are exempt" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]' 'TICKET_ID_TRUSTED_AUTHOR=dependabot[bot]'
expect_rc "custom author exemption list is data-driven" 0 "chore: generated update" \
  TICKET_ID_REQUIRED=1 TICKET_ID_AUTHOR=release-bot TICKET_ID_EXEMPT_AUTHORS=release-bot
# HIMMEL-1483 CR2: `dependabot[bot]` is a GLOB — a matching file in the hook's
# cwd (e.g. `dependabotb`) used to pathname-expand the unquoted list expansion
# and silently break the exemption. Globbing is now off around the split.
touch "$R/dependabotb"
expect_rc "glob-matching file in cwd does not break the bot exemption" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]'
rm -f "$R/dependabotb"
expect_rc "fixup without ticket rejects in strict mode" 1 "fixup! feat: add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "fixup carrying ticket passes strict mode" 0 "fixup! feat: ACME-42 add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME

printf 'TICKET_ID_REQUIRED=1\nJIRA_PROJECT_KEY=ENVKEY\n' > "$R/.env"
expect_rc "primary .env supplies strict mode and Jira key" 0 "docs: ENVKEY-9 update docs"
expect_rc "live env overrides the primary .env" 0 "docs: no ticket needed" TICKET_ID_REQUIRED=0
rm -f "$R/.env"

# HIMMEL-2183: WARN-only negative-existence claim linter. Never blocks — rc
# must match what the case would get without the linter.
expect_warn() {
  local name="$1" want_rc="$2" want_warn="$3" message="$4"
  shift 4
  local out rc=0
  out=$(run_gate "$message" "$@" 2>&1) || rc=$?
  local has_warn=0
  local warn_hit
  warn_hit=$(printf '%s' "$out" | grep -o "WARN" 2>/dev/null)
  [ -n "$warn_hit" ] && has_warn=1
  if [ "$rc" -eq "$want_rc" ] && [ "$has_warn" -eq "$want_warn" ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (rc=%s want %s; warn=%s want %s)\n' "$name" "$rc" "$want_rc" "$has_warn" "$want_warn"
    failures=$((failures + 1))
  fi
}

# TICKET_ID_REQUIRED=0 keeps these focused on the linter: the ticket gate is ON
# by default (HIMMEL-2442) and would otherwise decide rc for these messages.
expect_warn "bare negative claim warns, rc unchanged" 0 1 \
  "feat: add feature

We don't have this handled yet." TICKET_ID_REQUIRED=0
expect_warn "claim with adjacent path evidence is silent" 0 0 \
  "feat: add feature

We don't have this handled yet.
See scripts/hooks/check-commit-msg.sh for details." TICKET_ID_REQUIRED=0
expect_warn "no claim is silent" 0 0 \
  "feat: add feature

Everything here works as expected." TICKET_ID_REQUIRED=0
# HIMMEL-2461: an unreadable message file used to be asserted as a SILENT
# rc=0 pass here — that fail-open assertion is exactly what let the vacuous
# gate (pass_filenames: false, empty $1) look tested for months. It must now
# fail CLOSED with a named rejection, while the HIMMEL-2183 linter above stays
# silent (no WARN) since it never got a message to scan.
MALFORMED_RC=0
MALFORMED_OUT=$( ( cd "$R" && env -u TICKET_ID_REQUIRED -u TICKET_ID_PATTERN \
    -u TICKET_ID_EXEMPT_AUTHORS -u TICKET_ID_AUTHOR -u TICKET_ID_TRUSTED_AUTHOR -u JIRA_PROJECT_KEY \
    bash "$SCRIPT" "$R/no-such-commit-msg-file" ) 2>&1 ) || MALFORMED_RC=$?
MALFORMED_WARN_HIT=$(printf '%s' "$MALFORMED_OUT" | grep -o "WARN" 2>/dev/null)
MALFORMED_REJECTED_HIT=$(printf '%s' "$MALFORMED_OUT" | grep -o "COMMIT REJECTED" 2>/dev/null)
if [ "$MALFORMED_RC" -ne 0 ] && [ -n "$MALFORMED_REJECTED_HIT" ] && [ -z "$MALFORMED_WARN_HIT" ]; then
  printf '  PASS  %s\n' "malformed input (missing commit-msg file) fails CLOSED"
else
  printf '  FAIL  %s (rc=%s, rejected-present=%s, warn-present=%s)\n' "malformed input (missing commit-msg file) fails CLOSED" \
    "$MALFORMED_RC" "$([ -n "$MALFORMED_REJECTED_HIT" ] && echo 1 || echo 0)" "$([ -n "$MALFORMED_WARN_HIT" ] && echo 1 || echo 0)"
  failures=$((failures + 1))
fi

# codex-1 (CR round 2, .ps1 twin parity): a $1 naming a DIRECTORY must also
# fail CLOSED. bash's `[ ! -f "$FILE" ]` guard is already false for a
# directory, so this checks the guard stays correct rather than fixing a bug
# — the .ps1 twin needed `-PathType Leaf` explicitly since its Test-Path
# returns true for directories. $R itself is a directory, so it doubles as
# the fixture here.
DIR_RC=0
DIR_OUT=$( ( cd "$R" && env -u TICKET_ID_REQUIRED -u TICKET_ID_PATTERN \
    -u TICKET_ID_EXEMPT_AUTHORS -u TICKET_ID_AUTHOR -u TICKET_ID_TRUSTED_AUTHOR -u JIRA_PROJECT_KEY \
    bash "$SCRIPT" "$R" ) 2>&1 ) || DIR_RC=$?
DIR_REJECTED_HIT=$(printf '%s' "$DIR_OUT" | grep -o "COMMIT REJECTED" 2>/dev/null)
if [ "$DIR_RC" -ne 0 ] && [ -n "$DIR_REJECTED_HIT" ]; then
  printf '  PASS  %s\n' "a \$1 naming a directory fails CLOSED"
else
  printf '  FAIL  %s (rc=%s, rejected-present=%s)\n' "a \$1 naming a directory fails CLOSED" \
    "$DIR_RC" "$([ -n "$DIR_REJECTED_HIT" ] && echo 1 || echo 0)"
  failures=$((failures + 1))
fi

# HIMMEL-2442: this checkout's OWN posture must be unchanged by the new default.
# Runs against the real primary .env (cwd inside the repo, no env stripping), so
# it proves the claim for this repo rather than a synthetic fixture. Skipped on a
# checkout whose primary .env carries no JIRA_PROJECT_KEY (an adopter clone),
# where the `#N` default legitimately applies instead.
# CR1: gating on JIRA_PROJECT_KEY ALONE was wrong — TICKET_ID_PATTERN outranks
# it and TICKET_ID_REQUIRED=0 disables the ticket half, so a checkout that sets
# either alongside the key is a SUPPORTED posture in which both assertions below
# are false. Read all three and run only when the key is genuinely the pattern
# in force; every other posture is covered by the fixture cases above.
# CR3: resolve from $HOOKS, not the process CWD. load_dotenv's root resolution
# runs `git rev-parse --git-common-dir` against the CWD, so running this suite
# from ANOTHER git repo read THAT repo's .env, found no key, and silently
# skipped the assertions below — a vacuous pass. `cd "$HOOKS"` fixes it without
# the `--root <repo-root>` the review suggested: --root BYPASSES the
# git-common-dir hop entirely, and the gitignored .env exists only in the
# PRIMARY checkout, so pinning --root to this worktree would find no .env and
# skip in exactly the setup every leg runs from.
PRIMARY_POSTURE=$(
  cd "$HOOKS" || exit 0
  # shellcheck disable=SC1091
  . "$HOOKS/../lib/load-dotenv.sh" 2>/dev/null &&
    load_dotenv JIRA_PROJECT_KEY TICKET_ID_PATTERN TICKET_ID_REQUIRED >/dev/null 2>&1
  printf '%s\t%s\t%s' "${JIRA_PROJECT_KEY:-}" "${TICKET_ID_PATTERN:-}" "${TICKET_ID_REQUIRED:-}"
)
PRIMARY_KEY=${PRIMARY_POSTURE%%	*}
PRIMARY_REST=${PRIMARY_POSTURE#*	}
PRIMARY_PATTERN=${PRIMARY_REST%%	*}
PRIMARY_REQUIRED=${PRIMARY_REST#*	}
# CR4: normalize here too. The hook now accepts EVERY mixed-case spelling, so a
# detector that only knew `false|FALSE` classified `TICKET_ID_REQUIRED=False` as
# Jira-driven and then asserted a rejection the hook correctly does not make —
# a supported posture failing the suite. The detector has to model the hook.
PRIMARY_REQUIRED_NORM=$(printf '%s' "$PRIMARY_REQUIRED" | tr '[:upper:]' '[:lower:]')
PRIMARY_JIRA_DRIVEN=0
case "$PRIMARY_REQUIRED_NORM" in
  0|false|off|no) ;;
  *) [ -n "$PRIMARY_KEY" ] && [ -z "$PRIMARY_PATTERN" ] && PRIMARY_JIRA_DRIVEN=1 ;;
esac
if [ "$PRIMARY_JIRA_DRIVEN" -eq 1 ]; then
  expect_repo_rc() {
    local name="$1" want="$2" rc=0
    printf '%s\n' "$3" > "$MSG"
    ( cd "$HOOKS" && bash "$SCRIPT" "$MSG" ) >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$want" ]; then
      printf '  PASS  %s\n' "$name"
    else
      printf '  FAIL  %s (rc=%s, want %s)\n' "$name" "$rc" "$want"
      failures=$((failures + 1))
    fi
  }
  expect_repo_rc "this repo's real .env posture still accepts ${PRIMARY_KEY}-N" 0 \
    "chore: ${PRIMARY_KEY}-2442 real posture"
  expect_repo_rc "this repo's real .env posture still rejects a ticketless message" 1 \
    "chore: no ticket id here"
else
  printf '  SKIP  primary .env is not JIRA_PROJECT_KEY-driven (no key, or TICKET_ID_PATTERN / TICKET_ID_REQUIRED=0 overrides it)\n'
fi

if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
fi
echo "FAIL: $failures case(s) failed"
exit 1
