# Handover — `handover-resume` (read-only)

**Script-driven (HIMMEL-1038).** The read path is fully mechanical and lives in
`scripts/handover/resume.sh` — the `/handover-resume` command calls it directly
and does **not** load this skill. When the `handover` skill itself is triggered
with resume phrasing, prefer the script over re-deriving the steps by hand:

- Resume an ID: `bash <repo-root>/scripts/handover/resume.sh <#N|PROJECT-N|N>`
  — resolves target repo + bucket from the registry, finds the item dir, prints
  its latest session's Cold-Start Prompt (fallback: `context.md` / `brief.md`),
  then the open-bugs + latest-CR panel and a stale nudge from `tech-debt.md`.
- No ID given (No-ID picker): `bash <repo-root>/scripts/handover/resume.sh --list`
  prints active items; render the picker (see No-ID picker flow in
  `references/resolution.md`) and re-invoke with the chosen ID.

Exit codes: `0` = printed; `2` = usage/hard error; `3` = graceful (no repo match
in registry / item not found → tell the user and stop).

Read-only — no worktree gate.

---

## Behavior contract (what the script implements)

`handover-resume #N` resolves any ID and outputs the cold-start prompt to resume
work in a new session. Kept here as the reference the script satisfies.

0. **Resolve target repo.** Read-only — if ambiguous from conversation context, ask which repo.
1. **If `#N` omitted:** run No-ID picker (see `references/resolution.md`).
2. **Normalize input:**
   - `<PROJECT>-K` (e.g. `HIMMEL-15`) → key form; scan only `<jira_project>-K-*/` namespace.
   - bare numeric `N` → scan BOTH `<jira_project>-N-*/` and `#N-*/` (per `references/routing.md` v2 rule).
   - strip leading `#` if present.
3. Scan in order, where `<form>` is each pattern from step 2. If the bucket layer is active and the ID has a Jira-prefix mapping, scan that bucket first; otherwise scan all buckets (and the legacy flat root):
   - `<state-root>/{,<bucket>/}epics/<form>-*/` → type: **epic**
   - `<state-root>/{,<bucket>/}epics/*/tasks/<form>-*/` → type: **task**
   - `<state-root>/{,<bucket>/}standalones/<form>-*/` → type: **standalone**
4. No match → output `No item with ID #N found in <repo-name>.` and stop.
5. List `next-session-*.md` in target dir. Find highest-numbered file.
6. **If session file exists:** read in full, locate the `## Cold-Start Prompt` heading, print every line **after** the heading up to the next `## ` heading or EOF (exclude the heading line itself, trim leading/trailing blank lines). Print under header `Cold-start prompt for #N (repo: <name>):`.
7. **No session file:** fallback — print `context.md` (epic) or `brief.md` (task/standalone), prefixed `No session file yet for #N in <repo-name>. Showing context:`.
7.5. **Surface open bugs + latest CR findings (C5).** Run `bash scripts/handover/resume-context.sh --item <resolved-item-dir>` (the dir found in step 3). If it prints anything, append it to the output under a blank line — so the resuming session sees open bugs (with FAILED/WORKED fixes-tried, to avoid re-trying a failed fix) and the most recent CR-findings block before continuing. Prints nothing for an item with no open bugs and no CR findings — leave the output clean.
8. **Stale nudge** — if `<state-root>/tech-debt.md` has any entries under `## Lingering` or `## Zombie`, append the top 3 to the printed output:

   ```text
   Stale items worth a glance before continuing:
   - <ID> (lingering — decompose)
   - <ID> (zombie — close or unblock)

   Full triage: /handover hygiene
   ```

   Top 3 ordered by tier severity (zombie > lingering > stale > warming).
