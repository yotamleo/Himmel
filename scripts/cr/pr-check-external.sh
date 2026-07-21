#!/usr/bin/env bash
# scripts/cr/pr-check-external.sh - Claude-free CR runner (HIMMEL-750).
#
# Runs the critic panel over a branch's diff WITHOUT a Claude validating
# session, so review still happens when the Claude quota bank is maxed. On a
# clean panel it records external_cr_verdict:pass into the spawn-glm session
# meta.json; scripts/glm/ship-branch.sh reads that verdict as the push
# authorization. This is the review half of the claude-down ship lane: GLM does
# the work quarantined, the hermes/codex critics carry review as paid lanes, and
# the branch becomes push-ready with NO Claude in the loop.
#
# The gate is fail-CLOSED and hardened (design critique):
#   1. panel non-zero exit            -> FAIL
#   2. unparseable Critical/Important -> FAIL (never default-0)
#   3. paid codex critic did not respond -> FAIL (with no Claude backstop a lone
#      flaky free critic must not clear the gate)
#   4. zero critics responded         -> FAIL (defensive)
#   5. Critical>0 or Important>0      -> NOT CLEAN
# CodeRabbit pass (HIMMEL-932): a third cross-model finding source run on an
# otherwise-clean panel. A missing CLI (exit 3) fails OPEN (never blocks); an
# attempted-but-failed review (any other non-zero, e.g. exit 1) fails CLOSED
# (HIMMEL-1222, HIMMEL-1126 parity). Only exit 0 findings feed the gate as
# blocking candidates ([coderabbit-N]), same merge contract as the interactive
# /pr-check step 3.2.
# Review floor (HIMMEL-1224) — stated once, per path, not left implied by which
# gate happens to fail-close:
#   * interactive /pr-check (a Claude session is present): the Claude self-review
#     backstop is the floor. It fails OPEN on the ABSENCE of external lanes
#     (codex/glm/CodeRabbit) and fails CLOSED on a lane that ATTEMPTED and failed;
#     distinct from SKIP_CR (a no-review bypass).
#   * THIS external path (Claude-FREE): there is NO Claude backstop, so the floor
#     is "the paid codex critic responded" (GATE 3). It fails CLOSED when codex is
#     absent rather than degrading to a lone flaky free critic. For a diff that
#     changes the CR/merge gate infrastructure ITSELF, the floor is RAISED to a
#     quorum (codex AND CodeRabbit both responded — the gate-infra quorum below).
# Lane outages are surfaced IN the verdict (critics=N; coderabbit=<state>), so a
# recorded 'pass' shows how much review actually ran — not merely that it passed.
#
# The CR marker is NOT touched here; the marker clear is bound to the pushed SHA
# in ship-branch.sh.
#
# Usage: pr-check-external.sh --branch <branch> [--session-dir <dir>] [--base <ref>]
#   default --branch = current branch; default --base = repo default (main/master).
#
# Env: CR_PROFILE - forced to include the paid lane on this Claude-absent path.
#      A caller who already exported a profile containing 'paid' is kept as-is;
#      CR_PROFILE=none is REFUSED (external CR needs a panel).
#      CRITIC_PANEL_CMD - path to the panel runner (default critic-panel.sh);
#      a test seam so the panel can be stubbed.
#
# bash 3.2-safe; node is the JSON tool the cr scripts already depend on.
# Exit: 0 = clean (or empty diff); 1 = not-clean / panel failure; 2 = usage/refusal.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_CMD="${CRITIC_PANEL_CMD:-$SCRIPT_DIR/critic-panel.sh}"

# guardrails/lib.sh gives default_branch (main OR master). Fail-closed if the
# substrate is missing - we cannot compute the right diff base without it.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "pr-check-external: cannot source guardrails/lib.sh - aborting" >&2
    exit 2
fi
# load_dotenv lets the operator's .env CR_PROFILE reach us (a live env var wins).
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null || true

usage() {
    cat <<'EOF'
Usage: pr-check-external.sh --branch <branch> [--session-dir <dir>] [--base <ref>]

Runs the critic panel over origin/<base>...<branch> with NO Claude session and,
on a clean+codex-backed panel, records external_cr_verdict:pass into
<session-dir>/meta.json. Does not touch the CR marker.
EOF
}

