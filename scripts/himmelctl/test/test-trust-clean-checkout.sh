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

# .claude/settings.json is a PRIVATE_PATHS entry in
# scripts/lib/public-clone-paths.sh: the public mirror deliberately does not
# carry the operator's live hook wiring, so on a checkout cloned from the
# public repo this file is genuinely absent, not broken. Every case below
# pins preconditions of, or round-trips, that one tracked file. "Missing from
# the working tree" and "not tracked" are DIFFERENT claims (CR panel finding,
# codex-2, round 3): a private checkout where the file was simply deleted or
# moved hits the same `[ ! -f ]` branch as the genuine public-mirror omission,
# and a broken hook inventory would silently read as an intentional skip
# instead of failing. Skip only when the file is genuinely untracked (the
# public-mirror case the message names); fail, naming the real cause, when it
# is tracked but the working copy is missing.
#
# is_settings_tracked <repo-dir> <path> — prints tracked|untracked|unknown.
# NOTE: this function's body is intentionally duplicated verbatim in
# scripts/codex/test-codex-hook-parity.sh (same defect, same fix, CR round 3
# codex-1/codex-2) rather than shared from a lib — the brief fixing this
# restricted edits to those two files only, so extracting a shared
# scripts/lib/*.sh would itself be a scope violation. Keep the two bodies
# byte-identical if either ever needs to change.
#
# `git ls-files --error-unmatch` alone reads the INDEX, not HEAD (CR round 3,
# codex-1): a STAGED deletion (`git rm --cached`) removes the index entry
# while HEAD still carries it, so an index-only probe misreports a genuinely
# tracked, merely-mid-deletion file as untracked — the exact hole this probe
# exists to close, moved one step along rather than closed (proven in a
# scratch repo: commit the file, `git rm --cached` it, `ls-files
# --error-unmatch` -> rc=1 while `git cat-file -e HEAD:<path>` -> rc=0). A
# freshly `git add`ed-but-not-yet-committed file is the mirror case: present
# in the index, absent from HEAD, and still legitimately tracked. So
# "tracked" means present in EITHER the index OR HEAD.
#
# HEAD may not exist yet (a fresh repo with no commits) — `git rev-parse
# --verify -q HEAD` failing there is a LOOKUP FAILURE for the HEAD probe, not
# evidence the path is absent from HEAD, so it must never be read as "not in
# HEAD"; only the index answer counts while HEAD is unborn.
#
# Callers must not conflate "prints untracked" with "the probe could not run":
# only a probe that genuinely ran and confirmed absence on both index and HEAD
# may report "untracked" — an unresolved git/work-tree precondition prints
# "unknown" instead, and the caller (below) treats unknown the same as tracked
# (fail-closed toward FAIL, never toward SKIP).
#
# CR round 3, second pass (codex, Suggestion but correct): every probe above
# was written as `if git ...; then yes; else no; fi`, which collapsed "git
# ran and confirmed absence" and "git failed to run at all" into the same
# `no`/`unborn` branch — a corrupted index or an unreadable ref would then
# read as confirmed absence, and the elif below would call that "untracked".
# Fixed by keying off the exit STATUS: `git ls-files --error-unmatch` and
# `git rev-parse --verify -q ...` both use rc=1 for a genuine "not found" and
# any OTHER nonzero for a real lookup failure (corrupt index, unreadable
# object, garbage ref) — measured directly, not assumed: a truncated
# `.git/index` gives ls-files rc=128; a `.git/HEAD` overwritten with garbage
# gives rev-parse rc=128 even under `-q`; a corrupted tree/commit object
# reached via `HEAD:<path>` gives rc=128. Only rc=1 maps to a genuine `no`
# (or `unborn`, for the HEAD-exists check specifically); every other nonzero
# maps to `unknown`.
#
# One deliberate departure from the literal instrument this fix was scoped
# to: `git cat-file -e HEAD:<path>` does NOT give rc=1 for "not present" on
# this git (2.55.0) — measured directly: `cat-file -e HEAD:<nonexistent>`
# gives rc=128 ("fatal: path '<path>' does not exist in '<ref>'"), the SAME
# rc a corrupted tree object gives. rc alone cannot discriminate genuine
# absence from corruption through cat-file, so mapping rc==1 to `no` there
# would never fire for a normal untracked file and would silently break the
# SKIP path this whole fix protects. `git rev-parse --verify -q
# "HEAD:<path>"` is the equivalent existence check that DOES carry the
# needed rc=1-for-absence / rc=128-for-corruption split (measured: absent ->
# rc=1, corrupt tree -> rc=128, corrupt commit object reached via HEAD:path
# -> rc=128) — same question, an instrument that actually answers it.
is_settings_tracked() {
  local dir="$1" path="$2" in_index in_head rc
  command -v git >/dev/null 2>&1 || { echo unknown; return; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo unknown; return; }

  if git -C "$dir" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    in_index=yes
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then in_index=no; else in_index=unknown; fi
  fi

  if git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    if git -C "$dir" rev-parse --verify -q "HEAD:$path" >/dev/null 2>&1; then
      in_head=yes
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then in_head=no; else in_head=unknown; fi
    fi
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then in_head=unborn; else in_head=unknown; fi
  fi

  if [ "$in_index" = yes ] || [ "$in_head" = yes ]; then
    echo tracked
  elif [ "$in_index" = no ] && { [ "$in_head" = no ] || [ "$in_head" = unborn ]; }; then
    echo untracked
  else
    echo unknown
  fi
}

