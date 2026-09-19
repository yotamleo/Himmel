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
#   2. The marker binds a pushed remote, destination ref, push ENDPOINT URL and
#      diff-base SHA; the endpoint ref's ACTUAL head (resolved via the endpoint,
#      never the mutable alias) must equal the branch tip the ledger certifies.
#      An unpushed or failed push must never let local evidence clear a marker
#      for older remote code. If the marker SHA is stale, gates 3-4 certify the
#      current tip; a stale docs-audit marker is still refused until a push
#      remints its lane.
#   3. The CR ledger records a critic that actually RESPONDED at the branch tip
#      (>=1 `avail ... status=ok`). Zero responders is a MISSING signal, not a
#      clean one (a rate-limited or timed-out critic) — refuse.
#   3b. OPT-IN (CR_REQUIRE_CROSS_MODEL, HIMMEL-1237): >=1 responder must be
#      NON-claude — a single-model Claude self-review floor is not sufficient in
#      this setup. Default off (adopter-portable HIMMEL-1224 floor). Else refuse.
#      OPT-IN ESCAPE (CR_FLOOR_FALLBACK=claude-only, HIMMEL-2128): when 3b would
#      otherwise refuse, accept the Claude-only floor instead IFF a
#      `claude-floor` avail-ok row exists WITH its provenance artifact (a
#      context-free review by claude-floor-review.sh, HIMMEL-3107 — a
#      session-written `claude` row no longer counts), zero blocking findings
#      are recorded, AND every non-Claude lane that recorded ANY avail row at
#      this head is `unavailable` with a VERIFIED-exhaustion reason
#      (quota/rate-limit, or `vacuous` for coderabbit only) — or critics.json
#      lists an EMPTY panel and no lane recorded a row. A lane that never ran
#      (with a non-empty panel), or that failed for any other reason (auth,
#      404, config, timeout, an unclassified rc), still refuses. `claude-floor`
#      is the Claude model family: never cross-model evidence. Default unset
#      (no fallback). Clearing THROUGH that escape is its own audited outcome
#      (HIMMEL-3108): under the opt-in the CLEARED line carries `via=` —
#      `via=cross-model` when a non-Claude lane reviewed the SHA,
#      `via=claude-floor same_model=1 context_free=1 exhausted=<lanes>` when the
#      same-model floor did — and the CR-clean message says which. So
#      CR_REQUIRE_CROSS_MODEL keeps meaning what its name says, and the durable
#      log answers "was this SHA reviewed by a non-Claude lane?" per clear.
#   4. The ledger records NO blocking finding at that SHA (severity crit|imp
#      whose verdict is anything other than `disproved` or a TRACKED `deferred`).
#      `amend` supersede records are applied before this is judged, so a
#      correction (wrong severity, wrong head) actually takes effect; a
#      `deferred` verdict clears ONLY with a ticket key AND a reason, so a bare
#      "deferred" is still blocking (HIMMEL-1294).
#   4b. The ledger records NO finding at that SHA with an EMPTY/missing verdict
#      (HIMMEL-2067) — including `sug`, which gate 4 never blocks on. `amend`
#      records are applied first, same as gate 4. A cleared head must carry a
#      decision for every finding, not just crit|imp.
#   5. POST-PR ONLY: when a PR already exists for the branch, its head commit
#      must BE the branch tip certified by the ledger, and check-ci.sh must also return 0 (CI green +
#      all review threads resolved + no changes-requested). check-ci evaluates
#      the PR HEAD, so without the head binding a green PR at a DIFFERENT commit
#      would satisfy this gate for code the review never covered. Pre-PR there is
#      no PR to evaluate — that is the marker's PRIMARY case (it gates
#      `gh pr create`), so gates 1-4 stand alone.
#   6. The read-validate-delete critical section runs under the branch-scoped
#      CR marker lock that check-cr-before-push.sh's marker write also takes
#      (HIMMEL-1558), and the marker's SHA, LANE and remote binding must be
#      unchanged inside it. Without the lock a push landing between the final
#      check and the unlink would leave a marker for NEWER, unreviewed code
#      deleted; without the lane check a marker reminted docs-audit mid-gate
#      cleared under the stale-marker fallback with no docs-audit refusal.
#
# Usage: clear-cr-marker.sh [<branch>] [--dry-run]
#   branch     optional; defaults to the current branch
#   --dry-run  run every gate that can be checked without writing, report the
#              verdict, then STOP (never clears). Skips the HIMMEL-3027
#              branch-wide still-open check specifically: that check's own
#              underlying command amends the shared ledger as a side effect
#              of checking, which --dry-run must never do (see gate 4c).
#
# Exit codes:
#   0   marker cleared (or --dry-run passed, or no marker — nothing to do)
#   10  usage error
#   11  required tool or component missing (git / node / the branch-lock lib)
#   12  cannot resolve the branch, its tip, or the marker path — refused
#   13  the branch tip, the marker SHA/lane/remote binding changed while the
#       gates ran, or a concurrent marker writer holds the branch lock —
#       re-run /pr-check
#   14  no critic responded at that SHA — no evidence /pr-check ran; refused.
#       Also: CR_REQUIRE_CROSS_MODEL set but no NON-claude critic responded (3b)
#       AND (CR_FLOOR_FALLBACK is unset, or the non-Claude lane(s) are not all
#       verified-exhausted — see 3b above), or a stale docs-audit marker must
#       be reminted before lane selection.
#       Also (4b, HIMMEL-2067): a finding at that SHA has no recorded verdict
#       (agree/disprove/defer it, then re-run).
#       Also (4c, HIMMEL-3027): review-round.sh promote found a still-open
#       (unadjudicated or un-re-raised) finding at an EARLIER round head on
#       this branch — adjudicate it, then re-run. A promote exit other than
#       0/3 (malformed ledger, bad head, missing ledger) also refuses here,
#       fail-closed, as reason=promote-error.
#   15  blocking finding(s) recorded at that SHA — address them, re-run /pr-check
#   16  the marker is unbound (no endpoint/base recorded — pre-HIMMEL-1540
#       format), the marker-bound endpoint head is unreadable/different, a PR
#       exists but its head is not the certified SHA, or its check-ci gate is
#       not green
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
# The SHORT form of the tip, for the amend hint below. New ledger writes are
# normalized to the full SHA by ledger-append.sh, but legacy rows may still carry
# the short key that older /pr-check runs wrote. The helper accepts this
# unambiguous abbreviation and normalizes it for new full-key rows, while still
# letting old short-key rows be amended through their recorded spelling.
tip_short=$(git rev-parse --short "$tip" 2>/dev/null || true)

# Marker format (check-cr-before-push.sh — see its identity-contract header):
# "<iso-ts> | <full-sha> | <lane> | <remote> | <remote-ref> | <endpoint> | <base-sha>".
# <endpoint> is the credential-scrubbed URL git actually pushed to; clearance
# resolves the remote head via IT, never via the alias in field 4 — the alias
# is mutable (remote.<name>.url / pushurl can be repointed after the push, and
# this repo's lane tooling does exactly that as a quarantine mechanism).
# <base-sha> is the immutable diff base the lane classification used.
# The WHOLE certificate, kept verbatim: the unlink at the bottom claims the
# marker by rename and then deletes it only if these exact bytes are what it
# claimed (HIMMEL-1558 CR round 4). The parsed fields below drive the specific
# refusal reasons; this string is what makes the deletion provably the marker
# this run certified.
marker_content=$(cat "$marker" 2>/dev/null || true)
marker_sha=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$marker" 2>/dev/null)
marker_lane=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$marker" 2>/dev/null)
marker_remote=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4; exit}' "$marker" 2>/dev/null)
marker_remote_ref=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5; exit}' "$marker" 2>/dev/null)
marker_endpoint=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$marker" 2>/dev/null)
marker_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$marker" 2>/dev/null)
if [ -z "$marker_sha" ]; then
    echo "clear-cr-marker: cannot read the certified SHA from $marker — refusing." >&2
    audit "REFUSED reason=unreadable-marker branch=$branch"
    exit 12
fi
if [ -z "$marker_remote" ] || [ "$marker_remote_ref" != "refs/heads/$branch" ]; then
    echo "clear-cr-marker: marker has no valid pushed remote binding for '$branch' — refusing. Push the branch again to remint the marker before clearing it. KNOWN TRAP (HIMMEL-2104): if the branch is already up-to-date on the remote, an ordinary 'git push' reports nothing to push and reproduces this SAME unbound marker (check-cr-before-push.sh now reminds from the upstream tracking ref when it can — an updated hook install may already fix this). If a re-push does not clear it, force a real ref update instead — every commit needs a ticket ID, so use the branch's OWN ticket: 'git commit --allow-empty -m \"chore: [TICKET-ID] remint CR marker\" && git push', then re-run /pr-check." >&2
    audit "REFUSED reason=unbound-marker-remote branch=$branch marker_remote=${marker_remote:-none} marker_ref=${marker_remote_ref:-none}"
    exit 16
fi
if [ -z "$marker_endpoint" ] || [ -z "$marker_base" ]; then
    echo "clear-cr-marker: marker for '$branch' predates the endpoint+base binding (no pushed endpoint URL / diff-base SHA recorded) — refusing. Push the branch again to remint the marker before clearing it. KNOWN TRAP (HIMMEL-2104): if the branch is already up-to-date on the remote, an ordinary 'git push' reports nothing to push and reproduces this SAME unbound marker (check-cr-before-push.sh now reminds from the upstream tracking ref when it can — an updated hook install may already fix this). If a re-push does not clear it, force a real ref update instead — every commit needs a ticket ID, so use the branch's OWN ticket: 'git commit --allow-empty -m \"chore: [TICKET-ID] remint CR marker\" && git push', then re-run /pr-check." >&2
    audit "REFUSED reason=unbound-marker-endpoint branch=$branch marker_endpoint=${marker_endpoint:-none} marker_base=${marker_base:-none}"
    exit 16
