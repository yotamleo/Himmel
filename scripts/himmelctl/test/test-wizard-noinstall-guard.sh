#!/usr/bin/env bash
# test-wizard-noinstall-guard.sh — the "no new install logic" guard
# (HIMMEL-887 T6, Draft-A R1). Statically asserts bin.js's ONLY side effects
# are: (a) read answers, (b) write the profile cache, (c) exec the ENUMERATED
# existing scripts — never a NEW script, and never a reimplementation of
# plugin-install / hook-wire / settings-merge logic of its own.
#
# Covers:
#   A. every *.sh/*.ps1 script-literal referenced anywhere in bin.js is a
#      member of the documented allow-set (script-target guard).
#   B. NEGATIVE proof the guard actually constrains: removing ANY single name
#      from the allow-set makes case A's checker fail.
#   C. bin.js calls fs.writeFileSync exactly once (the profile-cache write in
#      writeCache()) — no other file the wizard itself writes.
#   D. bin.js requires ONLY node builtins (fs/os/path/readline/child_process)
#      — zero npm deps, and no new lib smuggled in to reimplement
#      plugin-install/hook-wire/settings-merge logic.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# The documented allow-set (brief T6): every script bin.js is permitted to
# shell out to. bin.js's own comments name the non-script exec surfaces this
# guard does NOT enumerate here (the platform pkg-mgr via `bash -c` [T1] and
# the documented `claude plugin ...` commands [T4.5/config]) — those never
# carry a .sh/.ps1/.mjs literal, so extract_script_targets() below can't
# confuse them with a NEW script reference.
#
# HIMMEL-758: set-env-var.sh (the `config` HIMMEL_INITIATIVE writer) and
# set-lane-override.mjs (the `config` lanes.local.json writer) added — both
# are existing-primitive shell-outs, same class as set-handover-dir.sh above,
# not a reimplementation of the write logic inline in bin.js.
#
# HIMMEL-893/1192: himmel-update.sh — the existing dependency-chain update
# engine `himmelctl update` (deriveUpdateCommand) delegates to. Same class:
# an enumerated existing-script shell-out, not new inline logic. It was
# omitted when `update` landed (#1279), leaving this guard red; added here.
allow_full="$work/allow-full.txt"
cat > "$allow_full" <<'NAMES'
preflight-adopter.sh
setup.sh
setup.ps1
adopt.sh
wire-luna-vault.sh
luna-upgrade-all.sh
set-handover-dir.sh
uninstall.sh
uninstall.ps1
himmel-update.sh
set-env-var.sh
set-lane-override.mjs
NAMES

# extract_script_targets — every 'name.sh' / "name.sh" / 'name.ps1' /
# 'name.mjs' quoted literal referenced anywhere in bin.js (source text, so a
# rogue reference even inside a comment still trips the guard — a
# conservative trip-wire). .mjs joined HIMMEL-758 (set-lane-override.mjs).
extract_script_targets() {
  grep -oE "['\"][A-Za-z0-9_.-]+\.(sh|ps1|mjs)['\"]" "$wizard" | tr -d "'\"" | sort -u
}

# check_allow_set <allow-set-file> — 0 iff every script target bin.js
# references is present in <allow-set-file>; 1 on the first name that isn't.
check_allow_set() {
  local allow_file="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" "$allow_file" || return 1
  done < <(extract_script_targets)
  return 0
}

# ── Case A: the guard passes against the full, documented allow-set ────────
if check_allow_set "$allow_full"; then
  echo "ok: caseA bin.js's script-exec surface is fully covered by the documented allow-set"
else
  actual=$(extract_script_targets)
  fail "caseA: bin.js references a script NOT in the allow-set -- got: $actual"
fi

# ── Case B: NEGATIVE -- dropping any single allowed name breaks the guard ──
# Load the allow-set into an array ONCE (bash 3.2-safe: no mapfile) so the
# per-name reduced-set below never re-reads $allow_full inside its own loop.
allow_names=()
while IFS= read -r _n; do
  [ -n "$_n" ] && allow_names+=("$_n")
done < "$allow_full"

for name in "${allow_names[@]}"; do
  reduced="$work/allow-reduced-$name.txt"
  : > "$reduced"
  for other in "${allow_names[@]}"; do
    [ "$other" = "$name" ] && continue
    printf '%s\n' "$other" >> "$reduced"
  done
  if check_allow_set "$reduced"; then
    fail "caseB: dropping '$name' from the allow-set should make the guard fail, but it still passed (guard does not constrain)"
  fi
done
echo "ok: caseB dropping any single allow-set name breaks the guard (proves it constrains)"

# ── Case C: the ONLY file write is the profile cache (writeCache) ──────────
writes=$(grep -c 'fs\.writeFileSync' "$wizard")
[ "$writes" -eq 1 ] \
  || fail "caseC: expected exactly 1 fs.writeFileSync call (the profile cache), got $writes"
grep -q 'fs.writeFileSync(cachePath()' "$wizard" \
  || fail "caseC: the one fs.writeFileSync call should target cachePath() (the profile cache)"
echo "ok: caseC bin.js's only fs.writeFileSync is the profile-cache write"

# ── Case D: only node builtins are required -- zero npm deps ───────────────
required=$(grep -oE "require\('[a-zA-Z_/-]+'\)" "$wizard" | sed -E "s/require\('(.*)'\)/\1/" | sort -u)
allow_modules="child_process
fs
os
path
readline"
[ "$required" = "$allow_modules" ] \
  || fail "caseD: bin.js requires modules beyond the node-builtin allow-set -- got: $required"
echo "ok: caseD bin.js requires only node builtins (fs/os/path/readline/child_process) -- zero npm deps"

echo "PASS"
