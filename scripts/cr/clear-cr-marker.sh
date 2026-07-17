#!/usr/bin/env bash
# cr/clear-cr-marker.sh — sanctioned CR-marker clearing chokepoint (HIMMEL-1064).
#
# /pr-check step 5 used to clear its own marker with a bare `rm -f "$marker"`.
# The auto-mode classifier reliably DENIES that as [CI Bypass]: a raw `rm` of
# cr-pending/<branch> is byte-identical to the self-declare-clean pattern the
# operator's gotcha flags, and the classifier cannot see that /pr-check really
# ran. Structural, not a one-off — EVERY clean run hits it, and the marker then
# blocks `gh pr create` on a branch whose CR was actually clean.
#
# This is the narrow, self-gating clear path — the same shape as the
# merge-on-green.sh chokepoint (HIMMEL-1042). It does NOT take the session's
# word that the review was clean: it re-derives that verdict from evidence
# /pr-check recorded mechanically, and clears only on its OWN reading. That is
# strictly STRONGER than the `rm` it replaces, which asserted nothing.
#
# Gates (ALL must hold):
#   1. A marker exists for the branch (absent => nothing to do, exit 0).
#   2. The marker's certified SHA is STILL the branch tip. A commit after the
#      review means the reviewed code is not the code you would open a PR on.
#   3. The CR ledger records a critic that actually RESPONDED at that SHA
#      (>=1 `avail ... status=ok`). Zero responders is a MISSING signal, not a
#      clean one (the CodeRabbit CLI rate-limit shape) — refuse.
#   4. The ledger records NO blocking finding at that SHA (severity crit|imp
#      whose verdict is anything other than `disproved`).
#   5. POST-PR ONLY: when a PR already exists for the branch, its head commit
#      must BE the certified SHA, and check-ci.sh must also return 0 (CI green +
#      all review threads resolved + no changes-requested). check-ci evaluates
#      the PR HEAD, so without the head binding a green PR at a DIFFERENT commit
#      would satisfy this gate for code the review never covered. Pre-PR there is
#      no PR to evaluate — that is the marker's PRIMARY case (it gates
#      `gh pr create`), so gates 1-4 stand alone.
#
# Usage: clear-cr-marker.sh [<branch>] [--dry-run]
#   branch     optional; defaults to the current branch
#   --dry-run  run every gate, report the verdict, then STOP (never clears)
#
# Exit codes:
#   0   marker cleared (or --dry-run passed, or no marker — nothing to do)
#   10  usage error
#   11  required tool missing (git / node)
#   12  cannot resolve the branch, its tip, or the marker path — refused
#   13  marker SHA is not the branch tip (stale review) — re-run /pr-check
#   14  no critic responded at that SHA — no evidence /pr-check ran; refused
#   15  blocking finding(s) recorded at that SHA — address them, re-run /pr-check
#   16  a PR exists but its head is not the certified SHA, or its check-ci gate
#       is not green — refused
#
# GATE INTEGRITY (mirrors merge-on-green.sh): the ledger path, `check-ci.sh`,
# and `gh` are NOT environment-overridable here. ledger-append.sh honors a
# CR_LEDGER override for its WRITES, but this GATE must never read a
# caller-pointed ledger — that would let a contaminated environment forge the
# evidence the clear depends on. The ledger is always the fixed
# `<git-common-dir>/cr-critic-scores.jsonl`; check-ci.sh is the fixed in-repo
# sibling. Tests exercise this by running a COPY of the script tree inside a
# temp git repo (whose git-common-dir IS the temp repo) with a stub `gh` on
# PATH — never via a caller-settable seam.
set -uo pipefail
# NOT set -e: this script inspects sub-call exit codes explicitly and must fail
# CLOSED with its own codes, never abort mid-gate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_CI="$SCRIPT_DIR/../check-ci.sh"

branch=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            # Anchored to the `set -uo pipefail` line, not a hardcoded count, so
            # a header edit cannot silently truncate this reference (HIMMEL-1042).
            sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "clear-cr-marker: unknown option: $1" >&2; exit 10 ;;
        *)
            if [ -n "$branch" ]; then
                echo "clear-cr-marker: only one branch allowed (got '$branch' and '$1')" >&2
                exit 10
            fi
            branch="$1"; shift ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "clear-cr-marker: required tool 'git' not on PATH" >&2; exit 11; }