BRANCH=""
SESSION_DIR=""
BASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch)      [ $# -ge 2 ] || { echo "pr-check-external: --branch needs an argument" >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
        --session-dir) [ $# -ge 2 ] || { echo "pr-check-external: --session-dir needs an argument" >&2; exit 2; }; SESSION_DIR="$2"; shift 2 ;;
        --base)        [ $# -ge 2 ] || { echo "pr-check-external: --base needs an argument" >&2; exit 2; }; BASE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "pr-check-external: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Pull CR_PROFILE from .env only if not already live (load_dotenv is a no-op when
# the key is already set, mirroring the Jira CLI's ??= semantics).
if command -v load_dotenv >/dev/null 2>&1; then
    load_dotenv CR_PROFILE 2>/dev/null || true
fi

# Defaults: current branch, repo default base.
[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "pr-check-external: no --branch and cannot resolve current branch" >&2; exit 2; }
[ -n "$BASE" ] || BASE="$(default_branch)"

# CR_PROFILE handling: this Claude-absent path REQUIRES the paid lane. Refuse a
# deliberate 'none'; otherwise force free,paid unless the caller already asked
# for a profile that includes paid.
case "${CR_PROFILE:-}" in
    none)
        echo "pr-check-external: CR_PROFILE=none refused - external CR needs a panel; unset CR_PROFILE=none" >&2
        exit 2 ;;
    *paid*) : ;;                 # caller already includes the paid lane; keep it
    *)      CR_PROFILE="free,paid" ;;
esac
export CR_PROFILE

# Fetch so we review the true remote-relative tip. Best-effort: an offline box
# can still review against a locally-present origin/<base> ref.
git fetch origin >/dev/null 2>&1 || echo "pr-check-external: git fetch origin failed - reviewing against local refs" >&2

reviewed_sha="$(git rev-parse "$BRANCH" 2>/dev/null || true)"
[ -n "$reviewed_sha" ] || { echo "pr-check-external: cannot resolve branch tip for $BRANCH" >&2; exit 2; }
reviewed_short="$(git rev-parse --short "$BRANCH" 2>/dev/null || echo "$reviewed_sha")"

diff_file="$(mktemp -t pr-check-ext-diff.XXXXXX)"
panel_out="$(mktemp -t pr-check-ext-out.XXXXXX)"
panel_err="$(mktemp -t pr-check-ext-err.XXXXXX)"
coderabbit_out="$(mktemp -t pr-check-ext-cr.XXXXXX)"
cr_err="$(mktemp -t pr-check-ext-crerr.XXXXXX)"
trap 'rm -f "$diff_file" "$panel_out" "$panel_err" "$coderabbit_out" "$cr_err"' EXIT

# 3-dot diff against origin/<base>. Fail-closed if it cannot be computed (a bad
# ref / no merge base) rather than reviewing an empty diff by accident.
if ! git diff "origin/${BASE}...${BRANCH}" > "$diff_file" 2>/dev/null; then
    echo "pr-check-external: cannot compute diff origin/${BASE}...${BRANCH} (bad ref / no merge base) - aborting" >&2
    exit 2
fi
if [ ! -s "$diff_file" ]; then
    echo "pr-check-external: empty diff vs origin/${BASE} - nothing to review (no verdict written)" >&2
    exit 0
fi

# HIMMEL-1224: the changed-file list for the gate-infra quorum check (GATE 6).
# Computed HERE, right after the diff was validated non-empty (a diff failure
# already fail-closed above), so the quorum decision never rides on a
# silently-empty list. Same 3-dot range as $diff_file, so the two never disagree.
# FAIL-CLOSED on enumeration failure (CodeRabbit, HIMMEL-1224): if we cannot list
# the changed files we cannot tell a gate-infra diff from a non-gate one, so the
# quorum must NOT be silently skipped (no `|| true` masking the failure).
if ! changed_files="$(git diff --name-only "origin/${BASE}...${BRANCH}" 2>/dev/null)"; then
    echo "pr-check-external: FAIL - cannot enumerate changed files for the gate-infra quorum (git diff --name-only failed) - fail-closed" >&2
    exit 1
fi

