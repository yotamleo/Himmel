---
description: Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output
---

Status-check the CR gate: run `/pr-review-toolkit:review-pr` for the current branch and clear the pre-push marker if the review is clean. This is the in-session counterpart to the pre-push hook — the hook writes a marker, this command reviews and clears it. Without a clean run, `gh pr create` is blocked by the PreToolUse hook.

Steps:

1. Determine the current branch and HEAD:
   ```bash
   branch=$(git branch --show-current)
   head=$(git rev-parse --short HEAD)
   # Use --git-common-dir (shared .git), not --git-dir (per-worktree),
   # so the marker lookup matches the pre-push hook's write path even
   # when /pr-check is invoked from a different worktree.
   git_dir=$(git rev-parse --git-common-dir)
   marker="${git_dir}/cr-pending/${branch}"
   ```

2. If `$marker` does not exist, report `no pending CR for $branch (HEAD=$head) — nothing to do` and stop. (Either the pre-push hook never ran, or `/pr-check` already cleared it.)

   **Lane detection (HIMMEL-303).** Read the marker's 3rd field — the CR lane:
   ```bash
   # FS is a literal " | " — bracket class [|], NOT \| (gawk warns on \| and
   # reads it as alternation, splitting on every space → wrong field).
   lane=$(awk -F' [|] ' '{print $3; exit}' "$marker" 2>/dev/null)
   ```
   - `lane = docs-audit` → run the **docs-audit lane** (step 2.5 below), NOT the full matrix. A docs-only PR is never zero-CR, but it gets ONE reviewer with a docs charter, not the 6-reviewer set.
   - `lane = full` or empty (legacy markers) → the normal flow (step 3 onward).

2.5. **Docs-audit lane (only when `lane = docs-audit`).** Dispatch ONE `pr-review-toolkit:code-reviewer` Agent (upstream type + the HIMMEL-178 directive prepended, same as step 3) with the docs charter and NOTHING else (no critic panel, no other matrix agents):

   > **Docs-audit charter (HIMMEL-299/303) — audit ONLY these five dimensions, nothing else (no prose-style nitpicks):** (1) factual accuracy of every repo claim (hooks/gates/flags/paths/commands) vs the actual code/config; (2) every markdown link resolves; (3) no stale file/flag/ticket references; (4) example blocks have correct paths + flags + syntax; (5) internal consistency. Return findings tagged `[ACCURACY|DEAD-LINK|STALE|EXAMPLE|CONSISTENCY]` with file:line + fix; say `DOCS-AUDIT CLEAN` if none. (`CLAUDE.md` diffs: prefer `/claude-md-audit` for the rubric pass; this charter still applies for accuracy.)

   Treat any `[ACCURACY|DEAD-LINK|STALE|EXAMPLE]` finding as a blocking Critical for the step 5/6 decision (`[CONSISTENCY]` is Important). Then go to step 4 with these counts. Skip steps 3 / 3.0 entirely.

