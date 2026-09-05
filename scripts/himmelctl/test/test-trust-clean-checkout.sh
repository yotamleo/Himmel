#!/usr/bin/env bash
# test-trust-clean-checkout.sh — `himmelctl trust on|status|off` succeed in a
# clean himmel checkout (HIMMEL-2465).
#
# WHY: wire-trust-hooks.mjs fails closed on two preconditions — (1) no entry
# may MIX a shadow-ledger command with other hooks, (2) the settings file must
# round-trip byte-for-byte through its fixed 2-space serializer, or `--off`
# could not restore it. Both guards are correct; the bug was that the TRACKED
# .claude/settings.json tripped both, so a documented top-level verb returned
# rc=1 out of the box (found by the HIMMEL-2457 v1 Linux matrix). This suite
# pins the shipped file to both preconditions, then proves the round trip on a
# scratch copy: off; on->off round-trips the unwired baseline byte-for-byte.
set -uo pipefail

# shellcheck source=_hermetic-home.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_hermetic-home.sh"

root="$(git rev-parse --show-toplevel)"
root_w="$(winpath "$root")"
node_bin="${NODE_BIN:-node}"
wizard="$root/scripts/himmelctl/bin.js"
settings="$root/.claude/settings.json"
settings_w="$(winpath "$settings")"
work=$(mktemp -d "${TMPDIR:-/tmp}/trust-clean-checkout.XXXXXX") || { echo "FAIL - mktemp -d failed"; exit 1; }
trap 'rm -rf "$work"' EXIT
fail=0

[ -f "$settings" ] || { echo "FAIL - no tracked settings at $settings"; exit 1; }

# Snapshot the tracked file BEFORE any trust invocation — the final
# never-written check compares against this.
cp "$settings" "$work/original.json"
# Now that a snapshot exists, upgrade the cleanup trap: restore the tracked
# file first if anything left it dirty (including a mid-suite crash), THEN
# remove the scratch dir — so the checkout is never left modified.
trap 'cmp -s "$settings" "$work/original.json" || cp "$work/original.json" "$settings"; rm -rf "$work"' EXIT

# The recorder's capability handshake and any hook it might run must never
# touch the operator's real ledger.
mkdir -p "$work/ledger"
HIMMEL_TRUST_LEDGER_DIR="$(winpath "$work/ledger")"
export HIMMEL_TRUST_LEDGER_DIR

# Every real bin.js `trust` invocation below pins its own cache dir + luna
# config path — test-suite-hermeticity.sh's check_dir() flags any bin.js
# spawn missing HIMMELCTL_CACHE_DIR/HIMMEL_LUNA_CONFIG_PATH as a leak onto the
# operator's real home (Windows: os.homedir() follows USERPROFILE, not HOME,
# so this is not optional cosmetics).
cache="$work/himmelctl-cache"
mkdir -p "$cache"

# 1. Precondition A — no mixed entry. Mirrors the guard: an entry carrying a
#    shadow-ledger command must carry ONLY that command.
# shellcheck disable=SC2016
mixed=$("$node_bin" -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const out = [];
  for (const [ev, list] of Object.entries(s.hooks || {})) {
    (list || []).forEach((e, i) => {
      const inner = (e && e.hooks) || [];
      const ledger = inner.filter(h => typeof h.command === "string" && h.command.includes("/scripts/trust/shadow-ledger.mjs"));
      if (ledger.length && inner.length > 1) out.push(`hooks.${ev}[${i}]`);
    });
  }
  process.stdout.write(out.join(" "));
' "$settings_w")
if [ -n "$mixed" ]; then
  echo "FAIL - tracked settings.json mixes a shadow-ledger command with other hooks in: $mixed"
  fail=1
fi

# 2. Precondition B — byte-stable round trip through the wiring script's own
#    serializer (JSON.stringify(_, null, 2) + "\n").
# shellcheck disable=SC2016
if ! "$node_bin" -e '
  const fs = require("fs");
  const raw = fs.readFileSync(process.argv[1], "utf8");
  const re = JSON.stringify(JSON.parse(raw), null, 2) + "\n";
  if (raw !== re) {
    const a = raw.split("\n"), b = re.split("\n");
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      if (a[i] !== b[i]) { console.error(`first divergence at line ${i + 1}: ${JSON.stringify(a[i])}`); break; }
    }
    process.exit(1);
  }
