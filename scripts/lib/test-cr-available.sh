#!/usr/bin/env bash
# Tests for scripts/lib/cr-available.sh (HIMMEL-1125).
#
# Hermetic: every case runs against a throwaway `git init` repo in a temp dir.
# Never talks to GitHub. Never reads the real checkout's git config.
#
# Cases:
#   1.  git config himmel.coderabbit=true        -> rc 0 (armed)
#   2.  no config at all                         -> rc 1 (no-op)  [THE adopter case]
#   3.  himmel.coderabbit=false                  -> rc 1
#   4.  truthy spellings (1 / yes / on)          -> rc 0 each
#   5.  a junk value is NOT truthy               -> rc 1 (default-disarmed)
#   6.  CR_PROFILE=none beats an armed repo      -> rc 1 (the established opt-out wins)
#   7.  CR_APP=1 beats an unarmed repo           -> rc 0
#   8.  CR_APP=0 beats an armed repo             -> rc 1
#   9.  CR_PROFILE=none beats CR_APP=1           -> rc 1 (documented precedence)
#   10. CR_PROFILE=free,paid is NOT availability -> rc 1 (it is a critic-TIER filter)
#   11. probe from a SUBDIR of the repo          -> rc 0 (resolves the repo)
#   12. not a git repo at all                    -> rc 1, no crash
#   13. a committed .coderabbit.yaml does NOT arm-> rc 1  [codex-adv-1: the whole
#       point of the marker design — a fork inherits the file, not the App]
#   14. a GLOBAL himmel.coderabbit does not arm  -> rc 1 (availability is per-repo)
#   15. the probe is SILENT on both verdicts     -> no stdout/stderr either way
#
# NOTE on structure: only the PROBE runs in a subshell (to scope the env
# overrides); the pass/fail counters are incremented in the PARENT. Counting
# inside the subshell would discard every increment and the suite would report
# "0 failed" unconditionally.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-available.sh"

PASS=0; FAIL=0; TMPROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ]; then rm -rf "$TMPROOT" 2>/dev/null || true; fi; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/cr-available-test.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$TMPROOT" ] || [ ! -d "$TMPROOT" ]; then echo "FATAL: no temp dir"; exit 1; fi

# HOME is redirected for the WHOLE suite, before any git runs — not inside the
# probe subshell. Case 14 writes a --global config, and `--global` means "in
# $HOME/.gitconfig": with HOME exported only inside probe_rc, that write landed
# in the developer's REAL ~/.gitconfig and persisted after the run (a hermetic
# suite must leave no machine state behind). Redirecting HOME up here makes
# --global mean the throwaway dir, which is the only thing that makes case 14
# safe to run at all.
# GIT_CONFIG_GLOBAL is the AUTHORITATIVE redirect for `git config --global`
# (coderabbit-12): it pins the global file directly, ahead of the HOME ->
# XDG -> ~/.gitconfig resolution chain that case 14's --global write would
# otherwise follow into the developer's REAL config. HOME + XDG are set too, as
# defence in depth and because other git operations read HOME. This suite
# already wrote himmel.coderabbit=true into a real ~/.gitconfig once; belt AND
# braces is the correct amount of paranoia here.
export HOME="$TMPROOT/fakehome"
export XDG_CONFIG_HOME="$TMPROOT/fake-xdg"
export GIT_CONFIG_GLOBAL="$TMPROOT/fake-global-gitconfig"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" || { echo "FATAL: could not create fake HOME/XDG"; exit 1; }
: > "$GIT_CONFIG_GLOBAL" || { echo "FATAL: could not create the temp global git config"; exit 1; }
# Fail closed: if the redirect did not take, case 14's --global write would hit a
# real config. Abort rather than pollute a developer's machine.
probe_home=$(git config --global --list --show-origin 2>/dev/null | head -1)
case "$probe_home" in
    *"$TMPROOT"*|'') ;;
    *) echo "FATAL: global-config redirect did not take (resolves to $probe_home) — refusing to run, case 14 would write to a real gitconfig"; exit 1 ;;
esac

# mk_repo <name> [<himmel.coderabbit value>] -> echoes the repo path
mk_repo() {
    local val="${2:-}" d="$TMPROOT/$1"
    mkdir -p "$d" || return 1
    git -C "$d" init --quiet >/dev/null 2>&1 || return 1
    if [ -n "$val" ]; then git -C "$d" config --local himmel.coderabbit "$val" || return 1; fi
    printf '%s\n' "$d"
}

# probe_rc <dir> <CR_PROFILE|-> <CR_APP|->  ("-" = unset)
# The subshell scopes the env; the rc is all that crosses back out.
# (HOME is redirected suite-wide above, not here — see the note there.)
probe_rc() {
    (
        if [ "$2" = "-" ]; then unset CR_PROFILE; else export CR_PROFILE="$2"; fi
        if [ "$3" = "-" ]; then unset CR_APP; else export CR_APP="$3"; fi
        cr_app_configured "$1"
    )
}