3. **Critic panel first-pass, then dispatch reviewer agents in parallel (HIMMEL-178, HIMMEL-270, HIMMEL-415).**

   **Step 3.0 — critic panel first-pass (decimal substep, runs BEFORE any Agent dispatch):**

   `/pr-check` runs the fast-free cross-model panel (gptoss+kimi, ~3min) by **default**. Control via `CR_PROFILE`:
   - `CR_PROFILE` unset/empty → **DEFAULT**: run panel with `CRITIC_PANEL_TIERS=free` (fast gptoss+kimi). Print note: "Default free cross-model CR (~3min; set CR_PROFILE=none for instant claude-only, CR_PROFILE=thorough to add qwen-480B)."
   - `CR_PROFILE=none` → **claude-only** (skip panel entirely); print a one-line note and skip.
   - `CR_PROFILE=thorough` → run panel with `CRITIC_PANEL_TIERS="free,thorough"` (all 3 critics, ~5min+).
   - `CR_PROFILE=paid` → run the **paid escalation** critic (codex / `gpt-5.5` via hermes `openai-codex` OAuth, HIMMEL-417) — for high-stakes PRs or when the free panel disagrees. Consumes your OpenAI usage bank. Combine with the free panel via `CR_PROFILE=free,paid`.
   - any other value → pass through as `CRITIC_PANEL_TIERS` (advanced/custom tier filter, e.g. `free,paid`).

   Per-member hang protection: `CRITIC_TIMEOUT_SECS` (default 150 s). `CR_PROFILE=none` skips the panel entirely.

   ```bash
   # Resolve the protected default (main OR master, HIMMEL-297) for the diff base.
   db=$(. scripts/guardrails/lib.sh 2>/dev/null && default_branch || echo main)
   diff_rc=0
   diff_out=$(git diff "$db...HEAD") || diff_rc=$?
   panel_avail_lines=""   # will hold "panel-availability: <slug> ok" or "panel-availability: <slug> unavailable (rc=N)" stderr lines
   panel_findings=""      # will hold the merged findings block on stdout
   if [ "${CR_PROFILE:-}" = "none" ]; then
       # Explicit claude-only opt-out. Skip panel.
       echo "claude-only review (CR_PROFILE=none)"
   elif [ "$diff_rc" -ne 0 ]; then
       # git itself failed — treat as panel unavailable, not empty-diff skip.
       echo "critic panel unavailable — claude-only review (git diff failed rc=$diff_rc: $diff_out)" >&2
   elif [ -z "$diff_out" ]; then
       echo "empty diff — critic panel skipped"
   else
       # Determine tier filter: unset/empty=free, thorough=free+thorough, other=passthrough.
       if [ -z "${CR_PROFILE:-}" ]; then
           panel_tiers="free"
           echo "Default free cross-model CR (~3min; set CR_PROFILE=none for instant claude-only, CR_PROFILE=thorough to add qwen-480B)."
       elif [ "$CR_PROFILE" = "thorough" ]; then
           panel_tiers="free,thorough"
       else
           panel_tiers="$CR_PROFILE"
       fi
       panel_tmp=$(mktemp -t cr-panel-avail.XXXXXX)
       # CR_USAGE_LOG=1 (HIMMEL-485): each critic logs a chars/4 ESTIMATED `usage`
       # ledger record (hermes does not expose real usage via the one-shot
       # chokepoint). Best-effort; surfaced per-model + cumulative by cr-scores.sh.
       panel_findings=$(printf '%s' "$diff_out" | CR_USAGE_LOG=1 CRITIC_PANEL_TIERS="$panel_tiers" bash scripts/cr/critic-panel.sh 2>"$panel_tmp")
       panel_rc=$?
       panel_avail_lines=$(cat "$panel_tmp"); rm -f "$panel_tmp"
       if [ "$panel_rc" -ne 0 ]; then
           # rc=1 = all critics failed — fail-open, continue with claude-only.
           echo "critic panel unavailable (all critics failed) — claude-only review" >&2
           panel_findings=""
       fi
       # If the environment token-proxies git (rtk), the plain git diff above
       # returns a stat summary, not a unified diff — critic-panel.sh will exit 1
       # (no valid diff). Retry once with the rtk proxy form before falling back.
       # rc=1 after retry → claude-only (same fail-open contract as above).
   fi
   ```
   If the panel runs and the environment token-proxies git (rtk), the plain `git diff "$db...HEAD"` returns a stat summary, not a unified diff — `critic-panel.sh` exits 1 (no critics responded). Retry once with `rtk proxy git diff "$db...HEAD"` before falling back to claude-only. On retry, the retry's output REPLACES (overwrites, not appends) `panel_findings` and the captured `panel-availability:` lines from the first attempt.

   The panel's `[<slug>-N]` Critical/Important findings are BLOCKING
   CANDIDATES under the adjudication rules below. Panel Suggestions are NOT
   forwarded to agents — append them directly to the aggregate
   `## Suggestions` section in step 3's output (step 7 files them).

   Replace the previous `/pr-review-toolkit:review-pr` slash-command invocation with explicit per-agent dispatches. All dispatches use the upstream `pr-review-toolkit:*` agent types — the himmel fork's `pr-review-toolkit-himmel:code-reviewer` is NOT registered as an Agent-tool type (verified HIMMEL-283; dispatching it errors `Agent type ... not found`). The HIMMEL-178 verify-before-critical rule is carried by prepending the directive below to EVERY agent prompt, code-reviewer included.

   Do NOT spawn `claude --print` as a subprocess (HIMMEL-128 billing — interactive only).

   **Dispatch matrix** — always dispatch the first row; add others when the diff matches:

   | Condition | Agent | Namespace rationale |
   |---|---|---|
   | Always | `code-reviewer` | Upstream — `pr-review-toolkit:code-reviewer`, HIMMEL-178 directive prepended (fork agent type not registered) |
   | Test files changed (`*.test.*`, `**/test_*`, `**/tests/**`, `*.spec.*`, etc.) | `pr-test-analyzer` | Upstream — `pr-review-toolkit:pr-test-analyzer` |
   | Comments / docs changed (`**/*.md`, comment-only diffs in code) | `comment-analyzer` | Upstream — `pr-review-toolkit:comment-analyzer` |
   | Error-handling code changed (try/catch, error-return, panic, etc.) | `silent-failure-hunter` | Upstream — `pr-review-toolkit:silent-failure-hunter` |
   | Types added / modified (`*.ts`, `*.d.ts`, type-defs in Python/Rust/etc.) | `type-design-analyzer` | Upstream — `pr-review-toolkit:type-design-analyzer` |

   `code-simplifier` (the 6th pr-review-toolkit agent) is intentionally NOT in this auto-dispatch matrix — matches the upstream `/pr-review-toolkit:review-pr` behavior, where simplification is invoked explicitly via `simplify` argument rather than auto-routed. If the operator wants simplification, they call `pr-review-toolkit:code-simplifier` directly. The verify-before-critical rule does not apply to it (simplification proposes refactors, not Critical findings).

   **Prepend the following directive to each of the 5 Agent tool prompts** (the fork plugin at `marketplace/plugins/pr-review-toolkit-himmel/` embeds the rule in its agent definition, but that agent type is not dispatchable — see `README.md` there for fork-scope rationale):

   > **Hard rule (HIMMEL-178 verify-before-critical):** before reporting any Critical finding, grep the actual diff (or read the file at the cited line) for the cited line / token / pattern. If the cited content does NOT appear verbatim, downgrade to Minor or drop entirely. Note any downgrade with reason `verify-before-critical: cited content not in diff`. Hallucinated Critical findings derail overnight-mode fix batches (~6 reviewers/PR × 50-60 dispatches/session) and burn tokens. This rule applies ONLY to Critical (91-100) findings — Important (80-89) and below tolerate inference.

   When the critic panel first-pass produced findings, ALSO prepend this directive
   plus the panel Critical/Important findings to each agent prompt:

   > **Cross-model adjudication (HIMMEL-270, HIMMEL-415):** the critic panel
   > findings below are blocking candidates, each tagged `[<slug>-N]`. For
   > each finding relevant to your role: AGREE (confirm with cited evidence
   > from the diff/file) or DISPROVE (grep the diff, read the file at the
   > cited line, or run a test proving it wrong). Emit exactly ONE verdict
   > line per adjudicated finding, using this exact format:
   > `VERDICT [<slug>-N] = agreed|disproved|conflict|unaddressed`
   > — `agreed` = confirmed with evidence; `disproved` = refuted with
   > evidence; `conflict` = evidence-backed AGREE AND DISPROVE (surface
   > verbatim to operator); `unaddressed` = relevant to your role but
   > cannot confirm or refute. Do not silently ignore a finding relevant
   > to your role.

   The `code-reviewer` dispatch's prompt additionally gets:
   **"You are the mandatory adjudicator: render a `VERDICT [<slug>-N] = …`
   line on EVERY `[<slug>-N]` Critical/Important finding from the panel,
   whether or not it looks relevant to your role — read the cited file if
   it is outside the diff context you were given."** (Closes the
   orphaned-finding hole — every panel finding gets at least one verdict.)

   Aggregate the per-agent results into the structured output format below (for downstream parsing by step 4):

   ```markdown
   # PR Review Summary

   ## Critical Issues (N found)
   - [agent-name]: Issue description [file:line]

   ## Important Issues (N found)
   - [agent-name]: Issue description [file:line]

   ## Suggestions (N found)
   - [agent-name]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR
   ```

   The `(N found)` parenthetical on Critical / Important headings is the contract surface that step 4 parses. Keep it stable.

