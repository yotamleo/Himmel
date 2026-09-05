#!/usr/bin/env bash
# scripts/cr/hermes-critic.sh — Orchestrator-Critic reviewer over a branch diff
# (HIMMEL-273). Claude implements, a fresh model family reviews: this script
# assembles the final code changes (NEVER the orchestrator's plans/reasoning —
# reviewer isolation, ticket item 3), sends them through the hermes chokepoint
# (scripts/hermes/invoke.sh) under a strict JSON response contract, and
# enforces a fail-closed verdict.
#
# Verdict policy (fail-closed, ticket item 2): any security_concerns or
# logic_errors entry forces passed=false regardless of what the model set.
#
# Bounded auto-fix loop (ticket item 4) lives in the ORCHESTRATOR, not here:
# on exit 1, feed the JSON report back to the implementer, fix, re-run.
# Max 2-3 iterations, then escalate to the operator.
#
# Failure mode (ticket item 5): hermes quota/auth/transport errors exit 3
# (fail-open) with a warning on stderr — the caller falls back to the
# gemini-cli route or claude-only review and notes that in its summary.
#
# Exit codes:
#   0  review ran, verdict passed=true   (JSON report on stdout)
#   1  review ran, verdict passed=false  (JSON report on stdout)
#   2  usage / not a git repo / empty diff
#   3  hermes transport/auth/quota failure or unparseable response (fail-open)
#
# Usage:
#   hermes-critic.sh [--repo <dir>] [--base <ref>] [--goal "<text>"|--goal-file <p>]
#                    [--model <name>] [--max-pack-bytes <n>]
#
# Defaults: repo = cwd; base = merge-base with the default branch — origin/main,
# origin/master, main, then master in order (HIMMEL-297);
# route = hermes with NO --model, but the HERMES route itself now defaults to
# the critics.json-pinned gpt-6-astra/openai-codex (HIMMEL-2059, operator
# ruling 2026-08-23) — NOT the himmel_agent hermes profile default (ox-alpha
# today: free, front-tier, temporary; operator ruling 2026-08-22 on
# HIMMEL-2017; lane profiling: HIMMEL-2024). ox-alpha stays the profile
# default for implementation/one-shot dispatch (hermes-oneshot); CR critics
# just no longer ride it. HERMES_CRITIC_MODEL still overrides the pin.
# That default deliberately spends no Claude subscription bank: a claude
# print-mode default would draw the same 5h/weekly bank as interactive use
# (HIMMEL-128) with no bank-preflight. `--route claude` is opt-in.
# (The 2026-06-12 nemotron spike default died: no strict JSON obedience on the
# NIM free tier; the 550b ultra took 105s+ on a trivial prompt.)
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail
# headless-claude-ok: the opt-in `--route claude` pass IS the CR critic lane's
# sanctioned product surface (HIMMEL-2017), not unattended background work.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../hermes/invoke.sh"

usage() {
    cat >&2 <<'EOF'
Usage: hermes-critic.sh [--repo <dir>] [--base <ref>]
                        [--goal "<text>" | --goal-file <path>]
                        [--route claude|hermes|both] [--implementer <lane>]
                        [--model <name>] [--max-pack-bytes <n>]

Cross-family CR: the reviewer must be a DIFFERENT family than whoever produced
the diff. Routing is by implementer:

  no --implementer and no CRITIC_ROUTE
      -> HERMES reviewer with no --model: defaults to the critics.json-pinned
         gpt-6-astra (HIMMEL-2059) — NOT the himmel_agent profile default.
         Spends no Claude bank (it spends the OpenAI Codex bank instead).
  hermes (any hermes-driven dev plan, incl. ox-alpha)
      -> CLAUDE CLI reviewer (claude print-mode; opt-in bank spend);
         optionally add a second hermes pass via --route both.
  codex CLI / claude CLI / other lanes
      -> HERMES reviewer, UNLESS the hermes reviewer is itself codex-family
         (HERMES_CRITIC_MODEL / HERMES_CRITIC_FAMILY, or the gpt-6-astra
         default itself) — then CLAUDE CLI.

An explicit --route overrides all of that and may knowingly break the
cross-family guarantee (e.g. --route hermes on a hermes-implemented diff).

--model applies to WHICHEVER route runs, and the hermes reviewer's family is
inferred from its resolved model id (gpt-*/o<N>*/codex* => codex, claude-* =>
claude, empty => the profile default, unreachable in practice since the
hermes route always resolves a model — see HIMMEL-2059 default above).
HERMES_CRITIC_FAMILY overrides that inference — use it when --model names a
claude-route model, or when the id does not match these patterns.

Env: CRITIC_ROUTE=claude|hermes|both, HERMES_CRITIC_MODEL=<model>,
     HERMES_CRITIC_FAMILY=<family>.
JSON report on stdout. Exit 0 pass / 1 fail / 2 usage / 3 transport
(fail-open — fall back to another review route).
EOF
}

