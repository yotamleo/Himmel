#!/usr/bin/env bash
# test-assert-provenance.sh — hermetic coverage for the guest-side helpers of
# the install-provenance round trip (HIMMEL-3332 S9b, HIMMEL-3351):
# scripts/vm/lib/assert-provenance.sh and seed-provenance.sh. NEVER touches a
# VM or the host: both run against a scratch HOME, fabricated inventories
# (INV_BASE) and a fake crontab / systemctl / systemd-analyze on PATH.
#
# Covers: the seeded telegram + bridge state (kept by a plain uninstall, purged
# by --purge-state, and not reported as residue either way), the qmd/graphify
# stubs the `all` profile seeds (user-owned: they must SURVIVE uninstall and are
# never himmel's), ~/.claude.json deleted = too-much, user-units-removed judged
# against inventory A, and the cadence-crontab-armed-at-B precondition.
#
# Platform guard (linux-only): the scripts under test are guest (Ubuntu) scripts.
#
# Usage: bash scripts/vm/test-assert-provenance.sh
# No pipefail: every assert is `producer | grep -q`.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/vm/lib"
[ "$(uname -s)" = Linux ] || { echo "SKIP: linux-only"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-assert-prov.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
# has <name> <regex> — the last run's output has a line matching the regex.
has() { if grep -qE "$2" <<<"$OUT"; then pass "$1"; else fail_case "$1 (no line matching: $2)"; printf '%s\n' "$OUT" | grep -E "${3:-CHECK}" | head -n 12 | sed 's/^/    /'; fi; }
hasnt() { if grep -qE "$2" <<<"$OUT"; then fail_case "$1 (unexpected line matching: $2)"; grep -E "$2" <<<"$OUT" | head -n 3 | sed 's/^/    /'; else pass "$1"; fi; }

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
# fake crontab: `-l` prints $FAKE_CRON (rc 1 when empty), `-` replaces it.
cat >"$FAKEBIN/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -l) [ -s "$FAKE_CRON" ] || { echo "no crontab for tester" >&2; exit 1; }; cat "$FAKE_CRON" ;;
    -) cat >"$FAKE_CRON" ;;
    *) exit 2 ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/systemd-analyze"