4. Parse the aggregated output (from step 3) for the two count headings:
   - `Critical Issues (N found)`
   - `Important Issues (N found)`

   **Panel adjudication cross-check (HIMMEL-270, HIMMEL-415):** when step 3.0
   produced panel findings, recompute the counts using `VERDICT` lines as the
   SINGLE verdict source (one parser, not two — retire the old
   `cross-model-adjudication:` prose parsing):

   For each `[<slug>-N]` Critical/Important forwarded in step 3:
   - Collect all `VERDICT [<slug>-N] = <v>` lines emitted by any reviewer.
   - **Excluded from blocking count** ONLY when: at least one `disproved`
     verdict AND zero `agreed` verdicts.
   - **Blocks** in every other state:
     - `agreed` (any) → blocks.
     - `conflict` (AGREE + DISPROVE both present) → blocks; surface verbatim
       to the operator.
     - `unaddressed` (no verdict line at all, or all verdicts are
       `unaddressed`) → append to the Critical count, fail-closed.
   - Panel Suggestions never enter blocking counts and need no verdict.

   Every `[<slug>-N]` Critical/Important forwarded in step 3 must appear in
   the aggregate with at least one `VERDICT [<slug>-N] = …` line (the
   mandatory `code-reviewer` adjudicator ensures this).

