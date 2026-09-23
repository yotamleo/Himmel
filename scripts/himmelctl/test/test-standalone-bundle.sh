#!/usr/bin/env bash
# test-standalone-bundle.sh — hermetic coverage for HIMMEL-3312 S13's bundle
# writer, launcher fallback and standalone.js (plan
# HIMMEL-3332-install-provenance-plan.md S13, design
# HIMMEL-3312-standalone-undo.md §3, §6, §7). Drives the REAL bin.js through
# `install --from-profile` (only scripts/adopt.sh + scripts/setup.sh are
# stubbed) against a fixture tree built from `git archive HEAD`, so
# writeStandaloneBundle() copies real files from a real closure. Covers the
# plan's RED list (bundle written, launcher falls back once the clone is
# gone, `status` also falls back and reports "not present") plus four
# additional assertions: 0700 dir / 0600 file perms, symlinked bundle dir
# refused and left alone, a higher-version bundle.json not overwritten, and
# exactly one `tree` ledger row per writing session.
set -uo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
command -v node >/dev/null 2>&1 || fail "node required"
node_bin=$(command -v node)
bash_bin=$(command -v bash)

work=$(mktemp -d -t standalone-bundle.XXXXXX) || fail "mktemp failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# ── A: install builds a real fixture tree, writes the launcher AND the ──────
# ── standalone bundle, with correct marker/perms and one ledger row. ────────
td="$work/caseA"
mkdir -p "$td/himmel" "$td/bin" "$td/home" "$td/prov" "$td/cache"
git archive HEAD | tar -x -C "$td/himmel"
printf '#!/usr/bin/env bash\nexit 0\n' > "$td/himmel/scripts/adopt.sh"
chmod +x "$td/himmel/scripts/adopt.sh"
# shellcheck disable=SC2016 # $INSTALL_CALL_LOG must expand when setup.sh RUNS, not now
printf '#!/usr/bin/env bash\nprintf "setup\\n" >> "$INSTALL_CALL_LOG"\n' > "$td/himmel/scripts/setup.sh"
chmod +x "$td/himmel/scripts/setup.sh"
cat > "$td/profile.json" <<'JSON'
{
  "role": "contributor",
  "tier": "standard",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON

run_install() {
  HOME="$td/home" USERPROFILE="$td/home" \
    HIMMELCTL_BASH="$bash_bin" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_CACHE_DIR="$td/cache" HIMMEL_LUNA_CONFIG_PATH="$td/cache-luna-config.json" \
    HIMMELCTL_REPO_ROOT="$td/himmel" \
    HIMMELCTL_BIN_DIR="$td/bin" HIMMELCTL_SHIM_PLATFORM=linux \
    HIMMEL_PROVENANCE_DIR="$td/prov" \
    INSTALL_CALL_LOG="$td/install-calls.log" \
    "$node_bin" "$td/himmel/scripts/himmelctl/bin.js" install --from-profile "$td/profile.json" </dev/null 2>&1
}
set +e
out=$(run_install); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseA: install exited $rc: $out"
[ "$(cat "$td/install-calls.log")" = 'setup' ] || fail "caseA: install executor did not run"
[ -x "$td/bin/himmelctl" ] || fail "caseA: launcher missing"
echo "ok: caseA install succeeds against a real archived fixture tree"

bundle_dir="$td/prov/uninstall"
bundle_json="$bundle_dir/bundle.json"
[ -f "$bundle_json" ] || fail "caseA: bundle.json missing at $bundle_json: $out"
grepq "$out" 'standalone uninstaller' || grepq "$(cat "$bundle_json")" 'himmel-standalone-uninstaller/1' \
  || fail "caseA: no evidence the bundle was written: $out"
grep -Fq 'himmel-standalone-uninstaller/1' "$bundle_json" || fail "caseA: bundle.json missing its marker"
echo "ok: caseA writes a marked standalone bundle"

dir_perm=$(stat -c '%a' "$bundle_dir")
file_perm=$(stat -c '%a' "$bundle_json")
[ "$dir_perm" = '700' ] || fail "caseA: bundle dir perms $dir_perm, want 700"
[ "$file_perm" = '600' ] || fail "caseA: bundle.json perms $file_perm, want 600"
echo "ok: caseA bundle dir is 0700, bundle.json is 0600"

row_count=$(grep -c '"manifest_row":"standalone-uninstaller"' "$td/prov/provenance.jsonl")
[ "$row_count" -eq 1 ] || fail "caseA: expected exactly one standalone-uninstaller ledger row, got $row_count"
echo "ok: caseA writes exactly one tree ledger row for this session"

# ── B: RED (then fixed) — once the clone is gone, the launcher falls back ───
# ── to the bundle's standalone.js: `uninstall --dry-run` works, `status` ────
# ── reports the checkout as not present. ─────────────────────────────────────
rm -rf "$td/himmel"

run_fallback() {
  # cwd must be neutral: uninstall.sh's "current project" step resolves off
  # the invoking directory, and this test's own worktree is a real himmel
  # checkout unrelated to the scratch fixture -- run from $td/home instead so
  # dry-run reports on the fixture's identity, not the leg's own repo.
  (cd "$td/home" && HOME="$td/home" USERPROFILE="$td/home" HIMMEL_PROVENANCE_DIR="$td/prov" \
    node "$td/bin/himmelctl.js" "$@" 2>&1)
}
set +e
dry=$(run_fallback uninstall --dry-run); dry_rc=$?
status_out=$(run_fallback status); status_rc=$?
set -e
[ "$dry_rc" -eq 0 ] || fail "caseB: uninstall --dry-run rc=$dry_rc after clone deleted: $dry"
grepq "$dry" 'standalone uninstaller' || fail "caseB: dry-run did not report the standalone uninstaller: $dry"
[ "$status_rc" -eq 1 ] || fail "caseB: status rc=$status_rc after clone deleted (want 1): $status_out"
grepq "$status_out" 'is not present' || fail "caseB: status did not report the checkout as not present: $status_out"
echo "ok: caseB launcher falls back to standalone.js once the clone is gone (dry-run works, status reports not-present)"

# ── C: a symlinked bundle dir is refused and left exactly as a symlink; ─────
# ── writeStandaloneBundle returns false. ─────────────────────────────────────
provC="$work/caseC-prov"
mkdir -p "$provC" "$work/caseC-elsewhere"
ln -s "$work/caseC-elsewhere" "$provC/uninstall"
out=$(HIMMEL_PROVENANCE_DIR="$provC" HIMMELCTL_SHIM_PLATFORM=linux \
  "$node_bin" -e "const b=require('$repo_root/scripts/himmelctl/lib/standalone-bundle.js'); process.stdout.write(String(b.writeStandaloneBundle('$repo_root')));")
[ "$out" = 'false' ] || fail "caseC: writeStandaloneBundle should refuse a symlinked bundle dir, got: $out"
[ -L "$provC/uninstall" ] || fail "caseC: symlink was replaced instead of left alone"
readlink "$provC/uninstall" | grep -Fq 'caseC-elsewhere' || fail "caseC: symlink target changed"
echo "ok: caseC a symlinked bundle dir is refused and left untouched"

# ── D: a bundle.json with a higher version is never downgraded. ─────────────
provD="$work/caseD-prov"
mkdir -p "$provD"
rc1=$(HIMMEL_PROVENANCE_DIR="$provD" HIMMELCTL_SHIM_PLATFORM=linux \
  "$node_bin" -e "const b=require('$repo_root/scripts/himmelctl/lib/standalone-bundle.js'); process.stdout.write(String(b.writeStandaloneBundle('$repo_root')));")
[ "$rc1" = 'true' ] || fail "caseD: first write should succeed, got: $rc1"
node -e "
const fs = require('fs');
const p = '$provD/uninstall/bundle.json';
const meta = JSON.parse(fs.readFileSync(p, 'utf8'));
meta.version = '99.0.0';
fs.writeFileSync(p, JSON.stringify(meta, null, 2) + '\n');
"
rc2=$(HIMMEL_PROVENANCE_DIR="$provD" HIMMELCTL_SHIM_PLATFORM=linux \
  "$node_bin" -e "const b=require('$repo_root/scripts/himmelctl/lib/standalone-bundle.js'); process.stdout.write(String(b.writeStandaloneBundle('$repo_root')));")
[ "$rc2" = 'false' ] || fail "caseD: second write should be refused as a downgrade, got: $rc2"
grep -Fq '"version": "99.0.0"' "$provD/uninstall/bundle.json" \
  || fail "caseD: the higher version was overwritten"
echo "ok: caseD a higher-version bundle.json is never downgraded"

echo
echo "ALL PASS"
