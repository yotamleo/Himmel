#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-choose-mode.sh -- hermetic tests for choose-mode.sh (HIMMEL-4767,
# HIMMEL-4748 WP8): setup asks for tracker and forge and writes git config.
# Every case runs in a temp repo; answers arrive on stdin.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$here/choose-mode.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
unset TRACKER FORGE JIRA_PROJECT_KEY TICKET_ID_REQUIRED TICKET_ID_PATTERN

td="$(mktemp -d "${TMPDIR:-/tmp}/choose-mode.XXXXXX")" || exit 1
trap 'rm -rf "$td"' EXIT
export GIT_CONFIG_GLOBAL="$td/gitconfig" GIT_CONFIG_NOSYSTEM=1
newrepo() { rm -rf "$td/r"; mkdir -p "$td/r"; git -C "$td/r" init -q; }
cfg() { git -C "$td/r" config --get "himmel.$1"; }

# Fresh repo: answers are written to git config.
newrepo
out=$(printf 'local\nlocal-git\n' | choose_mode "$td/r" 2>&1)
check "fresh: tracker written" "$(cfg tracker)" "local"
check "fresh: forge written" "$(cfg forge)" "local-git"
case "$out" in *"tracker=local forge=local-git"*) check "fresh: prints the resolved mode" ok ok ;; *) check "fresh: prints the resolved mode" "$out" "tracker=local forge=local-git" ;; esac

# Re-run: an existing value is the default; Enter keeps it (non-destructive).
out=$(printf '\n\n' | choose_mode "$td/r" 2>&1)
check "re-run Enter: tracker kept" "$(cfg tracker)" "local"
check "re-run Enter: forge kept" "$(cfg forge)" "local-git"
case "$out" in *"[local]"*"[local-git]"*) check "re-run: existing values offered as defaults" ok ok ;; *) check "re-run: existing values offered as defaults" "$out" "[local] ... [local-git]" ;; esac

# Re-run with no stdin at all (EOF): nothing changes.
choose_mode "$td/r" < /dev/null > /dev/null 2>&1
check "EOF: tracker kept" "$(cfg tracker)" "local"
check "EOF: forge kept" "$(cfg forge)" "local-git"

# An invalid answer is refused and the existing value kept.
out=$(printf 'bogus\ngitlab\n' | choose_mode "$td/r" 2>&1)
check "invalid: tracker kept" "$(cfg tracker)" "local"
check "invalid: forge kept" "$(cfg forge)" "local-git"
case "$out" in *"invalid"*) check "invalid: refusal shown" ok ok ;; *) check "invalid: refusal shown" "$out" "invalid" ;; esac

# The resolver's refusal is honoured: jira without JIRA_PROJECT_KEY is not written.
out=$(printf 'jira\n\n' | choose_mode "$td/r" 2>&1)
check "jira without key: tracker kept" "$(cfg tracker)" "local"
case "$out" in *"JIRA_PROJECT_KEY is not set"*) check "jira without key: resolver message shown" ok ok ;; *) check "jira without key: resolver message shown" "$out" "JIRA_PROJECT_KEY is not set" ;; esac

# I8: local-git on a github.com origin is refused, never written.
newrepo
git -C "$td/r" remote add origin https://github.com/o/r
printf '\nlocal-git\n' | choose_mode "$td/r" > /dev/null 2>&1
check "I8: local-git on github origin not written" "$(cfg forge)" ""
check "fresh Enter: tracker left to detection" "$(cfg tracker)" ""

# tracker=none points at the TICKET_ID_REQUIRED workflow note.
out=$(printf 'none\n\n' | choose_mode "$td/r" 2>&1)
check "none: tracker written" "$(cfg tracker)" "none"
case "$out" in *"TICKET_ID_REQUIRED"*) check "none: workflow-edit note shown" ok ok ;; *) check "none: workflow-edit note shown" "$out" "TICKET_ID_REQUIRED" ;; esac

# An explicit TICKET_ID_REQUIRED=1 still requires an ID: no "need no ticket ID" note.
out=$(printf '\n\n' | TICKET_ID_REQUIRED=1 choose_mode "$td/r" 2>&1)
case "$out" in *"need no ticket ID"*) check "none + TICKET_ID_REQUIRED=1: no note" "$out" "no note" ;; *) check "none + TICKET_ID_REQUIRED=1: no note" ok ok ;; esac

# A git config write that fails makes choose_mode fail, so setup.sh warns.
newrepo
chmod a-w "$td/r/.git"
rc=0; printf 'local\n\n' | choose_mode "$td/r" > /dev/null 2>&1 || rc=$?
chmod u+w "$td/r/.git"
check "write failure: choose_mode returns non-zero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