chmod +x "$FAKEBIN"/*

H="$WORK/home"
LB="$WORK/lib"        # the scripts write next to themselves, so they run from a copy
INV="$WORK/inv"
export FAKE_CRON="$WORK/cron"

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# inv <label> <type> <path> [content] — one inventory row (a file gets a sha row).
inv() {
    local l="$1" t="$2" p="$3" c="${4-x}"
    printf '%s\t644\t1\t%s\t\n' "$t" "$p" >>"$INV/inv-$l/home.meta"
    [ "$t" != f ] || printf '%s  %s\n' "$(sha "$c")" "$p" >>"$INV/inv-$l/home.sha"
}
# drop <label> <path> — remove the path's rows from one inventory.
drop() {
    local l="$1" f
    for f in home.meta home.sha; do grep -vF "$2" "$INV/inv-$l/$f" >"$INV/inv-$l/$f.new"; mv "$INV/inv-$l/$f.new" "$INV/inv-$l/$f"; done
}
# both <labels> <type> <path> [content] — the same row in every named inventory.
both() { local ls="$1"; shift; local l; for l in $ls; do inv "$l" "$@"; done; }

# fresh — an empty world: scratch HOME, three empty inventories, the copied
# scripts, a seeded.list of just ~/.claude.json, an empty crontab.
fresh() {
    rm -rf "$H" "$LB" "$INV" "$FAKE_CRON"
    mkdir -p "$H/.claude" "$LB/seed-state" "$INV/inv-A" "$INV/inv-B" "$INV/inv-C"
    local l; for l in A B C; do : >"$INV/inv-$l/home.meta"; : >"$INV/inv-$l/home.sha"; done
    cp "$LIB/assert-provenance.sh" "$LIB/seed-provenance.sh" "$LB/"
    echo '{}' >"$LB/seed-state/settings.json"; echo '{}' >"$H/.claude/settings.json"
    : >"$LB/seed-state/crontab.txt"; echo disabled >"$LB/seed-state/mine-enabled.txt"
    printf '%s\n' "$H/.claude.json" >"$LB/seeded.list"
    : >"$LB/state.list"
    both "A B C" f "$H/.claude.json" cj
    : >"$FAKE_CRON"
}
# run_assert <RT_PROFILE> <RT_PURGE> — populate OUT (HOME is the scratch one).
run_assert() {
    OUT=$(HOME="$H" PATH="$FAKEBIN:$PATH" INV_BASE="$INV" HIMMEL_RT_GUEST=1 RT_PROFILE="$1" RT_PURGE="$2" bash "$LB/assert-provenance.sh" 2>&1)
    RC=$?
}

TG="$H/.claude/channels/telegram" BR="$H/.claude/handover/bridge"
# state_world — the seeded state at A, B; state.list naming it.
state_world() {
    local d
    for d in "$TG" "$BR"; do both "A B" d "$d"; done
    both "A B" f "$TG/.env" tok; both "A B" f "$TG/access.json" acc; both "A B" f "$BR/state.json" st
    printf '%s\n' "$TG" "$TG/.env" "$TG/access.json" "$BR" "$BR/state.json" >"$LB/state.list"
}
state_kept_at_c() {
    local d
    for d in "$TG" "$BR"; do inv C d "$d"; done
    inv C f "$TG/.env" tok; inv C f "$TG/access.json" acc; inv C f "$BR/state.json" st
}

# ---- 1. plain uninstall: the state must be kept, identical.
fresh; state_world; state_kept_at_c
run_assert core 0
has "plain: state kept passes (.env)" 'CHECK state too-much PASS state-kept:~/.claude/channels/telegram/.env '
has "plain: state kept passes (bridge dir)" 'CHECK state too-much PASS state-kept:~/.claude/handover/bridge '
hasnt "plain: no purged-state line" 'state-purged'
hasnt "plain: state is not residue" 'CHECK residue [a-z-]+ FAIL [a-z]+:~/.claude/(channels|handover)'

fresh; state_world
both C d "$TG"; inv C f "$TG/access.json" acc     # .env gone, bridge gone, access.json kept
run_assert core 0
has "plain: a removed state file is too-much" 'CHECK state too-much FAIL state-kept:~/.claude/channels/telegram/.env '
has "plain: a removed state dir is too-much" 'CHECK state too-much FAIL state-kept:~/.claude/handover/bridge '
has "plain: a kept state file passes" 'CHECK state too-much PASS state-kept:~/.claude/channels/telegram/access.json '

fresh; state_world; state_kept_at_c
sed -i "s#^.*  $TG/.env\$#$(sha changed)  $TG/.env#" "$INV/inv-C/home.sha"
run_assert core 0
has "plain: a changed state file is too-much" 'CHECK state too-much FAIL state-kept:~/.claude/channels/telegram/.env '

# ---- 2. --purge-state: the state must be gone.
fresh; state_world
run_assert core 1
has "purge: state gone passes (.env)" 'CHECK state too-little PASS state-purged:~/.claude/channels/telegram/.env '
has "purge: state gone passes (bridge dir)" 'CHECK state too-little PASS state-purged:~/.claude/handover/bridge '
hasnt "purge: purged state is not a too-much residue" 'CHECK residue too-much FAIL gone:~/.claude/(channels|handover)'
hasnt "purge: no state-kept line" 'state-kept'

fresh; state_world; state_kept_at_c
run_assert core 1
has "purge: a surviving state file is too-little" 'CHECK state too-little FAIL state-purged:~/.claude/channels/telegram/.env '
has "purge: a surviving state dir is too-little" 'CHECK state too-little FAIL state-purged:~/.claude/handover/bridge '

# ---- 3. state.list is a required input (seed-provenance.sh always writes it).
fresh; rm -f "$LB/state.list"
run_assert core 0
if [ "$RC" -eq 2 ] && grep -q 'missing input .*state.list' <<<"$OUT"; then pass "a missing state.list is rc 2"; else fail_case "a missing state.list is rc 2 (rc=$RC)"; fi

# ---- 4. ~/.claude.json deleted is a too-much, not an identity, failure.
fresh; : >"$INV/inv-C/home.meta"; : >"$INV/inv-C/home.sha"
run_assert core 0
has "claude.json deleted is too-much" 'CHECK identity too-much FAIL claude-json-unchanged-from-B '
hasnt "claude.json deleted is not tagged identity" 'CHECK identity identity FAIL claude-json-unchanged-from-B '
fresh                                                # A=B=C, then C's ~/.claude.json differs from B's
sed -i "s#^.*  $H/.claude.json\$#$(sha other)  $H/.claude.json#" "$INV/inv-C/home.sha"
run_assert core 0
has "claude.json rewritten stays identity" 'CHECK identity identity FAIL claude-json-unchanged-from-B '

# ---- 5. the user's qmd/graphify stubs (profile all): user-owned, must survive.
STUBS="$H/.local/bin"
stub_world() {
    both "A B C" d "$STUBS"
    both "A B C" f "$STUBS/qmd" qmdstub; both "A B C" f "$STUBS/graphify" gfystub
    printf '%s\n' "$STUBS/qmd" "$STUBS/graphify" >>"$LB/seeded.list"
    mkdir -p "$STUBS"; printf '#!/bin/sh\nexit 0\n' >"$STUBS/qmd"; cp "$STUBS/qmd" "$STUBS/graphify"; chmod +x "$STUBS"/*
}
fresh; stub_world
run_assert all 0
has "all: a surviving qmd stub passes" 'CHECK stub too-much PASS user-stub-qmd-survives '
has "all: a surviving graphify stub passes" 'CHECK stub too-much PASS user-stub-graphify-survives '
has "all: the stubs are byte-identity checked as the user's own" 'CHECK identity identity PASS seeded:~/.local/bin/qmd '
hasnt "all: the stubs are not residue" 'CHECK residue [a-z-]+ FAIL [a-z]+:~/.local/bin'

fresh; stub_world; rm -f "$STUBS/qmd"
drop C "$STUBS/qmd"
run_assert all 0
has "all: a removed qmd stub is too-much" 'CHECK stub too-much FAIL user-stub-qmd-survives '
has "all: a removed qmd stub also fails the identity set" 'CHECK identity too-much FAIL seeded:~/.local/bin/qmd '
fresh; stub_world
run_assert core 0
hasnt "plain profile: no stub check" 'user-stub-'

# ---- 6. user-units-removed is judged against inventory A.
UD="$H/.config/systemd/user"
fresh
both "A B C" f "$UD/kept.service" unit                # at A, not in seeded.list: not himmel's
mkdir -p "$UD"; echo unit >"$UD/kept.service"
run_assert core 0
has "a user unit present at A is not 'left behind'" 'CHECK removal too-little PASS user-units-removed '
fresh
both "A B C" f "$UD/kept.service" unit; inv C f "$UD/himmel-qmd.service" new
mkdir -p "$UD"; echo unit >"$UD/kept.service"; echo new >"$UD/himmel-qmd.service"
run_assert core 0
has "a unit new since A is left behind" 'CHECK removal too-little FAIL user-units-removed .*himmel-qmd.service'

# ---- 7. cadence-crontab-armed-at-B (profile all only).
fresh
printf '17 3 * * * /bin/true # seed\n' >"$LB/seed-state/crontab.txt"; cp "$LB/seed-state/crontab.txt" "$FAKE_CRON"
cp "$LB/seed-state/crontab.txt" "$LB/crontab-B.txt"
run_assert all 0
has "all: no cadence line armed at B is a precondition failure" 'CHECK precondition precondition FAIL cadence-crontab-armed-at-B '
printf '5 * * * * /x/pipeline.sh # HIMMEL-Pipeline-Harvest\n' >>"$LB/crontab-B.txt"
run_assert all 0
has "all: a partly armed crontab (pipeline only) fails naming the missing cadences" 'CHECK precondition precondition FAIL cadence-crontab-armed-at-B — no armed line for: Qmd GraphMap'
printf '5 * * * * /x/qmd.sh # HIMMEL-Qmd-Reindex\n5 * * * * /x/gm.sh # HIMMEL-GraphMapAst-Luna\n' >>"$LB/crontab-B.txt"
run_assert all 0
has "all: every cadence armed at B passes the precondition" 'CHECK precondition precondition PASS cadence-crontab-armed-at-B '
run_assert core 0
hasnt "plain profile: no armed-at-B check" 'cadence-crontab-armed-at-B'

# ---- 8. seed-provenance.sh: the stubs, the telegram + bridge state, refusals.
seed() {  # <RT_PROFILE> — run the seed step from the scratch copy against the scratch HOME
    # GIT_TEMPLATE_DIR points nowhere: `git init` then creates no .git/hooks, as on the GitHub runners
    OUT=$(HOME="$H" PATH="$FAKEBIN:$PATH" GIT_TEMPLATE_DIR=/nonexistent-git-template HIMMEL_RT_GUEST=1 RT_PROFILE="$1" bash "$LB/seed-provenance.sh" 2>&1); RC=$?
}
fresh; rm -rf "$H"; mkdir -p "$H"
seed all
if [ "$RC" -eq 0 ]; then pass "seed (all) succeeds"; else fail_case "seed (all) succeeds (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/    /'; fi
for b in qmd graphify; do
    if [ -x "$H/.local/bin/$b" ]; then pass "seed (all): $b stub is executable"; else fail_case "seed (all): $b stub is executable"; fi
    if grep -qxF "$H/.local/bin/$b" "$LB/seeded.list"; then pass "seed (all): $b stub is in seeded.list"; else fail_case "seed (all): $b stub is in seeded.list"; fi
done
for f in .claude/channels/telegram/.env .claude/channels/telegram/access.json .claude/handover/bridge/state.json; do
    if [ -s "$H/$f" ]; then pass "seed: $f exists"; else fail_case "seed: $f exists"; fi
    if grep -qxF "$H/$f" "$LB/state.list"; then pass "seed: $f is in state.list"; else fail_case "seed: $f is in state.list"; fi
    if grep -qxF "$H/$f" "$LB/seeded.list"; then fail_case "seed: $f is NOT in seeded.list (purge removes it)"; else pass "seed: $f is not in seeded.list"; fi
done
for d in .claude/channels/telegram .claude/handover/bridge; do
    if grep -qxF "$H/$d" "$LB/state.list"; then pass "seed: $d dir is in state.list"; else fail_case "seed: $d dir is in state.list"; fi
done
if jq -e . "$H/.claude/channels/telegram/access.json" "$H/.claude/handover/bridge/state.json" >/dev/null 2>&1; then pass "seed: the JSON state files parse"; else fail_case "seed: the JSON state files parse"; fi

fresh; rm -rf "$H"; mkdir -p "$H"
seed core
if [ -e "$H/.local/bin/qmd" ] || [ -e "$H/.local/bin/graphify" ]; then fail_case "seed (core): no qmd/graphify stubs"; else pass "seed (core): no qmd/graphify stubs"; fi
if [ -s "$H/.claude/channels/telegram/.env" ]; then pass "seed (core): state is seeded under every profile"; else fail_case "seed (core): state is seeded under every profile"; fi

# refusals: existing telegram / bridge state, an existing qmd under all.
for t in .claude/channels/telegram/.env .claude/handover/bridge/state.json .claude/channels/telegram/access.json; do
    fresh; rm -rf "$H"; mkdir -p "$H/$(dirname "$t")"; echo mine >"$H/$t"
    seed core
    if [ "$RC" -eq 2 ] && grep -q "refusing: $H/$t already exists" <<<"$OUT"; then pass "seed refuses an existing $t"; else fail_case "seed refuses an existing $t (rc=$RC)"; fi
done
fresh; rm -rf "$H"; mkdir -p "$H/.local/bin"; echo mine >"$H/.local/bin/qmd"
seed all
if [ "$RC" -eq 2 ] && grep -q "refusing: $H/.local/bin/qmd already exists" <<<"$OUT"; then pass "seed (all) refuses an existing qmd"; else fail_case "seed (all) refuses an existing qmd (rc=$RC)"; fi
fresh; rm -rf "$H"; mkdir -p "$H/.local/bin"; echo mine >"$H/.local/bin/qmd"
seed core
if [ "$RC" -eq 0 ]; then pass "seed (core) leaves an existing qmd alone"; else fail_case "seed (core) leaves an existing qmd alone (rc=$RC)"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "test-assert-provenance: all passed"; exit 0; fi
echo "test-assert-provenance: $FAILED FAILED"
exit 1