# `node` (ledger read) and `gh` (PR state) are checked LATER, each immediately
# before the step that needs it — not here (codex-1 round 2 + coderabbit).
# Demanding them up-front broke this script's own documented no-op: on a box
# without them, even "no marker → nothing to do" exited 11 instead of 0, and
# that path reads neither the ledger nor any PR state. Only `git` is needed to
# get as far as the marker check.

# Audit to stdout (the transcript) AND, best-effort, an append log. Unlike
# merge-on-green, an unwritable log is NOT a hard refusal: clearing a marker is
# reversible (the next push rewrites it) and gates only `gh pr create`, so the
# transcript record is proportionate. The MERGE is where an unauditable action
# must abort — that gate lives in merge-on-green.sh.
audit() {
    local line ts logf
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')
    line="$ts clear-cr-marker $*"
    echo "$line"
    logf=$(git rev-parse --git-common-dir 2>/dev/null || true)
    [ -n "$logf" ] && printf '%s\n' "$line" >>"$logf/clear-cr-marker.log" 2>/dev/null
    return 0
}

git_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -z "$git_dir" ]; then
    echo "clear-cr-marker: not a git repository (cannot resolve --git-common-dir) — refusing." >&2
    exit 12
fi

if [ -z "$branch" ]; then
    branch=$(git branch --show-current 2>/dev/null || true)
fi
if [ -z "$branch" ]; then
    echo "clear-cr-marker: cannot resolve the branch (detached HEAD?) — pass one explicitly." >&2
    exit 12
fi

marker="$git_dir/cr-pending/$branch"
if [ ! -f "$marker" ]; then
    echo "clear-cr-marker: no pending CR marker for $branch — nothing to do."
    exit 0
fi

# The branch's OWN tip — not cwd HEAD. Clearing another branch's marker must be
# gated on THAT branch's state.
tip=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
if [ -z "$tip" ]; then
    echo "clear-cr-marker: cannot resolve the tip of '$branch' — refusing." >&2
    audit "REFUSED reason=no-branch-tip branch=$branch"
    exit 12
fi

# Marker format (check-cr-before-push.sh): "<iso-ts> | <full-sha> | <lane>".
marker_sha=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$marker" 2>/dev/null)
if [ -z "$marker_sha" ]; then
    echo "clear-cr-marker: cannot read the certified SHA from $marker — refusing." >&2
    audit "REFUSED reason=unreadable-marker branch=$branch"
    exit 12
fi

# 2. Stale-review gate — the reviewed commit must still be the branch tip.
if [ "$marker_sha" != "$tip" ]; then
    echo "clear-cr-marker: marker certifies ${marker_sha:0:8} but '$branch' is now at ${tip:0:8} — the review does not cover the current code. Re-run /pr-check on this HEAD." >&2
    audit "REFUSED reason=stale-marker branch=$branch marker_sha=$marker_sha tip=$tip"
    exit 13
fi

