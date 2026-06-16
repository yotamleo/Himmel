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

2.5. **Docs-audit lane (only when `lane = docs-audit`).** Dispatch ONE `pr-review-toolkit:code-reviewer` Agent (upstream type + the HIMMEL-178 directive prepended, same as step 3) with the docs charter and NOTHING else (no gemini first-pass, no other matrix agents):

   > **Docs-audit charter (HIMMEL-299/303) — audit ONLY these five dimensions, nothing else (no prose-style nitpicks):** (1) factual accuracy of every repo claim (hooks/gates/flags/paths/commands) vs the actual code/config; (2) every markdown link resolves; (3) no stale file/flag/ticket references; (4) example blocks have correct paths + flags + syntax; (5) internal consistency. Return findings tagged `[ACCURACY|DEAD-LINK|STALE|EXAMPLE|CONSISTENCY]` with file:line + fix; say `DOCS-AUDIT CLEAN` if none. (`CLAUDE.md` diffs: prefer `/claude-md-audit` for the rubric pass; this charter still applies for accuracy.)

   Treat any `[ACCURACY|DEAD-LINK|STALE|EXAMPLE]` finding as a blocking Critical for the step 5/6 decision (`[CONSISTENCY]` is Important). Then go to step 4 with these counts. Skip steps 3 / 3.0 entirely.

3. **Gemini first-pass, then dispatch reviewer agents in parallel (HIMMEL-178, HIMMEL-270).**

   **Step 3.0 — gemini first-pass (decimal substep, runs BEFORE any Agent dispatch):**
   ```bash
   diff_rc=0
   diff_out=$(git diff main...HEAD) || diff_rc=$?
   if [ "$diff_rc" -ne 0 ]; then
       # git itself failed — treat as gemini first-pass unavailable, not empty-diff skip.
       echo "gemini first-pass unavailable — claude-only review (git diff failed rc=$diff_rc: $diff_out)" >&2
   elif [ -z "$diff_out" ]; then
       echo "empty diff — gemini first-pass skipped"
   else
       printf '%s' "$diff_out" | bash scripts/cr/gemini-first-pass.sh
       # rc=0: capture stdout as the gemini findings block.
       # rc=1 or rc=2: print a warning, set the findings block to
       #       "(gemini first-pass unavailable — claude-only review)" and continue.
       #       (rc=2 = the script rejected stdin — usually a token-proxied git diff;
       #       retry once with the rtk proxy form below before falling back.)
   fi
   ```
   If the environment token-proxies git (rtk), the plain git diff above returns a stat summary, not a unified diff — the script exits 2 ('stdin is not a unified diff'). Produce the diff with `rtk proxy git diff main...HEAD` in that case.

   The script's `[gemini-N]` Critical/Important findings are BLOCKING
   CANDIDATES under the adjudication rules below. Its Suggestions are NOT
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

   When the gemini first-pass produced findings, ALSO prepend this directive
   plus the gemini Critical/Important findings to each agent prompt:

   > **Cross-model adjudication (HIMMEL-270):** the gemini first-pass findings
   > below are blocking candidates, each tagged `[gemini-N]`. For each finding
   > relevant to your role: AGREE (confirm with cited evidence from the
   > diff/file) or DISPROVE (grep the diff, read the file at the cited line,
   > or run a test proving it wrong). Record verdicts referencing the ID:
   > `cross-model-adjudication: [gemini-N] agreed — <evidence>` or
   > `cross-model-adjudication: [gemini-N] disproved — <evidence>`. Do not
   > silently ignore a finding relevant to your role.

   The `code-reviewer` dispatch's prompt additionally gets:
   **"You are the mandatory adjudicator: render a verdict on EVERY
   `[gemini-N]` Critical/Important, whether or not it looks relevant to your
   role — read the cited file if it is outside the diff context you were
   given."** (Closes the orphaned-finding hole — every gemini finding gets at
   least one verdict.)

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

   **Gemini adjudication cross-check (HIMMEL-270):** when step 3.0 produced
   findings, recompute the counts with this severity-partitioned rule before
   the step 5/6 decision:
   - A gemini Critical/Important is EXCLUDED from its count ONLY when it has
     at least one `disproved` verdict AND zero `agreed` verdicts. Every other
     state blocks: agreed-only, conflict (evidence-backed AGREE + DISPROVE —
     surface verbatim to the operator), and unaddressed (no verdict at all —
     append it to the Critical count as unaddressed, fail-closed).
   - Gemini Suggestions never enter blocking counts and need no verdict.
   Mechanically: every `[gemini-N]` Critical/Important forwarded in step 3
   must appear in the aggregate with at least one
   `cross-model-adjudication: [gemini-N] …` verdict line.

5. If both `N == 0`:
   - Delete `$marker` (`rm -f "$marker"`).
   - Report: `CR clean — marker cleared for $branch (HEAD=$head). Safe to gh pr create.`

6. If either `N > 0`:
   - Leave the marker in place.
   - Surface the Critical / Important findings to the user.
   - Instruct: address the findings, commit fixes, then re-run `/pr-check`. (A new commit invalidates the SHA in the marker too, but the marker is still present until `/pr-check` clears it.)

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
- COUPLING: this command parses the exact heading 'Critical Issues (N found)' / 'Important Issues (N found)' from TWO producers — /pr-review-toolkit:review-pr output AND `scripts/cr/gemini-first-pass.sh` (HIMMEL-270) — and recognises the deferred-class severities listed above. If either producer changes the format, update this command, the other producer, and `scripts/cr/file-deferred-issues.sh` in lockstep.