fi

resolve_marker_remote_head() {
    local lookup rc=0 remote_head remote_ref extra
    # The ENDPOINT, never the alias: `git ls-remote <alias>` resolves through
    # current fetch config, which can name a different repository than the one
    # the push actually targeted (pushurl, or set-url after the push).
    # `--` before the positionals (HIMMEL-2077): marker_endpoint is read back off
    # the on-disk marker file, untrusted input this hook does not fully control —
    # without the separator a value crafted to start with `-` would be parsed as
    # an ls-remote OPTION instead of the repository argument.
    lookup=$(git ls-remote --heads -- "$marker_endpoint" "$marker_remote_ref" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$lookup" ]; then
        return 1
    fi
    case "$lookup" in *$'\n'*) return 1 ;; esac
    IFS=$'\t' read -r remote_head remote_ref extra <<< "$lookup"
    if [ -z "$remote_head" ] || [ "$remote_ref" != "$marker_remote_ref" ] || [ -n "$extra" ]; then
        return 1
    fi
    case "$remote_head" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$remote_head"
}

remote_head=$(resolve_marker_remote_head) || {
    echo "clear-cr-marker: cannot resolve the actual head of push endpoint '$marker_endpoint' ('$marker_remote') '$marker_remote_ref' — refusing. An unreadable remote must not certify PR code." >&2
    audit "REFUSED reason=remote-head-unreadable branch=$branch remote=$marker_remote endpoint=$marker_endpoint remote_ref=$marker_remote_ref"
    exit 16
}
if [ "$remote_head" != "$tip" ]; then
    echo "clear-cr-marker: push endpoint '$marker_endpoint' ('$marker_remote') '$marker_remote_ref' is at ${remote_head:0:8}, but the ledger-certified local tip is ${tip:0:8} — refusing. Push this tip successfully, then re-run /pr-check." >&2
    audit "REFUSED reason=remote-head-mismatch branch=$branch remote=$marker_remote endpoint=$marker_endpoint remote_ref=$marker_remote_ref remote_head=$remote_head tip=$tip marker_sha=$marker_sha"
    exit 16
fi

# 2. A fresh marker is the normal certificate. A stale marker is not itself
# sufficient, but the ledger gates below inspect the branch tip directly and are
# stronger evidence that /pr-check covered the code currently proposed.
stale_marker=0
if [ "$marker_sha" != "$tip" ]; then
    stale_marker=1
    echo "clear-cr-marker: WARNING: marker certifies ${marker_sha:0:8} but '$branch' is now at ${tip:0:8}. The marker is stale; full/legacy lanes now depend entirely on clean ledger evidence at the current tip, while a docs-audit lane must be reminted. /pr-check records ledger evidence at this HEAD; it does not remint the marker." >&2
    audit "WARNING reason=stale-marker-ledger-fallback branch=$branch marker_sha=$marker_sha tip=$tip"

    # The marker lane selected which review /pr-check ran BEFORE this gate. A
    # docs-audit lane from the old SHA cannot certify the new tip: code may have
    # been added since that marker was written, and avail ledger rows do not bind
    # the lane. Refuse until the current branch is pushed again, which remints the
    # marker SHA and reclassifies the lane from the current diff. Conservatively
    # refusing every stale docs marker is smaller and safer than duplicating the
    # hook's diff classifier here.
    if [ "$marker_lane" = "docs-audit" ]; then
        echo "clear-cr-marker: stale docs-audit marker cannot certify the current tip — refusing. Push '$branch' again to remint the marker and recompute its lane, then re-run /pr-check (code changes will take the full lane)." >&2
        audit "REFUSED reason=stale-docs-lane-untrusted branch=$branch marker_sha=$marker_sha tip=$tip"
        exit 14
    fi
fi

# HIMMEL-1237 — resolve the opt-in cross-model floor flag. Default unset => the
# Claude self-review floor alone is a sufficient responder (HIMMEL-1224
# adopter-portable behaviour). When truthy (himmel's own .env), gate 3b below
# additionally requires a NON-claude responder. Loaded from the primary
# checkout's .env (process env wins) so the gate honours it even invoked
# directly or from a worktree — mirrors how /pr-check bridges CR_PROFILE. This
# flag can only make the gate STRICTER (fail-closed), so reading it from the
# trusted local .env never weakens the gate; the GATE INTEGRITY seams (ledger,
# check-ci, gh) stay non-overridable.
if [ -f "$SCRIPT_DIR/../lib/load-dotenv.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    # FAIL CLOSED if the opt-in flag cannot be loaded (coderabbit App, Major).
    # load_dotenv returns 0 on a missing/unresolvable .env (load-dotenv.sh:58,60),
    # so an adopter with no .env never trips this. A NON-zero return means .env
    # EXISTS but could not be READ (permission/race) — ignoring it would let a
    # genuine read failure silently fall through to require_cross_model=0 and
    # clear the marker WITHOUT the configured cross-model evidence (a fail-OPEN in
    # the wrong direction for a security-relevant opt-in). Refuse instead.
    # HIMMEL-2035 FR6 — PIN the .env root to himmel, do not let cwd pick it.
    # `_load_dotenv_root()` resolves with a bare `git rev-parse --git-common-dir`
    # (process cwd, no -C). That was correct only by accident, because cwd was
    # always inside himmel. This gate now runs with cwd = a FOREIGN repo (a
    # bare /pr-check run from a session whose cwd IS an adopter clone with the
    # gate installed, or that clone's own pre-push hook firing directly), and
    # without the pin it would read the ADOPTER's .env for HIMMEL's policy — silently
    # dropping a `CR_REQUIRE_CROSS_MODEL=true` the operator set to harden exactly
    # these reviews. A fail-OPEN on a deliberately tightened gate.
    # `_load_dotenv_primary_for` (not a bare `--root "$SCRIPT_DIR/../.."`):
    # `--root <dir>` is a SILENT no-op when <dir>/.env is missing, and the
    # gitignored .env lives only in the primary checkout — never in a linked
    # worktree, where all feature work happens. Byte-identical to the idiom at
    # critic-panel.sh:863 for this same variable.
    if ! load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK; then
        echo "clear-cr-marker: could not load CR_REQUIRE_CROSS_MODEL/CR_FLOOR_FALLBACK from .env (read failure) — refusing (cannot certify the configured cross-model policy)." >&2
        audit "REFUSED reason=dotenv-unreadable branch=$branch sha=$tip"
        exit 14
    fi
fi
# Truthy check, case-INSENSITIVE + whitespace-TRIMMED (1/true/on/yes). Lowercase
# then strip leading/trailing whitespace so any casing works, the accept-list
# can't drift (a hand-listed set of mixed-case variants omitted ON/True), and a
# padded ' true ' from .env cannot silently disable an intended opt-in
# (glm-1/coderabbit-1 CR round + coderabbit App).
case "$(printf '%s' "${CR_REQUIRE_CROSS_MODEL:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
    1|true|on|yes) require_cross_model=1 ;;
    *) require_cross_model=0 ;;
esac