repo=""
base=""
goal=""
goal_file=""
route="${CRITIC_ROUTE:-}"
hermes_model="${HERMES_CRITIC_MODEL:-}"   # empty falls through to the critics.json-pinned default below (HIMMEL-2059)
model=""
max_pack_bytes=200000

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)      [ $# -ge 2 ] || { usage; exit 2; }; repo="$2"; shift 2 ;;
        --base)      [ $# -ge 2 ] || { usage; exit 2; }; base="$2"; shift 2 ;;
        --goal)      [ $# -ge 2 ] || { usage; exit 2; }; goal="$2"; shift 2 ;;
        --goal-file) [ $# -ge 2 ] || { usage; exit 2; }; goal_file="$2"; shift 2 ;;
        --route)     [ $# -ge 2 ] || { usage; exit 2; }; route="$2"; shift 2 ;;
        --implementer) [ $# -ge 2 ] || { usage; exit 2; }; impl_lane="$2"; shift 2 ;;
        --model)     [ $# -ge 2 ] || { usage; exit 2; }; model="$2"; shift 2 ;;
        --max-pack-bytes) [ $# -ge 2 ] || { usage; exit 2; }; max_pack_bytes="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "hermes-critic.sh: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -n "$repo" ]; then
    cd "$repo" || { echo "hermes-critic.sh: cannot cd to --repo: $repo" >&2; exit 2; }
fi
git rev-parse --git-dir >/dev/null 2>&1 || { echo "hermes-critic.sh: not a git repo: $(pwd)" >&2; exit 2; }

if [ -n "$goal_file" ]; then
    [ -f "$goal_file" ] || { echo "hermes-critic.sh: goal file not found: $goal_file" >&2; exit 2; }
    goal="$(cat "$goal_file")"
fi
[ -n "$goal" ] || goal="(no task goal provided — review the change on its own merits)"

# HIMMEL-2059 (operator ruling 2026-08-23): CR critics must not ride the
# himmel_agent hermes profile default (ox-alpha today — free/front-tier,
# reserved for implementation/one-shot work, HIMMEL-2024). When neither
# --model nor HERMES_CRITIC_MODEL pins the hermes reviewer, default it to the
# critics.json "codex" row's model (gpt-6-astra/openai-codex) — the same pin
# the codex-CLI panel critic uses. Reused rather than duplicated into a
# second panel row: critic-panel.sh iterates every critics.json row with a
# slug+model as a live /pr-check panel member, so a second row would
# double-dispatch this exact model under a different slug. critics.json is
# thus the single source; the literal below is only the last-resort fallback
# if the registry is missing/unreadable. This must resolve BEFORE
# hermes_family() below is first called (route derivation), so the cross-family
# guarantee sees the real default family, not an empty placeholder.
if [ -z "$model" ] && [ -z "$hermes_model" ]; then
    if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/critics.json" ]; then
        hermes_model="$(REG="$SCRIPT_DIR/critics.json" node -e '
          const fs = require("fs");
          try {
            const panel = JSON.parse(fs.readFileSync(process.env.REG, "utf8")).panel || [];
            const row = panel.find(r => r && r.slug === "codex");
            if (row && row.model) process.stdout.write(row.model);
          } catch (e) {}
        ' 2>/dev/null)"
    fi
    [ -n "$hermes_model" ] || hermes_model="gpt-6-astra"
fi

# Which model family the HERMES reviewer actually is. HIMMEL-2059: hermes_model
# now defaults to the critics.json-pinned gpt-6-astra (codex family) rather
# than the profile default, so `codex -> hermes` is SAME-family by default —
# the route-derivation case below already falls back to claude for that
# combination. The "" branch is a defensive fallback only (e.g. an explicit
# --model ""), not the normal default path anymore. Override with
# HERMES_CRITIC_FAMILY when needed.
hermes_family() {
    # Validated at top level, not here: this function is only ever called inside
    # a command substitution, where `exit` would kill the subshell and leave the
    # script running with an empty family.
    if [ -n "${HERMES_CRITIC_FAMILY:-}" ]; then printf '%s' "$HERMES_CRITIC_FAMILY"; return 0; fi
    local id="${model:-$hermes_model}"
    # Match on the bare id: provider-qualified forms (openai-codex/gpt-6-astra,
    # openrouter/anthropic/claude-...) would otherwise fall through to 'other'
    # and skip the same-family fallback entirely.
    id="${id##*/}"
    case "$id" in
        "")                    printf 'profile-default' ;;  # ox-alpha today
        gpt-*|o[0-9]*|codex*)  printf 'codex' ;;
        claude-*)              printf 'claude' ;;
        *)                     printf 'other' ;;
    esac
}

