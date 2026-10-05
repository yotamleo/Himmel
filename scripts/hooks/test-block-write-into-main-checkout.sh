#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh (HIMMEL-2526)
# — the DESTINATION-based Bash/PowerShell write fence. Platform guard: Git
# Bash on Windows / any POSIX bash 3.2+ (see the guard's own header; no .ps1
# twin — both entry modes are already invoked BY a resolved bash).
#
# Exercises BOTH entry modes for every destination row via `check_both`:
#   - DIRECT-EXEC: `bash block-write-into-main-checkout.sh` with the raw JSON
#     hook payload on stdin — the shape the Claude Bash PreToolUse chain
#     actually uses (run-hook-with-bash.js's `spawnSync(bash, [member],
#     {input})`).
#   - SOURCED: `bash block-terminal-write-fence.sh` with the same payload —
#     the codex-lane adapter that sources this guard.
# A row that only exercised one mode would not prove the mode that actually
# ships proves anything — see FIXTURE RULE below for the other easy way to
# make this whole suite vacuous.
#
# FIXTURE RULE (load-bearing): fixtures are rooted under the REAL $HOME, NOT
# a bare `mktemp -d`. `/tmp` paths are exempted by is_temp_or_devnull, so
# every DENY row rooted under mktemp -d would silently pass as ALLOW for the
# wrong reason. Row 28 below is the FLIP CONTROL that proves this rule is
# load-bearing, not decorative.
# HIMMEL-4164: the fixture + harness setup (set, fixture repos, ok/bad/_run/
# check_*) moved to lib-test-write-fence.sh so this suite can be split into
# sibling shards (-heredoc, -matrix, -cd, -forms) under the CI per-suite cap.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"

echo "== DENY rows (destination-based, both wirings) =="

# 1. THE INCIDENT SHAPE.
check_both "1 incident shape: cat > primary/scripts/hooks/x.sh (cwd=wt)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $FIX/primary/scripts/hooks/x.sh\",\"cwd\":\"$FIX/wt\"}}"

# 2. Case-preserving extraction.
check_both "2 case-preserving: cat > Docs/Primary/... (cwd=wt)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $FIX/Docs/Primary/scripts/hooks/x.sh\",\"cwd\":\"$FIX/wt\"}}"

# 3. tee.
check_both "3 tee into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee $FIX/primary/scripts/x.sh\",\"cwd\":\"$FIX/primary\"}}"

# 4. sed -i file operand.
check_both "4 sed -i file operand into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' $FIX/primary/scripts/x.sh\",\"cwd\":\"$FIX/primary\"}}"

# 5. sed -i -e: the '>' inside the sed PROGRAM must not become a target, and
# the real file operand must still deny.
check_both "5 sed -i -e program-internal > is not a target; file operand still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -e 's/>/x/' $FIX/primary/scripts/x.sh\",\"cwd\":\"$FIX/primary\"}}"

# 6. cp with an existing-DIRECTORY dest -> sink = dir/basename(source).
check_both "6 cp somefile primary/ (dest is an existing directory)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp somefile $FIX/primary/\",\"cwd\":\"$FIX/primary\"}}"

# 7. mv: the SOURCE (inside primary) must deny even though the dest (wt) allows.
check_both "7 mv primary/scripts/x.sh wt/ (source inside primary denies)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/primary/scripts/x.sh $FIX/wt/\",\"cwd\":\"$FIX/primary\"}}"

# 8. rm.
check_both "8 rm primary/scripts/x.sh" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $FIX/primary/scripts/x.sh\",\"cwd\":\"$FIX/primary\"}}"

# 9 (HIMMEL-2946): touch creating the repo-root .single-writer opt-out itself
# must ALLOW — this is the exact catch-22 the hook's own deny text (line
# 842/1054) recommends as the remedy, then refused (not yet present in
# primary — .single-writer is only in the exclude file, not touched on disk).
check_both "9 touch primary/.single-writer (creating the opt-out itself) allows (HIMMEL-2946)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch $FIX/primary/.single-writer\",\"cwd\":\"$FIX/primary\"}}"

# 10 (HIMMEL-2946): redirect onto the same exact name — same exemption.
check_both "10 echo > primary/.single-writer (creating the opt-out itself) allows (HIMMEL-2946)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/.single-writer\",\"cwd\":\"$FIX/primary\"}}"

# 10b (HIMMEL-2946): the exemption is EXACT-BASENAME-AT-ROOT only — a
# subdirectory entry of the same basename must still deny.
check_both "10b touch primary/scripts/.single-writer (not the repo root) still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch $FIX/primary/scripts/.single-writer\",\"cwd\":\"$FIX/primary\"}}"

# 10c (HIMMEL-2946): near-miss basenames at the root must still deny — the
# exemption is the exact string ".single-writer", not a prefix/suffix match.
check_both "10c touch primary/.single-writer.bak (near-miss basename) still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch $FIX/primary/.single-writer.bak\",\"cwd\":\"$FIX/primary\"}}"
check_both "10d echo > primary/.single-writerx (near-miss basename) still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/.single-writerx\",\"cwd\":\"$FIX/primary\"}}"

# 10e (HIMMEL-2946): the exemption is by DESTINATION, not cwd — an absolute
# path into the primary's root marker from a DIFFERENT cwd (the worktree)
# must allow exactly like row 9.
check_both "10e touch \$FIX/primary/.single-writer from cwd=wt (destination-based, not cwd-based) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch $FIX/primary/.single-writer\",\"cwd\":\"$FIX/wt\"}}"

# 11. git commit, cwd = primary (main) — BOTH wirings agree (is_on_main and
# main_checkout_verdict both fire on plain "on main").
check_both "11 git commit cwd=primary (main) — both wirings agree" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FIX/primary\"}}"

# 12. git commit, cwd = featprimary (PRIMARY checkout, feature branch) — the
# NEW denial. DELIBERATE PER-LANE DIVERGENCE (RETASK, no codex-lane
# behaviour change): direct-exec uses main_checkout_verdict (the tighter
# main+primary-feature rule) and DENIES; the sourced/codex lane keeps
# HIMMEL-745's is_on_main (fail-open on any feature branch) and ALLOWS. This
# is the documented split, not a bug — see block-write-into-main-checkout.sh's
# CODEX-LANE PARITY header note.
check_one "12a git commit cwd=featprimary (primary-feature) — direct-exec DENIES (new rule)" \
    "$DIRECT" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FIX/featprimary\"}}"
check_one "12b git commit cwd=featprimary (primary-feature) — sourced/codex ALLOWS (HIMMEL-745 unchanged, deliberate)" \
    "$FENCE" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FIX/featprimary\"}}"

# 13. multi-sink: the SECOND sink (inside primary) must still be caught even
# though the first (wt) allows.
check_both "13 multi-sink: wt/ok.txt allows, primary/bad.txt still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo a > $FIX/wt/ok.txt; echo b > $FIX/primary/bad.txt\",\"cwd\":\"$FIX/primary\"}}"

# 14. a QUOTED operand directly after > IS a real target.
check_both "14 quoted redirect target (spaced filename) into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > \\\"$FIX/primary/quoted target.txt\\\"\",\"cwd\":\"$FIX/primary\"}}"

echo "== ALLOW rows =="

# 15. Linked worktree.
check_both "15 cat > wt/scripts/x.sh (linked worktree)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $FIX/wt/scripts/x.sh\",\"cwd\":\"$FIX/wt\"}}"

# 16. Relative target: TOOL PAYLOAD cwd wins over the hook PROCESS's own PWD.
check_both "16 relative cat > scripts/x.sh — payload cwd (wt) wins over hook PWD (primary)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > scripts/x.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary"

# 17. Arrow-shaped text inside a SINGLE-quoted argument is not a redirect.
check_both "17 printf '%s -> %s' — quoted arrow is not a redirect" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf '%s -> %s\\\\n' a b\",\"cwd\":\"$FIX/primary\"}}"

# 18. Arrow-shaped text inside a DOUBLE-quoted --format value is not a redirect.
check_both "18 git log --format=\"%h -> %s\" — quoted arrow is not a redirect" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log --format=\\\"%h -> %s\\\"\",\"cwd\":\"$FIX/primary\"}}"

# 19. Heredoc body blanked: `if a > b:` inside a python3 heredoc is not a target.
HEREDOC_CMD=$(printf "python3 - <<'PY'\nif a > b:\n    pass\nPY")
HEREDOC_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HEREDOC_CMD" | jq -Rs .),\"cwd\":\"$FIX/primary\"}}"
check_both "19 python3 heredoc body ('if a > b:') is blanked before the redirect scan" allow "$HEREDOC_JSON"

# 20. sed -i onto a real /tmp file — exempted.
check_both "20 sed -i onto /tmp/f (is_temp_or_devnull exemption)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' /tmp/f\",\"cwd\":\"$FIX/primary\"}}"

# 21. Dynamic target (unexpanded $T) fails OPEN on that candidate.
# HIMMEL-2592: the escape here was `\\\$T`, which emits `\$` into the JSON —
# NOT a valid JSON escape, so jq returned empty, the hook saw an EMPTY
# command and allowed. The row passed VACUOUSLY. A literal `$` inside a
# shell double-quoted string is `\$`, with no extra backslash.
check_both "21 echo > \"\$T/out\" — dynamic target fails open" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > \\\"\$T/out\\\"\",\"cwd\":\"$FIX/primary\"}}"

# 22. /dev/null with a trailing 2>&1 — no phantom target from the stderr dup.
check_both "22 echo > /dev/null 2>&1" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > /dev/null 2>&1\",\"cwd\":\"$FIX/primary\"}}"

# 22b. Whitespace-only candidate guard (CR finding): Pass A's quoted-operand
# regex can hand back a lone quoted SPACE straddling two unrelated arguments
# (`echo "a >" "target"` — the quoted span between the `>` and the next
# argument is `" "`, not a real redirect target). Without the whitespace trim
# in _bwimc_expand_token this resolved to "<cwd>/ " and fell through to a
# false DENY on an ordinary command. RED confirmed before the fix (rc=2 on a
# scratch copy of the pre-fix _bwimc_expand_token); GREEN after (rc=0).
check_both "22b whitespace-only quoted-span candidate does not false-deny an ordinary command" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\"a >\\\" \\\"target\\\"\",\"cwd\":\"$FIX/primary\"}}"

# 23. git commit in the linked worktree.
check_both "23 git commit cwd=wt (linked worktree)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FIX/wt\"}}"

# 23b. HIMMEL-2884: `git -C`/`--git-dir`/`--work-tree` must resolve the
# EFFECTIVE commit target instead of always checking the session cwd
# (CLAUDE.md prescribes `git -C <repo> commit` from a himmel-primary cwd, and
# the unfixed arm refused that shape even when the addressed repo allows).
# 23b-i: the ticket's own case — cwd is the primary, -C points at a
# single-writer repo, both wirings must ALLOW.
check_both "23b-i git -C swrepo commit (cwd=primary, -C target is single-writer) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIX/swrepo commit -q -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-ii: cwd is the primary, -C points at the linked worktree (feat/x) —
# allows, matching row 23's plain-cwd=wt case.
check_both "23b-ii git -C wt commit (cwd=primary, -C target is the worktree) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIX/wt commit -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-iii: the INVERSE of 23b-ii — cwd is the worktree, -C points BACK at the
# primary (main, no .single-writer). Must deny, and the deny text must name
# the RESOLVED -C target, not the cwd (today this false-ALLOWs: HIMMEL-2884).
check_both_reason "23b-iii git -C primary commit (cwd=wt, -C target is primary main) denies, names the -C target" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIX/primary commit -m x\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary"

# 23b-iv: bare `git commit`, cwd=primary — unaffected control (no -C to
# resolve; must keep denying exactly as row 11 already asserts).
check_both "23b-iv git commit (cwd=primary, no -C) still denies (control)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-v: chained relative `-C` — each `-C` resolves against the PREVIOUS one
# (git's own semantics), landing at $FIX itself (swrepo/..), which is not a
# git repo at all -> main_checkout_verdict's own "not in a repo -> allow".
check_both "23b-v git -C swrepo -C .. commit (chained relative -C lands outside any repo) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIX/swrepo -C .. commit -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-vi: `--git-dir=<p> --work-tree=<p>` naming the single-writer repo
# explicitly (no `-C` at all) — must resolve the same as 23b-i.
check_both "23b-vi git --git-dir/--work-tree targeting swrepo allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --git-dir=$FIX/swrepo/.git --work-tree=$FIX/swrepo commit -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-vii: an UNRESOLVABLE `-C` value (a live command substitution) must fail
# CLOSED back to checking the command's own cwd (still the primary here, so
# still denies) rather than silently allowing because the value couldn't be
# parsed.
check_both_reason "23b-vii git -C \"\$(pwd)\" commit (unresolvable -C value) fails closed to cwd, notes the failure" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C \\\"\$(pwd)\\\" commit -m x\",\"cwd\":\"$FIX/primary\"}}" \
    "could not be resolved"