' "$settings_w"; then
  echo "FAIL - tracked settings.json does not round-trip byte-for-byte through the 2-space serializer"
  fail=1
fi

# 3. `trust status` returns 0 against the checkout itself (--check writes nothing).
out=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache/luna-config.json")" CLAUDE_PROJECT_DIR="$root_w" HIMMELCTL_REPO_ROOT="$root_w" "$node_bin" "$wizard" trust status 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL - himmelctl trust status exited $rc in a clean checkout:"
  printf '%s\n' "$out" | sed 's/^/  /'
  fail=1
fi
cmp -s "$settings" "$work/original.json" \
  || { echo "FAIL - trust status modified the tracked settings.json (--check must write nothing); restored from snapshot"; cp "$work/original.json" "$settings"; fail=1; }

# 4. The shipped settings.json ships WIRED, so the script's reversibility
#    claim — `on` then `off` restores the file byte-for-byte — is a claim
#    about an UNWIRED baseline, not about the wired file as tracked. Produce
#    that baseline with a first `off`, then prove `on -> off` round-trips it.
#    `off -> on` from a WIRED file is NOT byte-stable by design (an emptied
#    event key is deleted, and `install()` re-adds it — and re-appends any
#    array entry it repairs — at the END rather than in its original
#    position), so that direction is deliberately not asserted here. The copy
#    carries the recorder so assertRecorderPresent/Capable pass; the tracked
#    checkout is never written.
proj="$work/proj"
proj_w="$(winpath "$proj")"
mkdir -p "$proj/.claude" "$proj/scripts/trust"
cp "$settings" "$proj/.claude/settings.json"
cp "$root"/scripts/trust/*.mjs "$proj/scripts/trust/"

out=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache/luna-config.json")" CLAUDE_PROJECT_DIR="$proj_w" HIMMELCTL_REPO_ROOT="$root_w" "$node_bin" "$wizard" trust off 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL - himmelctl trust off exited $rc on a copy of the shipped settings:"
  printf '%s\n' "$out" | sed 's/^/  /'
  fail=1
fi
# A vacuous pass is the failure mode this suite must not have: if `off` left
# the copy byte-identical to the wired original, it unwired nothing, and the
# round trip below would then trivially "restore" a baseline that was never
# actually distinct from the wired file.
if cmp -s "$work/original.json" "$proj/.claude/settings.json"; then
  echo "FAIL - trust off made no change to the shipped settings.json (nothing was unwired)"
  fail=1
fi
cp "$proj/.claude/settings.json" "$work/unwired.json"

out=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache/luna-config.json")" CLAUDE_PROJECT_DIR="$proj_w" HIMMELCTL_REPO_ROOT="$root_w" "$node_bin" "$wizard" trust on 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL - himmelctl trust on exited $rc after trust off:"
  printf '%s\n' "$out" | sed 's/^/  /'
  fail=1
fi
# Same non-vacuity guard, for the other direction: `on` must actually wire
# something back in, or the `off` below would trivially "restore" a file it
# never changed.
if cmp -s "$work/unwired.json" "$proj/.claude/settings.json"; then
  echo "FAIL - trust on made no change to the unwired settings.json (nothing was wired)"
  fail=1
fi

out=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache/luna-config.json")" CLAUDE_PROJECT_DIR="$proj_w" HIMMELCTL_REPO_ROOT="$root_w" "$node_bin" "$wizard" trust off 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL - himmelctl trust off exited $rc after trust on:"
  printf '%s\n' "$out" | sed 's/^/  /'
  fail=1
fi
if ! cmp -s "$work/unwired.json" "$proj/.claude/settings.json"; then
  echo "FAIL - trust on -> off did not restore the unwired baseline byte-for-byte"
  fail=1
fi
if ! cmp -s "$settings" "$work/original.json"; then
  echo "FAIL - the tracked settings.json was modified by the suite (must never be written); restored from snapshot"
  cp "$work/original.json" "$settings"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "ok - shipped .claude/settings.json satisfies both trust preconditions; trust status rc=0; off; on->off round-trips the unwired baseline byte-for-byte"