# Fail closed on a typo: an unrecognised family would compare unequal to every
# implementer and so read as "different family", silently defeating the very
# guarantee the override exists to steer.
case "${HERMES_CRITIC_FAMILY:-}" in
    ""|codex|claude|other|profile-default) : ;;
    *) echo "hermes-critic.sh: unknown HERMES_CRITIC_FAMILY '$HERMES_CRITIC_FAMILY' (codex|claude|other|profile-default)" >&2; exit 2 ;;
esac

# HIMMEL-2017 route selection by implementer family (cross-family guarantee):
# the reviewer family must differ from the implementer family. Explicit
# --route/CRITIC_ROUTE wins; else derive from --implementer; else hermes.
case "$route" in
    claude|hermes|both) : ;;                       # explicit route wins verbatim
    "")
        case "${impl_lane:-}" in
            ""|other) route="hermes" ;;         # default: free front-tier profile model
            hermes)   route="claude" ;;         # hermes-implemented -> Claude CLI reviews
            codex|claude)
                # hermes reviews, but only while it is not the implementer's own
                # family. When it IS, the Claude CLI is genuinely cross-family
                # for a codex implementer — and NOT for a claude one, which
                # leaves no cross-family route at all. Fail CLOSED there rather
                # than return a verdict that looks cross-family and is not; an
                # explicit --route (handled above) is the deliberate override.
                if [ "$(hermes_family)" != "$impl_lane" ]; then
                    route="hermes"
                elif [ "$impl_lane" = "codex" ]; then
                    route="claude"
                else
                    echo "hermes-critic.sh: --implementer claude with a claude-family hermes reviewer leaves no cross-family route (HERMES_CRITIC_MODEL/HERMES_CRITIC_FAMILY select the reviewer). Point the hermes reviewer at another family, or pass --route explicitly to override the guarantee deliberately." >&2
                    exit 2
                fi ;;
            *) echo "hermes-critic.sh: unknown --implementer '${impl_lane}' (hermes|codex|claude|other)" >&2; exit 2 ;;
        esac
        ;;
    *) echo "hermes-critic.sh: unknown --route '$route' (claude|hermes|both)" >&2; exit 2 ;;
esac

# Resolve the diff base: explicit --base, else merge-base with the default
# branch (main OR master, HIMMEL-297) — origin first, then local. The diff is
# the FINAL code change only (reviewer isolation). Two-dot semantics ($base
# HEAD) everywhere: with a merge-base SHA the result equals three-dot, and with
# an explicit --base ref two-dot is what the caller literally asked to compare
# against.
if [ -z "$base" ]; then
    base="$(git merge-base HEAD origin/main 2>/dev/null \
        || git merge-base HEAD origin/master 2>/dev/null \
        || git merge-base HEAD main 2>/dev/null \
        || git merge-base HEAD master 2>/dev/null \
        || echo "")"
fi
[ -n "$base" ] || { echo "hermes-critic.sh: could not resolve a diff base (no origin/main, origin/master, main, or master merge-base — pass --base)" >&2; exit 2; }

diff_text="$(git diff "$base" HEAD)" || { echo "hermes-critic.sh: git diff failed for base $base" >&2; exit 2; }
if [ -z "$diff_text" ]; then
    echo "hermes-critic.sh: empty diff vs $base — nothing to review" >&2
    exit 2
fi

