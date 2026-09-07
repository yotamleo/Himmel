#!/usr/bin/env bash
# Smoke test suite for scripts/hooks/check-main-ref-transaction.sh and
# scripts/hooks/install-main-ref-transaction.sh (HIMMEL-2095).
#
# Every case runs against a THROWAWAY sandbox repo this suite creates itself
# (a local `git init --bare` "origin" + a clone) -- never the real himmel
# repo, never a network remote. Assertions are on OBSERVABLE artifacts: the
# actual `git commit`/`git merge`/etc. exit code, `git rev-parse HEAD`, and
# (for the escape hatch) the literal contents of the override log -- never
# merely that some internal function returned 0.
#
# PLATFORM GUARD (no .ps1 twin -- this note is that decision, not a
# placeholder for one): this suite is plain POSIX shell exercising two
# scripts that are themselves plain POSIX shell (see their own headers),
# so it runs under Git Bash on Windows the same way it runs on Linux/macOS
# -- there is no PowerShell-specific behaviour here to give a `.ps1` twin
# anything different to assert. What this suite does NOT prove on Windows:
# it has never actually been RUN there (this session has no Windows
# station to run it on), so any Git-Bash-specific process behaviour --
# most concretely, whether `reference-transaction` delivers its full
# stdin ref-line stream identically under Git Bash's process model, the
# open question tracked as HIMMEL-2643 -- is unverified by this suite
# today, not merely untested by it. A future Windows run (or `.ps1` twin)
# is what closes that gap; until then, a green run of this suite is
# evidence for Linux/macOS only.
set -uo pipefail

# HERMETICITY (panel rounds 3, 5, 6, and the panel's own round-6 follow-up):
# three blacklist patches landed in a row, each closing exactly ONE
# config-ingress vector and leaving the next one open -- GIT_CONFIG_GLOBAL/
# GIT_CONFIG_SYSTEM (config FILES) in round 3, GIT_CONFIG_COUNT/KEY_n/
# VALUE_n (command-scope config) in round 5, GIT_CONFIG_PARAMETERS (git's
# own -c-propagation channel) named in round 6. A first draft of THIS fix
# tried to end the pattern by unsetting every GIT_* variable except a short
# allowed list -- but that would have been a FOURTH blacklist wearing an
# allowlist's clothes: HOME and XDG_CONFIG_HOME are not GIT_*-prefixed, yet
# they route ~/.gitconfig and ~/.config/git/config into git by exactly the
# same mechanism, so an ambient core.hooksPath in a developer's own
# ~/.gitconfig would have walked straight through it untouched.
#
# The fix that actually ends the pattern: stop enumerating what to remove.
# Re-exec this ENTIRE suite, once, under `env -i` with an explicit, minimal
# environment built from NOTHING -- every name passed through below is
# something this suite is known to need, with a reason on its own line;
# anything not named here simply does not exist for the rest of this
# process or anything it spawns (install-main-ref-transaction.sh, every
# git invocation in every sandbox, all of it) -- instead of this file
# trying to keep pace with every ingress vector git has ever grown or will
# grow. Do NOT "simplify" this back to a GIT_*-only unset loop -- that is
# the mistake this comment exists to prevent; see the ALLOWLIST MECHANISM
# PROOF case further down, which sets a hostile GIT_* variable AND a
# hostile HOME/XDG_CONFIG_HOME simultaneously in the ambient environment of
# the run and shows neither reaches git.
if [ "${HIMMEL_TEST_HERMETIC_REEXEC:-}" != "1" ]; then
    self_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    sandbox_home="$(mktemp -d "${TMPDIR:-/tmp}/himmel-mainref-hermetic-home.XXXXXX")" || {
        echo "FAIL - mktemp -d sandbox_home" >&2
        exit 1
    }
    mkdir -p "$sandbox_home/.config"
    exec env -i \
        HIMMEL_TEST_HERMETIC_REEXEC=1 \
        HIMMEL_TEST_SANDBOX_HOME="$sandbox_home" \
        PATH="$PATH" \
        HOME="$sandbox_home" \
        XDG_CONFIG_HOME="$sandbox_home/.config" \
        TMPDIR="${TMPDIR:-/tmp}" \
        LANG=C \
        LC_ALL=C \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_SYSTEM=/dev/null \
        bash "$self_abs" "$@"
    echo "FAIL - exec env -i re-exec did not replace this process" >&2
    exit 1
fi
# From here on, this process's ENTIRE environment is the minimal set built
# above:
#   PATH               -- need git/bash/coreutils to run at all
#   HOME               -- pointed at an empty, throwaway sandbox this run
#                          created for itself, so ~/.gitconfig resolves to
#                          a file that does not exist (git treats a
#                          missing config file as empty, not an error)
#   XDG_CONFIG_HOME     -- same reasoning, for ~/.config/git/config
#   TMPDIR             -- mktemp and this suite's own $BASE sandboxes need
#                          somewhere writable
#   LANG, LC_ALL        -- deterministic sort/grep/message text across runs
#   GIT_CONFIG_GLOBAL,
#   GIT_CONFIG_SYSTEM   -- redundant with the HOME/XDG_CONFIG_HOME
#                          redirection above, kept as a second, independent
#                          guard on the same two config tiers (belt and
#                          suspenders costs nothing here)
# Every other GIT_* variable this suite has been bitten by (COUNT, KEY_n/
# VALUE_n, PARAMETERS) -- and anything not yet named -- is simply absent,
# because env -i started this process from nothing.
#
# Cleanup: HIMMEL_TEST_SANDBOX_HOME is trusted for `rm -rf` ONLY because we
# just created it ourselves via mktemp with a distinctive name pattern --
# the case guard below refuses to remove anything that does not match that
# pattern, so a hostile/malformed re-invocation that pre-sets
# HIMMEL_TEST_HERMETIC_REEXEC=1 to skip the block above can never turn this
# trap into an arbitrary-directory delete.
cleanup_hermetic_home() {
    case "$(basename "${HIMMEL_TEST_SANDBOX_HOME:-}")" in
        himmel-mainref-hermetic-home.*) rm -rf "$HIMMEL_TEST_SANDBOX_HOME" ;;
        *) : ;;
    esac
}
trap cleanup_hermetic_home EXIT

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/hooks/check-main-ref-transaction.sh"
INSTALL="$ROOT/scripts/hooks/install-main-ref-transaction.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if bash -n "$CHECK"; then ok "check script syntax (bash -n)"; else bad "check script syntax"; fi
if bash -n "$INSTALL"; then ok "install script syntax (bash -n)"; else bad "install script syntax"; fi

BASE="$(mktemp -d "${TMPDIR:-/tmp}/himmel-mainref-test.XXXXXX")" || { echo "FAIL - mktemp -d base"; exit 1; }
trap 'rm -rf "$BASE"; cleanup_hermetic_home' EXIT

# mk_sandbox NAME -- creates $BASE/NAME-origin.git (bare) + $BASE/NAME-work
# (a clone, on main, one seed commit already pushed and fetched). Echoes the
# work dir's path.
mk_sandbox() {
    local n="$1" origin work
    origin="$BASE/$n-origin.git"
    work="$BASE/$n-work"
    git init -q --bare "$origin"
    git -c init.defaultBranch=main clone -q "$origin" "$work" 2>/dev/null
    git -C "$work" config user.name t
    git -C "$work" config user.email t@t
    git -C "$work" checkout -q -b main 2>/dev/null || git -C "$work" checkout -q main
    echo seed > "$work/note.txt"
    git -C "$work" add -A
    git -C "$work" commit -q -m "chore: seed" --no-verify
    git -C "$work" push -q -u origin main
    # A fresh bare repo's HEAD symref defaults to whatever this git build's
    # global default branch is (often "master") regardless of the clone's
    # own init.defaultBranch override, and pushing to it does NOT retarget
    # that symref on its own -- fix it explicitly so a SECOND clone of this
    # origin (the fast-forward/pull cases below) tracks main correctly
    # instead of failing with "warning: remote HEAD refers to nonexistent ref".
    git -C "$origin" symbolic-ref HEAD refs/heads/main
    git -C "$work" fetch -q origin
    printf '%s\n' "$work"
}

# install_hook WORK_DIR -- runs the REAL installer with cwd=WORK_DIR, so it
# exercises the full installer -> shim -> tracked-check-script pipeline
# exactly as production does (the shim always execs THIS suite's own
# checked-out $CHECK, absolute path, regardless of the sandbox).
install_hook() {
    ( cd "$1" && bash "$INSTALL" >/dev/null 2>&1 )
}

