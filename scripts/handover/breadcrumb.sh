#!/usr/bin/env bash
# scripts/handover/breadcrumb.sh — durable resume breadcrumb writer + resolver
# (HIMMEL-477, C3).
#
# WHY ----------------------------------------------------------------------
# Twice, an armed overnight resume found "no captured stop-point" and grounded
# in raw repo state — silently losing the armed work. C3 makes resume
# failure-survivable: after each pipeline stage the loop drops a versioned
# breadcrumb (ticket, branch, base + head SHA, completed dispatches, next step);
# on resume a resolver cross-references that breadcrumb against `git log` + open
# Jira and, when the breadcrumb is MISSING or STALE, FLAGS it explicitly
# ("DEGRADED — confirm before proceeding") instead of silently degrading to
# whatever the repo happens to look like now.
#
# There is no per-leg dispatch runtime to hook (inject-initiative is
# SessionStart-only; the legs are self-paced prose) — so `write` is invoked from
# the seams that ALREADY run between stages (the /overnight-shift post-fanout
# step, /pr-check, the handover writer). The breadcrumb root reuses the
# single-root resolver (scripts/lib/handover-path.sh) — never a hardcoded path.
#
# CLI ----------------------------------------------------------------------
#   breadcrumb.sh write   --ticket T [--branch B] [--base-sha S] [--head-sha H]
#                         [--next-step "..."] [--completed "x"]... [--cwd DIR]
#                         [--out PATH]
#   breadcrumb.sh resolve [--ticket T] [--cwd DIR] [--breadcrumb PATH]
#                         [--jira-cmd "CMD"] [--no-jira]
#
# write: a versioned JSON breadcrumb at <handover-root>/breadcrumbs/<ticket>.json
#   (override with --out). branch / head-sha / base-sha auto-detect from the
#   --cwd git repo when omitted. base-sha = merge-base vs the default branch
#   (best-effort; empty if it can't be computed).
#
# resolve: reads the breadcrumb and classifies the resume:
#   - FRESH    — breadcrumb exists AND its head_sha == current HEAD → deterministic
#                resume; prints the recorded next step + completed dispatches. exit 0.
#   - DEGRADED — breadcrumb MISSING, or STALE (head_sha != current HEAD, or branch
#                diverged) → reconstructs candidate intent from `git log` (commits
#                naming the ticket) + open Jira (when available) and prints
#                "DEGRADED — confirm before proceeding". NEVER silent. exit 3.
#   Jira enrichment runs the jira CLI when present (default
#   <repo>/scripts/jira/dist/index.js if it exists, or --jira-cmd); --no-jira
#   skips it. A jira failure degrades to git-only, it never crashes resolve.
#
# Exit codes: 0 fresh resume · 1 usage error · 2 handover root unresolvable ·
#             3 degraded (missing/stale breadcrumb — confirm before proceeding).
#
# bash 3.2-safe; shellcheck-clean; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh" || { echo "breadcrumb: cannot source handover-path.sh" >&2; exit 2; }

die() { printf 'breadcrumb: %s\n' "$1" >&2; exit 1; }

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# Extract a TICKET-like token (e.g. HIMMEL-477) from a branch name, upper-cased.
_ticket_from_branch() {
    printf '%s' "$1" | grep -Eio '[a-z]+-[0-9]+' | head -n1 | tr '[:lower:]' '[:upper:]'
}

# A ticket key must be <PROJECT>-<N> — it is interpolated into the breadcrumb
# FILENAME and into the jira lookup, so reject anything else up front (empty,
# path separators, '..', shell metacharacters) to close path-traversal /
# empty-filename / injection vectors.
_valid_ticket() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*-[0-9]+$'
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
SUBCMD="$1"; shift

# --- write ----------------------------------------------------------------