# Context pack: the post-change content of each touched file (the critic sees
# what the code IS, not how the orchestrator got there), truncated to the
# byte budget. Default 200KB of pack
# stays comfortably inside it alongside the diff.
pack_file="$(mktemp "${TMPDIR:-/tmp}/hermes-critic-pack.XXXXXX")"
trap 'rm -f "$pack_file"' EXIT

{
    printf '%s\n' "You are an independent code-review critic in an Orchestrator-Critic pipeline. The implementation was produced by a different model; review the FINAL code change on its objective merits, like a human PR reviewer. You are seeing only the code — no plans, no chat history."
    printf '%s\n' ""
    printf '%s\n' "Respond with ONLY a JSON object — no markdown fences, no prose before or after — matching exactly this schema:"
    printf '%s\n' '{"passed": boolean, "security_concerns": string[], "logic_errors": string[], "architectural_mismatches": string[], "suggestions": string[], "summary": string}'
    printf '%s\n' "Rules: passed=false if there is ANY security concern or logic error. architectural_mismatches = the change fights the surrounding code's structure or conventions. suggestions = non-blocking improvements."
    printf '%s\n' ""
    printf '%s\n' "## Original task goal"
    printf '%s\n' "$goal"
    printf '%s\n' ""
    printf '%s\n' "## Diff under review ($base..HEAD)"
    printf '%s\n' "$diff_text"
    printf '%s\n' ""
    printf '%s\n' "## Post-change content of touched files (truncated to budget)"
    git diff --name-only "$base" HEAD | while IFS= read -r f; do
        [ -f "$f" ] || continue   # deleted files have no post-change content
        printf '\n===== %s =====\n' "$f"
        cat "$f"
    done
} | head -c "$max_pack_bytes" > "$pack_file"
# head -c closing the pipe early SIGPIPEs the writers (rc 141) — that is
# intended truncation, not an error. Anything else is a real assembly failure.
pack_rc=${PIPESTATUS[0]}
if [ "$pack_rc" -ne 0 ] && [ "$pack_rc" -ne 141 ]; then
    echo "hermes-critic.sh: context-pack assembly failed (rc=$pack_rc)" >&2
    exit 2
fi
if [ "$(wc -c < "$pack_file")" -ge "$max_pack_bytes" ]; then
    printf '\n[CONTEXT PACK TRUNCATED AT %s BYTES — file contents above may end mid-file]\n' "$max_pack_bytes" >> "$pack_file"
fi

