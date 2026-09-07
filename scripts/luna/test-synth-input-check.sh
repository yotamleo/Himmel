#!/usr/bin/env bash
# test-synth-input-check.sh — HIMMEL-2045. Hermetic: a scratch vault, no claude.
# Mirrors test-bank-preflight.sh's shape — the sibling verdict-token helper.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/luna/synth-input-check.sh"
PASS=0; FAIL=0; SKIP=0
W="$(mktemp -d -t synth-input-check.XXXXXX)"; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

verdict() { bash "$SUT" "$1" 2>>"$W/err.log"; }

# A clip the triage leg has annotated. `triaged_at:` is the marker the gate
# keys on — a harvested-but-untriaged clip is not yet synthesis input.
write_clip() { printf -- '---\ntriaged_at: 2026-08-23\nprocessed: true\n---\nbody\n' > "$1"; }

# --- no inbox at all -------------------------------------------------------
V="$W/v-empty"; mkdir -p "$V"
check "no Clippings dir -> NONE" NONE "$(verdict "$V")"

# --- inbox with nothing triaged -------------------------------------------
V="$W/v-untriaged"; mkdir -p "$V/Clippings"
printf -- '---\nharvested_at: 2026-08-23\n---\nbody\n' > "$V/Clippings/raw.md"
check "harvested but untriaged clip -> NONE" NONE "$(verdict "$V")"

# --- first ever run: triaged clip, no synthesis, no stamp -----------------
V="$W/v-fresh"; mkdir -p "$V/Clippings"
write_clip "$V/Clippings/a.md"
check "triaged clip, no reference -> NEW" NEW "$(verdict "$V")"

# --- stamping is what closes the loop -------------------------------------
# The regression this guards: keying off the newest _synthesis/ page alone
# means a night that legitimately wrote ZERO pages leaves the reference where
# it was, so the same already-considered clips re-fire a session every night
# forever. The stamp moves even on a 0-page completion.
verdict "$V" >/dev/null                      # the gate leaves the pending mark
bash "$SUT" --stamp "$V" 2>>"$W/err.log"     # ...which --stamp promotes
check "stamp written" 0 "$([ -f "$V/Clippings/_synthesis/.cadence-last-synth" ] && echo 0 || echo 1)"
check "after a completed leg -> NONE" NONE "$(verdict "$V")"

# --- a clip triaged after the stamp re-opens the gate ---------------------
# Still $W/v-fresh, which the block above STAMPED. Reassigning V between these
# two blocks silently retargets this at an unstamped vault, where it passes
# through the no-reference path and stops testing its own name — so any new
# fixture goes AFTER this assertion, never between.
sleep 1
write_clip "$V/Clippings/b.md"
check "clip newer than the stamp -> NEW" NEW "$(verdict "$V")"

# --stamp with NO pending mark must leave the reference ALONE, not advance it
# to completion time — that would move it past every clip triaged during the
# session, which is the whole window the pending mark closes.
V="$W/v-nopending"; mkdir -p "$V/Clippings/_synthesis"
write_clip "$V/Clippings/a.md"
bash "$SUT" --stamp "$V" 2>>"$W/err.log"
check "--stamp without a pending mark writes no stamp" 1 \
  "$([ -f "$V/Clippings/_synthesis/.cadence-last-synth" ] && echo 0 || echo 1)"
check "--stamp without a pending mark leaves the clip NEW" NEW "$(verdict "$V")"

# --- no stamp: falls back to the newest synthesis page --------------------
V="$W/v-page"; mkdir -p "$V/Clippings/_synthesis"
write_clip "$V/Clippings/old.md"
sleep 1
printf 'theme\n' > "$V/Clippings/_synthesis/theme.md"
check "clip older than newest synthesis page -> NONE" NONE "$(verdict "$V")"
sleep 1
write_clip "$V/Clippings/new.md"
check "clip newer than newest synthesis page -> NEW" NEW "$(verdict "$V")"