# 23b-viii: codex CR round 1 (HIMMEL-2884) — when BOTH --git-dir and
# --work-tree are given, --git-dir determines the repository the commit
# actually updates (git's own semantics: --work-tree only supplies file
# content; HEAD moves in --git-dir's repo), so it must win over --work-tree
# regardless of which option is given first.
check_both_reason "23b-viii git --work-tree=wt --git-dir=primary/.git commit (both given) checks --git-dir's repo, not --work-tree's" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree=$FIX/wt --git-dir=$FIX/primary/.git commit -m x\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary"

# 23b-ix: codex CR round 1 (HIMMEL-2884) — a relative --git-dir/--work-tree
# value resolves against the FINAL cumulative -C directory, exactly like real
# git (`git --git-dir=a.git -C c status` == `git --git-dir=c/a.git status` per
# git(1)), regardless of whether -C appears before or after it on the line.
check_both "23b-ix git --git-dir=primary/.git -C \$FIX commit (relative --git-dir precedes -C) resolves against the FINAL -C dir, denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --git-dir=primary/.git -C $FIX commit -m x\",\"cwd\":\"$FIX/swrepo\"}}"

# 23b-x: codex CR round 2 (HIMMEL-2884) — a STANDALONE --work-tree (no
# --git-dir, no -C) does not change repository discovery at all: git still
# discovers .git by searching from the session's cwd, so HEAD moves in the
# cwd's repo while only the working-tree file content comes from the
# --work-tree path (confirmed against real git: `git --work-tree=<other>
# commit` from a repo cwd commits into the cwd's repo, not <other>'s). The
# unfixed code redirected the target to the --work-tree value itself, so
# `git --work-tree=$FIX/wt commit` from cwd=primary (main, denied) resolved
# to $FIX/wt (an allowed worktree) and false-ALLOWed a commit that actually
# lands on primary's HEAD.
check_both "23b-x git --work-tree=wt commit (cwd=primary, standalone --work-tree, no --git-dir/-C) still denies — HEAD moves in cwd's repo" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree=$FIX/wt commit -m x\",\"cwd\":\"$FIX/primary\"}}"

# 23b-xi: codex CR round 3 (HIMMEL-2884) — an UNRESOLVABLE -C value must fail
# CLOSED outright, not fall back to checking the command's cwd. 23b-vii's cwd
# is already primary, so its "falls back to cwd" outcome (deny) is identical
# whether the fallback denies-via-cwd or denies-outright, masking the gap:
# here cwd is the ALLOWED worktree, so an unresolvable -C that fell back to
# checking cwd would false-ALLOW a commit whose actual git target is unknown
# (real git could resolve it to primary). Must deny and name the failure.
check_both_reason "23b-xi git -C \"\$(pwd)\" commit (unresolvable -C, cwd=wt) fails CLOSED outright, not via cwd" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C \\\"\$(pwd)\\\" commit -m x\",\"cwd\":\"$FIX/wt\"}}" \
    "could not be resolved"

# 23b-xii: codex CR round 4 (HIMMEL-2884) — the --git-dir scan loop has no
# concept of `-C` at all, so when `-C`'s OWN VALUE happens to be the literal
# string "commit", the loop's break check fires on that value one token too
# early and never reaches a later --git-dir, silently dropping it. Real git
# still resolves the repo via --git-dir regardless of -C's value (confirmed
# against real git: `git -C commit --git-dir=<primary>/.git commit` reports
# "On branch main" — the PRIMARY's branch — from a worktree cwd), so a
# worktree containing (or merely naming) a "commit" entry must still deny.
check_both "23b-xii git -C commit --git-dir=primary/.git commit (-C value is literally \"commit\", masks --git-dir from the scan) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C commit --git-dir=$FIX/primary/.git commit -m x\",\"cwd\":\"$FIX/wt\"}}"

# 23b-xiii (HIMMEL-2949): same shape as 23b-xii but for --work-tree's OWN
# operand instead of -C's — neither scan loop skips it, so when that operand
# is literally the string "commit", the "stop at commit" break check fires
# one token early and the LATER -C (which real git honours) is never seen.
# Confirmed against real git: `git --work-tree commit -C <primary> status`
# from the worktree cwd reports "On branch main" (the PRIMARY's branch).
check_both_reason "23b-xiii git --work-tree commit -C primary commit (--work-tree's operand is literally \"commit\", masks a later -C) denies, names the -C target" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree commit -C $FIX/primary commit -q -m x\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary"

# 23b-xiv (HIMMEL-2949): the `--work-tree=<p>` compound-token form does not
# have a separate operand to mask anything, but pins that a LITERAL value of
# "commit" inside the compound token does not itself confuse the scan, and a
# later --git-dir is still honoured.
check_both "23b-xiv git --work-tree=commit --git-dir=primary/.git commit (compound --work-tree= form, --git-dir still resolves) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree=commit --git-dir=$FIX/primary/.git commit -q -m x\",\"cwd\":\"$FIX/wt\"}}"

# 23b-xv (HIMMEL-2949 control): a legitimate standalone `--work-tree <p>` (no
# --git-dir, no -C) stays a no-op for target resolution per the :970 design
# note — HEAD still moves in whatever repo cwd resolves to, so this must keep
# ALLOWing exactly like row 23.
check_both "23b-xv git --work-tree \$FIX/wt commit (cwd=wt, standalone --work-tree) still allows (control)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree $FIX/wt commit -q -m x\",\"cwd\":\"$FIX/wt\"}}"

# 23b-xvi (HIMMEL-2949 control): --work-tree's operand "commit" must not be
# mistaken for the subcommand even when a -C ALSO appears earlier and already
# resolves harmlessly to cwd — the fix must not overreact and start denying
# a genuinely allowed shape.
check_both "23b-xvi git -C wt --work-tree commit commit (-C already resolves to wt, --work-tree operand is \"commit\") still allows (control)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIX/wt --work-tree commit commit -q -m x\",\"cwd\":\"$FIX/wt\"}}"

# 24. handovers/ carve-out (main_checkout_verdict's own exemption).
check_both "24 cat > primary/handovers/x.md (handovers carve-out)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $FIX/primary/handovers/x.md\",\"cwd\":\"$FIX/primary\"}}"

# 25. .single-writer marker present at the repo root.
check_both "25 write into swrepo (.single-writer marker present)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/swrepo/x.txt\",\"cwd\":\"$FIX/swrepo\"}}"

# 26. `git push` through direct-exec: this script is NOT the external-write
# fence — it must ALLOW. Assert the codex/sourced wiring still DENIES it
# (class (a), unaffected by this PR — test-block-terminal-write-fence.sh's
# own "git push denied" row already pins this; re-asserted here for locality).
check_one "26a git push origin main — direct-exec ALLOWS (not the external-write fence)" \
    "$DIRECT" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\",\"cwd\":\"$FIX/primary\"}}"
check_one "26b git push origin main — sourced/codex still DENIES (class (a), unaffected)" \
    "$FENCE" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\",\"cwd\":\"$FIX/primary\"}}"

# 27. `gh pr create` through direct-exec — same rationale as 26.
check_one "27 gh pr create --fill — direct-exec ALLOWS (not the external-write fence)" \
    "$DIRECT" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --fill\",\"cwd\":\"$FIX/primary\"}}"

# 28. FLIP CONTROL: row 1's exact payload, retargeted at a /tmp-rooted
# primary. Proves the FIXTURE RULE above is load-bearing — this is the ONE
# row that is SUPPOSED to allow because the destination itself resolves
# beneath /tmp (the same ratified is_temp_or_devnull exemption pinned in
# test-block-terminal-write-fence.sh).
check_both "28 FLIP CONTROL: incident shape retargeted at a /tmp-rooted primary -> allow (proves the no-tmp-fixture rule matters)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $TMPFIX/primary/scripts/hooks/x.sh\",\"cwd\":\"$FIX/wt\"}}"

echo "== CR round 1 fixes (codex-2..6, HIMMEL-2526) =="

# 29 (codex-2): the deny REASON must actually print, not just rc=2. Before the
# fix, `repo_root=$(main_checkout_verdict ...); vrc=$?` fired errexit on the
# FAILING command substitution before `vrc=$?` ran, so the whole `case` was
# dead code and the EXIT trap silently converted this to a bare rc=2 with
# EMPTY stderr — asserted here on BOTH wirings (block-terminal-write-fence.sh
# already sets -euo pipefail before sourcing, so the sourced lane hits the
# identical bug).
F2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/wording.txt\",\"cwd\":\"$FIX/primary\"}}"
F2_ERR=$(_run_stderr "$DIRECT" "$F2_JSON")
case "$F2_ERR" in
    *"its repo is on main/master"*) ok "29 direct-exec deny prints the 'on main/master' wording (codex-2)" ;;
    *) bad "29 direct-exec deny prints the 'on main/master' wording (codex-2) — got: [$F2_ERR]" ;;
esac
F2_ERR=$(_run_stderr "$FENCE" "$F2_JSON")
case "$F2_ERR" in
    *"its repo is on main/master"*) ok "29 sourced/codex deny prints the 'on main/master' wording (codex-2)" ;;
    *) bad "29 sourced/codex deny prints the 'on main/master' wording (codex-2) — got: [$F2_ERR]" ;;
esac

# 30 (codex-3): a `>` sitting INSIDE a single-quoted argument (no real
# redirection happens at all) must NOT be treated as a redirect operator.
F3_CMD="echo 'text > \"$FIX/primary/q.txt\"'"
F3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F3_CMD" | jq -Rs .),\"cwd\":\"$FIX/primary\"}}"
check_both "30 quoted-argument '>' is not a real redirect (codex-3)" allow "$F3_JSON"

# 31 (codex-4): `tee` writes to EVERY file operand, not only the first.
check_both "31 tee /dev/null primary/teed.txt — SECOND operand still denies (codex-4)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null $FIX/primary/teed.txt\",\"cwd\":\"$FIX/primary\"}}"

# 32 (codex-5): `sed -i` with an ATTACHED `-e` program (`-e's/a/b/'`, no space)
# must still recognise the real file operand.
check_both "32 sed -i -e's/a/b/' primary/existing.txt — attached -e still denies (codex-5)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -e's/a/b/' $FIX/primary/existing.txt\",\"cwd\":\"$FIX/primary\"}}"

# 33 (codex-6): `cp -t<dir>` (attached), `cp -t <dir>` (separated), and
# `cp --target-directory=<dir>` all bypass a naive "last operand is the dest"
# assumption — the ACTUAL destination is the -t/--target-directory value.
check_both "33a cp -t<primary> src (attached -t) denies (codex-6)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t$FIX/primary src\",\"cwd\":\"$FIX/wt\"}}"
check_both "33b cp -t <primary> src (separated -t) denies (codex-6)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/primary src\",\"cwd\":\"$FIX/wt\"}}"
check_both "33c cp --target-directory=<primary> src denies (codex-6)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --target-directory=$FIX/primary src\",\"cwd\":\"$FIX/wt\"}}"
check_both "33d mv -t<primary> src denies too (codex-6, same option on mv)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -t$FIX/primary src\",\"cwd\":\"$FIX/wt\"}}"

echo "== CR round 3 fixes (codex-1/3/4, HIMMEL-2526) =="

# 34 (codex-1): a redirect operator ATTACHED to the preceding token (no
# space) must still be recognised — _bwimc_tokenize splits on whitespace
# only, so `x>/primary/f` used to be ONE token and the operator regex
# (anchored on the token START) never matched.
check_both "34a echo x>primary/attached.txt (no space before >) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x>$FIX/primary/attached.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "34b echo x>>primary/attached2.txt (append, no space) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x>>$FIX/primary/attached2.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "34c control: echo x > primary/spaced.txt (already spaced) still denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/spaced.txt\",\"cwd\":\"$FIX/wt\"}}"

