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
#   C. bin.js calls fs.writeFileSync exactly five times: the profile-cache
#      write (writeCache()), the named install-profile save
#      (offerSaveProfile()), the PATH-launcher shim tmp write
#      (writeMarkedLauncher()), and the two PHI guard-input writes
#      (mergePhiRoot(), the .salus marker) — no other file the wizard itself
#      writes.
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
#
# HIMMEL-1446: himmelctl.ps1 — NOT a script bin.js shells out to; it is the
# PATH-launcher FILENAME the shim (writeMarkedLauncher/removeMarkedLauncher)
# writes/removes in the user's binDir. Listed here only because
# extract_script_targets()'s conservative quoted-*.ps1 scan catches the
# literal — the trip-wire still fires on any genuinely-new shell-out script.
#
# HIMMEL-1551: wire-trust-hooks.mjs — the `trust on|off|status` verb's
# existing-primitive shell-out (cmdTrust -> scripts/trust/wire-trust-hooks.mjs
# via spawnSync), same class as set-lane-override.mjs above, not a
# reimplementation of the trust-wiring logic inline in bin.js.
#
# HIMMEL-2033's remove-retired-plugin.sh shell-out (offerRetiredPluginRemoval)
# was briefly dropped when pluginSet=full's ENABLE step was retired
# (HIMMEL-2304), then restored decoupled from that step (CR round 3
# [codex-1]): a legacy pluginSet=full --from-profile cache is exactly the
# population most likely to still carry the retired plugin, so
# applyPluginStep() still offers its removal for that answer alone, even
# though the enable step itself stays an unconditional no-op.
#
# HIMMEL-2537: check-user-slug.sh — the USER_SLUG step setup.sh's [0.5/9]
# runs, REPLAYED by userSlugState() so the install summary can name the step
# when it was left undone. Same class as the shell-outs above: bin.js invokes
# the existing primitive and reads its exit status; the resolution logic stays
# in scripts/lib/user-slug.sh, none of it reimplemented here.
allow_full="$work/allow-full.txt"
cat > "$allow_full" <<'NAMES'
check-user-slug.sh
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
himmelctl.ps1
set-env-var.sh
set-lane-override.mjs
wire-trust-hooks.mjs
remove-retired-plugin.sh
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

# ── Case C: the only DIRECT file writes are the documented ones ────────────
# The profile cache (writeCache -> cachePath()); the named install-profile
# save (offerSaveProfile -> tmpDest); since HIMMEL-1446, the PATH-launcher
# shim's atomic tmp write (writeMarkedLauncher); and since HIMMEL-2347, the
# two PHI guard-INPUT writes. No other file write — keeps the wizard from
# reimplementing plugin-install/hook-wire/settings-merge logic inline. Every
# site is pinned below so a SIXTH, undocumented write still trips the guard
# (count + site match).
#
# Why the two HIMMEL-2347 writes belong in this allow-set rather than being a
# reason to fail: they are not install/wiring logic reimplemented inline, they
# are the guard inputs themselves. The PHI guards key on
# ~/.config/claude-glm/phi-roots and a `.salus` marker, and NOTHING created
# either — so every launcher PHI guard was silently inert (HIMMEL-1773/1767).
# Materializing those two files IS that ticket's structural fix; there is no
# other component to delegate them to. Both are narrow by construction: the
# phi-roots write is append-if-absent and never truncates (a non-ENOENT read
# error throws rather than rewriting), and the marker write is exclusive-
# create ('wx'), so it can never overwrite an existing marker's contents.
#
# Why the offerSaveProfile() tmpDest write also belongs here rather than being
# a reason to fail: it is not install/wiring logic reimplemented inline
# either — it is the wizard saving its OWN output artifact (the named
# `<name>.install-profile.json` a later `--from-profile` run reads back), the
# same class of self-output as the profile cache above. It is narrow by
# construction too: the temp is created exclusively ('wx' — fails rather than
# clobbering if it already exists) in the same directory as `dest`, then
# renameSync'd onto `dest` atomically, which cannot be redirected through a
# symlink; the code refuses outright if `dest` is already a symlink; and
# `dest` itself is left untouched until the rename, so a failure at any point
# up to and including the write leaves a previously-saved profile intact.
writes=$(grep -c 'fs\.writeFileSync' "$wizard")
[ "$writes" -eq 5 ] \
  || fail "caseC: expected exactly 5 fs.writeFileSync calls (profile cache + install-profile save + PATH-launcher tmp + phi-roots + .salus marker), got $writes"
grep -q 'fs.writeFileSync(cachePath()' "$wizard" \
  || fail "caseC: missing the profile-cache write (cachePath())"
# Pinned on the FULL call shape (destination var + bytes var + the exclusive-
# create flag), not a bare `fs.writeFileSync(tmpDest,` prefix -- same
# name-collision reasoning as the PATH-launcher pin below: a prefix-only pin
# would silently re-match if some OTHER write later also targets a variable
# named `tmpDest`.
grep -q "fs.writeFileSync(tmpDest, bytes, { flag: 'wx' })" "$wizard" \
  || fail "caseC: missing the install-profile save write (offerSaveProfile tmpDest, HIMMEL-2483), or its call shape changed"
# Pinned on the FULL call shape, not the bare `fs.writeFileSync(tmp,` prefix:
# since HIMMEL-2347 fix 3, mergePhiRoot() also writes to a variable named
# `tmp`, so the short prefix matched EITHER site and this pin silently stopped
# being site-specific. The count check alone would not cover that — it only
# catches a write disappearing, not two pins collapsing onto one site.
grep -q "fs.writeFileSync(tmp, contents, 'utf8')" "$wizard" \
  || fail "caseC: missing the PATH-launcher shim write (writeMarkedLauncher tmp, HIMMEL-1446)"
# HIMMEL-2347 CR fix 3: mergePhiRoot() now writes to a sibling tmp file and
# rename()s it over the target (atomic write, torn-write fix) instead of
# writing `file` directly — the pin is updated to the new call shape
# deliberately, not bumped blindly; the call COUNT is unchanged (still one
# fs.writeFileSync site for this write, just now targeting `tmp`).
grep -q "fs.writeFileSync(tmp, lines.join('" "$wizard" \
  || fail "caseC: missing the phi-roots merge write (mergePhiRoot, HIMMEL-2347 — now via tmp+rename, HIMMEL-2347 CR fix 3)"
grep -q "fs.writeFileSync(markerPath, '', { flag: 'wx' })" "$wizard" \
  || fail "caseC: missing the .salus marker write, or it is no longer exclusive-create 'wx' (HIMMEL-2347 — a plain write would truncate an existing marker)"
echo "ok: caseC bin.js's only fs.writeFileSync calls are the profile cache, the install-profile save, the PATH-launcher shim, and the two PHI guard inputs"

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
