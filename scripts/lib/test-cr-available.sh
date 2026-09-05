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
# HIMMEL-2380 — cr_app_state, the WHY behind the yes/no:
#   16-17. armed / not-configured                -> the two ordinary states
#   18. an unparseable marker                    -> `broken`, NOT `not-configured`
#       [the only state where today's rc 1 hides a real defect]
#   19-21. CR_PROFILE=none / CR_APP=0 / false    -> `disabled` (a deliberate act)
#   22-23. precedence + CR_APP=1                 -> the order cr_app_configured uses
#   24. a GLOBAL broken marker                   -> not-configured (per-repo, still)
#   25. not a git repo                           -> not-configured, no crash
#   26. NEGATIVE CONTROL: every cr_app_configured rc unchanged by the new state
#   27. cr_app_state writes nothing to stderr, even on the broken marker
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

# _scoped_env <CR_PROFILE|-> <CR_APP|-> <command...>  ("-" = unset)
# ONE place the two env overrides are applied, for both predicates below. The
# subshell IS the mechanism: it scopes the overrides to a single probe, and
# nothing but the rc or stdout crosses back out — which is exactly the shape
# SC2030/SC2031 warn about, so the disable below states the intent rather than
# silencing a real risk. (HOME is redirected suite-wide above, not here — see the note
# there.) Written once rather than twice: a second textually identical
# subshell is what made shellcheck flag the first one at all.
# shellcheck disable=SC2030,SC2031
_scoped_env() {
    local prof="$1" app="$2"; shift 2
    (
        if [ "$prof" = "-" ]; then unset CR_PROFILE; else export CR_PROFILE="$prof"; fi
        if [ "$app" = "-" ]; then unset CR_APP; else export CR_APP="$app"; fi
        "$@"
    )
}

# probe_rc <dir> <CR_PROFILE|-> <CR_APP|->  -> the rc of cr_app_configured
probe_rc() { _scoped_env "$2" "$3" cr_app_configured "$1"; }

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


# ── HIMMEL-2380: cr_app_state — WHY the gate is disarmed ──────────────────────
# cr_app_configured answers a yes/no and is deliberately SILENT, because "an
# adopter must not notice it exists" (case 15, and test-check-ci.sh case 57).
# That silence is right for the adopter and WRONG for one caller: a repo whose
# marker is set to a value git cannot parse reads as "not armed" and every
# subsequent green certifies a review that never ran. Case 5 above pins that
# rc 1 — correct, and indistinguishable from the adopter's rc 1 to anyone who
# can only see the rc.
#
# cr_app_state names the reason so a caller can tell those apart. It does NOT
# change cr_app_configured's contract: case 24 below is the negative control
# that pins every rc unchanged.

# state_of <dir> <CR_PROFILE|-> <CR_APP|->  -> echoes the state
state_of() { _scoped_env "$2" "$3" cr_app_state "$1"; }

# expect_state <want> <label> <dir> <CR_PROFILE|-> <CR_APP|->
expect_state() {
    local want="$1" label="$2" got
    got=$(state_of "$3" "$4" "$5" 2>/dev/null)
    if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "wanted '$want', got '$got'"; fi
}

# 16. the armed repo names itself
r=$(mk_repo state_armed true)
expect_state armed "16. himmel.coderabbit=true -> armed" "$r" - -

# 17. THE adopter. Nothing was configured, so nothing is missing — and the
#     caller must stay SILENT on this state (nothing to report is not a defect).
r=$(mk_repo state_bare)
expect_state not-configured "17. no marker -> not-configured [adopter]" "$r" - -

# 18. THE case this predicate exists for. `git config --bool` FAILS on a
#     non-boolean (measured: rc 128, stderr "bad boolean config value"), the
#     failure is swallowed, and the repo silently loses its CodeRabbit gate
#     while genuinely having CodeRabbit. Distinguished from case 17 by the
#     plain --local --get succeeding on the same key.
r=$(mk_repo state_broken ture)
expect_state broken "18. an unparseable marker -> broken (not 'not-configured')" "$r" - -

# 19/20/21. deliberate disables, all three spellings.
r=$(mk_repo state_optout true)
expect_state disabled "19. CR_PROFILE=none -> disabled" "$r" none -
r=$(mk_repo state_crapp0 true)
expect_state disabled "20. CR_APP=0 -> disabled" "$r" - 0
r=$(mk_repo state_false false)
expect_state disabled "21. himmel.coderabbit=false -> disabled" "$r" - -

# 22. precedence is cr_app_configured's, unchanged: the explicit opt-out is
#     read BEFORE the marker, so it names the state even over a broken marker.
#     (An operator who set CR_PROFILE=none is not waiting to hear about a typo
#     in a marker their own setting already overrides.)
r=$(mk_repo state_optout_broken ture)
expect_state disabled "22. CR_PROFILE=none beats a broken marker" "$r" none -

# 23. CR_APP=1 arms an unmarked repo, same as the rc contract.
r=$(mk_repo state_forcearm)
expect_state armed "23. CR_APP=1 -> armed" "$r" - 1

# 24. per-repo, still: a GLOBAL marker — broken or not — is not THIS repo's
#     state (case 14's rule, one level down). Both reads are --local.
r=$(mk_repo state_globalbroken)
if ! git -C "$r" config --global himmel.coderabbit ture >/dev/null 2>&1; then
    fail "24. setup: could not write the (redirected) global config"
else
    expect_state not-configured "24. a GLOBAL broken marker is not this repo's state" "$r" - -
fi

# 25. not a git repo -> not-configured, no crash
d="$TMPROOT/state_notarepo"; mkdir -p "$d"
expect_state not-configured "25. not a git repo -> not-configured, no crash" "$d" - -

# 26. NEGATIVE CONTROL — the whole point. cr_app_state must not move
#     cr_app_configured's rc for ANY of the states above. If adding the
#     predicate changed one verdict, HIMMEL-1125's gate moved and this case
#     goes red before any caller notices.
expect 0 "26a. armed still rc 0" "$(mk_repo nc_armed true)" - -
expect 1 "26b. not-configured still rc 1" "$(mk_repo nc_bare)" - -
expect 1 "26c. broken still rc 1 (unchanged, still default-disarmed)" "$(mk_repo nc_broken ture)" - -
expect 1 "26d. disabled still rc 1" "$(mk_repo nc_optout true)" none -

# 27. cr_app_state writes the state to STDOUT and nothing to stderr — a caller
#     capturing it must not also capture git's "bad boolean" complaint (case 18
#     provokes exactly that on the real git binary).
r=$(mk_repo state_quiet ture)
noise=$(state_of "$r" - - 2>&1 >/dev/null)
if [ -z "$noise" ]; then
    pass "27. cr_app_state emits nothing on stderr (even on the broken marker)"
else
    fail "27. cr_app_state emits nothing on stderr (even on the broken marker)" "emitted: $noise"
fi
echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