# expect <want-rc> <label> <dir> <CR_PROFILE|-> <CR_APP|->
expect() {
    local want="$1" label="$2" got=0
    # Preserve the ACTUAL rc rather than collapsing every failure to 1
    # (coderabbit-5): the contract is "0 or 1", so a future rc 2 is a real
    # defect the disarmed-case assertions must be able to see, not silently
    # read as the expected 1.
    if probe_rc "$3" "$4" "$5"; then got=0; else got=$?; fi
    if [ "$got" -eq "$want" ]; then pass "$label"; else fail "$label" "wanted rc $want, got rc $got"; fi
}



echo "test-cr-available.sh"

# 1. the marker, set -> armed
r=$(mk_repo armed true)
expect 0 "1. himmel.coderabbit=true -> armed (rc 0)" "$r" - -

# 2. THE adopter case: a repo that has done nothing. This is the acceptance
#    criterion "adopter WITHOUT CodeRabbit: no new blocks" at its root, and it is
#    now the DEFAULT — the adopter takes no action and is never blocked.
r=$(mk_repo bare)
expect 1 "2. no marker -> no-op (rc 1) [adopter case, the default]" "$r" - -

# 3. explicit false
r=$(mk_repo disarmed false)
expect 1 "3. himmel.coderabbit=false -> rc 1" "$r" - -

# 4. the truthy spellings a human might reasonably type
for v in 1 yes on; do
    r=$(mk_repo "truthy_$v" "$v")
    expect 0 "4. himmel.coderabbit=$v -> armed (rc 0)" "$r" - -
done

# 5. junk is not truthy — default-disarmed means anything unrecognised disarms
r=$(mk_repo junk banana)
expect 1 "5. a junk marker value does not arm (rc 1)" "$r" - -

# 6. the established opt-out still wins over an armed repo
r=$(mk_repo optout true)
expect 1 "6. CR_PROFILE=none beats an armed repo (rc 1)" "$r" none -

# 7. env override arms an unmarked repo (shallow CI, or an App on defaults)
r=$(mk_repo forcearm)
expect 0 "7. CR_APP=1 beats an unarmed repo (rc 0)" "$r" - 1

# 8. env override disarms a marked repo
r=$(mk_repo forcedisarm true)
expect 1 "8. CR_APP=0 beats an armed repo (rc 1)" "$r" - 0

# 9. documented precedence: CR_PROFILE=none is the strongest signal
r=$(mk_repo precedence true)
expect 1 "9. CR_PROFILE=none beats CR_APP=1 (rc 1)" "$r" none 1

# 10. CR_PROFILE is a critic-TIER filter — a non-`none` value must not be read as
#     "CodeRabbit is available" (that would re-arm the gate on every adopter who
#     tunes their critic tiers).
r=$(mk_repo tierfilter)
expect 1 "10. CR_PROFILE=free,paid is not an availability signal (rc 1)" "$r" free,paid -

# 11. callers run from worktree subdirs — the probe must resolve the repo
r=$(mk_repo subdir true)
mkdir -p "$r/scripts/deep"
expect 0 "11. probe from a subdir resolves the repo (rc 0)" "$r/scripts/deep" - -

# 12. not a repo at all -> rc 1, no crash
d="$TMPROOT/notarepo"; mkdir -p "$d"
expect 1 "12. not a git repo -> rc 1, no crash" "$d" - -

# 13. codex-adv-1 — THE reason this design exists. A committed .coderabbit.yaml
#     must NOT arm the gate: it is tracked, so every clone/fork inherits it
#     WITHOUT inheriting the App installation. This harness ships by being
#     cloned, so arming on the file would block every adopter's merges forever —
#     the exact bug HIMMEL-1125 removes. The file is evidence of a config, never
#     of an installation.
r=$(mk_repo forked)
printf 'reviews:\n  profile: chill\n' > "$r/.coderabbit.yaml"
git -C "$r" add -A >/dev/null 2>&1
git -C "$r" -c user.email=t@t -c user.name=t commit -qm "inherited from upstream" >/dev/null 2>&1
expect 1 "13. an inherited .coderabbit.yaml does NOT arm (rc 1) [codex-adv-1]" "$r" - -

# 14. availability is PER-REPO: a value in ~/.gitconfig must not arm every repo
#     on the machine (the same over-reach as the inherited file, one level up).
r=$(mk_repo globalonly)
# No `|| true` (coderabbit-8): if this setup write fails, the case would "pass"
# for the wrong reason — there would be no global config to ignore. Surface it.
if ! git -C "$r" config --global himmel.coderabbit true >/dev/null 2>&1; then
    fail "14. setup: could not write the (redirected) global config"
else
    expect 1 "14. a GLOBAL himmel.coderabbit does not arm a repo (rc 1)" "$r" - -
fi

# 15. SILENCE. "An adopter must not notice it exists" is a testable claim: the
#     probe must emit nothing on stdout OR stderr, on either verdict.
r_on=$(mk_repo silent_on true)
r_off=$(mk_repo silent_off)
noise=$( { probe_rc "$r_on" - -; probe_rc "$r_off" - -; } 2>&1 )
if [ -z "$noise" ]; then
    pass "15. probe is silent on both verdicts"
else
    fail "15. probe is silent on both verdicts" "emitted: $noise"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