# HIMMEL-1222 (codex-adv): a real review is about to run, so REVOKE any existing
# external_cr_verdict for this session NOW. Otherwise a fail-closed exit below
# (a panel/codex/CodeRabbit failure) would leave a stale 'pass (sha=X)' that
# ship-branch.sh still trusts while the branch tip is unchanged -- defeating the
# fail-closed posture. The verdict is re-written only after every gate passes.
if [ -n "$SESSION_DIR" ] && [ -f "$SESSION_DIR/meta.json" ]; then
    if ! node -e '
const fs = require("fs");
const mp = process.argv[1];
const m = JSON.parse(fs.readFileSync(mp, "utf8"));
if ("external_cr_verdict" in m) { delete m.external_cr_verdict; fs.writeFileSync(mp, JSON.stringify(m, null, 2) + "\n"); }
' "$SESSION_DIR/meta.json" 2>/dev/null; then
        # Revocation FAILED (unparseable or unwritable meta): we cannot prove a
        # stale 'pass' is gone, so FAIL CLOSED rather than warn-and-continue.
        # Best-effort stamp a denied verdict ship-branch.sh rejects, then abort
        # BEFORE reviewing so no fresh pass is written either. (An unwritable
        # meta may keep a stale pass on disk -- unprotectable here; the exit 1
        # still stops THIS lane from proceeding and re-authorizing.)
        node -e '
const fs = require("fs");
const mp = process.argv[1];
try {
  const m = JSON.parse(fs.readFileSync(mp, "utf8"));
  m.external_cr_verdict = "denied (verdict-revocation failed)";
  fs.writeFileSync(mp, JSON.stringify(m, null, 2) + "\n");
} catch (e) { /* best-effort; the exit 1 below is the real guard */ }
' "$SESSION_DIR/meta.json" 2>/dev/null || true
        echo "pr-check-external: FAIL - could not revoke a prior external_cr_verdict at $SESSION_DIR/meta.json - fail-closed (stamped denied where writable), not reviewing" >&2
        exit 1
    fi
fi

echo "pr-check-external: reviewing $BRANCH @ $reviewed_short vs origin/$BASE (CR_PROFILE=$CR_PROFILE)" >&2

CR_USAGE_LOG=1 bash "$PANEL_CMD" < "$diff_file" > "$panel_out" 2> "$panel_err"
panel_rc=$?

# Surface the panel's availability lines to our own stderr for the operator.
grep '^panel-availability:' "$panel_err" >&2 || true

# GATE 1: panel non-zero exit -> FAIL.
if [ "$panel_rc" -ne 0 ]; then
    echo "pr-check-external: FAIL - critic panel exited $panel_rc (all critics failed?)" >&2
    exit 1
fi

# GATE 2: parse Critical/Important counts; unparseable = fail-closed (never 0).
nc="$(sed -n 's/^## Critical Issues (\([0-9][0-9]*\) found).*/\1/p' "$panel_out" | head -1)"
ni="$(sed -n 's/^## Important Issues (\([0-9][0-9]*\) found).*/\1/p' "$panel_out" | head -1)"
if [ -z "$nc" ] || [ -z "$ni" ]; then
    echo "pr-check-external: FAIL - could not parse Critical/Important counts from panel output (fail-closed)" >&2
    exit 1
fi

# GATE 3: the paid codex critic MUST have responded (a plain 'ok' or a
# fallback(...) form both count as responded).
if grep -qE '^panel-availability: codex (ok|fallback\()' "$panel_err"; then
    codex_ok=1
else
    codex_ok=0
fi
if [ "$codex_ok" -ne 1 ]; then
    echo "pr-check-external: FAIL - paid codex critic unavailable - the Claude-absent path requires it; retry when the OpenAI bank resets, or SKIP_CR=1 to override" >&2
    exit 1
fi

# GATE 4: at least one critic responded overall (implied by codex-ok; asserted
# defensively off the panel header).
responders="$(sed -n 's/^# Critic Panel Review (\([0-9][0-9]*\)\/[0-9].*/\1/p' "$panel_out" | head -1)"
[ -n "$responders" ] || responders=0
if [ "$responders" -lt 1 ]; then
    echo "pr-check-external: FAIL - no critics responded" >&2
    exit 1
fi

# GATE 5: clean = zero Critical AND zero Important.
if [ "$nc" -ne 0 ] || [ "$ni" -ne 0 ]; then
    echo "pr-check-external: NOT CLEAN - Critical=$nc Important=$ni (codex responded; $responders critics). Findings:" >&2
    cat "$panel_out" >&2
    exit 1
