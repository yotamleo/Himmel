#!/usr/bin/env bash
# cr/cr-pending-audit.sh — machine classification of pending CR markers
# (HIMMEL-1553): NEEDS-ACTION with a named remedy, never a narrative.
#
# Live incident (2026-08-04): HIMMEL-1519 needed ZERO code changes — it was
# blocked by a stale CR marker, and two tools printed the exact remedy
# ("re-run /pr-check on this HEAD"). The orchestrator instead reasoned to the
# conclusion "structurally unopenable", wrote that into the append-only ledger
# AND the next leg's handover, and the false conclusion propagated as inherited
# fact for FOUR legs. The actual unblock was three commands and worked first
# try.
#
# This script is the structural counter: it RE-DERIVES, from the marker + the
# branch tip + the CR ledger, what state every pending marker is actually in,
# and prints one parseable line per marker with class= and remedy=. Every
# classification is NEEDS-ACTION — a pending CR marker is NEVER a terminal
# block; each state names its next command. A "blocked" claim that cannot cite
# a refusal from the named remedy is a narrative, not a fact.
#
# READ-ONLY + ADVISORY by design. It never clears a marker and never certifies
# a review — clear-cr-marker.sh keeps that authority, with its fail-closed
# ledger read. That split is why this audit may use the cheaper prefix-based
# head match and skip malformed ledger lines: its failure direction is
# OVER-reporting NEEDS-ACTION, whose remedy is running the authoritative gate.
#
# Usage: cr-pending-audit.sh [--ticket <KEY-N>] [<branch>...]
#   (no args)        sweep every marker under <git-common-dir>/cr-pending/
#                    whose branch still exists; orphaned markers (branch
#                    deleted) are summarized in one line, not audited.
#   --ticket KEY-N   only markers whose branch names the ticket (boundary
#                    match, case-insensitive). Scoped mode also reports the
#                    ticket's orphaned markers individually.
#   <branch>...      audit exactly these branches (marker or not).
#
# Classes (all NEEDS-ACTION):
#   stale-marker      marker certifies a commit the branch moved past
#                     -> re-run /pr-check on this HEAD
#   no-review-at-tip  marker is at the tip but no critic RESPONDED there (an
#                     avail status=ok row — the same predicate clear-cr-marker
#                     gate 3 uses; failed/rate-limited attempts do not count)
#                     -> run /pr-check on this HEAD
#   findings-at-tip   blocking finding(s) recorded at the tip
#                     -> address or defer them, re-run /pr-check
#   gates-may-pass    review evidence exists, nothing blocking visible
#                     -> run scripts/cr/clear-cr-marker.sh <branch> (it may
#                        clear right now; it is also the authoritative check)
#   unreadable-marker marker file exists but its SHA cannot be read
#                     -> inspect the marker file
#
# Exit codes:
#   0  nothing pending (no markers in scope, or only orphans)
#   1  >= 1 NEEDS-ACTION line printed
#   2  usage error / not a git repo
set -uo pipefail

command -v git >/dev/null 2>&1 || { echo "cr-pending-audit: required tool 'git' not on PATH" >&2; exit 2; }

ticket=""
branches=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ticket)
            [ $# -ge 2 ] || { echo "cr-pending-audit: --ticket requires a value" >&2; exit 2; }
            ticket="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "cr-pending-audit: unknown option: $1" >&2; exit 2 ;;
        *)  branches+=("$1"); shift ;;
    esac
done
if [ -n "$ticket" ] && ! printf '%s' "$ticket" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'; then
    echo "cr-pending-audit: --ticket must be a key like HIMMEL-1519 (got '$ticket')" >&2
    exit 2
fi

git_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ -n "$git_dir" ] || { echo "cr-pending-audit: not a git repository" >&2; exit 2; }
pending_dir="$git_dir/cr-pending"
ledger="$git_dir/cr-critic-scores.jsonl"

needs_action=0
orphans=0

# branch_matches_ticket <branch> — boundary-guarded on BOTH sides (non-alnum,
# hyphen allowed), case-insensitive: HIMMEL-151 never matches a himmel-1519
# branch, and himmel-1519abc is not a HIMMEL-1519 branch (codex-2 class, CR
# round 2 — a digit-only trailing guard let a letter suffix count).
branch_matches_ticket() {
    printf '%s' "$1" | grep -qiE "(^|[^a-zA-Z0-9])${ticket}([^a-zA-Z0-9]|\$)"
}