# ---------------------------------------------------------------------------
# HERMETICITY PROOF (panel round 3, codex-2; retained as regression
# evidence for this specific vector after the round-6 env -i redesign --
# see the ALLOWLIST MECHANISM PROOF further down for the general case).
# The GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM=/dev/null isolation this file
# carries is not "safety" until shown working against a genuinely hostile
# ambient config, not merely written down. RED: a subshell that explicitly
# UNDOES the isolation (as if this suite never had it), with a fake HOME
# whose ~/.gitconfig sets an ABSOLUTE core.hooksPath at a canary directory
# -- installing there for real proves the exposure the panel described is
# real, not theoretical. GREEN: the SAME hostile fake HOME, but relying
# ONLY on this file's own ambient isolation (nothing re-declared inside
# the subshell) -- the canary must stay untouched.
# ---------------------------------------------------------------------------
canary_dir="$BASE/GLOBAL-HOOKSPATH-CANARY"
mkdir -p "$canary_dir"
fake_home="$BASE/fake-home-hostile-gitconfig"
mkdir -p "$fake_home"
cat > "$fake_home/.gitconfig" <<CFG
[core]
	hooksPath = $canary_dir
CFG

red_repo="$BASE/hermeticity-red-repo"
git init -q "$red_repo"
(
    unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
    cd "$red_repo" && HOME="$fake_home" bash "$INSTALL"
) >/dev/null 2>&1
if [ -f "$canary_dir/reference-transaction" ]; then
    ok "HERMETICITY RED control: WITHOUT isolation, a hostile GLOBAL core.hooksPath genuinely gets installed into (the exposure is real, not theoretical)"
else
    bad "HERMETICITY RED control did not reproduce the exposure -- something else is suppressing it (investigate before trusting the GREEN case below)"
fi
rm -f "$canary_dir/reference-transaction"

green_repo="$BASE/hermeticity-green-repo"
git init -q "$green_repo"
( cd "$green_repo" && HOME="$fake_home" bash "$INSTALL" ) >/dev/null 2>&1
if [ ! -f "$canary_dir/reference-transaction" ]; then
    ok "HERMETICITY GREEN: WITH this suite's isolation (inherited, not re-declared), the SAME hostile global core.hooksPath is never consulted -- canary untouched"
else
    bad "HERMETICITY GREEN FAILED: the canary directory was written to despite this suite's isolation -- sandboxes in this suite are NOT hermetic"
fi

# ---------------------------------------------------------------------------
# HERMETICITY PROOF, extended (panel round 5, codex-1; retained as
# regression evidence for this specific vector after the round-6 env -i
# redesign -- see the ALLOWLIST MECHANISM PROOF further down for the
# general case). GIT_CONFIG_GLOBAL/SYSTEM=/dev/null suppress the config
# FILES, but git ALSO reads COMMAND-SCOPE config from GIT_CONFIG_COUNT/
# GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n in the process environment, and that
# block TAKES PRECEDENCE over the (nulled) file tiers. The file-based
# RED/GREEN pair above does not exercise this path at all, so it would
# pass even with this hole open -- which is exactly what happened: the
# panel found it, that control did not. RED: a subshell with an ambient
# GIT_CONFIG_COUNT/KEY_0/VALUE_0 pointing core.hooksPath at a SECOND
# canary, with none of this suite's clearing applied (simulating the hole
# as it existed before this fix) -- installing there for real proves the
# exposure. GREEN: the SAME ambient block, but with the equivalent
# clearing logic applied first -- proving the MECHANISM for this vector,
# not merely that this one subshell happened not to set it -- the canary
# must stay untouched.
# ---------------------------------------------------------------------------
canary_dir2="$BASE/COMMAND-SCOPE-HOOKSPATH-CANARY"
mkdir -p "$canary_dir2"

red2_repo="$BASE/hermeticity-red2-repo"
git init -q "$red2_repo"
# shellcheck disable=SC2030,SC2031 # deliberately subshell-local -- these must NOT leak into the rest of this suite
(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$canary_dir2"
    cd "$red2_repo" && bash "$INSTALL"
) >/dev/null 2>&1
if [ -f "$canary_dir2/reference-transaction" ]; then
    ok "HERMETICITY RED control (command-scope): WITHOUT clearing GIT_CONFIG_COUNT/KEY_n/VALUE_n, an ambient core.hooksPath delivered that way genuinely gets installed into"
else
    bad "HERMETICITY RED control (command-scope) did not reproduce the exposure -- something else is suppressing it (investigate before trusting the GREEN case below)"
fi
rm -f "$canary_dir2/reference-transaction"

green2_repo="$BASE/hermeticity-green2-repo"
git init -q "$green2_repo"
# shellcheck disable=SC2030,SC2031 # deliberately subshell-local -- these must NOT leak into the rest of this suite
(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$canary_dir2"
    unset GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    unset GIT_CONFIG_COUNT
    cd "$green2_repo" && bash "$INSTALL"
) >/dev/null 2>&1
if [ ! -f "$canary_dir2/reference-transaction" ]; then
    ok "HERMETICITY GREEN (command-scope): clearing GIT_CONFIG_COUNT/KEY_n/VALUE_n neutralizes the SAME ambient core.hooksPath -- canary untouched"
else
    bad "HERMETICITY GREEN (command-scope) FAILED: the canary directory was written to despite clearing GIT_CONFIG_COUNT -- command-scope isolation does not work"
fi

# ---------------------------------------------------------------------------
# ALLOWLIST MECHANISM PROOF (panel round 6 follow-up): the two pairs above
# each prove ONE specific vector stays closed -- but naming vectors is
# exactly the game this suite kept losing (three rounds, three different
# vectors). This case proves the GENERAL mechanism instead: with a hostile
# GIT_* variable (GIT_CONFIG_PARAMETERS -- git's own -c-propagation
# channel, the vector round 6 named, deliberately NOT one of the two
# vectors already covered above) AND a hostile HOME/XDG_CONFIG_HOME BOTH
# set in the ambient environment of the run, does `git config --show-origin
# --list` inside the sandbox show any origin outside the sandbox?
# --show-origin answers the question this suite actually cares about --
# WHERE did each value come from -- rather than a checklist of variable
# names someone remembered to test. RED: the two hostile vectors applied
# with NONE of this suite's isolation (GIT_CONFIG_GLOBAL/SYSTEM explicitly
# undone, exactly like the round-3 RED control above) -- both markers must
# show up in --show-origin, proving the exposure is real. GREEN: the SAME
# two hostile vectors exported into the ambient environment, but the
# actual git invocation goes through a FRESH env -i wrap naming only the
# small allowed set (mirroring exactly what this file's own top-of-file
# re-exec does) -- env -i does not inherit anything not explicitly passed,
# so neither hostile vector is even visible to the wrapped process,
# regardless of what surrounds it. Neither marker may appear anywhere in
# --show-origin's output.
# ---------------------------------------------------------------------------
mech_hostile_home="$BASE/MECH-HOSTILE-HOME"
mkdir -p "$mech_hostile_home/.config/git"
cat > "$mech_hostile_home/.gitconfig" <<CFG
[user]
	name = hostile-ambient-home-$mech_hostile_home
CFG
cat > "$mech_hostile_home/.config/git/config" <<CFG
[user]
	email = hostile-ambient-xdg-$mech_hostile_home@example.invalid
CFG
# git's own on-disk encoding for GIT_CONFIG_PARAMETERS (see git-config(1)
# ENVIRONMENT): a space-separated list of shell-quoted 'key=value' tokens --
# this is what `git -c key=value` sets for child processes to inherit, not
# something this suite invented.
mech_hostile_gcp="'user.name=hostile-via-GIT_CONFIG_PARAMETERS'"

mech_red_repo="$BASE/mech-red-repo"
git init -q "$mech_red_repo"
# shellcheck disable=SC2030,SC2031 # deliberately subshell-local -- these must NOT leak into the rest of this suite
mech_red_out=$(
    unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
    HOME="$mech_hostile_home" XDG_CONFIG_HOME="$mech_hostile_home/.config" \
        GIT_CONFIG_PARAMETERS="$mech_hostile_gcp" \
        git -C "$mech_red_repo" config --show-origin --list 2>&1
)
if grep -q "$mech_hostile_home" <<< "$mech_red_out" && grep -q "hostile-via-GIT_CONFIG_PARAMETERS" <<< "$mech_red_out"; then
    ok "ALLOWLIST MECHANISM RED control: WITHOUT the env -i wrap, a hostile ambient HOME/XDG_CONFIG_HOME AND GIT_CONFIG_PARAMETERS both genuinely reach git config --show-origin (the exposure is real, not theoretical)"