4.5. **Ledger append (runs after verdict extraction, before the step 5/6 gate decision; no-op when `panel_findings` is empty, i.e. claude-only path).** Single-writer: only this orchestrator step writes the ledger.

   For each `[<slug>-N]` finding emitted by the panel (Critical, Important, or
   Suggestion), extract its severity (`crit`, `imp`, or `sug`), file, line, and
   the resolved verdict (`agreed|disproved|conflict|unaddressed`), then call:
   ```bash
   bash scripts/cr/ledger-append.sh finding \
       --branch "$branch" --head "$head" \
       --model "<slug>" --id "<slug>-N" \
       --severity <crit|imp|sug> \
       --file <file> --line <line> \
       --verdict <agreed|disproved|conflict|unaddressed>
   ```

   For each `panel-availability:` line captured in `$panel_avail_lines` from
   step 3.0 (format: `panel-availability: <slug> ok` for responders, or
   `panel-availability: <slug> unavailable (rc=N)` for drops), call.
   Parsing: the slug is the 2nd whitespace-delimited token and the status is
   the 3rd token (`ok` or `unavailable`) — ignore any trailing ` (rc=N)`.
   Pass `--status` as exactly `ok` or `unavailable`.
   ```bash
   bash scripts/cr/ledger-append.sh avail \
       --branch "$branch" --head "$head" \
       --model "<slug>" --status <ok|unavailable>
   ```

   Both calls are best-effort — ledger errors are logged to stderr but do NOT
   block the gate decision in steps 5/6. The ledger is deduped on
   `(head, finding_id)` for findings and `(head, model)` for avail records, so
   re-running `/pr-check` on the same HEAD is safe.