# 3+4. Ledger evidence at the certified SHA. The ledger is keyed on the SHORT
# sha /pr-check passes, so both forms must resolve — but an abbreviation is
# matched by RESOLVING it through git and requiring the full object to BE the
# tip, never by string prefix (see atHead below). FIXED path — no CR_LEDGER seam
# (see GATE INTEGRITY above).
command -v node >/dev/null 2>&1 || {
    echo "clear-cr-marker: required tool 'node' not on PATH (cannot read the CR ledger) — refusing." >&2
    audit "REFUSED reason=no-node branch=$branch sha=$tip"
    exit 11
}
ledger="$git_dir/cr-critic-scores.jsonl"
verdict=$(LEDGER="$ledger" FULL_SHA="$tip" node -e '
  const fs = require("fs"), e = process.env;
  const lines = fs.existsSync(e.LEDGER)
      ? fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean) : [];
  const cp = require("child_process");
  // A ledger head is EVIDENCE — it must name the certified commit, not merely
  // look like it. Prefix equality (the shipped form) accepted any record whose
  // head shared the tip first 7 chars, so a record for a DIFFERENT commit with a
  // colliding abbreviation satisfied gates 3/4. /pr-check step 4.5 writes SHORT
  // heads, so short-SHA support must survive: RESOLVE, then compare. An
  // unresolvable OR ambiguous abbreviation resolves to null and matches nothing
  // — an unknown head is not this head.
  const HEX = "0123456789abcdef";
  const isHex = (s) => s.length >= 7 && s.length <= 40 &&
      s.split("").every((c) => HEX.indexOf(c) >= 0);
  const cache = new Map();
  const resolve = (h) => {
      if (!cache.has(h)) {
          let full = null;
          try {
              // No --git-dir: cwd is inside the repo (every other git call here
              // relies on that too). --quiet turns an unknown OR ambiguous rev
              // into a silent non-zero, which the catch maps to null.
              full = cp.execFileSync("git",
                  ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
                  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
          } catch { full = null; }
          cache.set(h, full || null);
      }
      return cache.get(h);
  };
  const atHead = (o) => {
      const h = String(o.head || "");
      // The length floor also guards a truncated/garbage head from resolving.
      if (!isHex(h)) return false;
      if (e.FULL_SHA === h) return true;
      return resolve(h) === e.FULL_SHA;
  };
  // A malformed record is a REFUSAL, not a skip (coderabbit). Silently
  // skipping unparseable lines fails OPEN: if a blocking finding is truncated
  // or corrupted while an avail-ok line stays readable, the gate would clear
  // the marker without ever evaluating that finding. An unreadable ledger is
  // an unknown verdict, and unknown must never mean clean.
  let responders = 0, blocking = [], malformed = 0;
  for (const l of lines) {
      let o;
      try { o = JSON.parse(l); } catch { malformed++; continue; }
      if (!atHead(o)) continue;
      if (o.kind === "avail" && o.status === "ok") responders++;
      if (o.kind === "finding" && (o.severity === "crit" || o.severity === "imp")
          && o.verdict !== "disproved") {
          // String concat, not a template literal: a dollar-brace inside this
          // single-quoted node block trips shellcheck SC2016, and the quotes
          // must stay single so the shell never expands the JS.
          blocking.push((o.finding_id || "?") + "(" + o.severity + "," +
              (o.verdict || "no-verdict") + ")");
      }
  }
  console.log(JSON.stringify({ responders, blocking, malformed }));
' 2>/dev/null)
if [ -z "$verdict" ]; then
    echo "clear-cr-marker: could not read the CR ledger at $ledger — refusing (cannot certify the review)." >&2
    audit "REFUSED reason=ledger-unreadable branch=$branch sha=$tip"
    exit 14
fi
responders=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).responders))' 2>/dev/null)
blocking=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).blocking.join(" ")))' 2>/dev/null)
malformed=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).malformed))' 2>/dev/null)

# Malformed ledger lines => the verdict is UNKNOWN. Refuse (coderabbit).
if [ "${malformed:-0}" -gt 0 ]; then
    echo "clear-cr-marker: the CR ledger has ${malformed} unparseable record(s) — the review verdict cannot be read reliably. Refusing (an unknown verdict is not a clean one). Inspect $ledger." >&2
    audit "REFUSED reason=ledger-malformed branch=$branch sha=$tip malformed=$malformed"
    exit 14
fi

# 3. A MISSING signal is not a clean one. Zero responders means no critic
# actually reviewed this SHA (all failed / rate-limited / never ran) — the
# CodeRabbit-CLI rate-limit shape that /pr-check fails OPEN on. Refuse.
if [ "${responders:-0}" -lt 1 ]; then
    echo "clear-cr-marker: no critic responded at ${tip:0:8} (ledger records 0 'avail ... ok') — that is a MISSING review signal, not a clean one. Run /pr-check on this HEAD." >&2
    audit "REFUSED reason=no-responders branch=$branch sha=$tip"
    exit 14
fi