else
    bad "ALLOWLIST MECHANISM RED control did not reproduce both vectors -- investigate before trusting the GREEN case below: $mech_red_out"
fi

mech_green_repo="$BASE/mech-green-repo"
git init -q "$mech_green_repo"
mech_green_sandbox_home="$(mktemp -d "$BASE/mech-green-home.XXXXXX")"
mkdir -p "$mech_green_sandbox_home/.config"
# shellcheck disable=SC2030,SC2031 # deliberately subshell-local -- these must NOT leak into the rest of this suite
mech_green_out=$(
    export HOME="$mech_hostile_home"
    export XDG_CONFIG_HOME="$mech_hostile_home/.config"
    export GIT_CONFIG_PARAMETERS="$mech_hostile_gcp"
    env -i \
        PATH="$PATH" \
        HOME="$mech_green_sandbox_home" \
        XDG_CONFIG_HOME="$mech_green_sandbox_home/.config" \
        TMPDIR="${TMPDIR:-/tmp}" \
        LANG=C \
        LC_ALL=C \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$mech_green_repo" config --show-origin --list 2>&1
)
if ! grep -q "$mech_hostile_home" <<< "$mech_green_out" && ! grep -q "hostile-via-GIT_CONFIG_PARAMETERS" <<< "$mech_green_out"; then
    ok "ALLOWLIST MECHANISM GREEN: WITH the env -i allowlist wrap, the SAME hostile ambient HOME/XDG_CONFIG_HOME AND GIT_CONFIG_PARAMETERS both vanish from git config --show-origin -- no origin outside the sandbox, proving the mechanism generally rather than one named vector at a time"
else
    bad "ALLOWLIST MECHANISM GREEN FAILED: a hostile origin reached git config --show-origin despite the env -i wrap: $mech_green_out"
fi
rm -rf "$mech_green_sandbox_home"

# ---------------------------------------------------------------------------
# RED control: WITHOUT the hook installed, a --no-verify commit on main
# succeeds. This is what proves the bypass this ticket is about is real --
# a suite that only shows the GREEN side proves nothing.
# ---------------------------------------------------------------------------
work=$(mk_sandbox red)
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-red >> "$work/note.txt"
git -C "$work" add -A
red_rc=0
git -C "$work" commit -q --no-verify -m "update graphify" || red_rc=$?
red_head=$(git -C "$work" rev-parse HEAD)
if [ "$red_rc" -eq 0 ] && [ "$red_head" != "$seed_oid" ]; then
    ok "RED control: no hook installed -> --no-verify commit on main SUCCEEDS (rc=0, HEAD $seed_oid -> $red_head) -- the bypass is real"
else
    bad "RED control did not reproduce the bypass (rc=$red_rc head=$red_head seed=$seed_oid)"
fi

# ---------------------------------------------------------------------------
# GREEN: WITH the hook installed, the same --no-verify commit is refused and
# HEAD does not move.
# ---------------------------------------------------------------------------
work=$(mk_sandbox green)
if ! install_hook "$work"; then bad "installer failed for GREEN sandbox"; fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-green >> "$work/note.txt"
git -C "$work" add -A
green_rc=0
green_out=$(git -C "$work" commit -q --no-verify -m "update graphify" 2>&1) || green_rc=$?
green_head=$(git -C "$work" rev-parse HEAD)
if [ "$green_rc" -ne 0 ] && [ "$green_head" = "$seed_oid" ]; then
    ok "GREEN: hook installed -> --no-verify commit on main REFUSED (rc=$green_rc, HEAD unchanged at $seed_oid)"
else
    bad "GREEN: expected refusal, got rc=$green_rc head=$green_head seed=$seed_oid output=$green_out"
fi
# A here-string, not a `producer | grep -q` pipe: under `set -o pipefail`,
# grep -q exits the instant it matches, the producer can take SIGPIPE writing
# the remainder, and the PIPELINE status goes non-zero -- inverting a
# genuine match into a reported failure (HIMMEL-1430). $green_out is a
# captured string well under the ~64 KiB Git Bash here-string limit
# (HIMMEL-2027), so a here-string sidesteps the pipe entirely.
if grep -q -- '--no-verify' <<< "$green_out"; then
    ok "GREEN: refusal message names --no-verify explicitly"
else
    bad "GREEN: refusal message missing --no-verify mention: $green_out"
fi
# codex-3 (panel round 4): the refusal message's substantive claim -- the
# new commit must already be PUBLISHED in origin/main -- was previously
# untested. Confirmed RED before adding this: with the message body
# replaced by placeholder text, every other assertion in this suite still
# passed (nothing else pins this wording), so a regression to the earlier,
# OVERSTATED "fast-forward only" phrasing (which is false -- a rewind to an
# older published commit is also allowed, and is exercised by the
# `git reset --hard origin/main` case above) would ship unnoticed. Pin the
# real restriction, not the old wording and not something so loose it would
# pass on any text.
if grep -q -- 'ALREADY' <<< "$green_out" && grep -q -- 'published in refs/remotes/origin/main' <<< "$green_out"; then
    ok "GREEN: refusal message states the real restriction (already published in origin/main)"
else
    bad "GREEN: refusal message missing the substantive published-in-origin/main claim: $green_out"
fi

# ---------------------------------------------------------------------------
# Ordinary commit on a fix/ branch still succeeds with the hook installed.
# ---------------------------------------------------------------------------
work=$(mk_sandbox branch)
install_hook "$work" || bad "installer failed for branch sandbox"
git -C "$work" checkout -q -b fix/some-slug
echo probe-branch >> "$work/note.txt"
git -C "$work" add -A
branch_rc=0
git -C "$work" commit -q -m "fix: on a branch" || branch_rc=$?
if [ "$branch_rc" -eq 0 ] && [ "$(git -C "$work" rev-parse --abbrev-ref HEAD)" = "fix/some-slug" ]; then
    ok "ordinary commit on fix/ branch still succeeds with hook installed"
else
    bad "branch commit unexpectedly refused (rc=$branch_rc)"
fi

# ---------------------------------------------------------------------------
# A REAL fast-forward still succeeds: push a new commit into the bare origin
# from a SECOND clone, fetch it in the first, merge --ff-only.
# ---------------------------------------------------------------------------
push_from_second_clone() {
    # push_from_second_clone SANDBOX_NAME ORIGIN_BARE MSG -- clones ORIGIN_BARE
    # fresh, commits once, pushes to main. Used by the ff/pull/reset cases so
    # "origin is ahead of work" is a genuine, independently-produced commit,
    # not main merely reset back to a spot it was already at (the probe
    # script's control D was exactly that no-op, and is NOT reused here).
    local n="$1" origin="$2" msg="$3" clone
    clone="$BASE/$n-second"
    git clone -q "$origin" "$clone" 2>/dev/null
    git -C "$clone" config user.name t2
    git -C "$clone" config user.email t2@t
    echo "$msg" >> "$clone/note.txt"
    git -C "$clone" add -A
    git -C "$clone" commit -q -m "chore: $msg"
    git -C "$clone" push -q origin main
}

work=$(mk_sandbox ff)
install_hook "$work" || bad "installer failed for ff sandbox"
origin_bare="$BASE/ff-origin.git"
push_from_second_clone ff "$origin_bare" "from-second-clone-ff"
before=$(git -C "$work" rev-parse HEAD)
git -C "$work" fetch -q origin
ff_rc=0
git -C "$work" merge -q --ff-only origin/main || ff_rc=$?
after=$(git -C "$work" rev-parse HEAD)
if [ "$ff_rc" -eq 0 ] && [ "$after" != "$before" ] && [ "$after" = "$(git -C "$work" rev-parse origin/main)" ]; then
    ok "real fast-forward (fetch + merge --ff-only) succeeds, HEAD moved $before -> $after"
else
    bad "real fast-forward unexpectedly refused (rc=$ff_rc before=$before after=$after)"
fi

# ---------------------------------------------------------------------------
# git pull --ff-only still succeeds (the console's own merge-then-pull path).
# ---------------------------------------------------------------------------
work=$(mk_sandbox pull)
install_hook "$work" || bad "installer failed for pull sandbox"
origin_bare="$BASE/pull-origin.git"
push_from_second_clone pull "$origin_bare" "from-second-clone-pull"
before=$(git -C "$work" rev-parse HEAD)
pull_rc=0
git -C "$work" pull -q --ff-only origin main || pull_rc=$?
after=$(git -C "$work" rev-parse HEAD)
if [ "$pull_rc" -eq 0 ] && [ "$after" != "$before" ]; then
    ok "git pull --ff-only succeeds, HEAD moved $before -> $after"