4.6. **Handover CR-findings capture (HIMMEL-416 F2 / C2) — runs alongside 4.5; best-effort, single-writer for the `## CR Findings` section, graceful skip when there is no active handover item.** Mirrors the panel findings into the current work-item's `reviewer-notes.md` so CR results survive the session (the F1 ledger is machine state; this is the human-readable trail surfaced on resume).

   Resolve the active item ONCE; skip the whole block (no error) if there is none:
   ```bash
   item_dir=""
   if item_dir=$(bash scripts/handover/resolve-active-item.sh --branch "$branch" 2>/dev/null); then
       notes="$item_dir/reviewer-notes.md"
       today=$(date +%F)
       pr_ref=$(gh pr view --json number -q .number 2>/dev/null || echo "")
   else
       item_dir=""   # rc 3 (no item) or rc 2 (error) -> skip capture, never block the gate
       echo "F2: no active handover item for $branch — CR-findings capture skipped" >&2
   fi
   ```

   When `item_dir` is set, for each `[<slug>-N]` finding emitted by the panel (the SAME findings iterated in step 4.5 — Critical, Important, or Suggestion), extract its severity (`crit|imp|sug`), file, line, the finding's one-line title/description (from the step-3 aggregate), and the resolved verdict, then call:
   ```bash
   bash scripts/handover/append-cr-findings.sh \
       --notes "$notes" --head "$head" --date "$today" ${pr_ref:+--pr "$pr_ref"} \
       --id "<slug>-N" --severity <crit|imp|sug> \
       --file <file> --line <line> --title "<one-line finding title>" \
       --verdict <agreed|disproved|conflict|unaddressed>
   ```

   Like 4.5, this is **deduped** — `append-cr-findings.sh` skips a `(head, <slug>-N)` already present, so re-running `/pr-check` on the same HEAD adds nothing. Errors are best-effort: a missing `reviewer-notes.md` or unwritable state repo logs to stderr and does NOT block steps 5/6.

4.7. **CR→bug-tracker lifecycle (HIMMEL-446) — runs alongside 4.5/4.6; best-effort, graceful skip when there is no active handover item.** Where 4.6 writes a flat human-readable trail, 4.7 gives Critical/Important findings a tracked **open→resolved lifecycle** in the item's `bugs.md`, closing the CR-ledger / bug-tracker / handover triangle.

   **Names its own inputs — do NOT assume 4.6's shell vars persist** (each `pr-check.md` ```bash``` fence runs independently). Re-resolve the item dir, then write two temp files and call the bridge:
   ```bash
   if item_dir=$(bash scripts/handover/resolve-active-item.sh --branch "$branch" 2>/dev/null); then
       cr_find=$(mktemp -t cr-bugs-find.XXXXXX); cr_avail=$(mktemp -t cr-bugs-avail.XXXXXX)
       # Critical/Important panel findings → "<finding-id>\t<severity>\t<symptom>" (one per line, REAL tabs).
       # (write each [<slug>-N] Critical/Important finding from the step-3 aggregate here)
       # panel-availability lines → "<slug>\tok|unavailable" (strip any trailing " (rc=N)").
       # (write each $panel_avail_lines entry here)
       bash scripts/handover/append-cr-bugs.sh --bugs "$item_dir/bugs.md" --findings "$cr_find" --avail "$cr_avail"
       rm -f "$cr_find" "$cr_avail"
   else
       echo "4.7: no active handover item for $branch — CR-bug lifecycle skipped" >&2
   fi
   ```
   The bridge is idempotent (dedups by finding-id), reopens a `resolved` bug whose finding reappears (regression), and resolves a vanished finding ONLY when its critic was `panel-availability: ok` that HEAD (a flaky critic drop-out must not falsely resolve a still-open bug). Best-effort — it always exits 0 and never blocks steps 5/6.

5. If both `N == 0`:
   - Delete `$marker` (`rm -f "$marker"`).
   - Report: `CR clean — marker cleared for $branch (HEAD=$head). Safe to gh pr create.`

6. If either `N > 0`:
   - Leave the marker in place.
   - Surface the Critical / Important findings to the user.
   - Instruct: address the findings, commit fixes, then re-run `/pr-check`. (A new commit invalidates the SHA in the marker too, but the marker is still present until `/pr-check` clears it.)