# HIMMEL-2128 — CR_FLOOR_FALLBACK opt-in. Default unset => no fallback (today's
# fail-safe: gate 3b below refuses outright on cross-model absence). The only
# recognised value is "claude-only" (same trim+lowercase normalisation as
# CR_REQUIRE_CROSS_MODEL above); anything else — unset, a typo — leaves the
# fallback OFF, never silently on. This knob can only make gate 3b ACCEPT a
# case it would otherwise refuse, so it is read from the same trusted-.env
# bridge as CR_REQUIRE_CROSS_MODEL, never an env override at the GATE INTEGRITY
# seams (ledger, check-ci, gh).
cr_floor_fallback=$(printf '%s' "${CR_FLOOR_FALLBACK:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

# 3+4. Ledger evidence at the certified SHA. Current writers normalize ledger
# heads to full SHAs, but old rows may still carry the short sha /pr-check used
# to pass. Both forms must resolve — but an abbreviation is matched by RESOLVING
# it through git and requiring the full object to BE the tip, never by string
# prefix (see atHead below; the HIMMEL-2190 prefix step there is a pre-filter
# that only SKIPS heads git could never resolve to the tip, never an accept). FIXED path — no CR_LEDGER seam (see GATE INTEGRITY
# above).
command -v node >/dev/null 2>&1 || {
    echo "clear-cr-marker: required tool 'node' not on PATH (cannot read the CR ledger) — refusing." >&2
    audit "REFUSED reason=no-node branch=$branch sha=$tip"
    exit 11
}
ledger="$git_dir/cr-critic-scores.jsonl"
# HIMMEL-3107: is the configured critic panel EMPTY? Read from the FIXED
# sibling critics.json (no env seam, same as the ledger). Only a readable file
# whose .panel is an empty array counts; missing/unreadable => 0 (not empty),
# so an unknown roster never turns silence into an unlock.
panel_empty=$(CRITICS="$SCRIPT_DIR/critics.json" node -e '
  try { const p = JSON.parse(require("fs").readFileSync(process.env.CRITICS, "utf8")).panel;
        console.log(Array.isArray(p) && p.length === 0 ? 1 : 0); } catch (_) { console.log(0); }' 2>/dev/null)
# shellcheck disable=SC2016  # $-refs below are JS inside a single-quoted node script, not shell
verdict=$(LEDGER="$ledger" FULL_SHA="$tip" PANEL_EMPTY="${panel_empty:-0}" node -e '
  const fs = require("fs"), e = process.env;
  const lines = fs.existsSync(e.LEDGER)
      ? fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean) : [];
  const cp = require("child_process");
  // A ledger head is EVIDENCE — it must name the certified commit, not merely
  // look like it. Prefix equality (the shipped form) accepted any record whose
  // head shared the tip first 7 chars, so a record for a DIFFERENT commit with a
  // colliding abbreviation satisfied gates 3/4. Legacy ledger rows may still
  // carry short heads, so short-SHA support must survive: RESOLVE, then compare. An
  // unresolvable OR ambiguous abbreviation resolves to null and matches nothing
  // — an unknown head is not this head.
  const HEX = "0123456789abcdef";
  // 7-64 hex chars (HIMMEL-2029): a SHA-1 repo full head is 40 hex, a
  // SHA-256 repo full head is 64. ledger-append.sh --set head= shape check
  // is deliberately kept equal to this ceiling (see its own comment).
  const isHex = (s) => s.length >= 7 && s.length <= 64 &&
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
      // HIMMEL-2190: PREFIX PRE-FILTER. git resolves an abbreviation by object
      // -name prefix, so resolve(h) can only return FULL_SHA when h is a prefix
      // of it. A head that is not a prefix therefore cannot be at this head, and
      // needs no git call. This is a pure PERFORMANCE guard - it never changes a
      // verdict: the resolve-then-compare semantics (HIMMEL-2029) still decide
      // every head that survives it, so an AMBIGUOUS prefix still resolves to
      // null and still matches nothing. Load-bearing because the ledger is
      // append-only and global: ~16k rows / ~3.7k unique historical heads, each
      // costing a ~100-300ms git spawn on Windows, made every gate run take
      // 8-12 MINUTES. After the filter at most one head per length (7..64) can
      // reach resolve(), so the spawn count is bounded by the sha-length range
      // - not by ledger size - and a full pass is seconds.
      if (!e.FULL_SHA.startsWith(h)) return false;
      return resolve(h) === e.FULL_SHA;
  };
  // A malformed record is a REFUSAL, not a skip (coderabbit). Silently
  // skipping unparseable lines fails OPEN: if a blocking finding is truncated
  // or corrupted while an avail-ok line stays readable, the gate would clear
  // the marker without ever evaluating that finding. An unreadable ledger is
  // an unknown verdict, and unknown must never mean clean.
  let responders = 0, nonClaudeResponders = 0, blocking = [], malformed = 0, deferred = [], applied = [];
  // HIMMEL-2128: CR_FLOOR_FALLBACK=claude-only eligibility tracking. claudeOk
  // is a PRESENT-model check, mirroring the nonClaudeResponders normalisation
  // just below (trim+lowercase, model must actually equal "claude") - it is
  // MONOTONIC ("Claude was ever ok at this head"), never cleared by a later
  // row, consistent with how responders/nonClaudeResponders are counted, not
  // reset, elsewhere in this same pass. availByModel holds the LAST avail row
  // seen per non-claude model, ANY status - not just ok - so an exhausted
  // (unavailable) lane is visible even when it never recovered. Plain
  // last-write-wins (each line just overwrites the Map entry, in file order)
  // is correct here because ledger-append.sh itself now appends a fresh row
  // on EVERY effective change at a (head, model) - an unavailable to ok
  // recovery, AND (HIMMEL-2128) a same-status RECLASSIFICATION whose
  // reason/detail differs (e.g. unavailable reason=quota degrading to
  // reason=config) - so the last line in the ledger really is the last thing
  // that happened, never a stale reason an identical-status dedup left behind.
  // A future "claude-*" model slug (e.g. a distinct sub-agent identity) is NOT
  // exempted by this exact-string check and would count as non-claude for
  // both nonClaudeResponders and exhaustion tracking - deliberate: only the
  // literal "claude" string is ever the self-review floor.
  // HIMMEL-3107: the ONE exception is "claude-floor", the context-free floor
  // reviewer (claude-floor-review.sh). It is the Claude model family, so it is
  // never cross-model evidence and never an exhaustion-tracked lane; floorOk
  // (not claudeOk) is what unlocks CR_FLOOR_FALLBACK - a session-written
  // "claude" self-review row no longer does.
  let claudeOk = false, floorOk = false;
  const availByModel = new Map();
  // HIMMEL-2067: ANY finding at this head with no EFFECTIVE verdict (null,
  // undefined or empty string, after amends are applied) — not just
  // crit|imp. Gate 4 below only ever blocks on crit|imp, so a sug-severity
  // finding could be left with verdict:"" forever and still clear; this
  // bucket catches that (and, in principle, any crit|imp with no verdict
  // too, though gate 4 already refuses those before this is ever read).
  let unadjudicated = [];
  // Coalesced by (finding_id, artifact, perspective) — NOT pushed per raw row.
  // A legacy ledger can carry more than one raw `finding` row for the same
  // logical finding (pre-dedup-guard duplicates); every row here has already
  // passed atHead, so the LAST one written is the current state. Evaluating
  // rows independently (codex-1, HIMMEL-2067 CR round) let an old empty-
  // verdict row keep blocking after a newer row recorded the decision.
  const unadjByKey = new Map();
  // HIMMEL-1715: carry each blocking finding FILE alongside the id so the shell
  // can check the row against the head it is blocking. Kept as a separate key
  // rather than folded into the blocking string, which callers/tests match on.
  // Objects, not a delimited string: a pathname may contain any byte except
  // NUL, so no in-band text delimiter is safe (CR round 1).
  let blockingFiles = [];
  // AMENDS (HIMMEL-1294). The ledger is append-only, so a correction arrives as
  // a supersede record rather than an edited line. Collect them FIRST, keyed by
  // each finding by its ORIGINAL (head, finding_id, artifact, perspective), and
  // apply them before any finding is judged. NOTE: no apostrophes, backticks or
  // dollar-braces anywhere in this node block — it is single-quoted for the
  // shell, so an apostrophe ends the quote and every line after it becomes
  // shell syntax. Without this pass the ledger could
  // record a correction that the gate never sees - which is the same
  // caller-thinks-it-worked failure the amend verb exists to end.
  // Later amends win per key; a set.head then re-keys the finding, so atHead
  // below evaluates it against the head it was actually raised at.
  //
  // SEP is U+001F (unit separator), built with String.fromCharCode so no raw
  // control byte ever sits in this file. A PRINTABLE delimiter is the real
  // hazard codex-2/glm-4 pointed at: it can occur inside a field, so two
  // different tuples could flatten to one key and an amend could land on the
  // wrong finding. U+001F cannot appear in a sha, slug, artifact or perspective.
  const SEP = String.fromCharCode(31);
  const amends = new Map();
  for (const l of lines) {
      let a;
      try { a = JSON.parse(l); } catch { continue; }   // counted below in the main pass
      if (a.kind !== "amend" || !a.set || typeof a.set !== "object") continue;
      const k = [a.target_head, a.finding_id, a.artifact || "diff", a.perspective || "off"].join(SEP);
      amends.set(k, Object.assign({}, amends.get(k) || {}, a.set));
  }
  for (const l of lines) {
      let o;
      try { o = JSON.parse(l); } catch { malformed++; continue; }
      if (o.kind === "amend") continue;   // metadata, not a verdict record
      if (o.kind === "finding") {
          const k = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
          if (amends.has(k)) {
              // Report every amend the gate ACTS on. An amend can move a
              // finding off this SHA or change its severity, i.e. it can be the
              // reason the gate cleared - so applying one silently would make
              // the decisive evidence the one thing the transcript does not
              // show. Reported whether or not the finding ends up blocking.
              applied.push((o.finding_id || "?") + JSON.stringify(amends.get(k)));
              o = Object.assign({}, o, amends.get(k));
          }
      }
      if (!atHead(o)) continue;
      if (o.kind === "finding") {
        const k2 = [o.finding_id || "?", o.artifact || "diff", o.perspective || "off"].join(SEP);
        unadjByKey.set(k2, { id: o.finding_id || "?",
            severity: typeof o.severity === "string" ? o.severity : "?",
            file: typeof o.file === "string" ? o.file : "",
            artifact: o.artifact || "diff",
            perspective: o.perspective || "off",
            verdict: typeof o.verdict === "string" ? o.verdict.trim() : o.verdict });
      }
      if (o.kind === "avail") {
          // Require a PRESENT model string — a bare != "claude" also matches a
          // MISSING model (JS: undefined !== "claude" is true). Normalise
          // (trim+lowercase) so a mis-cased "Claude" is still the floor, never
          // cross-model evidence (codex-1/glm-2/coderabbit-1 CR round). Fail
          // closed. No backticks in this single-quoted node block — they trip
          // shellcheck SC2016.
          const model = (typeof o.model === "string" ? o.model : "").trim().toLowerCase();
          // HIMMEL-2128: track EVERY non-claude avail row (any status), last
          // one at this head wins - not just the "ok" rows gate 3 counts -
          // so a lane that stayed unavailable is visible to the floor-fallback
          // eligibility check below.
          if (model && model !== "claude" && model !== "claude-floor") {
              availByModel.set(model, {
                  status: (typeof o.status === "string" ? o.status : "").trim().toLowerCase(),
                  reason: (typeof o.reason === "string" ? o.reason : "").trim().toLowerCase(),
              });
          }
          if (o.status === "ok") {
              responders++;
              // HIMMEL-1237: the Claude self-review floor writes model
              // "claude"; every external critic (codex/glm/coderabbit/...) is
              // non-claude. Gate 3b uses this to enforce cross-model coverage
              // when required. (Scope: this tightens the cross-model count
              // only — the gate-3 responders count is unchanged; a model-less
              // row cannot occur via ledger-append.sh, which requires --model.)
              if (model && model !== "claude" && model !== "claude-floor") nonClaudeResponders++;
              if (model === "claude") claudeOk = true;
              if (model === "claude-floor") floorOk = true;
          }
      }
      if (o.kind === "finding" && (o.severity === "crit" || o.severity === "imp")
          && o.verdict !== "disproved") {
          // DEFERRAL (HIMMEL-1294). Before this, an honestly-recorded
          // out-of-diff / pre-existing crit|imp had exactly two mechanical
          // exits: downgrade it to sug, or claim disproved. Both are false, so
          // the gate pushed an honest session toward mis-recording - and a
          // single such record wedged a branch permanently.
          // A deferral is accepted ONLY when it is TRACKED: verdict deferred
          // AND a ticket key AND a stated reason. A bare "deferred" stays
          // blocking, so this is a third truthful exit, not a free pass.
          const ticket = typeof o.deferred_to === "string" ? o.deferred_to.trim() : "";
          const why = typeof o.reason === "string" ? o.reason.trim() : "";
          if (o.verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && why) {
              deferred.push((o.finding_id || "?") + "->" + ticket);
              continue;
          }
          // String concat, not a template literal: a dollar-brace inside this
          // single-quoted node block trips shellcheck SC2016, and the quotes
          // must stay single so the shell never expands the JS.
          blocking.push((o.finding_id || "?") + "(" + o.severity + "," +
              (o.verdict || "no-verdict") + ")");
          blockingFiles.push({ id: o.finding_id || "?",
              file: typeof o.file === "string" ? o.file : "" });
      }
  }
  for (const v of unadjByKey.values()) {
      if (v.verdict === undefined || v.verdict === null || v.verdict === "") {
          unadjudicated.push({ id: v.id, severity: v.severity, file: v.file, artifact: v.artifact, perspective: v.perspective });
      }
  }
  // HIMMEL-2128: CR_FLOOR_FALLBACK=claude-only eligibility. Verified-exhaustion
  // classes mirror failure-classify.sh quota/rate-limit buckets (HIMMEL-1176) -
  // a bare "quota" is also accepted for a caller not yet on the finer
  // quota-5h/quota-long split. Any OTHER reason (config, timeout, an
  // unclassified rc, auth, ...) - or NO reason at all - stays refused: a
  // failing lane is usually OUR OWN config and must be diagnosed, not routed
  // around. That asymmetry is the entire point of this knob. Silence (zero
  // non-claude avail rows at this head) is never eligible either - a lane that
  // never even attempted is not "verified exhausted".
  // HIMMEL-3107: a VACUOUS CodeRabbit pass (a success status with no review
  // behind it - the rate-limited / zero-review-object shapes check-ci reports)
  // is exhausted too, for model coderabbit ONLY: on any other lane "vacuous"
  // is not a classification failure-classify.sh emits. Twin of
  // claude-floor-review.sh eligible_lanes() - keep the two in step.
  const EXHAUSTION_REASONS = new Set(["quota", "quota-5h", "quota-long", "rate-limit"]);
  const isExhausted = (m, r) => r.status === "unavailable" &&
      (EXHAUSTION_REASONS.has(r.reason) || (m === "coderabbit" && r.reason === "vacuous"));
  const nonClaudeAvailModels = [...availByModel.keys()];
  const exhaustedLanes = [], nonExhaustedLanes = [];
  for (const m of nonClaudeAvailModels) {
      const r = availByModel.get(m);
      if (isExhausted(m, r)) {
          exhaustedLanes.push(m + "(reason=" + r.reason + ")");
      } else {
          nonExhaustedLanes.push(m + "(status=" + (r.status || "?") + ",reason=" + (r.reason || "none") + ")");
      }
  }
  // HIMMEL-3107: the empty panel is its own explicit unlock - critics.json
  // lists no panel critic at all (PANEL_EMPTY=1, read by the shell below), so
  // no non-Claude lane can ever record a row and silence IS the whole roster.
  // A non-empty or unreadable roster keeps "silence != exhaustion".
  const emptyPanel = e.PANEL_EMPTY === "1" && nonClaudeAvailModels.length === 0;
  if (emptyPanel) exhaustedLanes.push("empty-panel");
  const floorFallbackEligible = floorOk && (nonClaudeAvailModels.length > 0 || emptyPanel) &&
      nonExhaustedLanes.length === 0 && blocking.length === 0;
  console.log(JSON.stringify({ responders, nonClaudeResponders, blocking, blockingFiles, malformed, deferred, applied, unadjudicated, floorFallbackEligible, floorOk, exhaustedLanes, nonExhaustedLanes }));
' 2>/dev/null)
if [ -z "$verdict" ]; then
    echo "clear-cr-marker: could not read the CR ledger at $ledger — refusing (cannot certify the review)." >&2
    audit "REFUSED reason=ledger-unreadable branch=$branch sha=$tip"
    exit 14
fi
responders=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).responders))' 2>/dev/null)
non_claude_responders=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).nonClaudeResponders))' 2>/dev/null)
blocking=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).blocking.join(" ")))' 2>/dev/null)
malformed=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).malformed))' 2>/dev/null)
deferred=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log((JSON.parse(s).deferred||[]).join(" ")))' 2>/dev/null)
applied_amends=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log((JSON.parse(s).applied||[]).join(" ")))' 2>/dev/null)
unadjudicated_count=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log((JSON.parse(s).unadjudicated||[]).length))' 2>/dev/null)
# HIMMEL-2128: CR_FLOOR_FALLBACK=claude-only eligibility (see gate 3b below).
floor_fallback_eligible=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).floorFallbackEligible?1:0))' 2>/dev/null)
exhausted_lanes=$(printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log((JSON.parse(s).exhaustedLanes||[]).join(" ")))' 2>/dev/null)