else
    bad "git pull --ff-only unexpectedly refused (rc=$pull_rc before=$before after=$after)"
fi

# ---------------------------------------------------------------------------
# git reset --hard origin/main still succeeds.
# ---------------------------------------------------------------------------
work=$(mk_sandbox reset)
install_hook "$work" || bad "installer failed for reset sandbox"
origin_bare="$BASE/reset-origin.git"
push_from_second_clone reset "$origin_bare" "from-second-clone-reset"
git -C "$work" fetch -q origin
before=$(git -C "$work" rev-parse HEAD)
reset_rc=0
git -C "$work" reset -q --hard origin/main || reset_rc=$?
after=$(git -C "$work" rev-parse HEAD)
if [ "$reset_rc" -eq 0 ] && [ "$after" != "$before" ] && [ "$after" = "$(git -C "$work" rev-parse origin/main)" ]; then
    ok "git reset --hard origin/main succeeds, HEAD moved $before -> $after"
else
    bad "git reset --hard origin/main unexpectedly refused (rc=$reset_rc before=$before after=$after)"
fi

# ---------------------------------------------------------------------------
# .single-writer at the repo root allows the same --no-verify commit.
# ---------------------------------------------------------------------------
work=$(mk_sandbox singlewriter)
install_hook "$work" || bad "installer failed for single-writer sandbox"
touch "$work/.single-writer"
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-sw >> "$work/note.txt"
git -C "$work" add -A
sw_rc=0
git -C "$work" commit -q --no-verify -m "update graphify" || sw_rc=$?
sw_head=$(git -C "$work" rev-parse HEAD)
if [ "$sw_rc" -eq 0 ] && [ "$sw_head" != "$seed_oid" ]; then
    ok ".single-writer present -> --no-verify commit on main ALLOWED"
else
    bad ".single-writer present but commit was refused (rc=$sw_rc)"
fi

# ---------------------------------------------------------------------------
# refs/remotes/origin/main absent entirely -> allowed, with a warning
# (fail-open: cannot be this bug's class without a published main to bypass).
# ---------------------------------------------------------------------------
noorigin="$BASE/noorigin-work"
git init -q -b main "$noorigin"
git -C "$noorigin" config user.name t
git -C "$noorigin" config user.email t@t
install_hook "$noorigin" || bad "installer failed for no-origin sandbox"
echo x > "$noorigin/note.txt"
git -C "$noorigin" add -A
noorigin_rc=0
noorigin_out=$(git -C "$noorigin" commit -q --no-verify -m "first commit, no origin" 2>&1) || noorigin_rc=$?
# Same here-string reasoning as the GREEN case above -- $noorigin_out is a
# small captured string, so this sidesteps the `producer | grep -q` pipefail
# trap (HIMMEL-1430) instead of risking an inverted result.
if [ "$noorigin_rc" -eq 0 ] && grep -q "refs/remotes/origin/main not found" <<< "$noorigin_out"; then
    ok "refs/remotes/origin/main absent -> allowed with a warning"
else
    bad "no-origin case: rc=$noorigin_rc out=$noorigin_out"
fi

# ---------------------------------------------------------------------------
# Escape hatch: MAIN_REF_TRANSACTION_OK=1 allows an otherwise-refused commit
# on main AND appends exactly one line to <git-common-dir>/main-ref-overrides.log.
# Negative twin: unset -> refused, and the log gains NO line.
# ---------------------------------------------------------------------------
work=$(mk_sandbox escape)
install_hook "$work" || bad "installer failed for escape sandbox"
log="$work/.git/main-ref-overrides.log"

# Negative twin FIRST (same sandbox, log must still be absent/empty after).
echo probe-escape-neg >> "$work/note.txt"
git -C "$work" add -A
neg_rc=0
git -C "$work" commit -q --no-verify -m "update graphify" || neg_rc=$?
neg_lines=0
[ -f "$log" ] && neg_lines=$(wc -l < "$log" | tr -d ' ')
if [ "$neg_rc" -ne 0 ] && [ "${neg_lines:-0}" -eq 0 ]; then
    ok "escape negative twin: MAIN_REF_TRANSACTION_OK unset -> refused, log gains NO line"
else
    bad "escape negative twin failed (rc=$neg_rc log_lines=${neg_lines:-0})"
fi
git -C "$work" checkout -q -- . 2>/dev/null
git -C "$work" clean -q -fd note.txt 2>/dev/null

# Positive: env var set, per-command prefix (this hook is a direct child of
# `git commit`, unlike EDIT_ON_MAIN_OK which needs a launching-shell var).
before=$(git -C "$work" rev-parse HEAD)
echo probe-escape-pos >> "$work/note.txt"
git -C "$work" add -A
pos_rc=0
( cd "$work" && MAIN_REF_TRANSACTION_OK=1 git commit -q --no-verify -m "update graphify" ) || pos_rc=$?
after=$(git -C "$work" rev-parse HEAD)
pos_lines=0
[ -f "$log" ] && pos_lines=$(wc -l < "$log" | tr -d ' ')
if [ "$pos_rc" -eq 0 ] && [ "$after" != "$before" ] && [ "${pos_lines:-0}" -eq 1 ]; then
    ok "escape: MAIN_REF_TRANSACTION_OK=1 -> commit ALLOWED, log gains exactly 1 line"
else
    bad "escape positive case failed (rc=$pos_rc before=$before after=$after log_lines=${pos_lines:-0})"
fi
if [ -f "$log" ] && grep -q "ref=refs/heads/main" "$log" && grep -q "old=$before" "$log" && grep -q "new=$after" "$log" && grep -q "var=MAIN_REF_TRANSACTION_OK=1" "$log"; then
    ok "escape log line carries ref/old/new/var fields"
else
    bad "escape log line missing expected fields: $(cat "$log" 2>&1)"
fi

# ---------------------------------------------------------------------------
# Direct-stdin unit cases: exercise phase/refname/deletion filtering without
# going through a real git transaction, using an oid that genuinely exists
# in the sandbox's object db but is NOT reachable from origin/main (so the
# ancestor check would refuse it if these filters did not short-circuit
# first).
# ---------------------------------------------------------------------------
work=$(mk_sandbox unit)
base_oid=$(git -C "$work" rev-parse HEAD)
# Produce a genuinely unreachable-from-origin/main oid WITHOUT ever moving
# refs/heads/main while doing it (once the hook is installed below, doing
# that directly on main would itself be the refused case) -- commit it on a
# throwaway branch instead, then drop the branch; the commit object stays in
# the odb (reachable via reflog) even though no ref other than the reflog
# points at it any more.
git -C "$work" branch -q scratch-orphan
git -C "$work" checkout -q scratch-orphan
git -C "$work" commit -q --allow-empty -m "orphan, not pushed" --no-verify
unreachable_oid=$(git -C "$work" rev-parse HEAD)
git -C "$work" checkout -q main
git -C "$work" branch -q -D scratch-orphan
install_hook "$work" || bad "installer failed for unit sandbox"

unit_rc=0
out=$(printf '%s %s %s\n' "$base_oid" "$unreachable_oid" "refs/heads/main" | ( cd "$work" && bash "$CHECK" committed )) || unit_rc=$?
if [ "$unit_rc" -eq 0 ]; then
    ok "phase=committed with a would-be-refused line is ignored (rc=0)"
else
    bad "phase=committed unexpectedly acted (rc=$unit_rc out=$out)"
fi

unit_rc=0
out=$(printf '%s %s %s\n' "$base_oid" "$unreachable_oid" "refs/heads/other" | ( cd "$work" && bash "$CHECK" prepared )) || unit_rc=$?
if [ "$unit_rc" -eq 0 ]; then
    ok "non-main ref (refs/heads/other) is ignored even with an unreachable new oid (rc=0)"
else
    bad "non-main ref unexpectedly refused (rc=$unit_rc out=$out)"
fi

unit_rc=0
zero40="0000000000000000000000000000000000000000"
out=$(printf '%s %s %s\n' "$unreachable_oid" "$zero40" "refs/heads/main" | ( cd "$work" && bash "$CHECK" prepared )) || unit_rc=$?
if [ "$unit_rc" -eq 0 ]; then
    ok "deletion (all-zero new oid) on refs/heads/main is ignored (rc=0)"
else
    bad "deletion unexpectedly refused (rc=$unit_rc out=$out)"