fi

# CodeRabbit pass (HIMMEL-932): third cross-model finding source, availability-
# gated FAIL-OPEN. Runs ONLY on an otherwise-clean panel - a panel that already
# found Critical/Important has blocked the branch at GATE 5 regardless, so
# spending a (paid, minutes-long) CodeRabbit review there is waste. The codex
# fail-closed posture at GATE 3 is untouched; this seat is its fail-open peer.
# Wrapper contract: stdout = findings, stderr = one panel-availability line;
# exit 0 = review completed, 1 = review failed (fail-closed, HIMMEL-1222), 3 = CLI absent (skip),
# 4 = rate-limited/quota-exhausted (HIMMEL-1219; a MISSING-review signal, not a failure).
cr_rc=0
bash "$SCRIPT_DIR/coderabbit-review.sh" --branch "$BRANCH" --base "$BASE" \
    > "$coderabbit_out" 2> "$cr_err" || cr_rc=$?
# Surface the wrapper's stderr: the skip note on exit 3, the panel-availability
# line on exit 1 (a machine without the CLI / a failed review is not a critic
# drop-out - the operator just sees the availability state).
cat "$cr_err" >&2
# HIMMEL-1224: record the CodeRabbit availability state — surfaced in the verdict
# (critics=N; coderabbit=<state>) and consumed by the gate-infra quorum below.
# "ok" only when the review actually RAN (rc=0); absent (rc=3) / unavailable
# (rc=4) are MISSING-review signals, never a responded reviewer.
coderabbit_state="unknown"
case "$cr_rc" in
    0)
        coderabbit_state="ok"
        # Review completed. The wrapper passes the CLI's --agent stream through
        # (JSONL: status/heartbeat/complete lines PLUS '"type":"finding"' lines),
        # so gate on finding lines, not on non-empty stdout. Severity map matches
        # the interactive /pr-check step 3.2: critical/major block ([coderabbit-N]
        # candidates); minor = Suggestion tier, surfaced but non-blocking. A
        # finding with a missing/unknown severity blocks (fail-closed - no
        # adjudicator on this Claude-absent path). Non-empty output with NO
        # recognizable JSONL at all = format drift - also fail-closed.
        cr_blocking=$(grep '"type":"finding"' "$coderabbit_out" 2>/dev/null | grep -cv '"severity":"minor"' || true)
        cr_minor=$(grep '"type":"finding"' "$coderabbit_out" 2>/dev/null | grep -c '"severity":"minor"' || true)
        if [ -s "$coderabbit_out" ] && ! grep -q '"type":"' "$coderabbit_out" 2>/dev/null; then
            echo "pr-check-external: NOT CLEAN - CodeRabbit output in unrecognized format (fail-closed):" >&2
            cat "$coderabbit_out" >&2
            exit 1
        fi
        if [ "${cr_blocking:-0}" -gt 0 ]; then
            echo "pr-check-external: NOT CLEAN - CodeRabbit critical/major findings (blocking candidates [coderabbit-N]):" >&2
            grep '"type":"finding"' "$coderabbit_out" | grep -v '"severity":"minor"' >&2
            exit 1
        fi
        if [ "${cr_minor:-0}" -gt 0 ]; then
            echo "pr-check-external: CodeRabbit minor findings (Suggestion tier - non-blocking):" >&2
            grep '"type":"finding"' "$coderabbit_out" | grep '"severity":"minor"' >&2
        fi
        ;;  # clean / minor-only: fall through to the verdict.
    3)
        coderabbit_state="absent"
        : ;;  # CLI absent - skip note already surfaced above; continue fail-open.
    4)
        coderabbit_state="unavailable"
        # Rate-limited/quota-exhausted (HIMMEL-1219) — a MISSING-review signal,
        # NOT a failure, so do NOT fall through to the generic "review failed"
        # message below (that would mislabel a rate-limit). The wrapper's stderr
        # already carried the retry-later note + `panel-availability: coderabbit
        # unavailable (rc=4)` (surfaced above); continue fail-open, same posture
        # as the absent-CLI (3) and failed-review (1) arms.
        : ;;
    *)
        echo "pr-check-external: NOT CLEAN - CodeRabbit review was attempted but failed (rc=$cr_rc) -> fail-closed (HIMMEL-1126/1222 parity); a machine without the CLI (exit 3) is the fail-open path" >&2
        exit 1
        ;;
