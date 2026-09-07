#!/usr/bin/env bash
# update-marketplaces.sh — re-sync the installed Claude Code marketplaces that
# NOTHING else updates (HIMMEL-2134).
#
# WHY: the 2026-08-26 full drift sweep (issue #518) found `mkt-manual` rows
# sitting BEHIND with no repair path on either side of the fence:
#
#   * `scripts/check-plugin-drift.sh` DETECTS them — it discovers every entry in
#     ~/.claude/plugins/known_marketplaces.json and reports `mkt:<name>` rows
#     tiered `mkt-auto` (autoUpdate true — Claude Code refreshes them itself) or
#     `mkt-manual` (autoUpdate falsy — nothing refreshes them, ever).
#   * `.claude/commands/drift-fix.md` step 2 explicitly says to IGNORE `mkt:*`
#     rows, because a marketplace re-sync is not a version bump and produces no
#     repo diff, so the drift leg's PR flow has nothing to carry.
#   * `scripts/himmel-update.sh`'s chain item 2 re-syncs exactly ONE marketplace,
#     `himmel` — a `directory` source, where autoUpdate only re-reads the on-disk
#     dir, which is why that step exists at all.
#
# So a `mkt-manual` marketplace was detected nightly and repaired never. This
# script is the repair, and it is deliberately the ONLY place the recipe lives:
# himmel-update.sh's advisory block calls it (machine-local catch-up) and the
# /drift-fix runbook calls it (the sweep's own repair leg). One implementation,
# two front doors — the same shape himmel-update.sh already has with himmelctl.
#
# SCOPE — `mkt-manual` ONLY, and never `himmel`:
#   * autoUpdate:true rows are refreshed by Claude Code at session start.
#     Re-updating them here would be N wasted network calls per run.
#   * `himmel` is chain item 2 of himmel-update.sh, where a failure MUST abort
#     the update (a stale himmel marketplace means stale hooks + commands). Here
#     a failure must NOT abort anything. Keeping the two apart preserves that
#     severity split rather than flattening it. `himmel` is autoUpdate:true so
#     the tier filter already excludes it; the explicit skip below makes that
#     independent of a future known_marketplaces.json edit.
#
# FAILURE ISOLATION is the whole point: one marketplace failing to update must
# never stop the others. Every row is attempted; failures are collected and
# reported together at the end.
#
# Usage:
#   bash scripts/upstreams/update-marketplaces.sh [--check]
#
#   --check   list the rows that WOULD be updated; run no update, mutate nothing.
#
# Test seams (used by test-update-marketplaces.sh):
#   DRIFT_KNOWN_MARKETPLACES   path to known_marketplaces.json (same env name
#                              check-plugin-drift.sh uses — one seam, not two)
#   HIMMEL_UPDATE_CLAUDE_BIN   claude binary override (same env name
#                              himmel-update.sh uses)
#
# Exit codes:
#   0  every selected row updated, or nothing selected (a no-op is a success)
#   1  at least one row FAILED to update (the others were still attempted)
#   2  cannot run: no claude CLI, no python3, or an unreadable/malformed
#      known_marketplaces.json. Distinct from 1 on purpose — "could not look"
#      is not "looked and something is broken".
#
# Bash 3.2 compatible (no mapfile, no associative arrays, no `wait -n`).

set -uo pipefail

CLAUDE_BIN="${HIMMEL_UPDATE_CLAUDE_BIN:-claude}"

# Cross-platform user-home resolution (HIMMEL-645): on Windows Git-Bash the MSYS
# $HOME can differ from where ~/.claude actually lives, so prefer USERPROFILE.
# Same resolution check-plugin-drift.sh's own consumers use.
_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

KNOWN_MKTS="${DRIFT_KNOWN_MARKETPLACES:-$(_user_home)/.claude/plugins/known_marketplaces.json}"

mode="apply"
case "${1:-}" in
    "") ;;
    --check|--dry-run) mode="check" ;;
    *)
        echo "usage: bash scripts/upstreams/update-marketplaces.sh [--check]" >&2
        exit 2
        ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    echo "update-marketplaces: python3 not available — cannot parse known_marketplaces.json." >&2
    exit 2
fi

if [ ! -f "$KNOWN_MKTS" ]; then
    # NOT "nothing to update" (CR round 4, codex-3): that is the rc-0
    # empty-selection wording, and reusing it on an rc-2 path made a
    # could-not-look read like a successful empty run — the exact distinction
    # this script's exit codes exist to keep.
    echo "update-marketplaces: CANNOT RUN — no known_marketplaces.json at $KNOWN_MKTS; the installed marketplaces were NOT checked." >&2
    exit 2
fi