fi

unit_rc=0
out=$(printf '%s %s %s\n' "$base_oid" "$unreachable_oid" "refs/heads/main" | ( cd "$work" && bash "$CHECK" prepared )) || unit_rc=$?
if [ "$unit_rc" -ne 0 ]; then
    ok "sanity: the same unreachable oid on refs/heads/main IS refused directly (rc=$unit_rc) -- proves the two ignores above are real filters, not a broken ancestor check"
else
    bad "sanity check failed: unreachable oid on main was allowed (rc=$unit_rc out=$out)"
fi

# ===========================================================================
# Installer-only cases.
# ===========================================================================

# Idempotent: a second run is a no-op (same file, same marker, still execs
# the same check script), not a duplicate/corrupted hook.
work=$(mk_sandbox idempotent)
install_hook "$work" || bad "first install failed (idempotent case)"
hook_path="$work/.git/hooks/reference-transaction"
first_sum=$(git -C "$work" hash-object "$hook_path" 2>/dev/null)
install_hook "$work" || bad "second install failed (idempotent case)"
second_sum=$(git -C "$work" hash-object "$hook_path" 2>/dev/null)
if [ -n "$first_sum" ] && [ "$first_sum" = "$second_sum" ]; then
    ok "installer is idempotent: re-running produces the identical hook file"
else
    bad "installer NOT idempotent (first=$first_sum second=$second_sum)"
fi

# Refuses to overwrite a foreign (non-Himmel) reference-transaction hook.
work=$(mk_sandbox foreign)
mkdir -p "$work/.git/hooks"
printf '#!/usr/bin/env bash\n# some other tool'"'"'s hook, not ours\nexit 0\n' > "$work/.git/hooks/reference-transaction"
chmod +x "$work/.git/hooks/reference-transaction"
foreign_before=$(cat "$work/.git/hooks/reference-transaction")
foreign_rc=0
( cd "$work" && bash "$INSTALL" >/dev/null 2>&1 ) || foreign_rc=$?
foreign_after=$(cat "$work/.git/hooks/reference-transaction")
if [ "$foreign_rc" -ne 0 ] && [ "$foreign_before" = "$foreign_after" ]; then
    ok "installer refuses to overwrite a foreign reference-transaction hook (rc=$foreign_rc, content unchanged)"
else
    bad "installer clobbered a foreign hook (rc=$foreign_rc)"
fi