# ledger_counts <full-tip> — echoes "<responders> <blocking>" for the tip.
# Prefix head-match + skipped malformed lines are ADVISORY-SAFE here (header);
# amends ARE applied so an already-corrected finding (HIMMEL-1294) is not
# re-reported as blocking. Requires node; without it, report unknown ("? ?")
# and let the classifier fall back to the authoritative gate remedy.
ledger_counts() {
    command -v node >/dev/null 2>&1 || { echo "? ?"; return 0; }
    LEDGER="$ledger" TIP="$1" node -e '
      const fs=require("fs"),e=process.env;
      const lines=fs.existsSync(e.LEDGER)?fs.readFileSync(e.LEDGER,"utf8").split("\n").filter(Boolean):[];
      const tip=String(e.TIP).toLowerCase();
      // 7-64 hex chars (HIMMEL-2029): a SHA-1 repo full head is 40 hex, a
      // SHA-256 repo full head is 64 - the old 7-40 ceiling rejected every
      // 41-64-char head in a SHA-256 repo as "not a head" at all. Plain
      // prefix matching, no extra length gate (codex-1 CR round 2 raised, and
      // an attempted "shorter than tip.length" gate round 3 disproved: it
      // rejected every real 40-63-char SHA-256 abbreviation, which a genuine
      // abbreviated head legitimately can be). The cross-format concern round
      // 2 raised - an unrelated commit whose full spelling happens to
      // textually prefix this tip - needs an actual accidental hex-prefix
      // collision across a 160+ bit hash, which is cryptographically
      // negligible, not a realistic engineering risk; this audit is
      // ADVISORY-ONLY besides (see the file header), so plain prefix
      // matching is the correct, simpler tradeoff.
      const at=(h)=>{h=String(h||"").trim().toLowerCase();
        return /^[0-9a-f]{7,64}$/.test(h)&&(h===tip||tip.indexOf(h)===0);};
      // Amends key on target_head, NOT head. Current ledger-append writes
      // normalize abbreviated heads to full SHAs, but legacy ledgers may still
      // contain the SAME commit in both short and full forms. An exact-string
      // head match here silently skips an amend recorded in the other form and
      // re-reports an already-corrected finding as blocking (codex-1/glm-5, CR
      // round 2 — the chain runbook carries this exact trap). Heads are
      // therefore compared by hex prefix in EITHER direction, the same posture
      // as at() above. Advisory-safe:
      // this only applies corrections, and the authoritative gate keeps its
      // own fail-closed read. Amends apply SEQUENTIALLY in ledger order, so a
      // set.head re-key updates o.head and later amends match the moved head
      // (mirrors ledger-append original-or-effective matching).
      // Same posture as at() above - plain prefix matching, no extra length
      // gate (an attempted one broke the ordinary short+full same-commit
      // pairing this function exists for, CR round 3).
      const sameHead=(x,y)=>{x=String(x||"").trim().toLowerCase();y=String(y||"").trim().toLowerCase();
        if(!/^[0-9a-f]{7,64}$/.test(x)||!/^[0-9a-f]{7,64}$/.test(y))return false;
        return x.indexOf(y)===0||y.indexOf(x)===0;};
      const SEP=String.fromCharCode(31);
      const amends=[];
      for(const l of lines){let a;try{a=JSON.parse(l);}catch{continue;}
        if(a.kind!=="amend"||!a.set||typeof a.set!=="object")continue;
        amends.push({th:a.target_head,k:[a.finding_id,a.artifact||"diff",a.perspective||"off"].join(SEP),set:a.set});}
      // responders uses the SAME predicate as clear-cr-marker gate 3: only an
      // avail row with status "ok" is a critic that responded. usage rows and
      // avail "unavailable" (failed/rate-limited attempts) are NOT evidence —
      // counting them classified an interrupted review as "gates-may-pass"
      // while the authoritative gate would refuse it (adversarial round 3,
      // failed-attempt-as-completed-review; worst exactly here, because this
      // panel is labelled more trustworthy than inherited prose).
      let responders=0,blocking=0;
      for(const l of lines){let o;try{o=JSON.parse(l);}catch{continue;}
        if(o.kind==="amend")continue;
        if(o.kind==="finding"){
          const k=[o.finding_id,o.artifact||"diff",o.perspective||"off"].join(SEP);
          for(const a of amends){ if(a.k===k&&sameHead(a.th,o.head)) o=Object.assign({},o,a.set); }
        }
        if(!at(o.head))continue;
        if(o.kind==="avail"&&o.status==="ok")responders++;
        if(o.kind==="finding"&&(o.severity==="crit"||o.severity==="imp")&&o.verdict!=="disproved"){
          const t=typeof o.deferred_to==="string"?o.deferred_to.trim():"";
          const why=typeof o.reason==="string"?o.reason.trim():"";
          if(!(o.verdict==="deferred"&&/^[A-Z][A-Z0-9]*-[0-9]+$/.test(t)&&why))blocking++;
        }}
      console.log(responders+" "+blocking);
    ' 2>/dev/null || echo "? ?"
}