# HIMMEL-3107: provenance of the context-free floor review. claude-floor-review.sh
# stamps <git-common-dir>/cr-floor/<full-head>.json with the head, the diff base,
# a hash of the exact diff it reviewed, the headless session id and the
# dispatch id of its claude-headless.sh registry row. Returns 0 only when that
# artifact exists, names THIS tip, its diff hash matches the diff between its
# base and this tip recomputed here - so a review of an older push or of some
# other diff never unlocks the floor - AND its ed25519 stamp verifies against
# the floor signing PUBLIC key (claude-floor.mjs verify, HIMMEL-3220), so a
# hand-written artifact (correct hash, invented session id) is refused.
# ponytail: the signer runs as the authoring leg's uid, so any same-uid process
# can still sign a forgery: run `claude-floor.mjs sign` with a registry row it
# wrote itself, read the private key (~/.himmel/cr-floor-key/signing.key), or
# swap the key pair. Even the headless reviewer is kept from the key only by
# Claude Code's cwd permission model (no grant outside its snapshot under
# acceptEdits), not by OS isolation, and that is unproven without a live
# run. The stamp stops the hand-written
# artifact, not a determined same-uid forger; the real fix is a signer on a
# separate uid legs cannot become (verification here is public-key only, so
# that move needs no gate change). Trust boundary: scripts/cr/claude-floor.mjs.
floor_provenance_ok() {
    local _art="$git_dir/cr-floor/$tip.json" _fields _base _want _got
    [ -s "$_art" ] || { floor_provenance_why="no floor artifact at $_art"; return 1; }
    _fields=$(ART="$_art" node -e '
      try { const a = JSON.parse(require("fs").readFileSync(process.env.ART, "utf8"));
            const ok = typeof a.head === "string" && typeof a.base === "string" &&
                       typeof a.diff_hash === "string" && typeof a.session_id === "string" &&
                       a.session_id.trim() !== "" && Array.isArray(a.findings);
            console.log(ok ? [a.head, a.base, a.diff_hash].join(" ") : "");
      } catch (_) { console.log(""); }' 2>/dev/null)
    [ -n "$_fields" ] || { floor_provenance_why="floor artifact $_art is malformed (needs head, base, diff_hash, session_id, findings)"; return 1; }
    read -r _got _base _want <<<"$_fields"
    [ "$_got" = "$tip" ] || { floor_provenance_why="floor artifact names head $_got, not ${tip}"; return 1; }
    # The hash binds the artifact to $_base...$tip, so $_base must be on the
    # REMOTE default branch: a mid-branch base hashes a narrower range that
    # reviewed only the newest slice of the branch, and a local main can hold
    # mid-PR commits. One resolver, shared with claude-floor-review.sh.
    case "$_base" in *[!0-9a-f]*|'') floor_provenance_why="floor artifact base '$_base' is not a commit sha"; return 1 ;; esac
    local _ref
    # shellcheck source=scripts/lib/cr-default-base.sh
    if ! { [ -f "$SCRIPT_DIR/../lib/cr-default-base.sh" ] && . "$SCRIPT_DIR/../lib/cr-default-base.sh" && _ref=$(cr_default_base_ref); }; then
        floor_provenance_why="no remote default branch (origin/HEAD or origin/main) to bind the floor artifact base to"; return 1
    fi
    git merge-base --is-ancestor "$_base" "$_ref" 2>/dev/null ||
        { floor_provenance_why="floor artifact base ${_base:0:8} is not on the default branch ($_ref) — the review did not cover the whole branch"; return 1; }
    _got=$(git diff --no-color --no-ext-diff "$_base...$tip" 2>/dev/null | git hash-object --stdin 2>/dev/null)
    if [ -z "$_got" ] || [ "$_got" != "$_want" ]; then
        floor_provenance_why="floor artifact diff hash $_want does not match the diff $_base...${tip:0:8} ($_got)"; return 1
    fi
    # HIMMEL-3220: the stamp. Public key only; a missing key fails closed.
    [ -f "$SCRIPT_DIR/claude-floor.mjs" ] || { floor_provenance_why="the stamp verifier $SCRIPT_DIR/claude-floor.mjs is missing"; return 1; }
    if ! _got=$(node "$SCRIPT_DIR/claude-floor.mjs" verify "$_art" 2>&1); then
        floor_provenance_why="${_got#claude-floor: }"; return 1
    fi
    return 0
}
# Say what was amended BEFORE reporting the verdict it produced. An amend can be
# the reason the gate cleared (it can re-key a blocking finding off this SHA, or
# lower its severity), so it must never be the one piece of decisive evidence
# the transcript omits.
if [ -n "$applied_amends" ]; then
    echo "clear-cr-marker: merged amend(s) while evaluating ${tip:0:8}: $applied_amends" >&2
    audit "AMENDS-MERGED branch=$branch sha=$tip merged=$applied_amends"