# Installs into the COMMON dir, shared by a linked worktree.
work=$(mk_sandbox commondir)
install_hook "$work" || bad "installer failed for commondir sandbox"
git -C "$work" worktree add -q -b feat/from-worktree "$BASE/commondir-wt" >/dev/null 2>&1
common_dir_from_wt=$(git -C "$BASE/commondir-wt" rev-parse --git-common-dir 2>/dev/null)
case "$common_dir_from_wt" in
    /*) : ;;
    *) common_dir_from_wt="$BASE/commondir-wt/$common_dir_from_wt" ;;
esac
if [ -f "$common_dir_from_wt/hooks/reference-transaction" ] && grep -Fq "himmel-main-ref-transaction-v1" "$common_dir_from_wt/hooks/reference-transaction"; then
    ok "hook installed into the git COMMON dir -- a linked worktree sees the same hook"
else
    bad "linked worktree does not see the installed hook (common_dir=$common_dir_from_wt)"
fi

# ---------------------------------------------------------------------------
# The installer's shim FAILS OPEN if its configured target stops resolving
# (the checkout that ran the installer got moved, renamed, or pruned) --
# exercised for real, HERMETICALLY: install normally (so the shim is the
# REAL installer's own static output, not a hand-duplicated copy that could
# drift from it), then retarget by overwriting ONLY this sandbox's OWN
# `git config --local himmel-main-ref.target` (round 5: the shim is now
# 100% static and reads the target from git config at run time -- nothing
# in the FILE needs editing at all any more). Nothing outside $BASE is
# touched -- in particular this suite's OWN tracked check-main-ref-
# transaction.sh is never moved, unlike an earlier version of this case (a
# prior CR round: mutating a tracked file mid-run is a hermeticity
# violation this repo has a structural guard for elsewhere,
# scripts/himmelctl/test/test-suite-hermeticity.sh).
# ---------------------------------------------------------------------------
work=$(mk_sandbox failopen)
install_hook "$work" || bad "installer failed for fail-open sandbox"
missing_target="$work/.git/himmel-test-nonexistent-check-script.sh"
if git -C "$work" config --local himmel-main-ref.target "$missing_target"; then
    seed_oid=$(git -C "$work" rev-parse HEAD)
    echo probe-failopen >> "$work/note.txt"
    git -C "$work" add -A
    fo_rc=0
    fo_out=$(git -C "$work" commit -q --no-verify -m "should be allowed, target missing" 2>&1) || fo_rc=$?
    fo_head=$(git -C "$work" rev-parse HEAD)
    if [ "$fo_rc" -eq 0 ] && [ "$fo_head" != "$seed_oid" ] \
        && grep -q "ALLOWING this ref update unconditionally" <<< "$fo_out" \
        && grep -F -q "$missing_target" <<< "$fo_out"
    then
        ok "installer's shim fails OPEN when its configured target is missing: commit ALLOWED (rc=0, HEAD $seed_oid -> $fo_head), warning names the missing path"
    else
        bad "fail-open case: rc=$fo_rc head=$fo_head seed=$seed_oid out=$fo_out"
    fi
else
    bad "fail-open case: could not retarget the sandbox's own git config"
fi

# ---------------------------------------------------------------------------
# panel round 9: a READABLE DIRECTORY at the configured target must ALSO
# fail OPEN, not fail-CLOSED. `[ -r DIR ]` is true for a readable directory,
# so a bare readability check (this shim's shape before this round) let a
# directory reach `exec bash "$target"` -- bash fails to exec a directory,
# so the hook would fail-CLOSED instead of the documented fail-open: EVERY
# ref update in the repo refused (fetch, every commit, every branch),
# recoverable only by deleting an untracked file under .git/hooks/ that no
# `git diff` ever shows. There is no realistic route by which the
# installer-set target becomes a directory -- but the impact (a silent,
# near-undiagnosable brick) outweighs the negligible probability, so this
# is tested the same way the missing-target case above is: install for
# real, then retarget this sandbox's OWN git config at a directory,
# hermetically, same as above.
# ---------------------------------------------------------------------------
work=$(mk_sandbox failopendir)
install_hook "$work" || bad "installer failed for fail-open-directory sandbox"
dir_target="$work/.git/himmel-test-target-is-a-directory"
mkdir -p "$dir_target"
if git -C "$work" config --local himmel-main-ref.target "$dir_target"; then
    seed_oid=$(git -C "$work" rev-parse HEAD)
    echo probe-failopendir >> "$work/note.txt"
    git -C "$work" add -A
    fod_rc=0
    fod_out=$(git -C "$work" commit -q --no-verify -m "should be allowed, target is a directory" 2>&1) || fod_rc=$?
    fod_head=$(git -C "$work" rev-parse HEAD)
    if [ "$fod_rc" -eq 0 ] && [ "$fod_head" != "$seed_oid" ] \
        && grep -q "ALLOWING this ref update unconditionally" <<< "$fod_out" \
        && grep -F -q "$dir_target" <<< "$fod_out"
    then
        ok "installer's shim fails OPEN when its configured target is a directory: commit ALLOWED (rc=0, HEAD $seed_oid -> $fod_head), warning names the directory path"
    else
        bad "fail-open-directory case: rc=$fod_rc head=$fod_head seed=$seed_oid out=$fod_out"
    fi
else
    bad "fail-open-directory case: could not retarget the sandbox's own git config"
fi

# ---------------------------------------------------------------------------
# panel round 10: git < 2.31 does NOT fail on an unsupported --path-format
# -- it ECHOES the option as output and still exits 0, returning a
# garbled/relative value (proven directly on this station, git 2.55: `git
# rev-parse --totally-unknown-option --git-path hooks` echoes the unknown
# option, then prints a relative path, rc=0). A first fix pass assumed the
# call would FAIL and left the resolved value untrusted-but-unvalidated;
# this reproduces the real mechanism (not a fabricated hard failure) with
# a `git` shim that strips --path-format=absolute out of argv, echoes it
# back, then execs real git with the rest -- exactly what git itself does.
# Both this installer's exit code AND the QUALITY of its diagnosis matter
# here: on this station, the pre-fix installer happens to still exit
# non-zero in this exact scenario (GNU dirname's own option parser chokes
# on a value that starts with `-`, an ACCIDENT of this station's coreutils,
# not a deliberate check) -- but its error is a raw, uninterpretable
# `dirname: unrecognized option` splat that never mentions git versions at
# all, which is not "refuses correctly", it is "happens to crash in a way
# that also fails". The fix must produce a genuine diagnosis (names the
# git-version cause, points at this installer's own GIT VERSION note)
# regardless of what any particular `dirname` implementation does with a
# flag-shaped path.
# ---------------------------------------------------------------------------
real_git=$(command -v git)
work=$(mk_sandbox pathformat230)
fakegit_dir="$BASE/pathformat230-fake-git-bin"
mkdir -p "$fakegit_dir"
cat > "$fakegit_dir/git" <<GITSHIM
#!/usr/bin/env bash
saw_path_format=0
args=()
for a in "\$@"; do
    if [ "\$a" = "--path-format=absolute" ]; then
        saw_path_format=1
        continue
    fi
    args+=("\$a")
done
if [ "\$saw_path_format" -eq 1 ]; then
    echo "--path-format=absolute"
fi
exec "$real_git" "\${args[@]}"
GITSHIM
chmod +x "$fakegit_dir/git"
pf230_rc=0
pf230_log="$BASE/pathformat230-install.log"
( cd "$work" && PATH="$fakegit_dir:$PATH" bash "$INSTALL" ) >"$pf230_log" 2>&1 || pf230_rc=$?
pf230_out="$(cat "$pf230_log")"
if [ "$pf230_rc" -ne 0 ] && [ ! -e "$work/.git/hooks/reference-transaction" ] \
    && grep -q "git >= 2.31" <<< "$pf230_out"
then
    ok "installer correctly DIAGNOSES (not just happens to fail on) git echoing an unsupported --path-format: rc=$pf230_rc, no hook at the real location, names the git-version cause"
else
    bad "installer did not correctly diagnose the git-2.30 echo-back shape: rc=$pf230_rc, real hook present=$([ -e "$work/.git/hooks/reference-transaction" ] && echo yes || echo no), out=$pf230_out"
fi

# ---------------------------------------------------------------------------
# codex-1 (panel round 1): core.hooksPath, when set, is the ONLY place git
# looks -- .git/hooks/ (and the common dir) are never consulted. Installing
# there unconditionally would report success while git never invokes the
# guard: the exact "shipped but not protecting" failure C32 exists to
# catch, silently defeated. Proven two ways: a RELATIVE hooksPath (resolved
# against the worktree TOP, matching check-hookspath.sh's own rule -- NOT
# the git dir, NOT cwd) and an ABSOLUTE one, both installed into and both
# genuinely consulted by git for a real --no-verify refusal.
# ---------------------------------------------------------------------------
work=$(mk_sandbox hookspath-rel)
git -C "$work" config core.hooksPath ".githooks"
install_hook "$work" || bad "installer failed for relative-hookspath sandbox"
hp_rel_hook="$work/.githooks/reference-transaction"
if [ -f "$hp_rel_hook" ] && [ -x "$hp_rel_hook" ] && [ ! -f "$work/.git/hooks/reference-transaction" ]; then
    ok "relative core.hooksPath=.githooks: shim lands at the resolved location, NOT at .git/hooks/"
else
    bad "relative core.hooksPath: shim not at the resolved location (found .githooks=$([ -f "$hp_rel_hook" ] && echo yes || echo no), leaked into .git/hooks=$([ -f "$work/.git/hooks/reference-transaction" ] && echo yes || echo no))"
fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-hookspath-rel >> "$work/note.txt"
git -C "$work" add -A
hpr_rc=0
git -C "$work" commit -q --no-verify -m "should be refused via .githooks" || hpr_rc=$?
if [ "$hpr_rc" -ne 0 ] && [ "$(git -C "$work" rev-parse HEAD)" = "$seed_oid" ]; then
    ok "relative core.hooksPath: git genuinely consults .githooks/ and REFUSES the --no-verify commit"
else
    bad "relative core.hooksPath: refusal did not fire (rc=$hpr_rc)"
fi

work=$(mk_sandbox hookspath-abs)
abs_hooks_dir="$BASE/hookspath-abs-external-hooks"
git -C "$work" config core.hooksPath "$abs_hooks_dir"
install_hook "$work" || bad "installer failed for absolute-hookspath sandbox"
hp_abs_hook="$abs_hooks_dir/reference-transaction"
if [ -f "$hp_abs_hook" ] && [ -x "$hp_abs_hook" ] && [ ! -f "$work/.git/hooks/reference-transaction" ]; then
    ok "absolute core.hooksPath: shim lands at the resolved external location, NOT at .git/hooks/"
else
    bad "absolute core.hooksPath: shim not at the resolved location"
fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-hookspath-abs >> "$work/note.txt"
git -C "$work" add -A
hpa_rc=0
git -C "$work" commit -q --no-verify -m "should be refused via the external hooksPath dir" || hpa_rc=$?
if [ "$hpa_rc" -ne 0 ] && [ "$(git -C "$work" rev-parse HEAD)" = "$seed_oid" ]; then
    ok "absolute core.hooksPath: git genuinely consults the external dir and REFUSES the --no-verify commit"
else
    bad "absolute core.hooksPath: refusal did not fire (rc=$hpa_rc)"
fi

# ---------------------------------------------------------------------------
# codex-3 (panel round 1) + codex-1 (panel round 3): a checkout path used to
# be interpolated into the generated shim -- first as a `%q`-escaped shell
# assignment (round 1: broken by `$`/backtick/`"`), then, when that
# assignment was replaced with a literal comment line for check_c32 to read
# (round 2's own eval fix), the comment form broke a THIRD way: an embedded
# NEWLINE byte terminates a comment line early and injects a new line of
# shell into the file (round 3, codex-1). Round 3's fix removes the
# question rather than patching it a third time: the path is no longer
# interpolated into the shim file's TEXT at all -- it lives in `git config
# --local himmel-main-ref.target`, which round-trips arbitrary bytes
# (verified separately: `$`, backticks, `"`, AND a literal embedded newline
# all survive a set/get round-trip byte-exact). Proven here, not assumed:
# copy the installer + check script into a directory whose name carries
# `$`, a backtick, AND `"` simultaneously, install FROM there (so
# SCRIPT_DIR -- and therefore the value handed to `git config`-- genuinely
# contains them), and confirm the guard still resolves and refuses
# correctly, with nothing executed along the way.
# ---------------------------------------------------------------------------
hostile_dir="$BASE"/$'hostile$(echo pwned)`bt`"q'
mkdir -p "$hostile_dir/scripts/hooks"
cp "$INSTALL" "$hostile_dir/scripts/hooks/install-main-ref-transaction.sh"
cp "$CHECK" "$hostile_dir/scripts/hooks/check-main-ref-transaction.sh"
chmod +x "$hostile_dir/scripts/hooks/"*.sh
work=$(mk_sandbox hostile-escape)
hostile_rc=0
( cd "$work" && bash "$hostile_dir/scripts/hooks/install-main-ref-transaction.sh" >/dev/null 2>&1 ) || hostile_rc=$?
hostile_hook="$work/.git/hooks/reference-transaction"
if [ "$hostile_rc" -eq 0 ] && grep -Fq "himmel-main-ref-transaction-v1" "$hostile_hook" 2>/dev/null; then
    ok "installing from a hostile-charactered path (\$, backtick, \") succeeds and writes the shim"
else
    bad "install from hostile path failed (rc=$hostile_rc)"
fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-hostile >> "$work/note.txt"
git -C "$work" add -A
hostile_commit_rc=0
hostile_out=$(git -C "$work" commit -q --no-verify -m "should be refused, not exploited" 2>&1) || hostile_commit_rc=$?
if [ "$hostile_commit_rc" -ne 0 ] \
    && [ "$(git -C "$work" rev-parse HEAD)" = "$seed_oid" ] \
    && grep -q "refusing to update refs/heads/main" <<< "$hostile_out"
then
    ok "hostile-path shim still correctly REFUSES (rc!=0, HEAD unchanged) -- the escaping holds: a broken escape would either fail to write the shim at all or silently fail-open (allow) here instead"
else
    bad "hostile-path escaping failed: rc=$hostile_commit_rc out=$hostile_out"
fi

# ---------------------------------------------------------------------------
# codex-1 (panel round 3), the specific finding: a checkout path containing
# a literal EMBEDDED NEWLINE byte (legal on POSIX filesystems -- only NUL
# and `/` are forbidden in a filename). This is the exact case that broke
# the round-2 comment-line format. Same technique as the hostile-path case
# above -- install FROM a directory whose name contains a real newline --
# but asserted on its own, since a broken git-config round-trip for THIS
# one byte would be silent corruption (a truncated/split value), not
# necessarily a loud failure the hostile-path case's assertions would
# catch.
# ---------------------------------------------------------------------------
newline_dir="$BASE"/$'weird\nname\ndir'
mkdir -p "$newline_dir/scripts/hooks"
cp "$INSTALL" "$newline_dir/scripts/hooks/install-main-ref-transaction.sh"
cp "$CHECK" "$newline_dir/scripts/hooks/check-main-ref-transaction.sh"
chmod +x "$newline_dir/scripts/hooks/"*.sh
work=$(mk_sandbox newline-escape)
newline_rc=0
( cd "$work" && bash "$newline_dir/scripts/hooks/install-main-ref-transaction.sh" >/dev/null 2>&1 ) || newline_rc=$?
expected_target="$newline_dir/scripts/hooks/check-main-ref-transaction.sh"
got_target=$(git -C "$work" config --local --get himmel-main-ref.target 2>/dev/null)
if [ "$newline_rc" -eq 0 ] && [ "$got_target" = "$expected_target" ]; then
    ok "installing from a path containing a literal embedded newline: git config round-trips the value byte-exact (including the newline)"
else
    bad "newline-path install/round-trip failed (rc=$newline_rc got=[$got_target] expected=[$expected_target])"
fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-newline >> "$work/note.txt"
git -C "$work" add -A
newline_commit_rc=0
newline_out=$(git -C "$work" commit -q --no-verify -m "should be refused via the newline-pathed target" 2>&1) || newline_commit_rc=$?
if [ "$newline_commit_rc" -ne 0 ] \
    && [ "$(git -C "$work" rev-parse HEAD)" = "$seed_oid" ] \
    && grep -q "refusing to update refs/heads/main" <<< "$newline_out"
then
    ok "newline-path shim still correctly REFUSES (rc!=0, HEAD unchanged) -- no injection, no corruption, the guard genuinely fires through it"
else
    bad "newline-path functional refusal failed: rc=$newline_commit_rc out=$newline_out"
fi

# ---------------------------------------------------------------------------
# codex-4 (panel round 2): `git rev-parse --git-common-dir`'s own output is
# relative to the INVOKING DIRECTORY, not the worktree top -- the installer
# used to join it against repo_root regardless, which computed the WRONG
# path (one level too far up, outside the repo) whenever run from a
# subdirectory. It reported success while installing nowhere git would ever
# look. Fixed by asking git for the answer directly (`--path-format=
# absolute --git-path hooks`), which is correct from any cwd. Proven
# red/green before this case was written: the pre-fix installer run from
# `<repo>/deep/sub` wrote to `<repo>/deep/sub/../../.git/hooks/…` (a path
# that resolves OUTSIDE the repo, since repo_root was ALREADY the top) and
# still printed "installed" -- `.git/hooks/reference-transaction` never
# existed. This case exercises the exact same shape end-to-end.
# ---------------------------------------------------------------------------
work=$(mk_sandbox subdir)
mkdir -p "$work/deep/sub/dir"
subdir_rc=0
( cd "$work/deep/sub/dir" && bash "$INSTALL" >/dev/null 2>&1 ) || subdir_rc=$?
subdir_hook="$work/.git/hooks/reference-transaction"
if [ "$subdir_rc" -eq 0 ] && [ -f "$subdir_hook" ] && [ -x "$subdir_hook" ]; then
    ok "installer run from a subdirectory still lands the shim at the real .git/hooks/ (not one level too far up)"
else
    bad "subdirectory invocation: rc=$subdir_rc, hook present=$([ -f "$subdir_hook" ] && echo yes || echo no)"
fi
seed_oid=$(git -C "$work" rev-parse HEAD)
echo probe-subdir >> "$work/note.txt"
git -C "$work" add -A
subdir_commit_rc=0
git -C "$work" commit -q --no-verify -m "should be refused" || subdir_commit_rc=$?
if [ "$subdir_commit_rc" -ne 0 ] && [ "$(git -C "$work" rev-parse HEAD)" = "$seed_oid" ]; then
    ok "subdirectory-installed shim genuinely refuses a --no-verify commit on main"
else
    bad "subdirectory-installed shim did not refuse (rc=$subdir_commit_rc)"
fi

# ---------------------------------------------------------------------------
# codex-3 (panel round 2): a RELATIVE core.hooksPath resolves against EACH
# worktree's OWN top-level (git's own semantics, confirmed empirically --
# see the installer's header) -- so a naive single-location install would
# leave every OTHER linked worktree unprotected, silently breaking the
# common-dir sharing guarantee this guard otherwise relies on. The
# installer now covers every worktree explicitly when it detects this
# case. Proven with THREE worktrees (the primary checkout + two linked),
# asserting each one independently gets its OWN shim at its OWN resolved
# location, and that each one genuinely refuses.
# ---------------------------------------------------------------------------
work=$(mk_sandbox multiwt)
git -C "$work" config core.hooksPath ".githooks"
git -C "$work" worktree add -q -b feat/multiwt-a "$BASE/multiwt-a" >/dev/null 2>&1
git -C "$work" worktree add -q -b feat/multiwt-b "$BASE/multiwt-b" >/dev/null 2>&1
install_hook "$work" || bad "installer failed for multi-worktree relative-hookspath sandbox"
all_covered=1
for wt in "$work" "$BASE/multiwt-a" "$BASE/multiwt-b"; do
    hp="$wt/.githooks/reference-transaction"
    if [ ! -x "$hp" ] || ! grep -Fq "himmel-main-ref-transaction-v1" "$hp"; then
        all_covered=0
        bad "multi-worktree relative hookspath: $wt/.githooks/reference-transaction missing or not executable"
    fi
done
[ "$all_covered" -eq 1 ] && ok "relative core.hooksPath: installer covers the primary checkout AND both linked worktrees, each at its own resolved location"
# Functional check from ONE of the linked worktrees (not the one that ran
# the installer, and not itself checked out on main -- it's on
# feat/multiwt-a) -- proves the coverage is real protection, not just files
# on disk. `git commit` there would only test an ordinary branch commit
# (always allowed, proves nothing about main); refs/heads/main can only be
# checked out in ONE worktree at a time, so exercise the ref update
# directly with `update-ref` -- reference-transaction fires for whichever
# worktree's git PROCESS performs the update, regardless of what that
# worktree has checked out, and `update-ref` (unlike `branch -f`/checkout)
# has no "checked out elsewhere" guard of its own to get in the way.
main_oid=$(git -C "$work" rev-parse main)
tree_oid=$(git -C "$BASE/multiwt-a" rev-parse 'HEAD^{tree}')
unpublished_oid=$(git -C "$BASE/multiwt-a" commit-tree -m "unpublished, from the linked worktree" -p "$main_oid" "$tree_oid")
multiwt_out=$(git -C "$BASE/multiwt-a" update-ref refs/heads/main "$unpublished_oid" 2>&1)
multiwt_rc=1
grep -q "reference-transaction hook" <<< "$multiwt_out" && multiwt_rc=0
after_oid=$(git -C "$work" rev-parse main)
if [ "$multiwt_rc" -eq 0 ] && [ "$after_oid" = "$main_oid" ]; then
    ok "the linked worktree that did NOT run the installer still genuinely refuses an update to refs/heads/main (main unchanged)"
else
    bad "linked worktree feat/multiwt-a was not protected (grep_rc=$multiwt_rc main before=$main_oid after=$after_oid)"
fi

# ---------------------------------------------------------------------------
# codex-1 (panel round 4): `extensions.worktreeConfig` lets a SIBLING
# worktree override core.hooksPath independently of what the INVOKING
# checkout's own value reads as -- "usually shared" is not "always shared".
# This is the exact scenario the pre-round-4 installer missed: it only
# looped over every worktree when THIS invocation's own core.hooksPath read
# as relative, so a primary checkout with core.hooksPath UNSET (the common,
# "shared" case) took a single-install shortcut and never discovered a
# linked worktree's independent override. Proven here: primary UNSET,
# linked worktree overrides via `git config --worktree` (only visible once
# `extensions.worktreeConfig` is enabled), installer run from the PRIMARY,
# asserting the sibling's own INDEPENDENTLY-resolved location gets the
# shim -- not just the primary's shared common-dir location.
# ---------------------------------------------------------------------------
work=$(mk_sandbox worktreeconfig)
git -C "$work" config extensions.worktreeConfig true
git -C "$work" worktree add -q -b feat/wtconfig-override "$BASE/worktreeconfig-override" >/dev/null 2>&1
git -C "$BASE/worktreeconfig-override" config --worktree core.hooksPath ".this-worktree-only-hooks"
install_hook "$work" || bad "installer failed for extensions.worktreeConfig sandbox"
override_hook="$BASE/worktreeconfig-override/.this-worktree-only-hooks/reference-transaction"
if [ -x "$override_hook" ] && grep -Fq "himmel-main-ref-transaction-v1" "$override_hook"; then
    ok "extensions.worktreeConfig: a sibling worktree's INDEPENDENTLY-overridden core.hooksPath location is covered even though the invoking checkout's own core.hooksPath is unset"
else
    bad "extensions.worktreeConfig: sibling's overridden location not covered ($override_hook)"
fi
if [ -x "$work/.git/hooks/reference-transaction" ]; then
    ok "extensions.worktreeConfig: the primary's own shared .git/hooks/ is ALSO covered"
else
    bad "extensions.worktreeConfig: primary's own shared location not covered"
fi

# ---------------------------------------------------------------------------
# codex-2 (panel round 4): `git worktree list --porcelain`'s plain
# newline-delimited output treats a worktree PATH containing a literal
# embedded newline byte (legal on POSIX filesystems) as ending at that
# newline -- silently truncating the entry, which then fails to resolve as
# a real worktree and gets skipped. Fixed with `--porcelain -z`
# (NUL-terminated fields), read via `read -r -d ''` fed by process
# substitution. Proven with a RELATIVE core.hooksPath (so this worktree
# gets its OWN distinct, verifiable install location derived from its full
# path, unlike the unset/shared case where every worktree collapses onto
# the same common-dir location regardless of whether enumeration actually
# saw it) -- a linked worktree whose own path contains a real embedded
# newline must still be discovered and get its own shim.
# ---------------------------------------------------------------------------
work=$(mk_sandbox wtnewlinepath)
git -C "$work" config core.hooksPath ".githooks"
newline_wt_path="$BASE"/$'weird-worktree-name\nwith-a-newline'
git -C "$work" worktree add -q -b feat/wt-newline-name "$newline_wt_path" >/dev/null 2>&1
install_hook "$work" || bad "installer failed for newline-worktree-path sandbox"
newline_wt_hook="$newline_wt_path/.githooks/reference-transaction"
if [ -x "$newline_wt_hook" ] && grep -Fq "himmel-main-ref-transaction-v1" "$newline_wt_hook"; then
    ok "a linked worktree whose OWN path contains a literal embedded newline is still correctly enumerated (-z parsing) and gets its own shim at its own resolved location"
else
    bad "newline-named worktree not covered (checked $newline_wt_hook)"
fi

# ---------------------------------------------------------------------------
# codex-2 (panel round 8): when worktree ENUMERATION itself fails (`git
# worktree list --porcelain -z` produces no output at all), the installer
# falls back to installing into just the CURRENT worktree -- but it used to
# report exit 0 whenever that single install succeeded, even though it has
# NO IDEA whether other worktrees exist and are therefore left uncovered.
# That is the exact "partial coverage indistinguishable from full coverage"
# property the codex-2 fix above (panel round 6) exists to prevent, on the
# one path that fix did not reach. Reproduced with a REAL, non-simulated
# enumeration failure: a `git` shim placed first on PATH that intercepts
# ONLY `worktree list ...` (exiting 1, no output) and execs the real git
# for everything else (`git rev-parse`, `git config`, the actual hook-file
# write) -- so the installer's own enumeration call fails for real, on a
# repo that DOES have a second worktree, while every other git operation
# inside the installer behaves normally.
# ---------------------------------------------------------------------------
real_git=$(command -v git)
work=$(mk_sandbox enumfail)
git -C "$work" worktree add -q -b feat/enumfail-a "$BASE/enumfail-a" >/dev/null 2>&1
fake_git_bin="$BASE/enumfail-fake-git-bin"
mkdir -p "$fake_git_bin"
cat > "$fake_git_bin/git" <<GITSHIM
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
    exit 1
fi
exec "$real_git" "\$@"
GITSHIM
chmod +x "$fake_git_bin/git"
enumfail_rc=0
enumfail_log="$BASE/enumfail-install.log"
( cd "$work" && PATH="$fake_git_bin:$PATH" bash "$INSTALL" ) >"$enumfail_log" 2>&1 || enumfail_rc=$?
if [ "$enumfail_rc" -ne 0 ]; then
    ok "enumeration failure: installer's own exit code is non-zero (rc=$enumfail_rc) even though the single-worktree fallback install itself succeeded -- coverage of the OTHER (real) linked worktree is unknown, not silently reported as complete"
else
    bad "enumeration failure: installer exited 0 despite worktree enumeration genuinely failing on a repo with a second, real worktree -- partial/unknown coverage read as complete coverage (see $enumfail_log)"
fi
if [ -x "$work/.git/hooks/reference-transaction" ] && grep -Fq "himmel-main-ref-transaction-v1" "$work/.git/hooks/reference-transaction"; then
    ok "enumeration failure: the fallback still installs into the invoking worktree (SOME protection, not none)"
else
    bad "enumeration failure: fallback did not install into the invoking worktree at all"
fi

# ---------------------------------------------------------------------------
# codex-2 (panel round 6): a PARTIAL install failure (some worktree
# locations get the guard, one does not) used to still `exit 0` -- a caller
# scripting against this installer's exit code could not tell "every
# location is protected" apart from "some are, some are not". Proven with
# THREE worktrees again, but one of the three -- $BASE/multiwt2-b's
# resolved .githooks/ path -- pre-occupied by a plain FILE (not a
# directory) before the installer runs, so its own `mkdir -p
# "$(dirname "$hook_path")"` genuinely fails (not simulated: a real
# ENOTDIR/File-exists error from the filesystem). A regular file occupying
# a needed directory component is a DETERMINISTIC failure -- unlike a
# permission bit (panel round 8, codex-3: `chmod 555` does not block
# writes for root, nor on a filesystem without POSIX permission
# enforcement), no privilege level or filesystem mode makes `mkdir` turn
# an existing file into a directory of the same name, so this reproduces
# identically for every user and every POSIX-compliant filesystem this
# suite might run on. Asserts (a) the installer's exit code is NON-zero,
# (b) the two locations that COULD be written to genuinely got the shim
# (no rollback of a partial success), and (c) the one that could not is
# genuinely absent (the blocker file itself, untouched).
# ---------------------------------------------------------------------------
work=$(mk_sandbox multiwt2)
git -C "$work" config core.hooksPath ".githooks"
git -C "$work" worktree add -q -b feat/multiwt2-a "$BASE/multiwt2-a" >/dev/null 2>&1
git -C "$work" worktree add -q -b feat/multiwt2-b "$BASE/multiwt2-b" >/dev/null 2>&1
: > "$BASE/multiwt2-b/.githooks"
partial_rc=0
partial_log="$BASE/partial-install.log"
( cd "$work" && bash "$INSTALL" ) >"$partial_log" 2>&1 || partial_rc=$?
if [ "$partial_rc" -ne 0 ]; then
    ok "partial worktree-install failure: installer's own exit code is non-zero (rc=$partial_rc) -- a caller can tell this apart from complete coverage"
else
    bad "partial worktree-install failure: installer exited 0 despite a real write failure at $BASE/multiwt2-b/.githooks -- partial coverage is indistinguishable from complete coverage (see $partial_log)"
fi
partial_kept=1
for wt in "$work" "$BASE/multiwt2-a"; do
    hp="$wt/.githooks/reference-transaction"
    if [ ! -x "$hp" ] || ! grep -Fq "himmel-main-ref-transaction-v1" "$hp"; then
        partial_kept=0
        bad "partial worktree-install failure: the location that COULD be written to ($hp) was not kept -- a partial failure must not roll back successful installs"
    fi
done
[ "$partial_kept" -eq 1 ] && ok "partial worktree-install failure: the locations that installed successfully are KEPT, not rolled back, despite the overall non-zero exit"
if [ ! -e "$BASE/multiwt2-b/.githooks/reference-transaction" ]; then
    ok "partial worktree-install failure: the location that genuinely could not be written to is genuinely absent (not silently reported as installed)"
else
    bad "partial worktree-install failure: $BASE/multiwt2-b/.githooks/reference-transaction exists despite the read-only directory -- the failure was not real"
fi

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