if [ ! -f "$settings" ]; then
  if [ "$(is_settings_tracked "$root" .claude/settings.json)" = untracked ]; then
    echo "[SKIP] test-trust-clean-checkout.sh — no tracked .claude/settings.json at $settings (PRIVATE_PATHS entry in scripts/lib/public-clone-paths.sh; the public mirror deliberately omits the operator's live hook wiring, so this suite has no shipped settings file to pin or round-trip)."
    exit 0
  fi
  echo "FAIL - .claude/settings.json is tracked (or its tracked-ness could not be confirmed) at $settings but missing from the working tree - this is a broken or dirty checkout, not the public-mirror omission (PRIVATE_PATHS only omits the file from the PUBLIC clone; a private checkout's git history always carries it). Restore it, e.g. 'git checkout -- .claude/settings.json', before re-running this suite." >&2
  exit 1
fi

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

# HIMMEL-2756: adopters cannot enable a recorder the portable core does not
# ship. Both verbs must explain that limit without changing their exit codes
# or writing settings; removing dead wiring remains supported.
adopted="$work/adopted"
adopted_w="$(winpath "$adopted")"
mkdir -p "$adopted/.claude"
printf '{}\n' > "$adopted/.claude/settings.json"
cp "$adopted/.claude/settings.json" "$work/adopted-original.json"
for verb in on status off; do
  out=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache/luna-config.json")" CLAUDE_PROJECT_DIR="$adopted_w" HIMMELCTL_REPO_ROOT="$root_w" "$node_bin" "$wizard" trust "$verb" 2>&1)
  rc=$?
  expected_rc=0
  [ "$verb" = on ] && expected_rc=1
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL - adopted project trust $verb exited $rc (expected $expected_rc)"
    fail=1
  fi
  if [ "$verb" != off ]; then
    for message in 'not part of the portable core yet' 'HIMMEL-2756' 'himmel checkout'; do
      if ! grep -qF "$message" <<< "$out"; then
        echo "FAIL - adopted project trust $verb omits: $message"
        fail=1
      fi
    done
  fi
  if ! cmp -s "$work/adopted-original.json" "$adopted/.claude/settings.json"; then
    echo "FAIL - adopted project trust $verb modified settings"
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "ok - shipped .claude/settings.json satisfies both trust preconditions; trust status rc=0; off; on->off round-trips the unwired baseline byte-for-byte"