fi

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

# HIMMEL-3108 — how the marker ultimately cleared, appended to the CLEARED
# audit line (same mechanism as carry_audit below). Empty on every refusal, so
# a refusal never records a clearing basis.
clear_basis=""
cleared_via_floor=0

# 3b. Cross-model floor (HIMMEL-1237, opt-in via CR_REQUIRE_CROSS_MODEL). Default
# off => the Claude self-review floor alone satisfies gate 3 (HIMMEL-1224
# adopter-portable behaviour). When set (himmel's own .env), a single-model
# Claude review is NOT enough: require >=1 NON-claude 'avail ... ok' at this SHA.
# A configured cross-model lane (codex/glm/CodeRabbit) that was absent OR
# attempted-but-failed leaves no non-claude 'ok' row, so the gate stays CLOSED
# rather than clearing on the floor. Structural — enforced HERE in the gate, not
# by pr-check.md prose (HIMMEL-195).
if [ "${require_cross_model:-0}" = "1" ] && [ "${non_claude_responders:-0}" -lt 1 ]; then
    # HIMMEL-2128 — CR_FLOOR_FALLBACK=claude-only escape. floor_fallback_eligible
    # (computed above) is true only when EVERY non-Claude lane that recorded
    # ANY avail row at this head is verified quota/rate-limit exhausted, a
    # Claude avail-ok row exists, and zero blocking findings are recorded — a
    # lane that never ran, timed out, or failed for an unclassified reason
    # keeps this false, so the fallback never papers over our own broken
    # config, only a genuinely exhausted bank. Exit codes are otherwise
    # unchanged: when this does not fire, the refusal below is byte-identical
    # to before this ticket.
    floor_provenance_why=""
    if [ "$cr_floor_fallback" = "claude-only" ] && [ "${floor_fallback_eligible:-0}" = "1" ] && ! floor_provenance_ok; then
        echo "clear-cr-marker: CR_FLOOR_FALLBACK=claude-only would accept the floor at ${tip:0:8}, but the claude-floor review has no valid provenance: $floor_provenance_why. Re-run scripts/cr/claude-floor-review.sh at this head." >&2
        audit "REFUSED reason=floor-provenance branch=$branch sha=$tip"
        exit 14
    fi
    if [ "$cr_floor_fallback" = "claude-only" ] && [ "${floor_fallback_eligible:-0}" = "1" ]; then
        # HIMMEL-2128 codex-1: worded against what this gate ACTUALLY checks —
        # every non-Claude lane that RECORDED an avail row at this head, not a
        # roster of every lane the operator has configured (a lane configured
        # but never even attempted leaves no row, and floor_fallback_eligible
        # is false in that case — see the "silence != exhaustion" guard above).
        # Roster-vs-recorded hardening for a multi-lane future is HIMMEL-2129,
        # deliberately not implemented here.
        # HIMMEL-3107: say what the floor did and did NOT cover. The review ran
        # in a fresh headless claude session with only the diff + a raw-blob snapshot of
        # this head (no session transcript, no CLAUDE.md/memory/hooks), so it
        # does not share the authoring session's context. It is still the SAME
        # model family as the author: context-freshness removes the shared
        # context, not the shared-model blind spot. This is not cross-model
        # coverage and must never be reported as such.
        echo "clear-cr-marker: CR_FLOOR_FALLBACK=claude-only — accepting the context-free Claude floor review at ${tip:0:8}. Unlocked by: ${exhausted_lanes:-none} (every non-Claude lane recorded at this head is exhausted: quota/rate-limit, or a vacuous CodeRabbit pass; an empty panel is labelled empty-panel). COVERED: a fresh headless claude session reviewed only the diff and a snapshot of this head, with no session context. NOT COVERED: this is NOT cross-model review — the reviewer is the same model family as the author, so the shared-model blind spot remains. An auth/404/config/timeout failure on any lane still refuses — diagnose it instead of routing around it." >&2
        audit "FLOOR-FALLBACK branch=$branch sha=$tip reason=claude-only-floor-accepted exhausted=${exhausted_lanes:-none} responders=$responders same_model=1 context_free=1"
        # HIMMEL-3108: carry that identity through to the CLEARING outcome.
        # The FLOOR-FALLBACK note above records that gate 3b took the floor
        # path, but gates 4-5 can still refuse after it, so it is not a record
        # of how the marker cleared — and the terminal CLEARED line was
        # byte-identical whether a codex lane or a same-model floor certified
        # the head. A reader of clear-cr-marker.log could not answer "was this
        # SHA ever reviewed by a non-Claude lane?" from the clearing record.
        cleared_via_floor=1
        clear_basis=" via=claude-floor same_model=1 context_free=1 exhausted=${exhausted_lanes:-none}"
    else
        echo "clear-cr-marker: CR_REQUIRE_CROSS_MODEL is set but no non-Claude 'avail ... ok' responder exists at ${tip:0:8} (${responders:-0} total responders, ${non_claude_responders:-0} non-Claude). This setup requires cross-model coverage — a codex/glm/CodeRabbit lane must actually review this SHA. Configure/retry an external critic, or unset CR_REQUIRE_CROSS_MODEL. If the diff is TRIVIAL (a one-liner or docs-only), the panel used to strip its only paid tier and leave exactly this refusal with no explanation — it now keeps ONE critic instead when this variable is set (HIMMEL-1950), so re-run the panel; CR_TRIVIALITY_OVERRIDE=full forces the whole panel. CR_FLOOR_FALLBACK=claude-only accepts a Claude-only floor ONLY once every configured non-Claude lane is verified quota/rate-limit exhausted (not merely absent or misconfigured) AND the floor is a context-free review by scripts/cr/claude-floor-review.sh (a session-written 'claude' row does not count)." >&2
        audit "REFUSED reason=no-cross-model branch=$branch sha=$tip responders=$responders non_claude=${non_claude_responders:-0}"
        exit 14
    fi
fi

# HIMMEL-3108 — the clearing basis, stated rather than inferred from the
# ABSENCE of a floor tag (absence is exactly the silent-weakening shape this
# ticket closes). Only under the CR_REQUIRE_CROSS_MODEL opt-in is there a
# cross-model claim to qualify: with the knob unset the gate never claimed one,
# so the CLEARED line stays byte-identical to the adopter-portable default.
if [ "${require_cross_model:-0}" = "1" ] && [ "${cleared_via_floor:-0}" != "1" ]; then
    clear_basis=" via=cross-model non_claude=${non_claude_responders:-0}"
fi

# HIMMEL-1715: is <path> one of the NUL-delimited paths in <file>? String
# equality on whole records — no globbing, no regex, and nothing a pathname
# could contain changes the comparison.
_path_in_diff() {
    local _p
    while IFS= read -r -d '' _p; do [ "$_p" = "$1" ] && return 0; done < "$2"
    return 1
}

# 4. Blocking findings recorded at this SHA.
if [ -n "$blocking" ]; then
    echo "clear-cr-marker: blocking finding(s) recorded at ${tip:0:8}: $blocking — address them, resolve the threads, re-run /pr-check." >&2
    # HIMMEL-1715 provenance. A ledger row can be stamped with a branch+head
    # whose diff does not contain the file the finding is about (observed
    # 2026-08-10: a docs-only branch wedged by an Important on
    # merge-on-green.sh). The gate refuses correctly on the evidence it has,
    # but the refusal read exactly like a legitimate one — only noticing the
    # file was absent from the diff revealed it. So check the row against the
    # head it is blocking and SAY so. Diagnostic only: the gate still refuses.
    # Auto-ignoring an out-of-diff row would be a false-clean hole of exactly
    # the kind HIMMEL-1714 closed. An unreadable/empty diff prints nothing —
    # a wrong misattribution claim would push a real finding to be deferred.
    #
    # NUL-delimited end to end (CR round 1). Plain `git diff --name-only`
    # QUOTES any path holding a control character or backslash ("a\tb" ->
    # "a\\tb" in quotes) while the ledger carries it raw, and any in-band text
    # delimiter splits a path that contains that character. Both turn a real,
    # in-diff finding into a false PROVENANCE note — precisely the mirror
    # failure the fail-quiet guard above exists to avoid. NUL is the one byte a
    # pathname cannot contain, and it cannot survive in a shell variable, so
    # both streams go through temp files.
    _difffile="$(mktemp 2>/dev/null || true)"
    _bffile="$(mktemp 2>/dev/null || true)"
    if [ -n "$_difffile" ] && [ -n "$_bffile" ] \
       && git diff --name-only -z "$marker_base...$tip" > "$_difffile" 2>/dev/null \
       && [ -s "$_difffile" ]; then
        printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const r of (JSON.parse(s).blockingFiles||[])) process.stdout.write(r.id+"\0"+r.file+"\0");})' > "$_bffile" 2>/dev/null
        _ood=""
        # Two reads per record: the writer emits <id>NUL<file>NUL. `read -d ""`
        # is bash 3.2 safe; GNU-only `grep -z` is not (macOS ships BSD grep).
        while IFS= read -r -d '' _fid && IFS= read -r -d '' _ffile; do
            [ -n "$_ffile" ] || continue
            _path_in_diff "$_ffile" "$_difffile" && continue
            _ood="$_ood ${_fid}[${_ffile}]"
        done < "$_bffile"
        if [ -n "$_ood" ]; then
            echo "  PROVENANCE (HIMMEL-1715): the file(s) named by$_ood are absent from this head's own diff (git diff --name-only ${marker_base:0:8}...${tip:0:8}). A finding about a file this branch does not touch was recorded against the wrong diff — it is NOT evidence about this branch. Confirm against the panel output, then DEFER it with a ticket; do NOT mark it disproved, nobody has shown it wrong." >&2
            audit "PROVENANCE branch=$branch sha=$tip out_of_diff=$_ood"
        fi
    fi
    rm -f "$_difffile" "$_bffile"
    echo "  If a finding is genuinely out-of-diff / pre-existing / out-of-scope, DEFER it to a ticket instead of downgrading or disproving it (HIMMEL-1294):" >&2
    # `--set reason=` is NOT redundant with `--reason` (glm-3): the gate reads
    # the FINDING's reason, while --reason documents why the RECORD was wrong.
    # Omitting it leaves the deferral rejected for a missing reason, i.e. this
    # very hint would send the reader into a dead end.
    echo "    scripts/cr/ledger-append.sh amend --head ${tip_short:-$tip} --id <finding-id> --set verdict=deferred --set deferred_to=<TICKET> --set reason=\"<why it is out of scope here>\" --reason \"deferred after review\"" >&2
    audit "REFUSED reason=blocking-findings branch=$branch sha=$tip findings=$blocking"
    exit 15
