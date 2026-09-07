#!/usr/bin/env bash
# HIMMEL-480 — every debrand rule must still match the staged CLAUDE.md.
#
# generate.mjs debrands via `split(from).join(to)`, which silently no-ops when
# `from` is absent. So a CLAUDE.md edit that moves, rewraps, or rewrites a
# debranded phrase turns its rule into a dead no-op with NO signal: the string
# it protected stops being neutralized, and the AGENTS.md freshness guard does
# not notice (it compares generated output to generated output — both sides
# regenerate together, so both are equally wrong).
#
# This gate closes that. It runs the generator with coverage enforcement ON
# against the STAGED CLAUDE.md, so an unmatched rule that has not declared
# `"dormant": true` (with a note) blocks the commit.
#
# Deliberately SEPARATE from check-agents-md-fresh.sh: that hook regenerates
# from a staged temp copy and its own tests use stub fixtures, so coverage can
# neither be always-on there nor path-detected (the temp copy never matches the
# canonical path — which is exactly how an earlier attempt left the check dead
# in the only path that gates a commit).
#
# Exit: 0 covered / not applicable · 1 an orphaned rule · 2 cannot evaluate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN="$SCRIPT_DIR/../agents-md/generate.mjs"

# himmel-dev only: adopters who vendored the repo do not maintain debrand.json.
# Use the shared resolver, NOT a bare [ -f "$REPO_ROOT/.himmel-dev" ] — the
# marker is gitignored and lives in the PRIMARY checkout, so a naive test
# silently no-ops in every worktree (i.e. in exactly the place feature work
# happens). Mirrors check-agents-md-fresh.sh.
# shellcheck source=scripts/guardrails/lib.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/guardrails/lib.sh"
rc=0
# shellcheck disable=SC2119  # deliberately called with no args to use its DIR default (.)
is_himmel_dev_repo || rc=$?
# `if`, not `[ … ] && exit 0` — under errexit a false test makes the compound
# return 1 and kills the script with a bogus failure.
if [ "$rc" -eq 1 ]; then exit 0; fi   # not a himmel-dev checkout → no-op
if [ ! -f "$GEN" ]; then echo "→ debrand-coverage: generator missing — fail-closed" >&2; exit 2; fi  # fail-open-ok: unreadable generator fails node under errexit → the gate reports and blocks (fail-closed)

# Only relevant when the repo-root CLAUDE.md or debrand table is staged. A git
# failure here is NOT "nothing staged" — suppressing it with `|| true` would
# turn an unreadable index into a silent pass, which is the opposite of
# fail-closed. Parse name-status fields exactly; substring matches would also
# fire for unrelated paths such as templates/luna-second-brain/_CLAUDE.md.
if ! staged="$(git diff --cached --name-status 2>/dev/null)"; then
    echo "→ debrand-coverage: cannot inspect staged paths — fail-closed" >&2; exit 2
fi
relevant=0
refuse=0
while IFS=$'\t' read -r status old_path new_path; do
    case "$old_path" in
      CLAUDE.md|scripts/agents-md/debrand.json)
        relevant=1
        case "$status" in D|R[0-9]*) refuse=1 ;; esac
        ;;
    esac
    case "$status" in
      R[0-9]*)
        case "$new_path" in
          CLAUDE.md|scripts/agents-md/debrand.json) relevant=1; refuse=1 ;;
        esac
        ;;
    esac
done < <(printf '%s\n' "$staged")
if [ "$relevant" -eq 0 ]; then exit 0; fi

# A staged DELETION or RENAME of either input is not something to validate
# around — the fallbacks below would happily check HEAD's copy and pass a commit
# that removes or relocates the file. For rename records both old and new paths
# matter: moving an input out or replacing one by moving another file in must
# fail closed.
if [ "$refuse" -eq 1 ]; then
    echo "→ debrand-coverage: CLAUDE.md or debrand.json is staged for DELETION/RENAME — fail-closed" >&2
    exit 2
fi

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

# Validate the STAGED content, not the working tree — the commit is what ships.
if ! git show ":CLAUDE.md" > "$tmpd/CLAUDE.md" 2>/dev/null; then
    # CLAUDE.md not staged (only debrand.json was) — validate against HEAD's copy.
    if ! git show "HEAD:CLAUDE.md" > "$tmpd/CLAUDE.md" 2>/dev/null; then
        echo "→ debrand-coverage: no CLAUDE.md in index or HEAD — fail-closed" >&2; exit 2
    fi
fi
# Same rule as CLAUDE.md above: validate COMMITTED state, never the working
# tree. Falling back to $SCRIPT_DIR/../agents-md/debrand.json would let an
# unstaged edit of the mapping decide whether the staged commit passes.
deb="$tmpd/debrand.json"
if ! git show ":scripts/agents-md/debrand.json" > "$deb" 2>/dev/null; then
    if ! git show "HEAD:scripts/agents-md/debrand.json" > "$deb" 2>/dev/null; then
        echo "→ debrand-coverage: no debrand.json in index or HEAD — fail-closed" >&2
        exit 2
    fi
fi

# `if` exempts the call from errexit while still capturing its status — no
# set +e/-e toggling, so every other command in this script stays fail-closed.
#
# The branches must be `then rc=0; else rc=$?`, NOT `if ! cmd; then rc=$?`:
# `!` negates the status BEFORE the branch runs, so inside `then` $? is 0 and
# rc would always be 0 — a gate that reports success for every failure. That
# exact inversion shipped briefly and both CR lanes flagged it; the hook-level
# regression test (test-check-debrand-coverage.sh) exists to keep it dead.
if AGENTS_MD_ENFORCE_COVERAGE=1 \
   AGENTS_MD_SOURCE="$tmpd/CLAUDE.md" AGENTS_MD_TARGET="$tmpd/AGENTS.md" \
   AGENTS_MD_PREAMBLE="$SCRIPT_DIR/../agents-md/preamble.md" \
   AGENTS_MD_DEBRAND="$deb" node "$GEN" --write >/dev/null 2>"$tmpd/err"; then
    rc=0
else
    rc=$?
fi
cat "$tmpd/err" >&2 || true

# generate.mjs signals EVERY cannot-evaluate condition with exit 2 — an orphaned
# rule, a malformed entry, a non-array table, an @include. Only the first is a
# "you broke coverage" finding (our exit 1); the rest are genuine cannot-evaluate
# (our exit 2). The statuses do not distinguish them, so key off the message.
if [ "$rc" -eq 2 ] && ! grep -q 'no longer match' "$tmpd/err"; then
    echo "→ debrand-coverage: generator cannot evaluate (see message above) — fail-closed" >&2
    exit 2
fi

case "$rc" in
  0) exit 0 ;;
  2) cat >&2 <<'EOF'
⛔ debrand-coverage: a debrand rule no longer matches the staged CLAUDE.md
   (see the generator message above).

   Why it matters: the replacement is a literal split/join, so a rule that
   matches nothing silently protects nothing — the phrase it was neutralizing
   now reaches AGENTS.md (or moved out of CLAUDE.md entirely and is no longer
   debranded anywhere). Non-Claude harnesses read that file.

   Fix one of:
     1. Restore/rewrap the phrase in CLAUDE.md so the rule matches again.
     2. Update the rule's "from" to the new wording.
     3. If the content moved out on purpose, mark the rule
        "dormant": true with a "note" saying where it went — and make sure
        the new home carries its own non-Claude reader note.
EOF
     exit 1 ;;
  *) echo "→ debrand-coverage: generator exited $rc — fail-closed" >&2; exit 2 ;;
esac