# Emit one NAME per line for every manual-tier row. A malformed file raises,
# python3 exits non-zero, and we report rc 2 rather than treating "no rows" as
# "nothing to do" — silence from a parse failure must never read as clean.
#
# `himmel` is skipped here as well as by the autoUpdate filter (see the header):
# two independent reasons, so a future known_marketplaces.json that flips
# himmel's autoUpdate to false cannot silently pull it into this loop.
rows="$(python3 - "$KNOWN_MKTS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
# A registry that parses but is not a name->entry mapping (a top-level list, a
# scalar) is MALFORMED, not empty. Raising routes it to rc 2 — silently
# yielding zero rows would report "nothing to update" on a broken file, which
# is the one thing this script must never do.
if not isinstance(data, dict):
    raise ValueError('known_marketplaces.json is not an object')
mkts = data.get('marketplaces', data)
if not isinstance(mkts, dict):
    raise ValueError('known_marketplaces.json "marketplaces" is not an object')
for name, info in sorted(mkts.items()):
    # A non-object ENTRY is malformed for the same reason a non-object
    # top-level doc is (CR round 1, codex-4): silently skipping it would let a
    # corrupted registry report a clean run for the very rows it corrupted.
    # Raise -> rc 2, consistent with the shape checks above.
    if not isinstance(info, dict):
        raise ValueError('known_marketplaces.json entry %r is not an object' % (name,))
    if name == 'himmel':
        continue
    # autoUpdate decides whether this row is ours to sweep, so a malformed value
    # must not be guessed at. The string "false" is TRUTHY in Python, so a
    # quoted boolean would silently mark the row auto-updating and drop it from
    # the sweep while the run still reported success. Same fail-loud rule as the
    # shape checks above -- rc 2, never a partial clean.
    auto = info.get('autoUpdate')
    if auto is not None and not isinstance(auto, bool):
        raise ValueError('known_marketplaces.json entry %r has a non-boolean autoUpdate: %r' % (name, auto))
    if auto:
        continue
    print(name)
PY
)" || {
    echo "update-marketplaces: could not parse $KNOWN_MKTS (python3 error) — refusing to report a clean run." >&2
    exit 2
}

if [ -z "$rows" ]; then
    echo "update-marketplaces: no manual-tier marketplaces installed — nothing to update."
    exit 0
fi

# CRLF strip (HIMMEL-2134). On Windows the python3 that MSYS resolves is a
# NATIVE python whose text-mode stdout writes "\r\n" — so every name read below
# would carry a trailing CR. That is not cosmetic: `claude plugin marketplace
# update "obsidian-skills\r"` is a lookup for a marketplace that does not
# exist, and it would fail EVERY row on Windows while looking correct in the
# echoed output (the CR just returns the cursor). Caught by
# test-update-marketplaces.sh's failure-isolation case, which could not match
# its own row name. Stripped here rather than in the emitter so the fix holds
# for any python build.
_strip_cr() { printf '%s' "${1%$'\r'}"; }

if [ "$mode" = "check" ]; then
    echo "update-marketplaces: would update (manual-tier, autoUpdate off):"
    while IFS= read -r name; do
        name="$(_strip_cr "$name")"
        [ -n "$name" ] || continue
        echo "    $name"
    done <<EOF
$rows
EOF
    exit 0
fi

if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "update-marketplaces: claude CLI not on PATH ($CLAUDE_BIN) — cannot update." >&2
    exit 2
fi

updated=""
failed=""
while IFS= read -r name; do
    name="$(_strip_cr "$name")"
    [ -n "$name" ] || continue
    echo "    ==> claude plugin marketplace update $name"
    # No `set -e` in this script and no `||` short-circuit that would skip the
    # rest: every row is attempted regardless of what the previous row did.
    # </dev/null is load-bearing, not decoration (CodeRabbit, PR #1928): this
    # loop is fed by a here-document, and a child that reads stdin would EAT the
    # remaining rows. The loop would then skip them and report success without
    # ever attempting them — a silent partial sweep reported as clean, which is
    # exactly the failure mode this script exists to prevent. The test stub does
    # not read stdin, so no test can catch a regression here; the redirect is
    # the guarantee.
    if "$CLAUDE_BIN" plugin marketplace update "$name" </dev/null; then
        updated="$updated $name"
    else
        failed="$failed $name"
    fi
done <<EOF
$rows
EOF

echo ""
echo "update-marketplaces: updated:${updated:- none}"
if [ -n "$failed" ]; then
    echo "update-marketplaces: FAILED:${failed} — re-run per name: $CLAUDE_BIN plugin marketplace update <name>" >&2
    exit 1
fi
exit 0