fi
# Deferrals are not silent: they cleared the gate, so say so and name the tickets.
if [ -n "$deferred" ]; then
    echo "clear-cr-marker: deferred finding(s) at ${tip:0:8} (tracked, not blocking): $deferred" >&2
    audit "DEFERRED branch=$branch sha=$tip findings=$deferred"
fi

# 4b. Unadjudicated findings at this SHA (HIMMEL-2067). Gate 4 above only ever
# blocks on crit|imp, so a `sug` finding could be left with verdict:"" forever
# and the gate would still clear — under-counting cr-scores.sh and known-findings
# mining, which cannot tell an unreviewed finding from a confirmed or disproved
# one. A cleared head must carry a DECISION for every finding it recorded,
# suggestions included — not just an escape from the crit|imp floor. Runs AFTER
# the malformed-ledger refusal and the blocking-findings gate above, so a real
# crit|imp blocker still reports with ITS message first; by the time this is
# reached, any crit|imp finding with no verdict has already exited at gate 4
# (verdict "" is not "disproved"), so what remains here is genuinely the
# sug-shaped gap. No env bypass: the whole point is that every finding gets an
# actual decision, not a workaround.
if [ "${unadjudicated_count:-0}" -gt 0 ]; then
    echo "clear-cr-marker: ${unadjudicated_count} finding(s) at ${tip:0:8} have no recorded verdict — refusing. A cleared head must carry a decision for every finding, including suggestions." >&2
    _uafile="$(mktemp 2>/dev/null || true)"
    if [ -n "$_uafile" ]; then
        printf '%s' "$verdict" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const f of (JSON.parse(s).unadjudicated||[])) process.stdout.write((f.id||"?")+"\0"+(f.severity||"?")+"\0"+(f.file||"")+"\0"+(f.artifact||"diff")+"\0"+(f.perspective||"off")+"\0");})' > "$_uafile" 2>/dev/null
        while IFS= read -r -d '' _uid && IFS= read -r -d '' _usev && IFS= read -r -d '' _ufile && IFS= read -r -d '' _uart && IFS= read -r -d '' _upersp; do
            echo "  $_uid  severity=$_usev  file=$_ufile  artifact=$_uart  perspective=$_upersp" >&2
        done < "$_uafile"
        rm -f "$_uafile"
    fi
    # HIMMEL-2068 CR round: a finding recorded with a non-default artifact or
    # perspective amends onto a DIFFERENT ledger key (amendsMap is keyed on
    # all four of head/id/artifact/perspective, same as ledger-append.sh's own
    # amend target lookup) — so the recipe below MUST carry the exact
    # --artifact/--perspective values printed on the line above whenever they
    # are not the diff/off default, or the amend silently misses this finding
    # and the marker stays wedged. The generic --id <finding-id> is still a
    # placeholder; artifact/perspective are not.
    echo "  Record a decision for each, including suggestions, with the amend verb — a" >&2
    echo "  fresh 'finding' re-append dedups against the original row and refuses unless" >&2
    echo "  every other field is repeated byte-for-byte; amend does not have that trap." >&2
    echo "  Copy --artifact/--perspective from the finding's own line above if either is" >&2
    echo "  not the diff/off default shown there — omitting a non-default value targets" >&2
    echo "  the WRONG ledger key and leaves the marker wedged:" >&2
    echo "    scripts/cr/ledger-append.sh amend --head ${tip_short:-$tip} --id <finding-id> --artifact <artifact-from-above> --perspective <perspective-from-above> --set verdict=<agreed-or-disproved> --reason \"<one line>\"" >&2
    echo "  For a suggestion that is real but out of scope here, defer it instead (HIMMEL-1294):" >&2
    echo "    scripts/cr/ledger-append.sh amend --head ${tip_short:-$tip} --id <finding-id> --artifact <artifact-from-above> --perspective <perspective-from-above> --set verdict=deferred --set deferred_to=<TICKET> --reason \"<why>\"" >&2
    audit "REFUSED reason=unadjudicated-findings branch=$branch sha=$tip count=$unadjudicated_count"
    exit 14
fi

# 4c. Branch-wide still-open gate (HIMMEL-3027). Gate 4b above only sees the
# TIP; a finding left unadjudicated (or un-re-raised after an `agreed`) at an
# EARLIER round head on this branch is still unresolved CR business. Run the
# SAME check the console runs before promote/merge so the two verdicts can
# never drift apart (HIMMEL-2917, HIMMEL-2780).
#
# `review-round.sh promote` itself WRITES: any `agreed`-disposed row it finds
# is amended to verdict=fixed as part of computing still-open (coderabbitai,
# PR #743) — fine on a real run (a real run's whole job is to converge the
# ledger, and the console's own pre-merge check makes this exact call), but
# `--dry-run`'s contract is "run every gate, report the verdict, never write".
# `review-round.sh` has no check-only mode to ask for instead (out of scope
# to add one — HIMMEL-3027 touches only this file and its test), and the
# ledger it amends is a single shared file other branches/legs append to
# concurrently, so a snapshot-and-restore around the call would risk
# clobbering a concurrent writer's row. Skip the mutating call under
# --dry-run instead: the branch-wide verdict is simply not previewed, same as
# any other real-run-only side effect a dry run intentionally does not take.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "clear-cr-marker: [dry-run] skipping the branch-wide still-open check — scripts/cr/review-round.sh promote amends the shared ledger as a side effect of checking, and --dry-run must never write. Run without --dry-run, or run 'scripts/cr/review-round.sh promote --branch $branch --head $tip' directly, for the branch-wide verdict." >&2
else
    _promote_out="$(mktemp 2>/dev/null || true)"
    if [ -n "$_promote_out" ]; then
        bash "$SCRIPT_DIR/review-round.sh" promote --branch "$branch" --head "$tip" >"$_promote_out" 2>&1
        _promote_rc=$?
    else
        _promote_rc=1
    fi
    if [ "$_promote_rc" -eq 3 ]; then
        echo "clear-cr-marker: review-round.sh promote found still-open finding(s) at an earlier round head on $branch — refusing. Every round's ledger rows must carry a decision before the branch can clear, not just the tip's." >&2
        _stillopen_count=0
        if [ -n "$_promote_out" ] && [ -f "$_promote_out" ]; then
            while IFS= read -r _pline; do
                case "$_pline" in
                    "still-open "*)
                        echo "  $_pline" >&2
                        _stillopen_count=$((_stillopen_count + 1))
                        ;;
                esac
            done < "$_promote_out"
        fi
        echo "  Record a decision for each row above at its OWN head with the amend verb:" >&2
        echo "    scripts/cr/ledger-append.sh amend --head <head-from-above> --id <finding-id> --artifact <artifact> --perspective <perspective> --set verdict=<agreed-or-disproved> --reason \"<one line>\"" >&2
        rm -f "$_promote_out"
        audit "REFUSED reason=unadjudicated-earlier-round branch=$branch sha=$tip count=$_stillopen_count"
        exit 14
    elif [ "$_promote_rc" -ne 0 ]; then
        echo "clear-cr-marker: review-round.sh promote exited $_promote_rc (malformed ledger, bad head, or missing ledger) for $branch@${tip_short:-$tip} — refusing closed rather than clearing on a broken ledger." >&2
        if [ -n "$_promote_out" ] && [ -f "$_promote_out" ]; then
            cat "$_promote_out" >&2
        fi
        rm -f "$_promote_out"
        audit "REFUSED reason=promote-error branch=$branch sha=$tip code=$_promote_rc"
        exit 14
    fi
    rm -f "$_promote_out"
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
# GraphQL budget preflight (HIMMEL-3190): this lookup is the first of the two
# GraphQL-spending steps here (check-ci.sh, below, is the second and runs its own
# preflight). When the shared budget is exhausted, wait for the reset — bounded
# by CLEAR_CR_MARKER_BUDGET_WAIT (default 300 s) and a plain `sleep` (no sleep
# seam: the GATE INTEGRITY note above keeps this script's collaborators fixed) —
# rather than let the lookup fail into `pr-lookup-failed`. A reset beyond the
# bound refuses with the SAME exit 16 an unreadable PR state already gets, so
# no exit code changes meaning.
# ponytail: a missing helper file skips this ADVISORY wait (fail-open on the
# preflight only); the lookup and check-ci below still fail closed on their own.
GHB_LIB="$SCRIPT_DIR/../lib/gh-graphql-budget.sh"
if [ -f "$GHB_LIB" ]; then
    # shellcheck source=scripts/lib/gh-graphql-budget.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$GHB_LIB"
    if ! ghb_wait_for_budget "${CLEAR_CR_MARKER_BUDGET_WAIT:-300}" sleep; then
        echo "clear-cr-marker: GitHub GraphQL budget exhausted beyond the ${CLEAR_CR_MARKER_BUDGET_WAIT:-300}s bound — cannot read the PR state; refusing. Re-run after the reset." >&2
        audit "REFUSED reason=graphql-budget-exhausted branch=$branch sha=$tip"
        exit 16
    fi