esac

# GATE 6 — gate-infrastructure quorum (HIMMEL-1224). A diff that changes the
# CR/merge gate machinery is reviewed by the very gate it changes, so on this
# Claude-absent path a lone codex reviewer (GATE 3) is not enough: require a
# SECOND trusted cross-model reviewer (CodeRabbit) to have RESPONDED. CodeRabbit
# absent (rc=3) or rate-limited (rc=4) does NOT meet quorum — a change to the
# gate itself must not clear on one reviewer. Non-gate diffs keep the
# single-codex floor. The interactive /pr-check (with its Claude backstop) is the
# path for gate-infra changes when the external lane cannot reach two reviewers.
gate_infra_touched="$(printf '%s\n' "$changed_files" | grep -E '^(scripts/cr/|scripts/glm/ship-branch\.sh|scripts/hooks/|scripts/handover/merge-on-green\.sh|scripts/check-ci\.sh|\.claude/commands/pr-check\.md|\.agents/skills/pr-check/SKILL\.md)' || true)"
if [ -n "$gate_infra_touched" ] && [ "$coderabbit_state" != "ok" ]; then
    echo "pr-check-external: NOT CLEAN - gate-infrastructure diff requires a quorum (codex + CodeRabbit both responded), but coderabbit=$coderabbit_state. A change to the gate itself must not clear on a single reviewer; use the interactive /pr-check (Claude backstop) or retry when CodeRabbit recovers. Gate files touched:" >&2
    printf '%s\n' "$gate_infra_touched" | sed 's/^/  - /' >&2
    exit 1
fi
[ -n "$gate_infra_touched" ] && echo "pr-check-external: gate-infrastructure diff - quorum met (codex + CodeRabbit both responded)" >&2

echo "pr-check-external: CLEAN - Critical=0 Important=0, codex responded ($responders critics), coderabbit=$coderabbit_state @ $reviewed_short" >&2

# Record the verdict into the spawn-glm session meta.json (mirror d1-verdict.sh's
# node -e merge; string args are injection-safe). DISTINCT key external_cr_verdict
# - never d1_verdict (reserved for the Claude-validating-session lane; the
# WS10/D5 corpus keys on it and must stay uncontaminated).
if [ -n "$SESSION_DIR" ]; then
    META="$SESSION_DIR/meta.json"
    if [ ! -f "$META" ]; then
        echo "pr-check-external: --session-dir given but no meta.json at $META - not writing verdict" >&2
        exit 2
    fi
    # The verdict stores the FULL reviewed sha (ship-branch.sh compares it EXACTLY
    # to the branch tip - an authorization gate must not accept a short-prefix
    # match a grafted commit could collide on, CR [codex-1]).
    # shellcheck disable=SC2016  # ${...} below are JS template literals, not shell
    # FAIL-CLOSED if the verdict cannot be persisted (CodeRabbit, HIMMEL-1224):
    # node exits non-zero on an unreadable meta OR an unwritable file, and the
    # script must NOT then print/exit-0 a `pass` that never reached disk. (The
    # early revocation already removed any stale verdict, so a failed write leaves
    # meta.json with NO pass - ship-branch.sh reads meta.json, so it authorizes
    # nothing; the non-zero exit here also stops the misleading green.)
    if ! node -e '
const fs = require("fs");
const [mp, sha, critics, coderabbit] = process.argv.slice(1);
const m = JSON.parse(fs.readFileSync(mp, "utf8"));
m.external_cr_verdict = `pass (sha=${sha}; critics=${critics}; coderabbit=${coderabbit})`;
fs.writeFileSync(mp, JSON.stringify(m, null, 2) + "\n");
' "$META" "$reviewed_sha" "$responders" "$coderabbit_state"; then
        echo "pr-check-external: FAIL - could not persist external_cr_verdict to $META (write failed) - fail-closed, no pass recorded" >&2
        exit 1
    fi
    echo "pr-check-external: wrote external_cr_verdict to $META" >&2
fi

printf 'external_cr_verdict: pass (%s; coderabbit=%s)\n' "$reviewed_short" "$coderabbit_state"
exit 0