# 4. Blocking findings recorded at this SHA.
if [ -n "$blocking" ]; then
    echo "clear-cr-marker: blocking finding(s) recorded at ${tip:0:8}: $blocking — address them, resolve the threads, re-run /pr-check." >&2
    audit "REFUSED reason=blocking-findings branch=$branch sha=$tip findings=$blocking"
    exit 15
fi

# 5. Post-PR / pre-merge gate — when a PR already exists, the review threads and
# CI are evaluable, so they MUST also be green (operator, HIMMEL-1064). Pre-PR
# there is no PR to check: that is the marker's primary case, and gates 1-4 are
# the whole verdict.
# `gh` is REQUIRED from here on (codex-1): without it we cannot tell "no PR yet"
# from "a PR exists whose CI I cannot read", and the only safe reading of an
# unknown PR state is a refusal. A missing tool must never silently downgrade
# the gate. Checked HERE, at first use, so the gates above (and the no-marker
# no-op) still work on a box without gh.
command -v gh >/dev/null 2>&1 || {
    echo "clear-cr-marker: required tool 'gh' not on PATH (cannot determine PR state) — refusing." >&2
    audit "REFUSED reason=no-gh branch=$branch sha=$tip"
    exit 11
}
# Resolve the PR by an EXPLICIT head-branch query, never `gh pr view "$branch"`
# (coderabbit): that form takes `<number> | <url> | <branch>` positionally, so a
# branch literally named "42" resolves to PR #42 — a DIFFERENT PR, whose CI
# would then certify this branch's gate. `--head` is unambiguous.
#
# Failure handling (codex-1): an empty result from a SUCCESSFUL query is the
# real "no PR yet" state; a non-zero rc is an unreadable state and must refuse.
# Swallowing the error and reading empty as "no PR" would FAIL OPEN — a
# transient gh outage would skip the post-PR CI gate and clear unverified.
#
# `headRefOid` rides along with the number (coderabbit, public #468): check-ci.sh
# certifies the PR HEAD, but nothing here proved the PR head IS the SHA this
# marker certifies. A green PR whose head differs from $tip would satisfy this
# gate for a commit no critic reviewed. One extra --json field closes it.
pr_num=""
pr_head=""
pr_rc=0
pr_lookup=$(gh pr list --head "$branch" --state open --json number,headRefOid \
    -q '.[] | "\(.number) \(.headRefOid)"' 2>&1) || pr_rc=$?
if [ "$pr_rc" -ne 0 ]; then
    echo "clear-cr-marker: cannot determine whether '$branch' has a PR (gh: ${pr_lookup:-<no output>}) — refusing. An unreadable PR state must not skip the CI gate." >&2
    audit "REFUSED reason=pr-lookup-failed branch=$branch gh_rc=$pr_rc"
    exit 16
fi
# A SUCCESSFUL call returning unexpected text must NOT be filtered down to
# "no PR" (coderabbit): stripping non-matching lines would silently take the
# pre-PR path and skip check-ci entirely. Empty output is the only valid no-PR
# result; anything that is neither blank nor a `<number> <full-sha>` pair is an
# unreadable state.
invalid_pr_lookup=$(printf '%s\n' "$pr_lookup" | grep -Ev '^[[:space:]]*$|^[0-9]+ [0-9a-f]{40}$' || true)
if [ -n "$invalid_pr_lookup" ]; then
    echo "clear-cr-marker: unexpected output from the PR lookup ($(printf '%s' "$invalid_pr_lookup" | head -1)) — refusing. An unreadable PR state must not skip the CI gate." >&2
    audit "REFUSED reason=invalid-pr-lookup branch=$branch"
    exit 16
fi
pr_lookup=$(printf '%s\n' "$pr_lookup" | grep -E '^[0-9]+ [0-9a-f]{40}$' || true)
pr_count=$(printf '%s' "$pr_lookup" | grep -c . || true)
if [ "${pr_count:-0}" -gt 1 ]; then
    echo "clear-cr-marker: '$branch' has ${pr_count} open PRs ($(printf '%s' "$pr_lookup" | awk '{print $1}' | tr '\n' ' ')) — ambiguous; refusing to guess which gates this marker." >&2
    audit "REFUSED reason=ambiguous-prs branch=$branch count=$pr_count"
    exit 16