6.5. **Critic-score footer (append after the gate decision in steps 5/6).** Emit a per-model verdict tally for this run plus the cumulative agreed% from the ledger:
   ```bash
   bash scripts/cr/cr-scores.sh
   ```
   For any critic slug that appeared in the panel registry but whose
   `panel-availability:` line was `unavailable` (or absent entirely), append an
   **"absent this run"** note next to that model's row so the operator can see
   transient drop-outs. If the ledger has no records yet (first run),
   `cr-scores.sh` prints `no critic scores recorded yet` — emit that verbatim
   rather than suppressing it.

7. **Auto-file deferred nits (HIMMEL-30).** Runs whenever the review surfaces low-severity findings worth tracking, independently of steps 5/6:
   - Recognise findings tagged `NIT`, `LOW`, `SUGGESTION`, `IMPROVEMENT`, or `DEFERRED` (typically in a `## Suggestions (N found)` section per the `/pr-review-toolkit:review-pr` template).
   - **Why MEDIUM is excluded:** MEDIUM findings warrant attention before merge. Auto-filing them would let them drift into a backlog. CRITICAL / HIGH / IMPORTANT block the PR via steps 5/6; NIT / LOW / SUGGESTION / IMPROVEMENT / DEFERRED get auto-filed by step 7. MEDIUM is the explicit gap — surface to the operator, don't file.
   - Skip this step if there is no open PR yet — there's no target to link the issue to. Re-run `/pr-check` after `gh pr create`.
   - When a PR exists, write the full review markdown to a temp file (so the script reads it via `--input <path>` — piping multi-line review markdown through `printf` would mangle backticks and special chars) and run the filer:
     ```bash
     pr_num=""
     if pr_status=$(gh pr view --json number -q .number 2>&1); then
         pr_num="$pr_status"
     else
         case "$pr_status" in
             *"no pull requests"*|*"no open pull"*) ;;  # expected when no PR yet
             *) echo "WARN /pr-check: gh pr view failed: $pr_status" >&2 ;;
         esac
     fi

     if [ -n "$pr_num" ]; then
         review_tmpfile=$(mktemp -t cr-review.XXXXXX.md)
         # Claude writes the captured /pr-review-toolkit:review-pr markdown here:
         cat > "$review_tmpfile" <<'REVIEW_EOF'
         ... full review markdown ...
         REVIEW_EOF
         bash scripts/cr/file-deferred-issues.sh --pr "$pr_num" --input "$review_tmpfile" --dry-run
         # STOP HERE. Inspect the dry-run plan. If it looks right, re-invoke /pr-check
         # (or the same script without --dry-run) to actually file the issues.
         # rm "$review_tmpfile" after filing.
     fi
     ```
   - The script is idempotent — dedupe is content-hash based, so re-running `/pr-check` on the same review output produces zero new issues. Editing a flagged file (which shifts line numbers) creates a new issue, which is correct: the finding moved.
   - **Fail-closed dedupe:** if the gh issue-list lookup errors (rate-limit, auth expired), the script skips that finding rather than silently filing a duplicate. Operator should re-run after fixing the gh state.
   - Auto-creates the `cr-deferred` label on first non-dry-run invocation.

Notes:
- The PreToolUse hook (`scripts/hooks/check-cr-marker-on-pr-create.sh`) blocks `gh pr create` whenever the marker exists, regardless of SHA match — stale or fresh, you have to clear it.
- Bypass for emergencies: `SKIP_CR=1 git push` skips the marker write at push time, and a missing marker means `gh pr create` is allowed. Document any bypass in the PR body.
- COUPLING: this command parses the exact heading 'Critical Issues (N found)' / 'Important Issues (N found)' from TWO producers — `/pr-review-toolkit:review-pr` output AND `scripts/cr/critic-panel.sh` (HIMMEL-415) — and recognises the deferred-class severities listed above. If either producer changes the format, update this command, the other producer, and `scripts/cr/file-deferred-issues.sh` in lockstep. Note: `file-deferred-issues.sh` keys on the `file:LINE: SEVERITY:` line shape, NOT on `[<slug>-N]` bracket tags — those tags pass through untouched (expected no-op).