# Dispatch through the chokepoint. Toolset stays the invoke.sh default (todo,
# neutralized) — a critic must not run tools. Stderr is captured (not
# discarded): auth/quota errors must reach the operator, not be collapsed
# into an anonymous transport failure.
err_file="$(mktemp "${TMPDIR:-/tmp}/hermes-critic-err.XXXXXX")"
trap 'rm -f "$pack_file" "$err_file"' EXIT
run_claude_review() {
    # Reviewer isolation, three layers:
    #  - tools: --tools "" disables the built-in toolset outright, so untrusted
    #    diff content has nothing to reach for. --permission-mode plan and
    #    --max-turns 1 are defence in depth, not the tool fence: plan mode still
    #    permits read-only and outward-facing tools that ambient user settings
    #    allow, and max-turns only bounds the round-trips.
    #  - context: scratch cwd + empty MCP config so the reviewed repo's CLAUDE.md,
    #    hooks, memory and MCP servers are NOT loaded — the diff is untrusted input.
    # KNOWN LIMIT: this isolates the REPO scope only. User-scope ~/.claude
    # settings, CLAUDE.md, memory and SessionStart hooks still load, because the
    # scratch cwd does not move HOME. Full scrubbing needs a dedicated HOME,
    # which would also cut the reviewer off from its own credentials — out of
    # scope here, so treat the claude route as repo-isolated, not fully sandboxed.
    # --output-format json + envelope unwrap: bare text mode truncated mid-JSON twice.
    # An ARRAY, not a word-split string: a --model value carrying spaces would
    # otherwise split into extra CLI flags, and flags appended after the
    # isolation ones can override them (e.g. re-enabling the toolset).
    local claude_model_args=()
    [ -n "$model" ] && claude_model_args=(--model "$model")
    local out crc scratch_dir bank
    # HIMMEL-128 / CLAUDE.md § billing: this route draws the SAME 5h/weekly
    # subscription bank as interactive use, and its callers (/pr-check, and the
    # auto-derived route for a hermes implementer) run unattended. Preflight the
    # bank and fall back to another reviewer rather than spend the last of it on
    # a critic. Only SKIPPED-BANK refuses: BANK-STALE / BANK-UNKNOWN are the
    # helper's deliberate fail-open verdicts, and a missing helper yields no
    # token at all, which must not block an adopter who does not ship one.
    bank="$(CADENCE_BANK_LEG=hermes-critic bash "$SCRIPT_DIR/../lib/bank-preflight.sh" 2>/dev/null)"
    if [ "$bank" = "SKIPPED-BANK" ]; then
        echo "hermes-critic.sh: claude route refused — bank preflight returned $bank (HIMMEL-128); fall back to another review route" >&2
        return 1
    fi
    # Ambient proxy exports must not silently redirect this subscription launch
    # off native auth (HIMMEL-1867). The whole function runs in a command
    # substitution, so the unsets stay scoped to this review.
    # shellcheck source=../lib/native-auth-pin.sh
    # shellcheck disable=SC1091
    if ! . "$SCRIPT_DIR/../lib/native-auth-pin.sh" || ! native_auth_pin_env; then
        echo "hermes-critic.sh: native-auth pin unavailable — refusing the claude route" >&2
        return 1
    fi
    # Removed below rather than via the EXIT trap: this function always runs
    # inside a command substitution, whose subshell resets the parent's trap.
    scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-critic-cwd.XXXXXX")"
    # Reviewer isolation depends on this cwd, so do not lean on `cd ""` failing
    # (POSIX leaves an empty operand unspecified) — refuse the route instead.
    if [ -z "$scratch_dir" ] || [ ! -d "$scratch_dir" ]; then
        echo "hermes-critic.sh: could not create the reviewer scratch cwd — refusing the claude route" >&2
        return 1
    fi
    # headless-claude-ok: CR critic pass — this invocation IS the product (HIMMEL-2017).
    out="$(cd "$scratch_dir" && claude -p --output-format json --permission-mode plan --max-turns 1 --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' ${claude_model_args[@]+"${claude_model_args[@]}"} < "$pack_file" 2>"$err_file")"
    crc=$?
    [ -n "$scratch_dir" ] && rm -rf "$scratch_dir"
    printf '%s' "$out" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);console.log(j.result??"")}catch(e){console.log(d)}})'
    # Return CLAUDE's rc, not the node unwrap's — a transport failure must not
    # surface to the caller as rc=0.
    return $crc
}

run_hermes_review() {
    # HIMMEL-2059: hermes_model is resolved above to the critics.json-pinned
    # gpt-6-astra whenever neither --model nor HERMES_CRITIC_MODEL set it, so
    # "$m" is no longer empty in the default case — the profile default is not
    # used for critics. The openai-codex provider pin applies ONLY to
    # codex-family model ids: a gpt-6-astra reviewer is ChatGPT-auth and
    # without the pin lands on openai-api and dies on a missing OPENAI_API_KEY
    # (observed 2026-08-22). Pinning it for any other model would misroute it.
    local m="${model:-$hermes_model}"
    local args=()
    [ -n "$m" ] && args=(--model "$m")
    [ "$(hermes_family)" = "codex" ] && args=(${args[@]+"${args[@]}"} --provider openai-codex)
    bash "$INVOKE" ${args[@]+"${args[@]}"} --prompt-file "$pack_file" 2>"$err_file"
}