cmd_write() {
    local ticket="" branch="" base_sha="" head_sha="" next_step="" out="" cwd="."
    local completed=""   # newline-separated
    while [ $# -gt 0 ]; do
        case "$1" in
            --ticket)    [ -n "${2:-}" ] || die "--ticket requires a value"; ticket="$2"; shift 2 ;;
            --branch)    [ -n "${2:-}" ] || die "--branch requires a value"; branch="$2"; shift 2 ;;
            --base-sha)  [ -n "${2:-}" ] || die "--base-sha requires a value"; base_sha="$2"; shift 2 ;;
            --head-sha)  [ -n "${2:-}" ] || die "--head-sha requires a value"; head_sha="$2"; shift 2 ;;
            --next-step) [ -n "${2:-}" ] || die "--next-step requires a value"; next_step="$2"; shift 2 ;;
            --completed) [ -n "${2:-}" ] || die "--completed requires a value"; completed="$completed$2"$'\n'; shift 2 ;;
            --out)       [ -n "${2:-}" ] || die "--out requires a PATH"; out="$2"; shift 2 ;;
            --cwd)       [ -n "${2:-}" ] || die "--cwd requires a DIR"; cwd="$2"; shift 2 ;;
            -h|--help)   usage; exit 0 ;;
            *) die "write: unknown arg: $1" ;;
        esac
    done
    [ -n "$ticket" ] || die "write: --ticket is required"
    _valid_ticket "$ticket" || die "write: invalid --ticket '$ticket' (want <PROJECT>-<N>, e.g. HIMMEL-477)"

    # Auto-detect git facts when not supplied.
    if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        [ -n "$branch" ]   || branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        [ -n "$head_sha" ] || head_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
        if [ -z "$base_sha" ]; then
            local db
            db="$(git -C "$cwd" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
            [ -n "$db" ] || db="main"
            base_sha="$(git -C "$cwd" merge-base "$db" HEAD 2>/dev/null || git -C "$cwd" merge-base "origin/$db" HEAD 2>/dev/null || true)"
        fi
    fi

    # Resolve output path (write op → _ensure so Mode A inline dir is created).
    if [ -z "$out" ]; then
        local root
        root="$(handover_root_ensure)" || { echo "breadcrumb write: handover root unresolvable — pass --out" >&2; exit 2; }
        mkdir -p "$root/breadcrumbs"
        out="$root/breadcrumbs/$ticket.json"
    else
        mkdir -p "$(dirname "$out")"
    fi

    # Build JSON via node (safe escaping + array for completed). Write
    # ATOMICALLY: serialize to a temp file, round-trip-verify it parses, then
    # rename into place — so a crash/disk-full mid-write never leaves a partial
    # breadcrumb (which resolve could misread) and never clobbers a prior good one.
    local tmp="$out.tmp.$$"
    TICKET="$ticket" BRANCH="$branch" BASE="$base_sha" HEAD_="$head_sha" \
    NEXT="$next_step" COMPLETED="$completed" TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" OUT="$tmp" node -e '
      const fs=require("fs"), e=process.env;
      const completed=(e.COMPLETED||"").split("\n").filter(Boolean);
      const rec={version:1,ts:e.TS,ticket:e.TICKET,branch:e.BRANCH,
                 base_sha:e.BASE,head_sha:e.HEAD_,completed,next_step:e.NEXT};
      const s=JSON.stringify(rec,null,2)+"\n";
      fs.writeFileSync(e.OUT, s);
      JSON.parse(fs.readFileSync(e.OUT,"utf8"));   // verify round-trip before commit
    ' || { rm -f "$tmp"; die "write: failed to serialize/verify breadcrumb (node error)"; }
    mv -f "$tmp" "$out" || { rm -f "$tmp"; die "write: failed to install breadcrumb at $out"; }
    echo "breadcrumb write: $out (ticket=$ticket head=${head_sha:0:12})"
}

# --- resolve --------------------------------------------------------------