# 35 (codex-1 regression guard): fd duplication (2>&1) must still ALLOW after
# the attached-operator fix. The disproved codex-2 finding claimed splitting
# clauses at every unquoted `&` breaks this shape; it does not reproduce, and
# this row exists so a FUTURE "fix" of that non-finding cannot silently
# regress it.
check_both "35 echo x 2>&1 (fd-dup) still allows after the attached-> fix (codex-1 regression guard)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x 2>&1\",\"cwd\":\"$FIX/wt\"}}"

# 36 (codex-3): a worktree symlink pointing AT a file inside the PRIMARY
# checkout must deny — guard_canon_path's ancestor walk only followed a
# symlink that resolved to a DIRECTORY (via `cd`+`pwd -P`); a symlink to a
# regular file fell out of the walk as a plain textual tail component and
# was joined onto the worktree-local resolved path unresolved.
check_both "36a echo hi > wt/link-to-primary.txt (symlink into primary) denies (codex-3)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
# 36b (HIMMEL-2592 round 4, DENY REMOVAL): codex-3's actual finding was that
# guard_canon_path's ancestor walk only followed a symlink that resolved to a
# DIRECTORY — a symlink to a REGULAR FILE fell out of the walk unresolved.
# Row 36a proves that fix still holds. This row's separate assumption — that
# `sed -i` also writes THROUGH a final-component symlink like a redirect does
# — was wrong: measured against GNU sed 4.10, the default `sed -i` REPLACES
# the directory ENTRY (rename-over-a-new-regular-file) and leaves the
# referent ($FIX/primary/existing.txt) untouched. So `sed -i` on a worktree
# symlink into the primary only ever touches the worktree's own entry and
# must ALLOW. The twin that must still DENY — `sed -i --follow-symlinks` on
# this same link, which genuinely writes through — is row 36c below.
check_both "36b ARGUED REMOVAL: sed -i on that same symlink allows — sed -i replaces the worktree's own entry, referent untouched [twin: 36c]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
# 36c: the FOLLOW twin of 36b — `--follow-symlinks` genuinely writes through
# the link into the primary's referent and must still deny. Without this row
# the 36b removal would be a fail-open.
check_both_reason "36c control: sed -i --follow-symlinks on that same symlink still denies (writes THROUGH)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --follow-symlinks 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/wt/link-to-primary.txt"
# 36d: PRIMARY-SIDE control under the new `entry` mode — a symlink INSIDE the
# primary whose referent is OUTSIDE it ($FIX/primary/link-to-wt.txt ->
# $FIX/wt/wtfile.txt) must still deny under plain `sed -i`: the primary's own
# ENTRY is what gets replaced, regardless of where the referent lives.
check_both "36d control: sed -i on a symlink INSIDE the primary still denies (entry mode replaces the primary's own entry)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}"

# 36e/36f (RETASK R-N1-SED-4b91d7): the sed ground truth that 36b/36c/45e's
# mode choice rests on, MEASURED here (by running the real `sed`) rather than
# asserted from a table, so it lives in the PR's own oracle instead of a
# throwaway probe script nobody remembers. Fixture rooted under $FIX (real
# $HOME-derived, per the FIXTURE RULE above) — never a bare /tmp root, which
# is_temp_or_devnull would exempt and make this vacuous. Skipped cleanly (not
# failed) on a non-GNU sed: this is GNU-specific behaviour, and a skip here
# is a signal to re-derive the mode logic for that platform, not a red.
sedver=$(sed --version 2>/dev/null | grep -i 'GNU sed')  # gnu-ok: measures the HOST's own sed to pick which oracle rows below apply; SKIPs cleanly on non-GNU sed
if [ -n "$sedver" ]; then
    SEDGT="$FIX/sedground"
    mkdir -p "$SEDGT"

    printf 'orig\n' > "$SEDGT/referent-default.txt"
    ln -sf "$SEDGT/referent-default.txt" "$SEDGT/link-default.txt"
    sed -i 's/orig/changed/' "$SEDGT/link-default.txt" >/dev/null 2>&1  # gnu-ok: measures GNU sed -i's own default (ENTRY-replacing) semantics, the oracle 36b/36c/45e's mode choice rests on
    if [ "$(cat "$SEDGT/referent-default.txt" 2>/dev/null)" = "orig" ] && [ ! -L "$SEDGT/link-default.txt" ]; then
        ok "36e sed -i ground truth: default replaces the ENTRY (referent unchanged, entry no longer a symlink)"
    else
        bad "36e sed -i ground truth: default replaces the ENTRY — referent='$(cat "$SEDGT/referent-default.txt" 2>/dev/null)' still-symlink=$([ -L "$SEDGT/link-default.txt" ] && echo yes || echo no)"
    fi

    printf 'orig\n' > "$SEDGT/referent-follow.txt"
    ln -sf "$SEDGT/referent-follow.txt" "$SEDGT/link-follow.txt"
    sed -i --follow-symlinks 's/orig/changed/' "$SEDGT/link-follow.txt" >/dev/null 2>&1  # gnu-ok: measures GNU sed -i --follow-symlinks' own write-through semantics, the oracle's FOLLOW twin
    if [ "$(cat "$SEDGT/referent-follow.txt" 2>/dev/null)" = "changed" ] && [ -L "$SEDGT/link-follow.txt" ]; then
        ok "36f sed -i ground truth: --follow-symlinks writes THROUGH (referent changed, entry still a symlink)"
    else
        bad "36f sed -i ground truth: --follow-symlinks writes THROUGH — referent='$(cat "$SEDGT/referent-follow.txt" 2>/dev/null)' still-symlink=$([ -L "$SEDGT/link-follow.txt" ] && echo yes || echo no)"
    fi
else
    echo "  SKIP 36e/36f sed -i ground truth rows — host sed is not GNU sed ($(sed --version 2>&1 | head -1))"
fi

# 37 (codex-4): a glob SOURCE must not skip a STATIC destination directory
# check — every source token being unparseable (`*.txt`, _bwimc_expand_token
# returns 1 on `*`) used to mean the destination check (nested inside
# `if [ -n "$_bwimc_src_abs" ]`) never ran at all.
check_both "37 cp *.txt primary/ (glob source) still denies via the static destination (codex-4)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp *.txt $FIX/primary/\",\"cwd\":\"$FIX/wt\"}}"

echo "== CR round 4 fixes (codex-1/2/3, HIMMEL-2526) =="

# 38 (codex-1): the SAME glob-source-skips-the-destination-check defect row
# 37 fixed above, but in the OTHER branch of the same `if` — the -t/
# --target-directory branch treats every remaining operand as a SOURCE and
# only checked the target dir via a per-source basename join, so an
# all-glob source list left the explicitly named -t/--target-directory
# value unchecked entirely.
check_both "38a cp -t primary *.txt (glob source, -t form) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/primary *.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "38b cp --target-directory=primary *.txt (glob source) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --target-directory=$FIX/primary *.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "38c control: cp -t primary <static src> still denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/primary src\",\"cwd\":\"$FIX/wt\"}}"

# 39 (codex-2): `tee` must be anchored to COMMAND POSITION — but "command
# position" means "the first token that is not a command PREFIX", not
# literally index 0. A bare token equal to "tee" appearing LATER in an
# unrelated, read-only command must not start scanning every following
# token as a destination (39a) — but the closed prefix-skip list (env
# assignments, sudo/env/command/nohup/time/stdbuf, and sudo's -u/--user
# value) must still resolve `sudo tee f` / `FOO=1 tee f` / piped forms to
# "tee is the command" (39b-39f), or the round-4 anchoring fix silently
# drops the single most common way `tee` is actually invoked to write a
# protected file.
check_both "39a echo tee README.md (arg mentions tee, cwd=primary/main) allows (codex-2)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo tee README.md\",\"cwd\":\"$FIX/primary\"}}"
check_both "39b tee primary/teed2.txt (still the real command) denies (codex-2 regression guard)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee $FIX/primary/teed2.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39c echo x | tee primary/piped.txt (piped tee starts its own clause) denies (codex-2 regression guard)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x | tee $FIX/primary/piped.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39d sudo tee primary/sudoed.txt denies (codex-2 prefix-skip)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sudo tee $FIX/primary/sudoed.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39e echo x | sudo tee primary/pipedsudo.txt denies (codex-2 prefix-skip)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x | sudo tee $FIX/primary/pipedsudo.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39f FOO=1 tee primary/envpfx.txt denies (codex-2 prefix-skip, env assignment)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"FOO=1 tee $FIX/primary/envpfx.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39g sudo -u someone tee primary/sudou.txt denies (codex-2 prefix-skip, sudo -u value)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sudo -u someone tee $FIX/primary/sudou.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "39h command -v tee (query, no operand) still allows (codex-2 prefix-skip)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"command -v tee\",\"cwd\":\"$FIX/primary\"}}"

# 40 (codex-3): a here-string `<<<` must not be mistaken for a heredoc
# opener. `[[ =~ ]]` tries every start position, and on `cat <<<EOF` the
# old regex could match beginning at the SECOND `<` (chars 2-3 are `<<`,
# followed by identifier `EOF`), setting active=1 and blanking every
# following line — including a real write — until a line equal to "EOF"
# appeared: a fail-OPEN on the write.
HS_CMD=$(printf 'cat <<<EOF\necho pwned > %s/hidden.txt' "$FIX/primary")
HS_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HS_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "40a cat <<<EOF then a real write on the next line denies (codex-3)" block "$HS_JSON"

# 40b control: a genuine UNQUOTED heredoc opener (`<<EOF`, distinct from
# row 19's quoted `<<'PY'` — a different regex alternative/group) must
# still blank its body so a write-shaped line inside it is not a target.
HD_CMD=$(printf "cat <<EOF\necho not-a-write > %s/inbody2.txt\nEOF" "$FIX/primary")
HD_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HD_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "40b control: genuine unquoted heredoc <<EOF still blanks its body (codex-3)" allow "$HD_JSON"

echo "== HIMMEL-2592: operand/opener/splitter token classes + operation-chosen resolution =="

# The class, stated once: an operand, opener or splitter meets a token it
# cannot classify and silently CONSUMES or MANGLES it instead of failing
# closed or handing it on. Every row below is one instance, and every DENY
# row asserts the REASON.

# 41 (HIMMEL-2591, instance 1): a QUOTED or COMMENTED `<<EOF` is not a
# heredoc opener. It used to start body blanking, which ERASES the real
# write on the following line — a fail-OPEN produced by ordinary text.
for _q in "single:echo '<<EOF'" "double:echo \"<<EOF\"" "comment:# <<EOF"; do
    _qname="${_q%%:*}"; _qline="${_q#*:}"
    _CMD=$(printf '%s\necho pwned > %s/q-%s.txt' "$_qline" "$FIX/primary" "$_qname")
    _JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
    check_both_reason "41 $_qname-quoted <<EOF does not blank the following real write (HIMMEL-2591)" \
        "$_JSON" "its repo is on main/master"
done

# 41d CONTROL (load-bearing, both directions): a GENUINE heredoc must still
# blank its body — that is what stops a `>` inside heredoc TEXT reading as a
# redirect. The body deliberately carries an unbalanced quote, because the
# rewritten walk FREEZES quote state while a body is active (a heredoc body
# is literal text; its quotes are not shell quotes).
HD5_CMD=$(printf "cat <<EOF\nit's not a write > %s/inbody3.txt\nEOF" "$FIX/primary")
HD5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HD5_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "41d control: a genuine heredoc still blanks its body (quote state frozen inside it)" allow "$HD5_JSON"

# 42 (HIMMEL-2592, instance 2 — the fourth Mode-1 hoist, with the invariant
# stated): the `mv` SOURCE check must not sit inside the DESTINATION's
# resolution guard. A dynamic `$DEST` used to suppress a fully-static
# primary-checkout source. INVARIANT: every operand this extractor can
# resolve statically is checked INDEPENDENTLY of whether any sibling
# resolved.
check_both_reason "42a mv <primary>/tracked.txt \$DEST — static SOURCE checked despite a dynamic dest" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/primary/existing.txt \$DEST\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/existing.txt"
check_both "42b control: cp <primary>/f \$DEST still allows (a cp SOURCE is READ-only)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/primary/existing.txt \$DEST\",\"cwd\":\"$FIX/wt\"}}"