fi
if [ "${pr_count:-0}" -eq 1 ]; then
    pr_num="${pr_lookup%% *}"
    pr_head="${pr_lookup##* }"
fi
if [ -n "$pr_num" ]; then
    # The certified SHA must be the code the PR actually proposes. check-ci.sh
    # reads the PR head, so a mismatch here means its verdict would certify a
    # commit this marker never covered.
    if [ "$pr_head" != "$tip" ]; then
        echo "clear-cr-marker: PR #$pr_num is at ${pr_head:0:8} but the marker certifies ${tip:0:8} — the PR does not propose the reviewed code. Push this HEAD (or re-run /pr-check on the PR head). Refusing." >&2
        audit "REFUSED reason=pr-head-mismatch branch=$branch pr=#$pr_num pr_head=$pr_head sha=$tip"
        exit 16
    fi
    if [ ! -f "$CHECK_CI" ]; then
        echo "clear-cr-marker: PR #$pr_num exists but check-ci.sh is missing at $CHECK_CI — cannot certify CI. Refusing." >&2
        audit "REFUSED reason=no-check-ci branch=$branch pr=#$pr_num"
        exit 16
    fi
    ci_rc=0
    bash "$CHECK_CI" "$pr_num" || ci_rc=$?
    if [ "$ci_rc" -ne 0 ]; then
        echo "clear-cr-marker: PR #$pr_num exists and its check-ci gate is not green (exit $ci_rc) — refusing. Address CI / unresolved threads, then re-run." >&2
        audit "REFUSED reason=ci-not-green branch=$branch pr=#$pr_num check_ci=$ci_rc"
        exit 16
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    audit "DRYRUN would-clear branch=$branch sha=$tip responders=$responders${pr_num:+ pr=#$pr_num}"
    echo "clear-cr-marker: [dry-run] gates passed — would clear the marker for $branch (${tip:0:8}). Not clearing."
    exit 0
fi

# Re-validate IMMEDIATELY before deleting (coderabbit). The gates above take
# real time — the gh lookup, and post-PR a full check-ci watch — and
# check-cr-before-push.sh rewrites this same branch-scoped file on every push
# with no coordination. A push landing inside that window replaces the marker
# with one certifying a NEWER, unreviewed SHA; deleting that would open
# `gh pr create` for code no critic ever saw. Re-reading here collapses the
# window from "the whole gate run" to the microseconds between this check and
# the unlink.
#
# RESIDUAL (deliberate, tracked): this is not a true mutual exclusion — a push
# in that final sliver still races. The proper fix is one branch-scoped lock
# held by BOTH this script and the pre-push hook, but `flock` is absent on the
# Git Bash this repo targets, so a portable lock is its own piece of work and
# would widen this PR into the pre-push gate. The operator's single-writer
# invariant (one writer per branch) already excludes the realistic case. Filed
# as a follow-up rather than half-done here.
now_sha=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
now_marker=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$marker" 2>/dev/null || true)
if [ "$now_sha" != "$tip" ] || [ "$now_marker" != "$marker_sha" ]; then
    echo "clear-cr-marker: the branch or its marker changed while the gates ran (tip ${tip:0:8}->${now_sha:0:8}, marker ${marker_sha:0:8}->${now_marker:0:8}) — refusing to clear a marker this run did not certify. Re-run /pr-check on the new HEAD." >&2
    audit "REFUSED reason=raced-during-gate branch=$branch validated_sha=$tip now_sha=$now_sha now_marker=$now_marker"
    exit 13
fi

if ! rm -f "$marker"; then
    echo "clear-cr-marker: failed to remove $marker" >&2
    audit "REFUSED reason=rm-failed branch=$branch sha=$tip"
    exit 12
fi
audit "CLEARED branch=$branch sha=$tip responders=$responders${pr_num:+ pr=#$pr_num}"
echo "clear-cr-marker: CR clean — marker cleared for $branch (${tip:0:8}). Safe to gh pr create."
exit 0