case "$route" in
    claude)  raw="$(run_claude_review)";  rc=$? ;;
    hermes)  raw="$(run_hermes_review)";  rc=$? ;;
    both)    # primary claude pass; then a hermes second pass. Verdicts are
             # parsed separately and MERGED (union of findings; passed=false wins) —
             # naive concatenation would break the single-JSON parser.
             raw="$(run_claude_review)"; rc=$?
             # Only rc=0 with a body is a usable primary verdict. This used to
             # accept rc=1 too, which was harmless while rc was the node
             # unwrap's (always 0) — now that it is CLAUDE's, rc=1 means the
             # primary failed (a transport error, or a bank/native-auth/scratch
             # refusal), the run exits 3 below regardless, and a second pass
             # would be a paid invocation whose verdict is then discarded.
             if [ $rc -eq 0 ] && [ -n "$raw" ]; then
                 h2="$(run_hermes_review)"; h2_rc=$?
                 # The primary verdict deliberately still stands if the second
                 # pass dies — but say so, don't degrade silently to claude-only.
                 if [ "$h2_rc" -ne 0 ] || [ -z "$h2" ]; then
                     echo "hermes-critic.sh: WARN --route both: the hermes second pass failed (rc=$h2_rc): $(cat "$err_file" 2>/dev/null) — reporting the claude verdict alone." >&2
                     # A transport-failed pass may still have printed a partial
                     # body; merging it would let a failed reviewer alter a valid
                     # verdict. Drop it rather than union it in.
                     h2=""
                 fi
                 if [ -n "$h2" ]; then
                     # The second verdict goes through a FILE, not the
                     # environment: a verbose model can push a JSON verdict past
                     # the Windows 32KB environment-block ceiling, and that would
                     # fail the merge and lose BOTH verdicts.
                     merge_file="$(mktemp "${TMPDIR:-/tmp}/hermes-critic-h2.XXXXXX")"
                     printf '%s' "$h2" > "$merge_file"
                     raw="$(printf '%s' "$raw" | MERGE_OTHER_FILE="$merge_file" node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const grab=(s)=>{try{const m=s.match(/\{[\s\S]*\}/);return m?JSON.parse(m[0]):null}catch(e){return null}};
  const other=(()=>{try{return require("fs").readFileSync(process.env.MERGE_OTHER_FILE,"utf8")}catch(e){return ""}})();
  let a=grab(d), b=grab(other);
  if(!a){console.log(d);return}
  // A parseable object is not yet a verdict: an empty one would merge to the
  // claude result while the summary still advertised a second pass. Require a
  // real verdict — a boolean passed, or one populated finding array.
  const keys=["security_concerns","logic_errors","architectural_mismatches","suggestions"];
  const usable=(o)=>!!o&&(typeof o.passed==="boolean"||keys.some(k=>Array.isArray(o[k])&&o[k].length>0));
  if(!usable(b)){console.error("hermes-critic.sh: WARN --route both: the hermes second pass returned no usable verdict — reporting the claude verdict alone.");console.log(JSON.stringify(a,null,2));return}
  for(const k of keys){
    a[k]=(a[k]||[]).concat(b[k]||[]);
  }
  a.passed=Boolean(a.passed)&&Boolean(b.passed??true);
  a.summary=(a.summary||"")+" | [hermes second pass] "+(b.summary||"");
  console.log(JSON.stringify(a,null,2));
})')"
                     rm -f "$merge_file"
                 fi
             fi
             ;;
esac
if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    route_err="$(cat "$err_file" 2>/dev/null)"
    echo "hermes-critic.sh: WARN $route route failed (rc=$rc): ${route_err:-<no stderr>} — fail-open, fall back to another review route and note it in the review summary." >&2
    exit 3
fi

# Parse + enforce fail-closed verdict. node is a himmel baseline dependency.
printf '%s' "$raw" | node -e '
let d = "";
process.stdin.on("data", c => d += c).on("end", () => {
    const m = d.match(/\{[\s\S]*\}/);
    // Raw head on EVERY rc=3 path — a malformed-JSON body is the case where it
    // helps most. C0/C1 controls are stripped first: the head is model output,
    // so it can carry ANSI escapes that would rewrite an operator or CI log.
    // The CONTENT is deliberately kept (operator ruling, HIMMEL-2017); this is
    // only about the escape sequences.
    const clean = (s) => s.slice(0, 300).replace(/[\x00-\x1F\x7F-\x9F]/g, " ");
    if (!m) { console.error("hermes-critic.sh: no JSON object in critic response. Raw head: " + clean(d)); process.exit(3); }
    let j;
    try { j = JSON.parse(m[0]); }
    catch (e) { console.error("hermes-critic.sh: critic response is not valid JSON: " + e.message + ". Raw head: " + clean(d)); process.exit(3); }
    for (const k of ["security_concerns", "logic_errors", "architectural_mismatches", "suggestions"])
        if (!Array.isArray(j[k])) j[k] = j[k] == null ? [] : [String(j[k])];
    // Fail-closed: findings beat the model self-assessment.
    if ((j.security_concerns.length + j.logic_errors.length) > 0) j.passed = false;
    if (typeof j.passed !== "boolean") j.passed = false;
    console.log(JSON.stringify(j, null, 2));
    process.exit(j.passed ? 0 : 1);
});
'
exit $?