# 43 (instance 3): a redirect operator in tee's OPERAND position. The tee
# loop now yields the token back to the redirect walk instead of resolving
# it as a filename.
check_both_reason "43a tee /dev/null >|primary|/f (attached) denies via the redirect arm" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null >$FIX/primary/t1.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/t1.txt"
check_both_reason "43b tee /dev/null >>|primary|/f (append, attached) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null >>$FIX/primary/t2.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/t2.txt"
# 43c is THE acceptance row for criterion 1: the SPACED form denied before
# this round too, but for the WRONG reason — the tee loop ate the bare `>`
# as a filename `<cwd>/>` and denied on THAT. Run from the primary, where
# the bogus path is itself inside the protected checkout, the pre-fix deny
# names `>` as the target token and the post-fix deny names the real path.
check_both_reason "43c tee /dev/null > |primary|/f (spaced) denies naming the REAL path, not the bare '>'" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null > $FIX/primary/t3.txt\",\"cwd\":\"$FIX/primary\"}}" \
    "target token: $FIX/primary/t3.txt"
# 43d: the relocation this round deliberately accepts — `cp src >/primary/f`
# no longer resolves `>/primary/f` as a cp DESTINATION (all arms share one
# tokenization now), so arm (a) must catch the real redirect instead. No
# coverage lost, only moved.
check_both_reason "43d cp src >|primary|/f — arm (a) catches the redirect the cp arm no longer sees" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt >$FIX/primary/reloc.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/reloc.txt"
# 43e: a verb arm must not STOP at a redirect either — bash allows a
# redirect anywhere in a simple command, so the operands after it are real.
check_both_reason "43e rm >|wt|/log |primary|/f — the operand AFTER a redirect is still checked" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm >$FIX/wt/log $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/existing.txt"

# 44 (instance 4): `>|` is the CLOBBER redirect operator, not a pipe. The
# clause splitter used to cut at that `|`, leaving `echo x >` + the target
# in two clauses and losing the target entirely.
check_both_reason "44a echo x >| |primary|/f (spaced clobber redirect) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >| $FIX/primary/clob.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/clob.txt"
check_both_reason "44b echo x >||primary|/f (attached clobber redirect) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >|$FIX/primary/clob2.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/clob2.txt"
check_both "44c control: a real pipe is still a clause boundary (echo x | tee wt/f)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x | tee $FIX/wt/piped.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "44d control: || is untouched by the >| rule" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true || echo x > $FIX/wt/ored.txt\",\"cwd\":\"$FIX/wt\"}}"

# 45 (instance 5) + the ONE argued deny removal. Resolution is chosen by the
# OPERATION: `rm` unlinks the directory ENTRY and never touches the
# referent, so it resolves with guard_canon_path_nofollow.
check_both_reason "45a rm |primary|/link-to-wt.txt (entry INSIDE the primary) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/link-to-wt.txt"
check_both_reason "45b mv |primary|/link-to-wt.txt |wt|/x (mv SOURCE = entry) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/primary/link-to-wt.txt $FIX/wt/moved.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/link-to-wt.txt"
# RATIFIED DENY REMOVALS (three rows, ONE class): an ENTRY verb — `rm`,
# `mv` SOURCE, recursive `rm` — acting on a BARE final-component symlink
# whose ENTRY lives in an UNPROTECTED checkout cannot reach the referent, so
# the old deny protected nothing. The ratification is CONDITIONAL on the
# MIRROR rows: each removal sits beside the assertion that the SAME verb
# still denies when the entry is INSIDE the primary. A removal row alone is
# not the assertion — the PAIR is.
#   45c removal <-> 45a mirror   (rm, file symlink)
#   45f removal <-> 45b mirror   (mv SOURCE, file symlink)
#   47c removal <-> 47f mirror   (recursive rm, DIRECTORY symlink)
check_both "45c ARGUED REMOVAL: rm |wt|/link-to-primary.txt -> allow (rm never touches the referent) [mirror: 45a]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "45f ARGUED REMOVAL: mv |wt|/link-to-primary.txt |wt|/x -> allow (rename moves the entry) [mirror: 45b]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/link-to-primary.txt $FIX/wt/moved2.txt\",\"cwd\":\"$FIX/wt\"}}"
# 45g is CONDITION (b) of the ratification, and criterion 1's independence
# invariant expressed as a test: the mv-SOURCE removal must NEVER suppress
# the DESTINATION check. The source entry here is worktree-local (allowed by
# 45f), so the deny can only come from the destination — which is why this
# row asserts the destination TOKEN and not merely rc=2.
check_both_reason "45g mv |wt|/filelink |primary|/x denies on the DESTINATION (the source removal suppresses nothing)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/link-to-primary.txt $FIX/primary/x\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/x"
check_both_reason "45d control: a redirect THROUGH that same link still denies (FOLLOW)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"
# 45e (HIMMEL-2592 round 4, DENY REMOVAL, mirrors 36b): the same ground truth
# as 36b — GNU sed -i's default form replaces the worktree's own ENTRY and
# leaves the referent untouched, so it never reaches the primary and must
# ALLOW. See 36e/36f above for the measured ground truth this rests on.
check_both "45e ARGUED REMOVAL: sed -i on that same link allows — sed -i replaces the worktree's own entry, referent untouched [twin: 45h]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "45h control: sed -i --follow-symlinks on that same link still denies (writes THROUGH)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --follow-symlinks 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"

# 46 (instance 6): the FALSE-POSITIVE direction of the same tee defect —
# `tee /dev/null > /dev/null` from the primary used to deny on the phantom
# path `<primary>/>` that the operand loop manufactured out of the operator.
check_both "46a tee /dev/null > /dev/null (cwd=primary) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null > /dev/null\",\"cwd\":\"$FIX/primary\"}}"
check_both "46b tee /dev/null >/dev/null (attached, cwd=primary) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null >/dev/null\",\"cwd\":\"$FIX/primary\"}}"

# 47 (RETASK rule A): ENTRY resolution is only correct when the symlink is
# the FINAL path component with NOTHING after it. Verified against the real
# `rm`: `rm -r <dirlink>` leaves the referent intact, `rm -r <dirlink>/`
# deletes the referent's contents THROUGH the link. The PAIR is the
# assertion — a single row proves nothing here.
check_both_reason "47a rm -r |wt|/dirlink/ (trailing slash forces FOLLOW) denies on the referent" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -r $FIX/wt/dirlink/\",\"cwd\":\"$FIX/wt\"}}" \
    "resolved target: $FIX/primary/somedir"
check_both_reason "47b rm -r |wt|/dirlink/. (trailing /. forces FOLLOW) denies on the referent" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -r $FIX/wt/dirlink/.\",\"cwd\":\"$FIX/wt\"}}" \
    "resolved target: $FIX/primary/somedir"
check_both "47c RATIFIED REMOVAL: rm -r |wt|/dirlink (bare final component) allows — ENTRY is worktree-local [mirror: 47f]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -r $FIX/wt/dirlink\",\"cwd\":\"$FIX/wt\"}}"
# 47f is 47c's MIRROR and the condition the removal was ratified on: the same
# recursive rm on a DIRECTORY symlink whose ENTRY lives in the primary must
# still deny. It is also the regression row for guard_canon_path_nofollow's
# dir-symlink handling — a nofollow that still dereferences a final
# dir-symlink turns exactly this row into a false ALLOW.
check_both_reason "47f MIRROR: rm -r |primary|/dirlink-out (entry INSIDE the primary) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -r $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
# 47d: the real `mv` REFUSES `mv <dirlink>/ X` outright (rc=1), so either
# verdict is defensible. Deliberate choice, asserted so it cannot drift: we
# DENY, because the trailing slash means the operand names the referent.
check_both_reason "47d mv |wt|/dirlink/ X denies (deliberate: real mv refuses this shape, we fail closed)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/dirlink/ $FIX/wt/x\",\"cwd\":\"$FIX/wt\"}}" \
    "resolved target: $FIX/primary/somedir"
check_both "47e PAIR CONTROL: mv |wt|/dirlink X (bare) allows — mv SOURCE is the ENTRY" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/dirlink $FIX/wt/x\",\"cwd\":\"$FIX/wt\"}}"