# --- output/archive subtrees are not input --------------------------------
# A clip graduating into _done/ and a synthesis page being rewritten are both
# newer-than-reference .md files; neither is new INPUT. -maxdepth 1 plus the
# triaged_at filter is what keeps them out.
V="$W/v-subtrees"; mkdir -p "$V/Clippings/_done/2026-08" "$V/Clippings/_synthesis"
printf 'seed\n' > "$V/Clippings/_synthesis/theme.md"
sleep 1
write_clip "$V/Clippings/_done/2026-08/graduated.md"
check "a graduated clip under _done -> NONE" NONE "$(verdict "$V")"

# --- the stamp records the GATE instant, not the leg end ------------------
# A synthesis session runs 8-39 minutes. A clip triaged INSIDE that window was
# never part of what the session read, so a completion-time stamp would leave
# it older than the reference and the next gate would skip it. The gate writes
# a pending mark at check time and --stamp promotes it.
V="$W/v-window"; mkdir -p "$V/Clippings"
write_clip "$V/Clippings/a.md"
check "gate opens" NEW "$(verdict "$V")"
check "gate left a pending mark" 0 "$([ -f "$V/Clippings/_synthesis/.cadence-last-synth.pending" ] && echo 0 || echo 1)"
sleep 1
# ...the leg is running; a clip is triaged mid-session...
write_clip "$V/Clippings/mid-session.md"
sleep 1
bash "$SUT" --stamp "$V" 2>>"$W/err.log"        # ...and only now does the leg finish
check "pending mark consumed by --stamp" 1 "$([ -f "$V/Clippings/_synthesis/.cadence-last-synth.pending" ] && echo 0 || echo 1)"
check "clip triaged mid-session is still NEW" NEW "$(verdict "$V")"

# --- an unreadable candidate is an unknown, not a 'no' --------------------
V="$W/v-unreadable"; mkdir -p "$V/Clippings"
printf 'not a clip\n' > "$V/Clippings/x.md"
chmod 000 "$V/Clippings/x.md" 2>/dev/null
if [ -r "$V/Clippings/x.md" ]; then
    # Windows/ACL hosts ignore chmod 000 — the case is unreachable there, and
    # asserting it anyway would fail for the wrong reason.
    echo "SKIP - unreadable-candidate case (chmod 000 not enforced on this host)"
    SKIP=$((SKIP+1))
else
    check "unreadable candidate -> NEW (fail-open)" NEW "$(verdict "$V")"
    chmod 644 "$V/Clippings/x.md" 2>/dev/null
fi

# --- triaged_at in the BODY is not frontmatter ----------------------------
# This vault clips articles about its own pipeline, so a body that quotes
# `triaged_at:` is a realistic false NEW — one bought session per night.
V="$W/v-body"; mkdir -p "$V/Clippings"
printf -- '---\nharvested_at: 2026-08-23\n---\nthe triage leg writes triaged_at: to each clip\n' > "$V/Clippings/article.md"
check "triaged_at in the body only -> NONE" NONE "$(verdict "$V")"

# ...and a clip with NO frontmatter at all, whose body has a horizontal rule
# before the line. Treating any `---` as an opening fence reintroduces the
# body-match bug one layer down; frontmatter is line-1-or-nothing.
V="$W/v-hrule"; mkdir -p "$V/Clippings"
printf -- 'intro\n\n---\ntriaged_at: not really\n' > "$V/Clippings/hrule.md"
check "hrule + triaged_at, no frontmatter -> NONE" NONE "$(verdict "$V")"

# --- a script the POSIX runners invoke DIRECTLY must be executable ---------
# The generated cron runner calls these by path, with no interpreter prefix.
# Committed non-executable, every POSIX invocation dies "Permission denied",
# the runner's fail-open branch swallows it, and the bank guard / input gate
# silently never run — a guard that reads as armed and is not.
for _rel in luna/synth-input-check.sh lib/bank-preflight.sh lib/flow-run-ledger.sh; do
    _mode=$(git -C "$REPO" ls-files -s -- "scripts/$_rel" 2>/dev/null | awk '{print $1}')
    check "scripts/$_rel is committed executable" 100755 "${_mode:-missing}"
done

# --- the contract: always exit 0, one token, no matter what ---------------
bash "$SUT" "$W/does-not-exist" >/dev/null 2>&1
check "missing vault still exits 0" 0 "$?"

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