# audit_branch <branch> — prints the classification line(s) for one branch.
audit_branch() {
    local branch="$1" marker msha tip counts responders blocking
    marker="$pending_dir/$branch"
    if [ ! -f "$marker" ]; then
        echo "cr-pending-audit: branch=$branch no pending marker — nothing gating gh pr create here."
        return 0
    fi
    tip=$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)
    if [ -z "$tip" ]; then
        echo "cr-pending-audit: branch=$branch class=INFO reason=orphan-marker remedy=\"branch no longer exists locally; the marker is dead weight (prune via /clean_garden)\""
        return 0
    fi
    msha=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$marker" 2>/dev/null)
    if [ -z "$msha" ]; then
        echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=unreadable-marker remedy=\"inspect $marker — its certified SHA cannot be read\""
        needs_action=$((needs_action+1))
        return 0
    fi
    if [ "$msha" != "$tip" ]; then
        echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=stale-marker marker=${msha:0:8} tip=${tip:0:8} remedy=\"re-run /pr-check on this HEAD — the review does not cover the current code\""
        needs_action=$((needs_action+1))
        return 0
    fi
    counts=$(ledger_counts "$tip")
    responders="${counts%% *}"; blocking="${counts##* }"
    if [ "$responders" = "?" ]; then
        echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=ledger-unreadable tip=${tip:0:8} remedy=\"run scripts/cr/clear-cr-marker.sh $branch for the authoritative verdict (node unavailable here)\""
        needs_action=$((needs_action+1))
        return 0
    fi
    if [ "${responders:-0}" -eq 0 ]; then
        echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=no-review-at-tip tip=${tip:0:8} remedy=\"run /pr-check on this HEAD — no critic RESPONDED here (a failed/rate-limited attempt is a missing signal, not a review)\""
        needs_action=$((needs_action+1))
        return 0
    fi
    if [ "${blocking:-0}" -gt 0 ]; then
        echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=findings-at-tip tip=${tip:0:8} blocking=$blocking remedy=\"address or defer the finding(s) (ledger-append.sh amend / --deferred-to), then re-run /pr-check\""
        needs_action=$((needs_action+1))
        return 0
    fi
    echo "cr-pending-audit: branch=$branch class=NEEDS-ACTION reason=gates-may-pass tip=${tip:0:8} remedy=\"run scripts/cr/clear-cr-marker.sh $branch — evidence looks clean, the marker may clear right now\""
    needs_action=$((needs_action+1))
}

if [ "${#branches[@]}" -gt 0 ]; then
    for b in "${branches[@]}"; do audit_branch "$b"; done
else
    if [ -d "$pending_dir" ]; then
        # Branch names contain slashes, so markers nest (cr-pending/fix/slug).
        # find + sort keeps the sweep deterministic; process substitution (not a
        # pipe into while) so needs_action survives the loop (no subshell).
        while IFS= read -r f; do
            b="${f#"$pending_dir"/}"
            if [ -n "$ticket" ] && ! branch_matches_ticket "$b"; then continue; fi
            if ! git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
                if [ -n "$ticket" ]; then
                    audit_branch "$b"     # scoped mode: orphans reported individually
                else
                    orphans=$((orphans+1))
                fi
                continue
            fi
            audit_branch "$b"
        done < <(find "$pending_dir" -type f 2>/dev/null | sort)
    fi
    if [ "$orphans" -gt 0 ]; then
        echo "cr-pending-audit: $orphans marker(s) for branches that no longer exist locally — dead weight, not audited (prune worktrees/branches via /clean_garden)."
    fi
fi

if [ "$needs_action" -gt 0 ]; then
    echo "cr-pending-audit: every class above is NEEDS-ACTION — a pending CR marker is NEVER a terminal block (HIMMEL-1519/1553). Do not record a branch as blocked/unopenable unless you RAN the named remedy and can cite its refusal output."
    exit 1
fi
exit 0