# 48 (RETASK rule B): a `glob` operand is not DROPPED. Its longest glob-free
# prefix is resolved with FOLLOW semantics and checked as a write-through
# directory — this is where rule A and the glob class meet. Deliberately NOT
# "deny any operand containing a glob": a DYNAMIC operand still fails open
# on itself alone, and a READ role never denies.
check_both_reason "48a rm |wt|/dirlink/* — the glob-free prefix follows into the primary" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $FIX/wt/dirlink/*\",\"cwd\":\"$FIX/wt\"}}" \
    "resolved target: $FIX/primary/somedir"
check_both "48b NEW DENY, deliberate: rm *.txt with cwd inside a protected checkout denies on the cwd" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm *.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "48c FALSE-POSITIVE CONTROL: rm ./*.txt from the worktree still allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm ./*.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "48d FALSE-POSITIVE CONTROL: cp |primary|/*.txt |wt|/ allows — a cp SOURCE is a READ role" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/primary/*.txt $FIX/wt/\",\"cwd\":\"$FIX/wt\"}}"

# 49: the new `ln` arm. `ln`/`ln -s` creates a directory ENTRY, and this
# fence had no `ln` arm at all — the same class, cheap to close.
check_both_reason "49a ln -s x |primary|/newlink (creates an entry in the primary) denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt $FIX/primary/newlink\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/newlink"
check_both_reason "49b ln (hard link) x |primary|/newhard denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln $FIX/wt/z.txt $FIX/primary/newhard\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/newhard"
check_both_reason "49c ln -t |primary| src denies (target-directory form)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -t $FIX/primary $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary"
check_both "49d FALSE-POSITIVE CONTROL: ln -s |primary|/a.txt |wt|/newlink allows (the TARGET is only read)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/primary/a.txt $FIX/wt/newlink\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 CR round 1 (codex-1, codex-2) — both fail-OPENs in code THIS PR added =="

# 50 (codex-1): inside a DOUBLE-quoted span a backslash escapes the next
# character, so `\"` does not close the span. Reading it as a close made the
# `<<EOF` that follows look UNQUOTED, activated blanking, and ERASED the real
# write on the next line — HIMMEL-2591's fail-open reached through a
# different door. 50b/50c are the DISCRIMINATING controls: quoted-opener
# handling in general is fine (the shipped 2591 fix) and an escaped quote
# with no opener is fine, which is what localises the defect to the escape.
Q1_CMD=$(printf 'echo "\\"<<EOF"\necho pwned > %s/esc1.txt' "$FIX/primary")
Q1_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$Q1_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50a echo \"\\\"<<EOF\" — an ESCAPED quote does not close the span (codex-1)" \
    "$Q1_JSON" "target token: $FIX/primary/esc1.txt"
Q2_CMD=$(printf "echo '<<EOF'\necho pwned > %s/esc2.txt" "$FIX/primary")
Q2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$Q2_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50b DISCRIMINATING CONTROL: plain quoted opener still denies (codex-1)" \
    "$Q2_JSON" "target token: $FIX/primary/esc2.txt"
Q3_CMD=$(printf 'echo "\\"hello"\necho pwned > %s/esc3.txt' "$FIX/primary")
Q3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$Q3_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50c DISCRIMINATING CONTROL: escaped quote with NO opener still denies (codex-1)" \
    "$Q3_JSON" "target token: $FIX/primary/esc3.txt"
# 50d-50g: the OTHER THREE passes. codex-1 was never one bug — escape
# blindness was in EVERY quote-aware pass, so all four now share ONE scanner
# (_bwimc_scan_init/_bwimc_scan_step). These rows are one per pass; they are
# what stops a future change fixing one walk and leaving three.
#
# 50d/50e — _bwimc_split_clauses. 50d: the whole command is ONE quoted
# argument, so there is no second clause; reading `\"` as closing the span
# manufactured a phantom write clause (false positive). 50e: the fail-OPEN
# direction — a REAL write after an argument containing an escaped quote.
P2A_CMD=$(printf '%s' "echo \"\\\";echo hi > $FIX/primary/p2a.txt\"")
P2A_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$P2A_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "50d split_clauses: an escaped quote does not manufacture a clause (codex-1 pass 2)" allow "$P2A_JSON"
P2B_CMD=$(printf '%s' "echo \"a\\\"b\" ; echo pwned > $FIX/primary/p2b.txt")
P2B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$P2B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50e split_clauses: a real write AFTER an escaped-quote argument still denies (codex-1 pass 2)" \
    "$P2B_JSON" "target token: $FIX/primary/p2b.txt"
# 50f — _bwimc_tokenize: the escaped quote must not end the token early, or
# the following real redirect is never seen.
P3_CMD=$(printf '%s' "echo \"a\\\" b\" > $FIX/primary/p3.txt")
P3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$P3_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50f tokenize: a real redirect after an escaped quote still denies (codex-1 pass 3)" \
    "$P3_JSON" "target token: $FIX/primary/p3.txt"
# 50g/50h — _bwimc_space_before_redirects, both directions: a REAL `>` after
# an escaped quote must still be spaced off into its own token (50g), and a
# `>` INSIDE the quoted span must still be left alone (50h).
P4A_CMD=$(printf '%s' "echo \"\\\"\" > $FIX/primary/p4a.txt")
P4A_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$P4A_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50g pre-spacing: a real redirect after an escaped quote still denies (codex-1 pass 4)" \
    "$P4A_JSON" "target token: $FIX/primary/p4a.txt"
P4B_CMD=$(printf '%s' "echo \"\\\">$FIX/primary/p4b.txt\"")
P4B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$P4B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "50h pre-spacing: an arrow INSIDE the quoted span is still not a redirect (codex-1 pass 4)" allow "$P4B_JSON"

# 50i/50j — THE MIRROR, and the regression guard on the ASYMMETRY. bash has
# NO escape inside a SINGLE-quoted span, so `'x\'` is a COMPLETE string and
# quoting is CLOSED after it. Both rows are green BEFORE this fix and must
# stay green: a naive SYMMETRIC fix believes the span is still open, hides
# everything after it, and invents a fail-open that does not exist today.
M5A_CMD=$(printf '%s\n%s' "echo 'x\\'" "echo pwned > $FIX/primary/p5a.txt")
M5A_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$M5A_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50i MIRROR: a backslash inside SINGLE quotes is LITERAL — span closes (multi-line)" \
    "$M5A_JSON" "target token: $FIX/primary/p5a.txt"
M5B_CMD=$(printf '%s' "echo 'x\\' ; echo pwned > $FIX/primary/p5b.txt")
M5B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$M5B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50j MIRROR: same, one line — the single-quote asymmetry is not a bug to 'fix'" \
    "$M5B_JSON" "target token: $FIX/primary/p5b.txt"

# 50k/50l — the UNQUOTED half of the escape rule, both directions, PAIRED.
# Modelling `\` outside quotes is not cosmetic; both verdicts were verified
# by running the real commands in a scratch dir:
#   `echo \"> f`   CREATES f  — `\"` is a literal quote and the `>` is a REAL
#                  redirect. Before the scanner, that `"` opened a phantom
#                  span, the `>` read as quoted, and the write was MISSED:
#                  a fail-OPEN (50k closes it).
#   `echo x \> f`  creates NOTHING — `\>` is a literal `>`, not a redirect.
#                  The old deny was a FALSE POSITIVE, so 50l is an argued
#                  deny REMOVAL, not a hole. 50k is its pair: if a future
#                  change drops unquoted-escape handling to "restore" 50l's
#                  deny, 50k flips to allow and names the bypass it costs.
E1_CMD=$(printf '%s' "echo \\\"> $FIX/primary/esc-real.txt")
E1_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$E1_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "50k unquoted escape: echo \\\"> |primary|/f is a REAL redirect and denies" \
    "$E1_JSON" "target token: $FIX/primary/esc-real.txt"
E2_CMD=$(printf '%s' "echo x \\> $FIX/primary/esc-none.txt")
E2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$E2_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "50l ARGUED REMOVAL: echo x \\> |primary|/f allows — an escaped > is not a redirect [pair: 50k]" allow \
    "$E2_JSON"

# 51 (codex-2): an `ln` DESTINATION that RESOLVES TO A DIRECTORY is written
# THROUGH — `ln -s src <dir>` creates `<dir>/basename(src)` — so it is
# FOLLOW, the same as a cp/mv destination directory. Ground truth (the real
# `ln`, run in the parent's probe): with
# `<wt>/dirlink -> <primary>/somedir`, `ln -s src <wt>/dirlink` actually
# creates `<primary>/somedir/src`. 51c/51d are the required false-positive
# controls: a link into a WORKTREE directory and an ordinary new link name
# must both still allow, or the rule has over-applied.
check_both_reason "51a ln -s src |wt|/dirlink (dest resolves to a PRIMARY dir) denies (codex-2)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt $FIX/wt/dirlink\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "51b ln -t |wt|/dirlink src (target-directory through a link) denies (codex-2)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -t $FIX/wt/dirlink $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both "51c FALSE-POSITIVE CONTROL: ln -s src |wt|/wtdirlink (link to a WORKTREE dir) allows (codex-2)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt $FIX/wt/wtdirlink\",\"cwd\":\"$FIX/wt\"}}"
check_both "51d FALSE-POSITIVE CONTROL: ln -s src |wt|/plainname (ordinary new entry) allows (codex-2)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt $FIX/wt/plainname\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 CR round 2 (codex-1, codex-2) — fail-OPENs in the round-1 fix =="

# 52 (round-2 codex-1): `tee` writes EVERY file operand; a `>` only redirects
# stdout. The round-1 fix stopped the tee loop consuming the operator as a
# filename, but it BROKE out of collection, so any operand AFTER the redirect
# was silently dropped. Ground truth: running
# `tee /dev/null > /dev/null <primary>/f` CREATES that file. Collection is now
# a state that persists across the redirect, which the redirect arm still
# handles and still CHECKS.
check_both_reason "52a tee /dev/null > /dev/null |primary|/f — operand AFTER a spaced redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null > /dev/null $FIX/primary/tee-after1.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tee-after1.txt"
check_both_reason "52b tee /dev/null >/dev/null |primary|/f — operand AFTER an attached redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null >/dev/null $FIX/primary/tee-after2.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tee-after2.txt"
check_both_reason "52c control: tee |primary|/f > /dev/null — operand BEFORE the redirect still denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee $FIX/primary/tee-before.txt > /dev/null\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tee-before.txt"

# 53 (round-2 codex-2): `-n`/`--no-dereference` and `-T`/
# `--no-target-directory` DISABLE the dereference that makes a directory
# destination FOLLOW, so `ln` replaces the ENTRY instead of writing through.
# Ground truth at `<primary>/dirlink-out -> <worktree>/somedir`: `ln -sf`
# wrote THROUGH into the worktree, `ln -sfn` and `ln -sfT` REPLACED the entry
# inside the primary. The flags here are BUNDLED on purpose — a fix matching
# only a standalone `-n` does not close the finding.
check_both_reason "53a ln -sfn src |primary|/dirlink-out (bundled -n) denies — ENTRY replaced (codex-2)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sfn $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both_reason "53b ln -sfT src |primary|/dirlink-out (bundled -T) denies — ENTRY replaced (codex-2)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sfT $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
# 53c is the DISCRIMINATING control and its expectation is ground-truthed, not
# assumed: WITHOUT -n the write genuinely lands in the worktree, so it must
# ALLOW. If a future change makes this deny, the rule has over-applied into
# "any ln at a dirlink denies".
check_both "53c DISCRIMINATING CONTROL: ln -sf src |primary|/dirlink-out (no -n) ALLOWS — writes through (codex-2)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sf $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
# 53d: the `-t` value must not be misread as bundled flags — a target
# directory whose name contains `n` or `T` (`-t/…/Tmp-n`) would otherwise
# flip the destination to ENTRY and lose the target-directory check.
check_both_reason "53d ln -sft |primary|/somedir src — a -t value containing n/T is not a flag bundle" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sft $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/somedir"

# 54 — TWIN 1 regression guards, one row per operand-collecting arm. Every
# arm must keep collecting operands AFTER a redirect, because bash allows a
# redirect anywhere in a simple command and the operands around it are all
# real. The tee arm was the last one still breaking instead of resuming;
# these seven rows are what stop any arm regressing to a bare `break`.
check_both_reason "54a tee: operand after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee /dev/null > /dev/null $FIX/primary/tw-tee.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tw-tee.txt"
check_both_reason "54b rm: operand after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm > /dev/null $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/existing.txt"
check_both_reason "54c touch: operand after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch > /dev/null $FIX/primary/tw-touch.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tw-touch.txt"
check_both_reason "54d cp: destination after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp > /dev/null $FIX/wt/z.txt $FIX/primary/tw-cp.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tw-cp.txt"
check_both_reason "54e mv: destination after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv > /dev/null $FIX/wt/z.txt $FIX/primary/tw-mv.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tw-mv.txt"
check_both_reason "54f sed -i: file operand after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/a/b/ > /dev/null $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/existing.txt"
check_both_reason "54g ln: destination after a redirect denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s > /dev/null $FIX/wt/z.txt $FIX/primary/tw-ln.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/tw-ln.txt"

# 55 — TWIN 2: `-T`/`--no-target-directory` changes DESTINATION semantics for
# `mv` ONLY. Every expectation here is ground-truthed, not reasoned, at
# `<primary>/dirlink-out -> <worktree>/somedir`:
#     mv        wrote THROUGH into the worktree    -> allow
#     mv -n     wrote THROUGH (that -n is --no-clobber, NOT --no-dereference)
#     mv -T     ENTRY REPLACED inside the primary  -> deny
#     mv -fT    ENTRY REPLACED (bundled)           -> deny
#     cp -T     rc=1, NOTHING written              -> allow
# 55d is the control that stops a cp `-T` deny being added "to match" mv:
# there is no write to fence, so a deny there is a pure false positive.
check_both_reason "55a mv -T src |primary|/dirlink-out denies — destination is the ENTRY" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -T $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both_reason "55b mv --no-target-directory src |primary|/dirlink-out denies (long form)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv --no-target-directory $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both_reason "55c mv -fT src |primary|/dirlink-out denies (BUNDLED short flags)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -fT $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both "55d CONTROL: mv src |primary|/dirlink-out (no -T) ALLOWS — writes THROUGH into the worktree" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
check_both "55e CONTROL: mv -n (that is --no-clobber, NOT --no-dereference) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -n $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
check_both "55f CONTROL: cp -T ALLOWS — real cp REFUSES this shape (rc=1) and writes nothing" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -T $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
check_both "55g CONTROL: cp -rT (bundled) ALLOWS for the same reason" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -rT $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
check_both "55h CONTROL: cp src |primary|/dirlink-out (no -T) ALLOWS — writes through" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
# 55i: bundled flags on the OTHER verbs must still parse as flags, not
# operands — `rm -rf` is the everyday shape.
check_both_reason "55i rm -rf |primary|/somedir denies (bundled flags are flags, not operands)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf $FIX/primary/somedir\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/somedir"
# 55j: a bundled `-t` was NOT recognised before the shared option splitter, so
# `cp -rt <primary>/dir src` lost its target-directory entirely. Incidental
# win from generalising bundle expansion beyond ln — pinned so it cannot
# regress. (`ln -sft` is the same shape, covered by 53d.)
check_both_reason "55j cp -rt |primary|/somedir src denies (BUNDLED -t, previously missed)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -rt $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/somedir"
check_both "55k CONTROL: cp -rt |wt|/realsub src still allows (bundled -t into a worktree dir)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -rt $FIX/wt/realsub $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 CR round 3 — destination resolution is verb AND type dependent =="

# 56 (round-3 codex-2): rename(2) does NOT follow a symlink destination, so
# `mv src <primary>/link-to-file` REPLACES the entry inside the primary.
# `cp` onto the same destination writes THROUGH into the referent. Both
# ground-truthed by running the real commands; 56b is the discriminating
# control, because a fix that treats the two verbs alike is wrong in one
# direction or the other.
check_both_reason "56a mv src |primary|/link-to-wt.txt denies — rename REPLACES the link entry" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/link-to-wt.txt"
check_both "56b DISCRIMINATING CONTROL: cp src |primary|/link-to-wt.txt ALLOWS — cp writes THROUGH into the worktree" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}"
# 56c is the DENY REMOVAL this rule implies, argued and ground-truthed: the
# same shape pointed the other way. `mv src <wt>/link-to-primary.txt`
# replaces a WORKTREE-LOCAL entry and leaves the primary file untouched, so
# the old FOLLOW deny was protecting nothing. 56a is its mirror.
check_both "56c ARGUED REMOVAL: mv src |wt|/link-to-primary.txt ALLOWS — the entry is worktree-local [mirror: 56a]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "56d CONTROL: cp src |wt|/link-to-primary.txt still DENIES — cp writes THROUGH into the primary" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"
check_both_reason "56e CONTROL: mv src |primary|/newfile.txt (plain, non-existent dest) still denies" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/primary/newfile.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/newfile.txt"
check_both_reason "56f CONTROL: mv src |primary|/ (destination IS a directory) still denies via FOLLOW" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/primary/\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"

# 57 (round-3 codex-3, plus its mv twin): creating a CHILD inside a
# destination DIRECTORY REPLACES that child entry for `ln` and `mv`, but
# writes THROUGH it for `cp`. Ground truth, at
# `<wt>/childdir/z.txt -> <primary>/a.txt`:
#     ln -sf src <wt>/childdir   child ENTRY replaced, primary untouched
#     mv     src <wt>/childdir/  child ENTRY replaced, primary untouched
#     cp     src <wt>/childdir/  wrote THROUGH into the PRIMARY
# 57c is what keeps the fix from over-applying: the DIRECTORY itself is still
# resolved with FOLLOW, which is what catches a dirlink pointing into the
# primary (round-1 codex-2).
check_both "57a ln -sf src |wt|/childdir ALLOWS — ln replaces the worktree-local child ENTRY (codex-3)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sf $FIX/wt/z.txt $FIX/wt/childdir\",\"cwd\":\"$FIX/wt\"}}"
check_both "57b TWIN: mv src |wt|/childdir/ ALLOWS — rename replaces the child ENTRY too" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $FIX/wt/z.txt $FIX/wt/childdir/\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "57c DISCRIMINATING CONTROL: cp src |wt|/childdir/ still DENIES — cp writes THROUGH the child" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/wt/childdir/\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"
check_both_reason "57d CONTROL: the DIRECTORY itself is still FOLLOW — ln -s src |wt|/dirlink denies (round-1 codex-2)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt $FIX/wt/dirlink\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 57e-57g: the same child rule through the `-t` form, which reaches the child
# join in the OTHER branch of the same `if`. Fixing one branch and not its
# twin is the Mode-1 pattern this ticket exists to end, so both are pinned —
# with the cp control that keeps the split honest.
check_both "57e mv -t |wt|/childdir src ALLOWS — child ENTRY (the -t branch of the same rule)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -t $FIX/wt/childdir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "57f ln -t |wt|/childdir src ALLOWS — child ENTRY (the -t branch)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -t $FIX/wt/childdir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "57g DISCRIMINATING CONTROL: cp -t |wt|/childdir src still DENIES — cp writes THROUGH" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/wt/childdir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "its repo is on main/master"

echo "== HIMMEL-2592 round 5 (RETASK R-N1-SED-4b91d7) — long-option ABBREVIATIONS =="

# 58 — GNU getopt_long accepts an unambiguous ABBREVIATION of a long option
# (`--targ` for `--target-directory`), so matching only the full spelling was
# a fail-open: probed end-to-end (real cp/sed run, primary snapshot-diffed)
# in $HOME/.himmel-2592-abbrevfence.sh before this round's fix, every
# row below was a live MISS. These rows are the suite's OWN copy of that
# evidence — the scratch probe dies with the session; these do not. They also
# double as the RED CONTROL: reverting _bwimc_is_long_abbrev to exact-spelling
# matching (or dropping the sed arm's abbreviation check) makes 58a-58f fail
# with "expected block got allow" — verified by hand, not asserted here,
# because the revert is the control, not a shipped code path.
check_both_reason "58a mv --no-target-dir src |primary|/dirlink-out denies (abbrev of --no-target-directory) [twin: 55b]" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv --no-target-dir $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both_reason "58b ln -sf --no-derefer src |primary|/dirlink-out denies (abbrev of --no-dereference) [twin: 53a]" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sf --no-derefer $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/dirlink-out"
check_both_reason "58c cp --target-dir |primary| src denies (abbrev of --target-directory) [twin: 33c]" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --target-dir $FIX/primary $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary"
check_both_reason "58d cp --targ |primary| src denies (shorter abbrev, same prefix rule)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --targ $FIX/primary $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary"
check_both_reason "58e sed -i --follow-sym on wt/link-to-primary.txt denies (abbrev of --follow-symlinks) [twin: 36c]" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --follow-sym 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/wt/link-to-primary.txt"
check_both_reason "58f sed -i --follow on wt/link-to-primary.txt denies (shorter abbrev, same prefix rule)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --follow 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/wt/link-to-primary.txt"
# 58g/58h — NEGATIVE CONTROLS (direction matters, per _bwimc_is_long_abbrev's
# header): an UNRELATED long option on the SAME verb must not be claimed by
# the prefix test. `--no-clobber`'s full name shares only "no-" with
# `--no-target-directory`/`--no-dereference` (diverges at the 4th
# character — "no-C" vs "no-T"/"no-D"), so it must not resolve as either and
# must not change the verdict; `--posix` shares no prefix with
# `--follow-symlinks`/`--in-place` at all.
check_both "58g NEGATIVE CONTROL: mv --no-clobber src |primary|/dirlink-out still ALLOWS — unrelated long option, not --no-target-directory [mirror: 55e]" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv --no-clobber $FIX/wt/z.txt $FIX/primary/dirlink-out\",\"cwd\":\"$FIX/wt\"}}"
check_both "58h NEGATIVE CONTROL: sed -i --posix on wt/link-to-primary.txt still ALLOWS — unrelated long option, not --follow-symlinks" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --posix 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 round 5 critic panel, codex-1 (RETASK R-N1-SED-4b91d7) — \`--\` end-of-options =="

# 60 — THE PANEL FINDING, reproduced end-to-end through the fence and
# ground-truthed against a real snapshot diff of the primary
# ($HOME/.himmel-2592-ddprobe.sh) before this round's fix: after
# `--`, a token that LOOKS like an option is a plain OPERAND. None of the
# option-scanning loops had a `--` concept, so `ln -s -- -n <wt>/dirlink`
# read `-n` as `--no-dereference`, forced the destination to plain-ENTRY
# resolution (the worktree-local symlink itself, not what it points at),
# and skipped the directory check entirely — the real command then created
# an entry named `-n` INSIDE the primary ($FIX/primary/somedir, reached
# through $FIX/wt/dirlink). Every arm that classifies a `-*` token got the
# same fix: sed, cp/mv, rm/touch, ln, and tee's operand collection — `--` is
# consumed (never added as an operand), and every token after it is checked
# like any other operand, never skipped and never silently dropped (a fix
# that only stopped recognising options but ALSO stopped collecting
# operands would trade this fail-open for a different one).
#
# NOT AN AXIS: `--` is a POSITION in the argument list, not a spelling of an
# option, so it does not belong in the matrix's generated spelling axis
# (_matrix_src_verbs/_matrix_srcless_verbs) — multiplying every verb x kind
# x placement x srckind cell by a `--`/no-`--` factor would not add distinct
# GRAMMAR coverage, only more instances of the same already-covered
# resolution rules with one extra consumed token. What is genuinely new is
# a single BOOLEAN per arm (does this arm honour `--` and keep collecting
# operands after it), which the fixed rows below test directly and cheaply.
check_both_reason "60a ln -s -- -n |wt|/dirlink denies (THE FINDING) — -n after -- is the ENTRY NAME, not a flag" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s -- -n $FIX/wt/dirlink\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 60b — the NO-`--` CONTROL, ground-truthed at want=allow: `ln -s -n
# <wt>/dirlink` is the ONE-OPERAND ln form (the documented gap this file
# already declines to model) — `-n` there genuinely IS --no-dereference,
# leaving a single positional operand, so nothing is checked. This is what
# stops the `--` fix from over-applying: 60a and 60b must NOT collapse to
# the same verdict.
check_both "60b CONTROL (no --): ln -s -n |wt|/dirlink still ALLOWS — -n there IS a real flag (one-operand ln form)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s -n $FIX/wt/dirlink\",\"cwd\":\"$FIX/wt\"}}"
# 60c-60f: `--` before ORDINARY (non-flag-shaped) operands must still deny —
# the interaction that a careless fix (stop recognising options, ALSO stop
# collecting operands) would get wrong. Same $FIX/wt/dirlink fixture as
# 60a/b, matching the coordinator probe's ln/cp/mv rows exactly.
check_both_reason "60c ln -s |wt|/z.txt -- |wt|/dirlink/l1 denies (-- then an ordinary child-entry operand)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s $FIX/wt/z.txt -- $FIX/wt/dirlink/l1\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "60d cp -- |wt|/z.txt |wt|/dirlink/c1 denies (-- then ordinary operands, cp writes THROUGH)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -- $FIX/wt/z.txt $FIX/wt/dirlink/c1\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "60e CONTROL (no --): cp |wt|/z.txt |wt|/dirlink/c2 denies the same way" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/wt/dirlink/c2\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "60f mv -- |wt|/z.txt |wt|/dirlink/m1 denies (-- then ordinary operands, mv REPLACES the child entry)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv -- $FIX/wt/z.txt $FIX/wt/dirlink/m1\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 60g-60i: the arms beyond the panel's own enumeration (rm/touch, tee) —
# "look rather than trust the panel's list" applied to the TEST side too.
check_both_reason "60g rm -- |primary|/existing.txt denies (-- then an ordinary rm operand)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -- $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "target token: $FIX/primary/existing.txt"
check_both_reason "60h touch -- |wt|/dirlink/tch1 denies (-- then an ordinary touch operand, FOLLOW mode)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch -- $FIX/wt/dirlink/tch1\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "60i printf x | tee -- |wt|/dirlink/t1 denies (-- inside tee's own operand collection)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf 'x\\\\n' | tee -- $FIX/wt/dirlink/t1\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 60j-60k: sed's own option loop, same `--` mechanism, ordinary operands on
# both sides of the resolution-mode split (36b/36d's shapes, through --).
check_both "60j sed -i -- 's/a/b/' |wt|/link-to-primary.txt ALLOWS (-- then the ordinary worktree-entry shape, 36b)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -- 's/a/b/' $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "60k sed -i -- 's/a/b/' |primary|/link-to-wt.txt denies (-- then the ordinary primary-entry shape, 36d)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -- 's/a/b/' $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/link-to-wt.txt"

echo "== HIMMEL-2592 round 6 panel, codex-1/codex-2 (RETASK R-N1-SED-4b91d7) — redirect sitting where a separated option VALUE is expected =="

# 61 — a SEPARATED option value (`-t DIR`, `--target-directory DIR`, any
# abbreviation of the latter) unconditionally read "the next raw token" as
# its value. The shell strips a redirection BEFORE the real command ever
# runs, so `cp -t > /dev/null <primary>/somedir <wt>/z.txt` is, to cp,
# `cp -t <primary>/somedir <wt>/z.txt` — the fence's old code swallowed `>`
# as the target directory instead, demoted the REAL primary destination to
# an unchecked source, and never checked it. Reproduced end-to-end through
# the fence, `want` derived from a real snapshot diff of the primary
# ($HOME/.himmel-2592-redirprobe.sh) before this round's fix; every
# row below was a live MISS except the two controls. `$FIX/primary/somedir`
# is an existing plain directory fixture (no symlink involved), so the deny
# reason is the resolved -t VALUE itself.
check_both_reason "61a cp -t > /dev/null |primary|/somedir |wt|/z.txt denies (THE FINDING, plain >)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t > /dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61b CONTROL (no redirect): cp -t |primary|/somedir |wt|/z.txt denies the same way" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61c ln -s -t > /dev/null |primary|/somedir |wt|/z.txt denies (same finding, ln)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -s -t > /dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61d cp --target-directory > /dev/null |primary|/somedir |wt|/z.txt denies (long form, same TWANT path)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --target-directory > /dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61e cp -t 2>/dev/null |primary|/somedir |wt|/z.txt denies (fd-numbered >, the accepted digit/operator split)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t 2>/dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both "61f NEGATIVE CONTROL: cp -t |wt| |wt|/z.txt still ALLOWS — -t names a worktree-local directory, nothing touches primary" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/wt $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}"
# 61g-61i: input redirection `<` — measured (not assumed) to be the SAME
# bypass as `>` before adding these: `cp -t < /dev/null DIR src`,
# `cp -t</dev/null DIR src` (attached) and `cp -t 3</dev/null DIR src`
# (fd-numbered) all really copy into DIR (confirmed against real cp; the
# shell strips a `<` redirect before the real command runs exactly like a
# `>` one). `<` never doubles the way `>>` does — `<<`/`<<<` are HEREDOC
# markers, an unrelated construct this file already handles separately and
# explicitly excludes here.
check_both_reason "61g cp -t < /dev/null |primary|/somedir |wt|/z.txt denies (input redirect, spaced)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t < /dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61h cp -t</dev/null |primary|/somedir |wt|/z.txt denies (input redirect, attached)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t</dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "61i cp -t 3</dev/null |primary|/somedir |wt|/z.txt denies (input redirect, fd-numbered)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t 3</dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 61j: the interaction with round 5's prefix matching — an ABBREVIATION of
# --target-directory must resolve past a redirect exactly like the full
# spelling.
check_both_reason "61j cp --targ > /dev/null |primary|/somedir |wt|/z.txt denies (abbreviation + redirect together)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --targ > /dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
# 61k: the interaction with round 5's `--` handling — a redirect resolving
# the TDIR value, with `--` still ending option parsing for what follows.
check_both_reason "61k cp -t > /dev/null |primary|/somedir -- |wt|/z.txt denies (redirect-skip AND -- together)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t > /dev/null $FIX/primary/somedir -- $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"

echo "== HIMMEL-2592 round 8 panel, codex-1/codex-2 (RETASK R-N1-SED-4b91d7) — round 6 fixed one hole and opened two =="

# 62 — round 6's OWN fix (adding `<` to the redirect predicate, and skipping
# a bare digit before a redirect) introduced a FALSE POSITIVE and a NARROWER
# FAIL-OPEN. Both measured end-to-end through the fence, `want` derived from
# a real snapshot diff ($HOME/.himmel-2592-r7probe.sh) before this
# round's fix.
#
# codex-1: an INPUT redirect is a READ, not a write. Adding `<` to
# _bwimc_redirect_op_of made input redirects match the SAME predicate the
# write-target scan uses, so `cat < <primary>/file` — touches nothing — was
# denied. Fixed by splitting "is this a redirect, so an operand walk should
# skip it" (true for input and output alike — unchanged) from "is this
# token's target a WRITE destination" (true only for output forms) via the
# new _bwimc_op_write output of _bwimc_redirect_op_of.
check_both "62a cat < |primary|/existing.txt ALLOWS — an input redirect is a READ" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat < $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "62b CONTROL: cat < |wt|/z.txt still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat < $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "62c wc -l < |primary|/existing.txt ALLOWS — a different command, same read shape" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"wc -l < $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "62d CONTROL: cat |primary|/existing.txt (no redirect) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both_reason "62e REGRESSION GUARD: echo x > |primary|/f still DENIES — an output redirect is still a write" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/f\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/f"

# codex-2: preserve whether a digit was ATTACHED to the redirect operator,
# not merely "is it all digits". `cp -t 2>/dev/null DIR src` (2 GLUED to
# >, no space) genuinely has no "2" operand to cp — the shell strips the
# whole thing. `cp -t 2 > /dev/null src` (a real SPACE before an unrelated
# redirect) has "2" as cp's actual -t value. The two are textually
# identical AFTER tokenizing unless the split itself is tagged
# (_BWIMC_FDSYN, set only when _bwimc_space_before_redirects synthesised
# the split) — round 6 treated every bare digit before a redirect as
# discardable, which fails OPEN when "2" is a symlink into the primary (the
# fixture at $FIX/wt/2, added for this round).
check_both_reason "62f cp -t 2 > /dev/null |wt|/z.txt denies — '2' is a REAL value (space-separated), not an fd artifact" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t 2 > /dev/null $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "62g CONTROL (no redirect): cp -t 2 |wt|/z.txt denies the same way" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t 2 $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"

# The two round-6 rows this fix must NOT regress — carried here as the
# self-contained guard against over-correcting codex-2 back into codex-1's
# shape (a genuinely GLUED fd-digit must still be discarded).
check_both_reason "62h ROUND-6 REGRESSION GUARD: cp -t |primary|/somedir > /dev/null |wt|/z.txt still denies (dir value, then an unrelated redirect)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t $FIX/primary/somedir > /dev/null $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"
check_both_reason "62i ROUND-6 REGRESSION GUARD: cp -t 2>/dev/null |primary|/somedir |wt|/z.txt still denies (genuinely GLUED fd-digit, still discarded)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t 2>/dev/null $FIX/primary/somedir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/somedir"

echo "== HIMMEL-2592 round 9 codex-3 (RETASK R-N1-SED-4b91d7) — sed's ENTRY GATE was a substring match, not a token decision =="

# 63 — live on main (confirmed via `git show main:...`, pre-existing, not
# introduced by this branch): the sed arm's own ENTRY test was
# `sed(\.exe)?[[:space:]]+.*-i`, an UNANCHORED substring search over the
# WHOLE clause — it matched the "-i" inside a PATH
# (`test-ws5-invariants.sh`) and denied a pure read. The arm's own token
# walk already parses -e/-f/--follow-symlinks correctly; only the GATE
# deciding whether to run it was string-shaped instead of token-shaped —
# the same defect class as the --target-directory prefix work and the
# fd-digit split, one layer up. Fixed by widening entry to "is this a sed
# invocation" (same one-word anchor cp/mv/rm/touch/ln use) and moving the
# in-place decision into the SAME token walk (_bwimc_saw_inplace), so a
# read with no in-place indicator checks nothing.
check_both "63a sed -n '1,3p' on the -i-in-the-PATH file ALLOWS (the false positive, fixed)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -n '1,3p' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}"
check_both "63b CONTROL: sed -n '1,3p' on the plain-named file ALLOWS — proves 63a is about the FILENAME, not sed -n" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -n '1,3p' $FIX/primary/run-shell-tests.sh\",\"cwd\":\"$FIX/wt\"}}"
check_both "63c sed -e 's/a/b/' (read, no -i) on the -i-in-the-PATH file ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -e 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}"
# 63d-63j: every real in-place spelling, verified against real GNU sed
# before being asserted here, against the SAME -i-in-the-PATH filename —
# narrowing a deny is the dangerous direction, so each must still DENY.
check_both_reason "63d sed -i on the -i-in-the-PATH file still DENIES (negative control: narrowing pinned both ways)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63e sed -i.bak (attached suffix) still DENIES" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i.bak 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63f sed -ni (bundled short form, an i inside a bundle) still DENIES" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -ni 's/a/b/p' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63g sed -nie (bundled, i then a backup-suffix char) still DENIES — ground-truthed: writes a '...e' backup, not a separate -e" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -nie 's/a/b/p' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63h sed --in-place still DENIES" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed --in-place 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63i sed --in-place=.bak still DENIES" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed --in-place=.bak 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"
check_both_reason "63j sed --in-pl (unambiguous abbreviation of --in-place) still DENIES" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed --in-pl 's/a/b/' $FIX/primary/test-ws5-invariants.sh\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/test-ws5-invariants.sh"

echo "== HIMMEL-2592 round 10 (RETASK R-N1-SED-4b91d7) — round 9 panel: our <> regression + a pre-existing sed bundle gap =="

# 64 — codex-2 (OUR REGRESSION, confirmed via `git show main:...`: main has
# no `<` handling at all in _bwimc_redirect_op_of, so splitting `<>/p/f`
# into `<` + `>/p/f` there leaves the `>/p/f` remainder independently
# recognised and checked — main blocks by accident. THIS branch taught `<`
# to be a recognised, SKIPPED-as-a-read redirect (round 6/8), so the split
# `<` token now greedily claims the very next token as ITS OWN read
# target and never checks it — the real write half swallowed by the read
# half. `cat <>@P@/new.txt` really CREATES the file (ground-truthed) and
# was allowed. Fixed by keeping `<>` (and `N<>`) glued as ONE token — same
# arbiter discipline as the fd-digit gluing — so _bwimc_redirect_op_of sees
# it as its own operator (WRITE) before ever reaching the plain `<` branch.
check_both_reason "64a cat <>|primary|/new-rw.txt denies (THE FINDING — read/write redirect creates the file)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat <>$FIX/primary/new-rw.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/new-rw.txt"
check_both_reason "64b cat 3<>|primary|/new-rwN.txt denies (fd-numbered read/write, ground-truthed against real bash)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat 3<>$FIX/primary/new-rwN.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/new-rwN.txt"
check_both_reason "64c cat <> |primary|/new-rw-spaced.txt denies (space AFTER the <> operator, before its target — ground-truthed, still valid bash)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat <> $FIX/primary/new-rw-spaced.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/new-rw-spaced.txt"
check_both "64d CONTROL: cat < |primary|/existing.txt still ALLOWS — plain input redirect is still a READ (round 7's fix, must stay green)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat < $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "64e NEGATIVE CONTROL: cat <>|wt|/local.txt (worktree-local) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat <>$FIX/wt/local.txt\",\"cwd\":\"$FIX/wt\"}}"

# 65 — codex-1 (PRE-EXISTING on main, confirmed via `git show main:...`:
# main's sed arm has the IDENTICAL `-e?*`/`-f?*` exact-match-only bundle
# handling, verbatim). `sed -i -nes/xxx/yyy/ FILE` bundles `-n` then `-e`
# with its program ATTACHED — the round-9 bundle scan hit `e`/`f` and just
# `break`, never setting _bwimc_saw_ef, so the sole remaining bare token
# (the REAL file) was treated as the IMPLICIT program and never checked
# (ground-truthed: it emptied the primary file). Fixed by setting
# _bwimc_saw_ef when the bundle scan hits `e`/`f`, and — ground-truthed
# against real sed first — consuming a SEPARATE next token too when
# nothing is left attached in the bundle (`-ne 's/x/y/p'`, `-nf
# script.sed`, same as the standalone `-e VALUE`/`-f VALUE` forms).
check_both_reason "65a sed -i -nes/xxx/yyy/ |primary|/existing.txt denies (THE FINDING — attached -e inside a bundle)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -nes/xxx/yyy/ $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"
check_both_reason "65b sed -i -ne s/xxx/yyy/p |primary|/existing.txt denies (SEPARATE -e value after a bundle, ground-truthed)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -ne s/xxx/yyy/p $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"
check_both_reason "65c sed -i -nfscript.sed |primary|/existing.txt denies (attached -f inside a bundle)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -nfscript.sed $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"
check_both_reason "65d sed -i -nf script.sed |primary|/existing.txt denies (SEPARATE -f value after a bundle)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -nf script.sed $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"
check_both_reason "65e CONTROL: sed -i -e s/xxx/yyy/ |primary|/existing.txt still DENIES (standalone -e, must stay green)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i -e s/xxx/yyy/ $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"
check_both_reason "65f CONTROL: sed -i s/xxx/yyy/ |primary|/existing.txt still DENIES (plain -i, no -e/-f, must stay green)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/xxx/yyy/ $FIX/primary/existing.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/existing.txt"

echo "== HIMMEL-2592 round 10 codex-1 (RETASK R-N1-SED-4b91d7) — the <> glue must respect escape/quote state, not the raw previous character =="

# 66 — round 9's own `<>` glue looked at the raw PREVIOUS CHARACTER, so an
# ESCAPED `<` (bash puts a literal `<` in the word) directly before a REAL,
# unescaped `>` got welded into one bogus `\<>...` token that
# _bwimc_redirect_op_of then ignored entirely — the write vanished. Main has
# no `<` handling at all and so never welds anything; it denies this shape
# by NOT being clever. Our own glue made this shape WORSE than main.
# Ground-truthed against real bash + the real hook before asserting: fixed
# by asking the SAME shared quote/escape scanner (_bwimc_scan_step's
# _BWIMC_ACT, via the `prevact` idiom _bwimc_split_clauses already uses for
# its own escaped/quoted `>` question) rather than a second, local escape
# check.
check_both_reason "66a echo x \\<>|primary|/g.txt denies (THE FINDING — escaped < does not glue with the real > after it)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x \\\\<>$FIX/primary/g.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/g.txt"
check_both_reason "66b CONTROL: echo x <>|primary|/h.txt still DENIES — a genuine unescaped <> still glues and writes (round 9's rows must stay green)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x <>$FIX/primary/h.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/h.txt"
check_both_reason "66c CONTROL: echo x > |primary|/i.txt still DENIES — an ordinary output redirect, unrelated to the glue fix" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $FIX/primary/i.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/i.txt"
check_both "66d NEGATIVE CONTROL: echo x \\<>|wt|/local.txt (worktree-local) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x \\\\<>$FIX/wt/local.txt\",\"cwd\":\"$FIX/wt\"}}"
# 66e-66g: the quoted/escaped forms the retask asked to check rather than
# assume. Ground-truthed against real bash first: a QUOTED "<>"/'<>' is
# INERT LITERAL TEXT to the shell — no redirect happens at all (measured: no
# file created; `echo` prints the literal characters). A real, UNESCAPED `<`
# followed by an ESCAPED `\>` is a genuine INPUT redirect whose target
# happens to start with a literal `>` — still a READ (measured: real bash
# reports "No such file or directory" trying to READ that name, never
# creates it). All three are correctly unaffected by this fix — quoted
# characters are already _BWIMC_ACT=0 (excluded from the whole glue/split
# question), and a real `<` followed by an escaped `>` never reaches the
# `<>` branch at all (the escaped `>` has _BWIMC_ACT=0 too).
check_both "66e CONTROL: echo x \"<>\"|primary|/dq.txt ALLOWS — a DOUBLE-quoted <> is inert literal text, not a redirect" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x \\\"<>\\\"$FIX/primary/dq.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "66f CONTROL: echo x '<>'|primary|/sq.txt ALLOWS — a SINGLE-quoted <> is inert literal text, not a redirect" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x '<>'$FIX/primary/sq.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "66g CONTROL: echo x <\\\\>|primary|/escgt.txt ALLOWS — a real < then an escaped > is still a READ (target starts with a literal >)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x <\\\\>$FIX/primary/escgt.txt\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 round 11 codex-1 — the REPEATED-operator glue must respect escape/quote state too =="

# 67 — the sibling of 66, in the same helper, found by the round-11 gate
# panel. Round 10 fixed the `<>` arm to ask `prevact`; the arm right below
# it — the one that keeps a REPEATED operator (`>>`, `<<`) glued as ONE
# operator — was still asking raw `prev`. So an ESCAPED `>` (bash puts a
# literal `>` in the word) directly before a REAL, unescaped `>` matched the
# "same character as the one before it" arm and got welded into the single
# token `\>>|primary|/g.txt`, which _bwimc_redirect_op_of does not recognise
# as a redirect at all — the primary write vanished and was ALLOWED.
#
# Ground-truthed against real bash before asserting (a snapshot diff of the
# primary decided each `want`, never a hand-written expectation): `echo
# \>>|primary|/g.txt` really does create the file. An inactive character is
# not part of an operator, so the active `>` after it must be SPACED OFF,
# not welded on — the same one arbiter (_bwimc_scan_step's _BWIMC_ACT via
# `prevact`), used a third time, not a third escape check.
check_both_reason "67a echo \\>>|primary|/rg.txt denies (THE FINDING — an escaped > does not glue with the real > after it)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\\>>$FIX/primary/rg.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/rg.txt"
check_both_reason "67b echo \\>>>|primary|/ri.txt denies (the escaped > is spaced off, leaving a REAL >> append)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\\>>>$FIX/primary/ri.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/ri.txt"
check_both_reason "67c CONTROL: echo x >>|primary|/rj.txt still DENIES — a genuine >> append still glues as ONE operator" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >>$FIX/primary/rj.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/rj.txt"
check_both_reason "67d CONTROL: echo x 2>|primary|/rk.txt still DENIES — an fd-numbered redirect stays glued to its digit" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x 2>$FIX/primary/rk.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/rk.txt"
check_both "67e NEGATIVE CONTROL: echo \\>>|wt|/rlocal.txt (worktree-local) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\\>>$FIX/wt/rlocal.txt\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-2592 round 12 — ESCAPED WHITESPACE is not a word boundary (the root cause behind rounds 10-12) =="

# 68 — the round-11 gate panel raised one instance (68a); the audit the
# console then asked for found its sibling (68c), which is strictly worse.
# Both are the SAME root cause, and naming it is the point of this block:
# `_bwimc_space_before_redirects` asked the RAW previous character two more
# times, so an ESCAPED space — a literal space INSIDE the word, never a word
# boundary — was read as one.
#
#   68a  echo foo\ 2>|primary|/m.txt   the fd-digit run survived the literal
#                                      space, so `2>` stayed glued to
#                                      `foo\ 2` and the anchored redirect
#                                      matcher never saw the write.
#   68c  echo x\ >|primary|/p.txt      worse: the `[[:space:]]` arm read
#                                      "already spaced" off the raw
#                                      character, so a PLAIN `>` output
#                                      redirect into the primary was ALLOWED
#                                      with no fd digit involved at all.
#
# Both fixed by asking the ONE shared arbiter (_bwimc_scan_step's _BWIMC_ACT)
# a third and fourth time — via `prevact`, and via gating the fd-digit run on
# _BWIMC_ACT — never a new local escape check. Start-of-text keeps asking raw
# `prev`, correctly: that arm is about there being no previous character at
# all, not about whether one was active.
#
# Every `want` below was GROUND-TRUTHED against real bash by snapshot-diffing
# the primary before it was written down here.
check_both_reason "68a echo foo\\ 2>|primary|/m.txt denies (GATE PANEL FINDING — an escaped space does not end the fd-digit run)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo foo\\\\ 2>$FIX/primary/m.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/m.txt"
check_both_reason "68b echo foo\\ 2>>|primary|/n.txt denies (same shape, fd append)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo foo\\\\ 2>>$FIX/primary/n.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/n.txt"
check_both_reason "68c echo x\\ >|primary|/p.txt denies (THE AUDIT FINDING — a PLAIN > after an escaped space, no fd digit)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ >$FIX/primary/p.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/p.txt"
check_both_reason "68d CONTROL: echo foo 2>|primary|/o.txt still DENIES — a REAL space keeps the fd digit glued to its operator" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo foo 2>$FIX/primary/o.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/o.txt"
check_both "68e NEGATIVE CONTROL: echo x\\ >|wt|/plocal.txt (worktree-local) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ >$FIX/wt/plocal.txt\",\"cwd\":\"$FIX/wt\"}}"

# 68f — the CLASS, enumerated, so it has a TEST rather than a probe list
# (console condition 3). This class has now surfaced six times, one instance
# at a time; a per-instance row cannot say when it is closed. Escaped
# whitespace x every redirect operator that can reach the primary x both
# locations, with the expectation taken from the measured grid rather than
# predicted: every write-capable operator must DENY into the primary and
# ALLOW into the worktree, and `<<` is a heredoc OPENER — it never writes
# through this path, so it allows in both locations and is listed to prove
# the fix did not turn it into a false positive.
#
# NOTE: this is a hand-enumerated mini-matrix, deliberately NOT folded into
# the 868-cell generated grammar matrix above. Adding an escape-state
# dimension there multiplies every existing cell, which is a structural
# change to the generator and its own piece of work — filed as the follow-up
# rather than smuggled into this round.
for _ewop in '>' '>>' '2>' '2>>' '<>'; do
    check_both "68f class: echo x\\ ${_ewop}|primary| denies (escaped whitespace, op=${_ewop})" block \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ ${_ewop}$FIX/primary/ew-$$-w.txt\",\"cwd\":\"$FIX/wt\"}}"
    check_both "68f class: echo x\\ ${_ewop}|wt| allows (escaped whitespace, op=${_ewop})" allow \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ ${_ewop}$FIX/wt/ew-$$-w.txt\",\"cwd\":\"$FIX/wt\"}}"
done
check_both "68f class: echo x\\ <<|primary| allows (heredoc OPENER never writes through this path — false-positive guard)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ <<$FIX/primary/ew-heredoc.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "68f class: echo x\\ <<|wt| allows (heredoc opener, worktree twin)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x\\\\ <<$FIX/wt/ew-heredoc.txt\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-4359 (an in-command HOME assignment taints ~ and \$HOME) =="
# The hook expands ~ / $HOME from its OWN HOME ($FIX/home here, outside every
# checkout), so `HOME=<primary>; ls > ~/x` used to resolve the target to
# $FIX/home/x and ALLOW a write into the primary. Every HOME-assignment
# spelling x both ~ and $HOME targets x a resolved and an unresolved cd must
# DENY; the cd forms (`cd ~`, `cd $HOME`, bare `cd`) must leave the cwd
# unresolved. Reads and unrelated absolute writes after the assignment allow.
_r4359() {  # _r4359 <label> <block|allow> <command>
    check_both "4359 $1" "$2" \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
}
_P4359="$FIX/primary"
for _h4359 in "HOME=$_P4359;" "export HOME=$_P4359;" "declare HOME=$_P4359;" \
        "declare -x HOME=$_P4359;" "typeset -x HOME=$_P4359;" "readonly HOME=$_P4359;" \
        "f() { local HOME=$_P4359;" "export \"HOME=$_P4359\";" "export H\\OME=$_P4359;"; do
    _e4359=""; case "$_h4359" in 'f()'*) _e4359="; }; f" ;; esac
    for _cd4359 in "cd $FIX/wt &&" "cd \"\$D\" &&"; do
        # shellcheck disable=SC2088,SC2016  # literal ~ / $HOME: the command text under test
        for _t4359 in '~/x' '$HOME/x' '"${HOME}"/x'; do
            _r4359 "$_cd4359 $_h4359 ls > $_t4359 denies" block "$_cd4359 $_h4359 ls > $_t4359$_e4359"
        done
        _r4359 "$_cd4359 $_h4359 cp a ~/x denies" block "$_cd4359 $_h4359 cp $FIX/wt/a ~/x$_e4359"
        _r4359 "$_cd4359 $_h4359 cd ~ then a relative write denies" block "$_cd4359 $_h4359 cd ~ && ls > x$_e4359"
        _r4359 "$_cd4359 $_h4359 cd \$HOME then a relative write denies" block "$_cd4359 $_h4359 cd \$HOME && touch x$_e4359"
        _r4359 "$_cd4359 $_h4359 bare cd then a relative write denies" block "$_cd4359 $_h4359 cd; rm -f x$_e4359"
    done
done
# Prefix (`HOME=x cmd`) and env forms: the assignment reaches the child shell.
for _cd4359 in "cd $FIX/wt &&" "cd \"\$D\" &&"; do
    # shellcheck disable=SC2088,SC2016  # literal ~ / $HOME: the command text under test
    for _t4359 in '~/x' '$HOME/x'; do
        for _w4359 in "HOME=$_P4359 sh -c" "env HOME=$_P4359 sh -c" "env -i HOME=$_P4359 sh -c" \
                "env -u PATH HOME=$_P4359 PATH=/bin bash -c"; do
            _r4359 "$_cd4359 $_w4359 'ls > $_t4359' denies" block "$_cd4359 $_w4359 'ls > $_t4359'"
        done
        _r4359 "$_cd4359 HOME=$_P4359 ls > $_t4359 (prefix) denies" block "$_cd4359 HOME=$_P4359 ls > $_t4359"
    done
    _r4359 "$_cd4359 env HOME=$_P4359 sh -c 'cd ~ && ls > x' denies" block \
        "$_cd4359 env HOME=$_P4359 sh -c 'cd ~ && ls > x'"
done
# ALLOW controls: the assignment alone, reads of ~, unrelated absolute writes,
# a non-HOME variable, and `$HOME=` text that is no assignment.
_r4359 "HOME=/tmp/h; echo hi allows" allow "HOME=/tmp/h; echo hi"
_r4359 "HOME=/tmp/x cat ~/f allows" allow "HOME=/tmp/x cat ~/f"
_r4359 "export HOME=/tmp/h; ls /tmp > /tmp/out allows" allow "export HOME=/tmp/h; ls /tmp > /tmp/out"
_r4359 "HOME=primary; cat ~/f; ls \$HOME allows" allow "HOME=$_P4359; cat ~/f; ls \$HOME"
_r4359 "HOME=primary; ls > wt/out (absolute worktree) allows" allow "HOME=$_P4359; ls > $FIX/wt/out"
_r4359 "env HOME=primary sh -c 'cat ~/f' > /tmp/out allows" allow "env HOME=$_P4359 sh -c 'cat ~/f' > /tmp/out"
_r4359 "cd wt && export HOME=/tmp/h; ls > /tmp/out allows" allow "cd $FIX/wt && export HOME=/tmp/h; ls > /tmp/out"
_r4359 "MYHOME=primary; ls > ~/x (not HOME) allows" allow "MYHOME=$_P4359; ls > ~/x"
_r4359 "echo \$HOME=1 > ~/x (no assignment) allows" allow "echo \$HOME=1 > ~/x"
_r4359 "no assignment: ls > ~/x allows" allow "ls > ~/x"


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