cmd_resolve() {
    local ticket="" cwd="." bc_path="" jira_cmd="" no_jira=0 jira_set=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --ticket)     [ -n "${2:-}" ] || die "--ticket requires a value"; ticket="$2"; shift 2 ;;
            --cwd)        [ -n "${2:-}" ] || die "--cwd requires a DIR"; cwd="$2"; shift 2 ;;
            --breadcrumb) [ -n "${2:-}" ] || die "--breadcrumb requires a PATH"; bc_path="$2"; shift 2 ;;
            --jira-cmd)   [ -n "${2:-}" ] || die "--jira-cmd requires a value"; jira_cmd="$2"; jira_set=1; shift 2 ;;
            --no-jira)    no_jira=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) die "resolve: unknown arg: $1" ;;
        esac
    done

    # Current git state (best-effort — resolve still works outside a repo).
    local cur_branch="" cur_head=""
    if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        cur_branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        cur_head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
    fi

    # Derive ticket from the current branch if not given.
    [ -n "$ticket" ] || ticket="$(_ticket_from_branch "$cur_branch")"
    [ -n "$ticket" ] || die "resolve: no --ticket and none derivable from branch '$cur_branch'"
    _valid_ticket "$ticket" || die "resolve: invalid ticket '$ticket' (want <PROJECT>-<N>)"

    # Locate the breadcrumb.
    if [ -z "$bc_path" ]; then
        local root
        if root="$(handover_root)"; then
            bc_path="$root/breadcrumbs/$ticket.json"
        else
            # Root unresolvable for READ is not fatal here — treat as missing
            # breadcrumb and degrade (the whole point is to never hard-stop a
            # resume). Note it so the operator knows enrichment is partial.
            echo "breadcrumb resolve: handover root unresolvable — treating breadcrumb as missing" >&2
            bc_path=""
        fi
    fi

    # Read + parse the breadcrumb (if present).
    local have_bc=0 bc_branch="" bc_head="" bc_base="" bc_next="" bc_completed="" bc_ts=""
    if [ -n "$bc_path" ] && [ -f "$bc_path" ]; then
        local parsed
        parsed="$(BC="$bc_path" node -e '
          const fs=require("fs"), e=process.env;
          try{
            const j=JSON.parse(fs.readFileSync(e.BC,"utf8"));
            // A breadcrumb MUST be a JSON object — reject arrays/scalars/null so
            // a parseable-but-wrong file degrades to "corrupt", never "fresh".
            if(!j || typeof j!=="object" || Array.isArray(j)) throw new Error("not a breadcrumb object");
            const c=(j.completed||[]).join("; ");
            process.stdout.write([j.branch||"",j.head_sha||"",j.base_sha||"",j.next_step||"",c,j.ts||""].join(String.fromCharCode(1)));
          }catch(err){ console.error("breadcrumb resolve: corrupt breadcrumb "+e.BC+": "+err.message); process.exit(1); }
        ')" && have_bc=1 || have_bc=0
        if [ "$have_bc" -eq 1 ]; then
            # Disable pathname expansion before the unquoted split: a field (e.g.
            # next_step) containing a glob char (* ?) must NOT be expanded against
            # the cwd. IFS=$'\001' gives the field split; set -f kills globbing.
            local IFS_OLD="$IFS"; IFS=$'\001'; set -f
            # shellcheck disable=SC2086
            set -- $parsed
            set +f; IFS="$IFS_OLD"
            bc_branch="${1:-}"; bc_head="${2:-}"; bc_base="${3:-}"; bc_next="${4:-}"; bc_completed="${5:-}"; bc_ts="${6:-}"
        fi
    fi

    # Classify: FRESH is a POSITIVE, VERIFIED assertion (both SHAs present AND
    # equal AND branch consistent) — NOT a fall-through. Anything we cannot
    # positively verify DEGRADES with a specific reason, so an empty current HEAD
    # (resolve outside a git repo / git failure) or a breadcrumb missing head_sha
    # is flagged, never silently blessed as "deterministic resume".
    local status reason
    if [ "$have_bc" -ne 1 ]; then
        status="DEGRADED"
        if [ -n "$bc_path" ] && [ -f "$bc_path" ]; then reason="breadcrumb corrupt ($bc_path)"; else reason="breadcrumb missing ($ticket)"; fi
    elif [ -z "$bc_head" ]; then
        status="DEGRADED"; reason="breadcrumb has no head_sha (incomplete/old-schema) — cannot verify resume point"
    elif [ -z "$cur_head" ]; then
        status="DEGRADED"; reason="cannot read current HEAD (not in a git repo?) — cannot verify breadcrumb head ${bc_head:0:12}"
    elif [ "$cur_head" != "$bc_head" ]; then
        status="DEGRADED"; reason="stale — breadcrumb head ${bc_head:0:12} != current HEAD ${cur_head:0:12} (repo advanced/diverged since)"
    elif [ -n "$cur_branch" ] && [ -n "$bc_branch" ] && [ "$cur_branch" != "$bc_branch" ]; then
        status="DEGRADED"; reason="stale — breadcrumb branch '$bc_branch' != current branch '$cur_branch'"
    else
        status="FRESH"; reason="breadcrumb head matches current HEAD"
    fi

    # Git cross-reference: commits naming the ticket (recent, across refs).
    # Case-sensitive fixed-string match: ticket keys are upper-cased and commit
    # refs use the same case, AND some MINGW greps abort (SIGABRT) on the -iF
    # combination — so -F alone, never -iF.
    local git_hits=""
    if [ -n "$cur_head" ]; then
        git_hits="$(git -C "$cwd" log --oneline -n 30 --all 2>/dev/null | grep -F -- "$ticket" | head -n 8 || true)"
    fi

    # Jira enrichment (optional, fail-soft). Default to the repo's jira CLI when
    # present; honour --jira-cmd / --no-jira.
    local jira_line=""
    if [ "$no_jira" -eq 1 ]; then
        jira_line="(skipped — --no-jira)"
    else
        if [ "$jira_set" -ne 1 ]; then
            if [ -f "$SCRIPT_DIR/../jira/dist/index.js" ]; then
                jira_cmd="node \"$SCRIPT_DIR/../jira/dist/index.js\""
            fi
        fi
        if [ -n "$jira_cmd" ]; then
            # eval is needed because jira_cmd is a shell command string (e.g.
            # `node "/path/index.js"`). The injection surface is bounded: $ticket
            # is validated to ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ above (no metachars),
            # and jira_cmd is operator-supplied (their own CLI), not attacker input.
            local jout
            if jout="$(eval "$jira_cmd get $ticket" 2>/dev/null)" && [ -n "$jout" ]; then
                jira_line="$(printf '%s\n' "$jout" | head -n1)"
            else
                jira_line="(jira lookup failed — git-only reconstruction)"
            fi
        else
            jira_line="(no jira CLI found — pass --jira-cmd to enable)"
        fi
    fi

    # Report ---------------------------------------------------------------
    printf '== resume resolver: %s ==\n' "$ticket"
    printf 'STATUS: %s — %s\n' "$status" "$reason"
    printf 'current: branch=%s HEAD=%s\n' "${cur_branch:-<none>}" "${cur_head:0:12}"
    if [ "$status" = "FRESH" ]; then
        printf 'breadcrumb: written %s\n' "${bc_ts:-?}"
        printf 'base_sha: %s\n' "${bc_base:-<none>}"
        printf 'completed: %s\n' "${bc_completed:-<none>}"
        printf 'NEXT STEP: %s\n' "${bc_next:-<none recorded>}"
        printf 'resume is deterministic — proceed from NEXT STEP.\n'
        exit 0
    fi

    # Degraded: reconstruct candidate intent and FLAG it.
    printf '\n-- candidate intent (RECONSTRUCTED — do not trust blindly) --\n'
    if [ "$have_bc" -eq 1 ]; then
        printf 'stale breadcrumb recorded NEXT STEP: %s\n' "${bc_next:-<none>}"
        printf 'stale breadcrumb completed: %s\n' "${bc_completed:-<none>}"
    fi
    printf 'git commits naming %s:\n' "$ticket"
    if [ -n "$git_hits" ]; then printf '%s\n' "$git_hits" | sed 's/^/  /'; else printf '  (none found)\n'; fi
    printf 'jira: %s\n' "$jira_line"
    printf '\nSTATUS: DEGRADED — confirm before proceeding (resume did NOT silently degrade to raw repo state).\n'
    exit 3
}

case "$SUBCMD" in
    write)     cmd_write "$@" ;;
    resolve)   cmd_resolve "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown subcommand: $SUBCMD (want write|resolve)" ;;
esac