fi
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
    ci_capture=$(mktemp 2>/dev/null || true)
    if [ -n "$ci_capture" ]; then
        bash "$CHECK_CI" "$pr_num" | tee "$ci_capture"
        ci_rc=${PIPESTATUS[0]}
    else
        # Preserve the gate if capture setup fails; only the optional provenance
        # annotation is unavailable on this exceptional path.
        bash "$CHECK_CI" "$pr_num" || ci_rc=$?
    fi
    if [ "$ci_rc" -ne 0 ]; then
        [ -z "$ci_capture" ] || rm -f "$ci_capture"
        echo "clear-cr-marker: PR #$pr_num exists and its check-ci gate is not green (exit $ci_rc) — refusing. Address CI / unresolved threads, then re-run." >&2
        audit "REFUSED reason=ci-not-green branch=$branch pr=#$pr_num check_ci=$ci_rc"
        exit 16
    fi
    if [ -n "$ci_capture" ]; then
        carry_line=$(grep -F 'check-ci: FRESHNESS panel carry stale_anchor=' "$ci_capture" | tail -1 || true)
        rm -f "$ci_capture"
        if [ -n "$carry_line" ]; then
            # Test each key is PRESENT before extracting it: `${line#*key=}`
            # returns the WHOLE line when `key=` is absent, so a bare
            # extract-then-test would read a missing field as a non-empty
            # (garbage) value and write it into the durable audit line. The
            # `case` guards make the -n test below mean what it says.
            carry_stale=""; carry_responders=""; carry_models=""
            case "$carry_line" in *stale_anchor=*)
                carry_stale=${carry_line#*stale_anchor=}; carry_stale=${carry_stale%% *} ;;
            esac
            case "$carry_line" in *responders=*)
                carry_responders=${carry_line#*responders=}; carry_responders=${carry_responders%% *} ;;
            esac
            case "$carry_line" in *models=*)
                carry_models=${carry_line#*models=}; carry_models=${carry_models%% *} ;;
            esac
            if [ -n "$carry_stale" ] && [ -n "$carry_responders" ] && [ -n "$carry_models" ]; then
                carry_audit=" carry=freshness-panel stale_anchor=$carry_stale responders=$carry_responders models=$carry_models"
            fi
        fi
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$stale_marker" -eq 1 ]; then
        audit "DRYRUN would-clear reason=stale-marker-superseded-by-ledger-at-tip branch=$branch marker_sha=$marker_sha tip=$tip responders=$responders${pr_num:+ pr=#$pr_num}"
    else
        audit "DRYRUN would-clear branch=$branch sha=$tip responders=$responders${pr_num:+ pr=#$pr_num}"
    fi
    echo "clear-cr-marker: [dry-run] gates passed — would clear the marker for $branch (${tip:0:8}). Not clearing."
    exit 0
fi

# ── The marker lock (HIMMEL-1558) ───────────────────────────────────────────
# Re-validate IMMEDIATELY before deleting, INSIDE a branch-scoped lock the
# pre-push marker writer takes too. The gates above take real time — the gh
# lookup, and post-PR a full check-ci watch — and check-cr-before-push.sh
# rewrites this same branch-scoped file on every push. A push landing inside
# that window replaces the marker with one certifying a NEWER, unreviewed SHA;
# deleting that would open `gh pr create` for code no critic ever saw.
#
# Re-reading alone collapsed the window to the microseconds between the check
# and the unlink but was NOT mutual exclusion — a push in that final sliver
# still raced. The lock closes it: the writer cannot rewrite the marker between
# this re-validation and the `rm` because it must hold the same lock to write.
#
# The lock is taken HERE, not around the whole gate run: the gates are minutes
# long (check-ci watches CI), and blocking every push on this branch for that
# long would be a worse failure than the race it prevents. The critical section
# is read-validate-delete, which is sub-second plus one ls-remote.
#
# `flock` is absent on the Git Bash this repo targets, so the primitive is the
# repo's existing mkdir-based lock lib under its own namespace (see its
# NAMESPACE + TTL RECLAMATION headers).
#
# GATE INTEGRITY: CR_MARKER_LOCK_WAIT_SECONDS tunes only how long this waits
# before REFUSING. Both directions fail closed — a shorter wait refuses sooner,
# a longer one waits longer — so unlike the ledger/check-ci/gh seams it cannot
# make this gate clear anything it would otherwise refuse. The TTL is a
# constant precisely because shortening IT would be the weakening direction.
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"
MARKER_LOCK_TTL=300
case "${CR_MARKER_LOCK_WAIT_SECONDS:-}" in
    ''|*[!0-9]*) marker_lock_wait=10 ;;
    *) marker_lock_wait="$CR_MARKER_LOCK_WAIT_SECONDS" ;;
esac
marker_lock_held=0
# Set once the lock is held (see the re-check before the unlink below).
lock_owner=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap installed below
release_marker_lock() {
    [ "$marker_lock_held" -eq 1 ] || return 0
    marker_lock_held=0
    # Never release a lock that was RECLAIMED from us -- that would delete the
    # current holder's lock and put two writers on the marker at once. The
    # release must therefore be conditional on the holder record, and it must
    # be so WITHOUT a check-then-release window of its own (CR round 2,
    # codex-3), which is what release-if-owner provides.
    #
    # An EMPTY holder record has NO unconditional fallback (HIMMEL-1994): a
    # plain `release` is an rm, and with no record to compare there is no way
    # to tell OUR lock from a replacement holder's -- so the fallback deleted a
    # live lock exactly when the ownership evidence was missing. The acquire
    # path below refuses instead, so this leaves the lock for the TTL (or the
    # manual release it names) rather than guessing.
    [ -n "$lock_owner" ] || return 0
    _rml_rc=0
    SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$LOCK_LIB" \
        release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || _rml_rc=$?
    if [ "$_rml_rc" -eq 3 ]; then
        echo "clear-cr-marker: WARNING: the CR marker lock for '$branch' was reclaimed from this run — leaving the current holder's lock alone." >&2
    elif [ "$_rml_rc" -ne 0 ]; then
        echo "clear-cr-marker: WARNING: could not release the CR marker lock for '$branch' — the next writer reclaims it after ${MARKER_LOCK_TTL}s." >&2
    fi
    return 0
}
# Set while the marker is claimed by rename (see the unlink below). The claim
# empties the canonical path for the two syscalls between the rename and the
# delete-or-restore; dying in that window would leave the marker orphaned at
# the claim path and `gh pr create` silently OPEN for this branch forever
# (CR round 7, codex-1). The restore is idempotent and runs on the way out.
marker_claim=""
# shellcheck disable=SC2329,SC2317  # invoked via the traps installed below
restore_marker_claim() {
    [ -n "$marker_claim" ] || return 0
    [ -e "$marker_claim" ] || return 0
    # ATOMIC create-if-absent, never a check-then-act: `ln` fails when the path
    # already exists, so a marker written while the path was free cannot be
    # clobbered by the restore — and such a marker is NEWER than this one.
    # The fallback for a filesystem without hard links is `set -C`, which makes
    # the redirect O_EXCL and so fails on an existing path too — a test
    # followed by `mv` was still check-then-act, and a marker created between
    # the two got overwritten (CR round 8, codex-2).
    if ! ln "$marker_claim" "$marker" 2>/dev/null; then
        ( set -C; cat "$marker_claim" > "$marker" ) 2>/dev/null || true
    fi
    # Both atomic attempts can fail for two very different reasons, and the
    # claim must NOT be deleted unconditionally (CR round 9, codex-1): if they
    # failed because the path is unwritable rather than occupied, the claim is
    # the ONLY copy of the certificate, and removing it opens `gh pr create`
    # on a REFUSAL path — the exact fail-open this ticket exists to close.
    if [ -e "$marker" ]; then
        # Occupied: the attempts failed because a NEWER marker landed. Ours is
        # stale, so dropping it is correct and the gate stays closed.
        rm -f "$marker_claim"
    elif mv "$marker_claim" "$marker" 2>/dev/null; then
        # Still absent: a filesystem error, not a race. `mv` is a last resort
        # and NOT create-if-absent, so it could in principle clobber a marker
        # landing in this instant — accepted deliberately, because the only
        # alternative here is no marker at all. A stale marker merely BLOCKS
        # `gh pr create`, which is the fail-CLOSED direction.
        :
    else
        # Even the last resort failed. Keep the claim: a certificate parked at
        # an odd path is recoverable, a deleted one is not.
        echo "clear-cr-marker: WARNING: could not restore the CR marker for '$branch' — the certificate is still on disk at $marker_claim, but $marker is EMPTY, so \`gh pr create\` is UNGATED for this branch until you move it back." >&2
    fi
    marker_claim=""
    return 0
}
# Every refusal below this point exits, so the release rides on EXIT rather
# than being repeated on each path (one of them would eventually be missed,
# and a leaked lock blocks pushes until the TTL). The marker goes back BEFORE
# the lock is released, so the writer this run excludes never observes the
# empty path. The signal traps exist because bash does NOT run an EXIT trap
# when it dies on an untrapped fatal signal, which is exactly the interruption
# that would make the claim window permanent.
trap 'restore_marker_claim; release_marker_lock' EXIT
trap 'restore_marker_claim; release_marker_lock; exit 130' INT
trap 'restore_marker_claim; release_marker_lock; exit 143' TERM
trap 'restore_marker_claim; release_marker_lock; exit 129' HUP

