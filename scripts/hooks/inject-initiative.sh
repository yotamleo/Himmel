#!/usr/bin/env bash
# inject-initiative.sh — SessionStart hook for opt-in initiative mode
# (HIMMEL-425; leg grammar + profiles HIMMEL-443).
#
# Gated by an initiative env var (must be set in the shell that LAUNCHED Claude
# — bypass convention per scripts/hooks/CLAUDE.md; a per-call prefix does NOT
# reach the hook process). When active, the session is given a scoped "drive to
# ship" directive so a normal session proactively advances the work through its
# active legs at natural completion points, without the operator saying "ship
# it" each time.
#
# Leg grammar (single source of truth: scripts/lib/initiative-legs.sh). The
# value is either a master switch (1/true/on/yes/all) or a comma-separated
# subset of the 8-leg vocabulary
# `plan,execute,prcheck,pr,ticket,merge,public,handover` (`plan` is a reserved
# token with no behavior yet). Parsing is case-insensitive, whitespace-tolerant,
# deduped; unknown tokens are ignored; steps always render in canonical order.
# The directive echoes the recognized tokens (`Active steps: …`) so a typo is
# visible.
#
# Profiles (selected by HIMMEL_OVERNIGHT):
#   - interactive (default): var = HIMMEL_INITIATIVE,           `all` = prcheck,pr,ticket,handover
#   - overnight (selector):  var = HIMMEL_INITIATIVE_OVERNIGHT, `all` = execute,prcheck,pr,ticket,merge,handover
#
# Default: OFF. Exit silently when the env is unset, falsy, or resolves to no
# recognized leg — behaviour then is byte-identical to a session without the
# directive.
#
# This is ADVISORY injected context, not a permission change: it cannot widen
# what the hooks allow. The safety rails still HARD-block (check-cr-marker-on-
# pr-create gates gh pr create; the persistence classifier vetoes reactive
# --amend and settings.json self-edits; the `merge` leg is advisory — branch
# protection still applies; the exfil classifier still blocks public push).
#
# Hook contract (SessionStart):
#   - Reads the SessionStart JSON payload from stdin (we don't consume fields).
#   - Exit 0 with stdout → stdout is injected as additional context.
#   - Non-zero exit → would surface an error; we never block, only ever exit 0.
#
# Wiring (in .claude/settings.json):
#   {
#     "hooks": {
#       "SessionStart": [
#         { "hooks": [ { "type": "command",
#                        "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh"
#                      } ] }
#       ]
#     }
#   }

set -euo pipefail

# Always exit clean; never block session start.
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a
# payload. We don't currently need the JSON body.
if [ -t 0 ]; then
    :
else
    cat >/dev/null 2>&1 || true
fi

# --- Source the himmel clone's .env for the initiative vars (R1, HIMMEL-460) -
# The hook reads HIMMEL_INITIATIVE* from the process env, but a session launched
# from a shell that never exported them (and without a settings.json `env` block)
# would see no legs. Populate them from the himmel clone's .env — but ONLY for
# vars not already set (process env / settings.json env still wins; load_dotenv is
# non-clobbering). Resolve the himmel root EXPLICITLY (HIMMEL_REPO, else the git
# toplevel of THIS hook script) and never trust the CWD: a session launched inside
# a DIFFERENT git repo must not read that repo's .env. Fail-open on any miss.
_ii_root="${HIMMEL_REPO:-}"
if [ -z "$_ii_root" ]; then
    _ii_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null) || _ii_root=""
fi
if [ -n "$_ii_root" ] && [ -f "$_ii_root/.env" ]; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh"
    load_dotenv --root "$_ii_root" HIMMEL_INITIATIVE HIMMEL_OVERNIGHT HIMMEL_INITIATIVE_OVERNIGHT || true
fi

# --- Resolve the active legs via the shared resolver (HIMMEL-443) -----------
# The leg grammar lives in ONE place: scripts/lib/initiative-legs.sh. We pass
# the relevant env vars as named arguments (the resolver never reads ambient
# env) and get back the normalized, canonical-ordered, deduped active leg set.
# Profile is selected by HIMMEL_OVERNIGHT: truthy → read HIMMEL_INITIATIVE_OVERNIGHT
# (overnight `all` = 6 legs), else HIMMEL_INITIATIVE (interactive `all` = legacy 4).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/initiative-legs.sh"

active=$(resolve_legs "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_OVERNIGHT:-}" "${HIMMEL_OVERNIGHT:-}")
# Off when nothing resolved (unset / falsy / all-unknown subset).
[ -n "$active" ] || exit 0

# Profile-dependent labels (which var the operator set; shown in the directive).
if _il_truthy "${HIMMEL_OVERNIGHT:-}"; then
    _var="HIMMEL_INITIATIVE_OVERNIGHT"; _profile="overnight"
else
    _var="HIMMEL_INITIATIVE"; _profile="interactive"
fi

# Membership test against the active leg set.
has_leg() { case " $active " in *" $1 "*) return 0;; *) return 1;; esac; }

# CSV of recognized tokens for the in-session echo (typo visibility).
_steps_csv=$(printf '%s' "$active" | tr ' ' ',')

# --- Assemble the directive ------------------------------------------------
# Invariant prose stays in quoted heredocs (it contains backticks that an
# unquoted heredoc would try to command-substitute). Only the numbered step
# list is built dynamically, so it renumbers to the active subset.
printf '<system-reminder>\n%s is active for this Claude Code session (%s profile).\n' "$_var" "$_profile"
printf 'Active steps: %s\n' "$_steps_csv"
# Tasklist-seed preamble (HIMMEL-539): an UNNUMBERED, handover-conditional
# instruction printed BEFORE the numbered legs (so it cannot acquire a leg
# number and does not break the "completion point:" → list coupling). The native
# tasklist is an agent-side tool (TaskCreate/TaskList/TaskUpdate) no shell can
# call — this prose is the only way to seed it on an armed/resumed session.
cat <<'EOF'

First — if this session was resumed from a handover (you were asked to "load
<handover>"), seed your native tasklist from the handover's ordered step list
BEFORE anything else, whatever heading that list uses (e.g. a "How to execute"
/ numbered-steps section): call TaskCreate once per step, then TaskUpdate each
task as you start and finish it so progress stays glanceable. Keeping it updated
through the run is best-effort. If you were not resumed from a handover, skip this.
EOF
cat <<'EOF'

Take initiative: drive the current work to done without waiting for an
explicit "ship it" each time. At a *natural completion point* (a logical chunk
of work is finished AND verified):
EOF

_n=0
# shellcheck disable=SC2016 # backticks in the format strings are literal directive prose, not expansions
for _tok in $active; do
    # `plan` is a reserved vocabulary token (no behavior yet) — consumes no number.
    [ "$_tok" = plan ] && continue
    _n=$((_n + 1))
    case "$_tok" in
        execute)  printf '%d. When a critic-hardened plan exists, hand it to execution: invoke `superpowers:subagent-driven-development` (recommended) to implement it task-by-task. (Advisory — it does not relax any rail.)\n' "$_n" ;;
        prcheck)  printf '%d. Run `/pr-check` and loop — fix every finding, re-run — until CR is clean.\n' "$_n" ;;
        pr)       printf '%d. When CR is clean, open or refresh the PR.\n' "$_n" ;;
        ticket)   printf '%d. Transition the Jira ticket to the appropriate status.\n' "$_n" ;;
        merge)    printf '%d. When CR is clean and the PR is open, squash-merge to PRIVATE main via `scripts/handover/pr-merge.sh` (plain-first; defer to the operator on real branch protection; never `--admin`). Advisory — branch protection still applies.\n' "$_n" ;;
        public)   printf '%d. After merge, run the public-propagation helper in PREP mode only: stage the public branch + patch and STOP. DO NOT push — the operator ships. The exfil classifier hard-blocks unattended public push regardless.\n' "$_n" ;;
        handover) printf '%d. Write the handover.\n' "$_n" ;;
    esac
done

cat <<'EOF'

Scope and limits:
- Fire only at completion points, NOT on every small edit. Don't interrupt
  mid-task.
EOF
# The unconditional no-merge guard is dropped only when the `merge` leg is
# explicitly active (then the merge step above carries the gate); every other
# configuration keeps merge an operator action.
has_leg merge || printf -- '- Do NOT merge — merge stays an operator action.\n'
cat <<'EOF'
- This directive does NOT relax any safety rail. The CR-marker hook still
  HARD-blocks `gh pr create` until a clean /pr-check; attestation trailers must
  be in the FIRST commit; reactive `git commit --amend` and self-editing
  `.claude/settings.json` to widen rules are still HARD-vetoed.
EOF
printf '\nTo disable for the rest of the session, unset %s in the\n' "$_var"
printf 'launching shell + restart claude (env vars do not propagate into a running\n'
printf 'session). For per-part control, set %s to a comma-separated\n' "$_var"
printf 'subset of: execute, prcheck, pr, ticket, merge, public, handover\n'
printf '(e.g. %s=prcheck,pr).\n' "$_var"
printf '</system-reminder>\n'

exit 0