if [ ! -f "$LOCK_LIB" ]; then
    echo "clear-cr-marker: the branch-lock library is missing at $LOCK_LIB — refusing. Without mutual exclusion a concurrent push could replace this marker between the final check and the unlink." >&2
    audit "REFUSED reason=no-marker-lock-lib branch=$branch sha=$tip"
    exit 11
fi
lock_out=$(SHARED_BRANCH_LOCK_NS=himmel-cr-marker SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
    bash "$LOCK_LIB" acquire-wait "." "$branch" "clear-cr-marker" "$marker_lock_wait" "$MARKER_LOCK_TTL" 2>&1)
lock_rc=$?
if [ -n "$lock_out" ]; then printf '%s\n' "$lock_out" >&2; fi
if [ "$lock_rc" -ne 0 ]; then
    echo "clear-cr-marker: another writer holds the CR marker lock for '$branch' (waited ${marker_lock_wait}s, lock rc=$lock_rc) — refusing. A push is rewriting this marker right now; let it finish, then re-run /pr-check." >&2
    audit "REFUSED reason=marker-lock-busy branch=$branch sha=$tip lock_rc=$lock_rc waited=$marker_lock_wait"
    exit 13
fi
marker_lock_held=1
# Our own holder record, re-checked before the unlink below. The TTL that stops
# a dead holder from wedging the branch forever cuts both ways: a critical
# section that outruns the TTL (a hung ls-remote) can be RECLAIMED under us,
# and then the writer we were excluding is running again. Comparing the holder
# record turns that into a refusal instead of a silent loss of exclusion.
lock_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$LOCK_LIB" status "." "$branch" 2>/dev/null || true)
# An EMPTY record here is NOT "no holder" — status prints a fixed sentinel for
# an absent owner.json, so empty means the record itself could not be read: a
# zero-byte owner.json (acquire creates it by redirect and keeps rc 0 when the
# printf fails, e.g. ENOSPC), or a failed read. Accepting it would compare ""
# against "" at the pre-unlink re-check, which PASSES for any holder, real or
# replacement — the exclusion this lock provides would be asserted from no
# evidence at all. Refuse instead (HIMMEL-1994). The lock is deliberately NOT
# released on the way out: without a holder record a release cannot tell our
# lock from a replacement holder's, and deleting a live one is the two-writer
# failure this whole section exists to prevent.
if [ -z "$lock_owner" ]; then
    echo "clear-cr-marker: the CR marker lock for '$branch' was acquired but its holder record is EMPTY (zero-byte or unreadable owner.json) — refusing, because this run cannot prove it still holds the lock before unlinking. The lock is left in place; if nothing else is running, clear it with: SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash scripts/lib/shared-branch-lock.sh release . '$branch'" >&2
    audit "REFUSED reason=marker-lock-owner-unreadable branch=$branch sha=$tip"
    exit 13
fi

now_sha=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
now_marker=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$marker" 2>/dev/null || true)
now_marker_lane=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$marker" 2>/dev/null || true)
now_marker_remote=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4; exit}' "$marker" 2>/dev/null || true)
now_marker_remote_ref=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5; exit}' "$marker" 2>/dev/null || true)
now_marker_endpoint=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$marker" 2>/dev/null || true)
now_marker_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$marker" 2>/dev/null || true)
# The LANE is part of the marker's identity, not decoration: it selected which
# review /pr-check ran. A marker reminted as docs-audit while the gates ran is
# a DIFFERENT obligation than the one this run certified, and the stale-marker
# fallback above (which refuses a stale docs-audit lane) never sees it because
# it read the lane before the gates. Checked FIRST so the lane change is what
# the refusal names when a push changed both fields (HIMMEL-1558).
if [ "$now_marker_lane" != "$marker_lane" ]; then
    echo "clear-cr-marker: the marker LANE changed while the gates ran ('$marker_lane' -> '${now_marker_lane:-none}') — refusing to clear a marker this run did not certify. The lane selects which review is owed; re-run /pr-check for the '${now_marker_lane:-none}' lane." >&2
    audit "REFUSED reason=raced-lane-changed branch=$branch validated_lane=$marker_lane now_lane=${now_marker_lane:-none} sha=$tip"
    exit 13
fi
if [ "$now_sha" != "$tip" ] || [ "$now_marker" != "$marker_sha" ] ||
   [ "$now_marker_remote" != "$marker_remote" ] || [ "$now_marker_remote_ref" != "$marker_remote_ref" ] ||
   [ "$now_marker_endpoint" != "$marker_endpoint" ] || [ "$now_marker_base" != "$marker_base" ]; then
    echo "clear-cr-marker: the branch or its marker changed while the gates ran (tip ${tip:0:8}->${now_sha:0:8}, marker ${marker_sha:0:8}->${now_marker:0:8}) — refusing to clear a marker this run did not certify. Re-run /pr-check on the new HEAD." >&2
    audit "REFUSED reason=raced-during-gate branch=$branch validated_sha=$tip now_sha=$now_sha now_marker=$now_marker"
    exit 13
fi
now_remote_head=$(resolve_marker_remote_head) || {
    echo "clear-cr-marker: the marker-bound remote became unreadable while the gates ran — refusing to clear. Re-run /pr-check when the remote is available." >&2
    audit "REFUSED reason=remote-raced-unreadable branch=$branch remote=$marker_remote remote_ref=$marker_remote_ref"
    exit 13
}
if [ "$now_remote_head" != "$tip" ]; then
    echo "clear-cr-marker: the marker-bound remote changed while the gates ran (${remote_head:0:8}->${now_remote_head:0:8}) — refusing to clear. Re-run /pr-check on the new remote head." >&2
    audit "REFUSED reason=remote-raced-during-gate branch=$branch validated_sha=$tip remote_head=$now_remote_head"
    exit 13
fi

# Last thing before the unlink: are we still the holder? (See lock_owner above.)
now_lock_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$LOCK_LIB" status "." "$branch" 2>/dev/null || true)
if [ "$now_lock_owner" != "$lock_owner" ]; then
    echo "clear-cr-marker: the CR marker lock changed hands while the gates ran — this run no longer holds it, so a concurrent push may be rewriting the marker right now. Refusing to unlink. Re-run /pr-check." >&2
    audit "REFUSED reason=marker-lock-lost branch=$branch sha=$tip"
    exit 13
fi

# CLAIM, then delete (CR round 4, codex-1). Everything above is still
# check-then-act: a verification followed by an unlink leaves a gap, and no
# lock closes it — a process starved past the TTL loses the lock between the
# two, and the resumed unlink would delete whatever marker is at the path by
# then. Renaming first removes the gap instead of narrowing it: the unlink
# operates on the bytes it claimed, so what is deleted is provably the marker
# this run certified, and a marker written concurrently lands at the now-free
# path and SURVIVES (a surviving marker only ever BLOCKS `gh pr create`, which
# is the fail-closed direction).
#
# The window the claim opens — the canonical path is empty between the rename
# and the delete-or-restore — is closed on the way out by restore_marker_claim
# above, on every exit path AND on INT/TERM/HUP (CR round 7, codex-1).
_pending_claim="$marker.clearing.$$"
rm -f "$_pending_claim"
if ! mv "$marker" "$_pending_claim" 2>/dev/null; then
    echo "clear-cr-marker: failed to claim $marker for deletion (it vanished, or the rename failed) — refusing." >&2
    audit "REFUSED reason=marker-claim-failed branch=$branch sha=$tip"
    exit 12
fi
# Armed only now: before the rename there is nothing to put back, and after it
# every exit path — including the two refusals below and a fatal signal — must
# put the marker back rather than leave the gate open.
marker_claim="$_pending_claim"
claimed_content=$(cat "$marker_claim" 2>/dev/null || true)
if [ "$claimed_content" != "$marker_content" ]; then
    restore_marker_claim
    echo "clear-cr-marker: the marker was rewritten between this run's last check and the unlink — the certificate this run validated is not the one on disk. Refusing (nothing was deleted). Re-run /pr-check on the new HEAD." >&2
    audit "REFUSED reason=marker-content-changed branch=$branch sha=$tip"
    exit 13
fi
if ! rm -f "$marker_claim"; then
    # The claim survives, so the trap restores it: a marker this run could not
    # delete must stay pending, not vanish.
    echo "clear-cr-marker: failed to remove $marker_claim" >&2
    audit "REFUSED reason=rm-failed branch=$branch sha=$tip"
    exit 12
fi
# Deleted for real — disarm the restore.
marker_claim=""
if [ "$stale_marker" -eq 1 ]; then
    echo "clear-cr-marker: WARNING: stale marker ${marker_sha:0:8} cleared only because the ledger gates certified the current tip ${tip:0:8}." >&2
    audit "CLEARED reason=stale-marker-superseded-by-ledger-at-tip branch=$branch marker_sha=$marker_sha tip=$tip responders=$responders${pr_num:+ pr=#$pr_num}${carry_audit:-}${clear_basis:-}"
else
    audit "CLEARED branch=$branch sha=$tip responders=$responders${pr_num:+ pr=#$pr_num}${carry_audit:-}${clear_basis:-}"
fi
if [ "${cleared_via_floor:-0}" = "1" ]; then
    # Same prefix as the ordinary line (pr-check.md step 5 reports it verbatim),
    # then the part that differs: what actually certified this head.
    echo "clear-cr-marker: CR clean — marker cleared for $branch (${tip:0:8}) ON THE SAME-MODEL FLOOR: a context-free Claude floor review cleared it, NOT a cross-model critic (unlocked by ${exhausted_lanes:-none}). The shared-model blind spot is uncovered at this SHA — say so wherever this PR's review coverage is reported. Safe to gh pr create."
else
    echo "clear-cr-marker: CR clean — marker cleared for $branch (${tip:0:8}). Safe to gh pr create."
fi
exit 0
