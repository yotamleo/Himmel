#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh (HIMMEL-4164 split, so each
# suite stays under its CI per-suite cap): the heredoc / fail-open bypass /
# command-substitution / ANSI-C rows (HIMMEL-2656/2679/3621/3622/4010).
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh;
# the FIXTURE RULE lives in test-block-write-into-main-checkout.sh.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck disable=SC2016  # the fixture commands carry literal $( in single quotes
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"

echo "== HIMMEL-2656/2679/2645: three fail-open bypasses =="

# 69 (HIMMEL-2656): `sed -i --expr=...` — the ABBREVIATED long option matched
# neither the exact-name case nor follow-symlinks/in-place, so `_bwimc_saw_ef`
# stayed 0 and the trailing file operand was mistaken for the sed PROGRAM —
# no file token was ever checked, so the write was allowed outright.
check_both_reason "69a sed -i --expr='s/x/y/' primary/a.txt denies (abbreviated --expression)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --expr='s/x/y/' $FIX/primary/a.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/a.txt"
check_both "69b NEGATIVE CONTROL: sed -i --expr='s/x/y/' |wt|/wtfile.txt still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i --expr='s/x/y/' $FIX/wt/wtfile.txt\",\"cwd\":\"$FIX/wt\"}}"

# 70 (HIMMEL-2679): `cp --remove-destination` unlinks the destination ENTRY
# and creates a fresh regular file in its place — it does not write through a
# symlink referent. The fence's destination resolution only checked the
# resolved referent (worktree-owned, allow); `$FIX/primary/link-to-wt.txt` is
# a symlink ENTRY inside the primary pointing at `$FIX/wt/wtfile.txt`
# (fixture set up above, row "HIMMEL-2592 fixtures").
check_both_reason "70a cp --remove-destination wt/z.txt primary/link-to-wt.txt denies (entry replaced, not the referent)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --remove-destination $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/link-to-wt.txt"
check_both "70b NEGATIVE CONTROL: plain cp (no --remove-destination) onto the same symlink writes THROUGH to the wt referent — still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}"

# 70c (HIMMEL-2679): `-f`/`--force` folds into the SAME entry-mode trigger as
# `--remove-destination` — GNU cp's `-f` falls back to unlinking the
# destination ENTRY when a FOLLOW-mode write to the referent fails on
# permissions (ground-truthed against real coreutils), the same
# entry-replacing effect, just conditional rather than unconditional.
check_both_reason "70c cp --force wt/z.txt primary/link-to-wt.txt denies (entry replaced, not the referent)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp --force $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/link-to-wt.txt"
check_both_reason "70d cp -f wt/z.txt primary/link-to-wt.txt denies (bundled short form of --force)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -f $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/primary/link-to-wt.txt"
check_both "70e NEGATIVE CONTROL: cp -P wt/z.txt primary/link-to-wt.txt (no-dereference) still ALLOWS" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -P $FIX/wt/z.txt $FIX/primary/link-to-wt.txt\",\"cwd\":\"$FIX/wt\"}}"

# 70f/70g (J1285R Critical, regression against THIS PR's own 2679 change):
# `-f`/`--force` does NOT unlink first like `--remove-destination` — GNU cp
# opens the destination and FOLLOWS a symlink referent, falling back to
# unlink-and-recreate only when that open fails on permissions (ground-truthed
# against real GNU coreutils 9.11). Folding `-f` into the SAME entry-only
# check as `--remove-destination` (rows 70c/70d) swapped FOLLOW for ENTRY
# instead of checking both, so a WORKTREE-side symlink whose referent is in
# the PRIMARY (the opposite direction from 70c/70d's primary-side symlink)
# stopped being checked at all: `$FIX/wt/link-to-primary.txt` ->
# `$FIX/primary/existing.txt` (fixture set up above) is exactly this shape.
# These DENY against main's hook (real primary write via the FOLLOWED
# referent) and must keep denying here — regression rows, not new coverage.
check_both_reason "70f cp -f wt/z.txt wt/link-to-primary.txt denies (force follows the referent into the primary)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -f $FIX/wt/z.txt $FIX/wt/link-to-primary.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/wt/link-to-primary.txt"
check_both_reason "70g cp -f -t wt/childdir wt/z.txt denies (force follows the -t child's referent into the primary)" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -f -t $FIX/wt/childdir $FIX/wt/z.txt\",\"cwd\":\"$FIX/wt\"}}" \
    "$FIX/wt/childdir"

# 71 (HIMMEL-2645): a heredoc OPENER that itself ends in a line continuation
# (`cat <<EOF \` then a newline) is not yet a complete command line — bash
# joins the next physical line onto it before the command ends, so a real
# redirect there is still COMMAND text, not heredoc body. The old
# `_bwimc_blank_heredocs` started body-blanking on the very next physical
# line unconditionally, erasing the real `> primary/a.txt` redirect.
HC_CMD=$(printf 'cat <<EOF \\\n> %s/a.txt\nbody\nEOF' "$FIX/primary")
HC_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HC_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "71a cat <<EOF \\ + newline + > primary/a.txt denies (continued opener's redirect is command text)" \
    "$HC_JSON" "$FIX/primary/a.txt"
HC_WT_CMD=$(printf 'cat <<EOF \\\n> %s/z.txt\nbody\nEOF' "$FIX/wt")
HC_WT_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HC_WT_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "71b NEGATIVE CONTROL: same shape into |wt|/z.txt still ALLOWS" allow "$HC_WT_JSON"
HC_BODY_CMD=$(printf "cat <<EOF\nif a > b:\n    pass\nEOF")
HC_BODY_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HC_BODY_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "71c REGRESSION CONTROL: a heredoc body line containing '>' (no continuation) still ALLOWS" allow "$HC_BODY_JSON"

# 71d COVERAGE (HIMMEL-2645 sibling, `<<-EOF` tab-strip opener variant): the
# same opener-ends-in-a-continuation shape as 71a, dashed variant. NOT a RED
# control — this shape already denies against main's (pre-fix) hook too, so
# it doesn't demonstrate a bug this PR fixes; it pins that the fix doesn't
# regress the dashed-opener case either.
HCD_CMD=$(printf 'cat <<-EOF \\\n> %s/a.txt\nbody\n\tEOF' "$FIX/primary")
HCD_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HCD_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "71d COVERAGE: cat <<-EOF \\ + newline + > primary/a.txt denies (tab-strip opener, continued redirect is command text)" \
    "$HCD_JSON" "$FIX/primary/a.txt"

# 71e COVERAGE (HIMMEL-2645 sibling, quoted opener `<<'EOF'` variant): same
# shape, quoted delimiter word. NOT a RED control, same reason as 71d — pins
# that quoting the delimiter doesn't suppress the continuation check.
HCQ_CMD=$(printf "cat <<'EOF' \\\\\n> %s/a.txt\nbody\nEOF" "$FIX/primary")
HCQ_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HCQ_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "71e COVERAGE: cat <<'EOF' \\ + newline + > primary/a.txt denies (quoted opener, continued redirect is command text)" \
    "$HCQ_JSON" "$FIX/primary/a.txt"

# 71f REGRESSION CONTROL (HIMMEL-2645 sibling): a line continuation that
# occurs INSIDE an already-active heredoc BODY (not on the opener line
# itself) must stay body text — it is not a second opener-continuation.
HCI_CMD=$(printf 'cat <<EOF\nline with \\\n> not-a-real-redirect\nEOF')
HCI_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$HCI_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "71f REGRESSION CONTROL: a continuation INSIDE an active heredoc body still ALLOWS (stays body)" allow "$HCI_JSON"

echo "== HIMMEL-3621: a heredoc terminator that is never matched fails CLOSED =="

# 72a (HIMMEL-3621): the heredoc delimiter word itself is split by a line
# continuation (`<<EO\` + newline + `F`), so the real bash delimiter is
# `EOF` split across two physical lines and no single following LINE can
# ever equal it — the terminator is never found. The old walk blanked to
# end-of-input on that guess, hiding the real write below. Fail CLOSED.
UT_CMD=$(printf 'cat <<EO\\\nF\nbody\nEOF\necho hi > %s/pwned.txt' "$FIX/primary")
UT_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$UT_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both_reason "72a heredoc delimiter split by continuation (terminator never matches) denies closed" \
    "$UT_JSON" "terminator was never found"

# 72b/72c (J1285R Minor): an unquoted arithmetic left-shift by a NAME
# (`$((1 << n))`, `(( x = y << z ))`) was misread as a heredoc opener `<<`
# followed by delimiter word `n`/`z` — no line ever equals that "delimiter",
# so it failed closed as unresolved-heredoc, a new false DENY vs main. Fixed
# by excluding `<<` that sits inside an unclosed `((`/`$((` on the same line.
check_both "72b echo \$((1 << n)) ALLOWS (arithmetic shift by a name is not a heredoc opener)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \$((1 << n))\",\"cwd\":\"$FIX/wt\"}}"
check_both "72c (( x = y << z )) ALLOWS (same shift-by-name shape, arithmetic COMMAND form)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"(( x = y << z ))\",\"cwd\":\"$FIX/wt\"}}"

# HIMMEL-3622 (command-substitution body scanning) was pulled from this PR by
# judge ruling J1285O: the extractor it added both left a real fail-open
# (backtick nested inside $(...)) and introduced a new false DENY on the
# fleet's own `git commit -m "$(cat <<'EOF' … EOF)"` / `gh pr create --body`
# idiom whenever the message has an apostrophe, a lone `(` or a `"`. 3622
# goes back to To Do for its own leg; rows 74a-74g below pin that this PR
# does not regress that idiom (ALLOW, ground-truthed against the real
# interpreter in a scratch worktree).

echo "== HIMMEL-2645/2679/3621 regression: the commit/PR-create heredoc idiom must still ALLOW =="

# 74a: `git commit -m "$(cat <<'EOF' ... EOF)"` with an apostrophe in the
# message. This is the fleet's standard commit idiom; must ALLOW.
CHA_CMD="git commit -m \"\$(cat <<'EOF'
fix: don't break things
EOF
)\""
CHA_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$CHA_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "74a REGRESSION CONTROL: commit heredoc message with an apostrophe still ALLOWS" allow "$CHA_JSON"

# 74b: same idiom, a lone `(` in the message.
CHB_CMD="git commit -m \"\$(cat <<'EOF'
fix: (see ticket)
EOF
)\""
CHB_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$CHB_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "74b REGRESSION CONTROL: commit heredoc message with a lone '(' still ALLOWS" allow "$CHB_JSON"

# 74c: same idiom, a `"` in the message.
CHC_CMD="git commit -m \"\$(cat <<'EOF'
fix: says \"hello\"
EOF
)\""
CHC_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$CHC_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "74c REGRESSION CONTROL: commit heredoc message with a double-quote still ALLOWS" allow "$CHC_JSON"

# 74d: `gh pr create --body "$(cat <<'EOF' ... EOF)"` with an apostrophe —
# same idiom, PR-body form. Direct-exec only, same rationale as row 27:
# block-terminal-write-fence.sh has its own separate, pre-existing HIMMEL-745
# policy that hard-blocks ALL `gh pr create` in the codex-direct lane
# regardless of content (external-write class) — unrelated to this hook's
# substitution/heredoc scanning, so sourced mode is out of scope here.
PRB_CMD="gh pr create --body \"\$(cat <<'EOF'
it's done
EOF
)\""
PRB_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$PRB_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_one "74d REGRESSION CONTROL: gh pr create --body heredoc with an apostrophe — direct-exec ALLOWS (not the external-write fence)" \
    "$DIRECT" allow "$PRB_JSON"

# 74e/74f: read-only \$(...)-shaped TEXT in a grep/sed pattern (not a real
# substitution at all — a literal string the command never evaluates) must
# not be misread as an opener.
GDP_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep -n '\$(' f\",\"cwd\":\"$FIX/wt\"}}"
check_both "74e REGRESSION CONTROL: grep -n '\$(' f still ALLOWS" allow "$GDP_JSON"
SDP_CMD="sed -n '/\$(/p' f"
SDP_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$SDP_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "74f REGRESSION CONTROL: sed -n '/\\\$(/p' f still ALLOWS" allow "$SDP_JSON"

# 74g: a backtick inside a single-quoted word — plain literal text, not a
# substitution.
BTQ_LIT_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'don\`t'\",\"cwd\":\"$FIX/wt\"}}"
check_both "74g REGRESSION CONTROL: echo 'don\`t' still ALLOWS" allow "$BTQ_LIT_JSON"

# HIMMEL-3622: a redirect INSIDE a command substitution writes exactly like a
# top-level one. The shared quote scanner marks everything inside a
# double-quoted span inert, so `x="$(echo hi > P/f)"` hid the redirect; the
# fix extracts every substitution body (any nesting, `$(...)` and backticks,
# skipping single-quoted text) and runs the SAME redirect-target check on it.
# DENY rows aim at the primary; ALLOW twins aim the identical shape at the
# worktree so a blanket "deny anything with $(" cannot pass.
echo "== HIMMEL-3622 redirects inside command substitutions =="
_P="$FIX/primary/subst-new.txt"
_W="$FIX/wt/subst-new.txt"
for _t in "P|block|$_P" "W|allow|$_W"; do
    _tag="${_t%%|*}"; _rest="${_t#*|}"; _v="${_rest%%|*}"; _f="${_rest#*|}"
    _subst_row "75a-$_tag assignment of a dq-quoted \$(echo > f)"           "$_v" "x=\"\$(echo hi > $_f)\""
    _subst_row "75b-$_tag echo dq-quoted \$(printf >f) (no space)"          "$_v" "echo \"\$(printf x >$_f)\""
    _subst_row "75c-$_tag unquoted assignment \$(echo > f)"                 "$_v" "x=\$(echo hi > $_f)"
    _subst_row "75d-$_tag backtick in dq span"                              "$_v" "x=\"\`echo hi > $_f\`\""
    _subst_row "75e-$_tag backtick, unquoted"                               "$_v" "x=\`echo hi > $_f\`"
    _subst_row "75f-$_tag backtick nested inside \$( ) (J1285O fail-open)"  "$_v" "x=\"\$(echo \`echo hi > $_f\`)\""
    _subst_row "75g-$_tag \$( \$( ... > f ) ) doubly nested"                "$_v" "x=\"\$(echo \$(echo hi > $_f))\""
    _subst_row "75h-$_tag redirect after a nested \$( ) in the same body"   "$_v" "x=\"\$(echo \$(pwd) > $_f)\""
    _subst_row "75i-$_tag tee inside a dq-quoted \$( )"                     "$_v" "x=\"\$(echo hi | tee $_f)\""
    _subst_row "75o-$_tag case item ) does not end the body (codex-2)"      "$_v" "x=\"\$(case a in a) echo hi > $_f ;; esac)\""
done
# The body runs where its clause runs: a later `cd` must not move it, and a
# `cd` inside a body (its own subshell) must not leak out of it (codex-1).
_subst_row "75n-P body judged at its own cwd, a later cd must not move it" block "cd $_PR; x=\"\$(echo hi > subst-rel.txt)\"; cd $_WR"
_subst_row "75n-W same shape aimed at the worktree (ALLOW)"               allow "cd $_WR; x=\"\$(echo hi > subst-rel.txt)\"; cd $_PR"
_subst_row "75p-P a cd inside a body does not leak to the next clause"    block "cd $_PR; x=\"\$(cd $_WR)\"; echo hi > subst-rel.txt"
_subst_row "75p-W same shape aimed at the worktree (ALLOW)"               allow "cd $_WR; x=\"\$(cd $_PR)\"; echo hi > subst-rel.txt"
_subst_row "75q-P a cd in an outer body reaches the nested body"          block "x=\"\$(cd $_PR; echo \"\$(echo hi > subst-rel.txt)\")\""
_subst_row "75q-W same shape aimed at the worktree (ALLOW)"               allow "x=\"\$(cd $_WR; echo \"\$(echo hi > subst-rel.txt)\")\""
# A body expands BEFORE its own clause runs: judged at the cwd the clause
# starts in, not the one its own cd leaves (panel round 2, codex-1).
_subst_row "75r-P body in a cd clause runs at the pre-cd cwd (primary)"      block "cd $_WR 2>\"\$(echo hi > subst-rel.txt)\"" "$_PR"
_subst_row "75r-W same shape, pre-cd cwd is the worktree (ALLOW)"           allow "cd $_PR 2>\"\$(echo hi > subst-rel.txt)\"" "$_WR"
# A quoted `)` inside a quoted nested substitution must not end the outer body
# (panel round 3, codex-1): the body has a quote state of its own.
_subst_row "75s-P quoted paren in a nested quoted body keeps the outer body open" block "x=\"\$(cd $_PR; echo \"\$(echo \")\" > subst-rel.txt)\")\""
_subst_row "75s-W same shape aimed at the worktree (ALLOW)"                allow "x=\"\$(cd $_WR; echo \"\$(echo \")\" > subst-rel.txt)\")\""
_subst_row "75t-P backtick with a quoted paren inside a quoted body"       block "x=\"\$(cd $_PR; echo \`echo \")\"\` > subst-rel.txt)\""
_subst_row "75t-W same shape aimed at the worktree (ALLOW)"                allow "x=\"\$(cd $_WR; echo \`echo \")\"\` > subst-rel.txt)\""
_subst_row "75u-P backtick body holds an escaped \$( that Bash unescapes"  block "x=\`echo \"\\\$(echo hi > $_PR/subst-rel.txt)\"\`"
_subst_row "75u-W same shape aimed at the worktree (ALLOW)"                allow "x=\`echo \"\\\$(echo hi > $_WR/subst-rel.txt)\"\`"
_SOH=$'\001'
_subst_row "75v-P a literal U+0001 byte must not consume a body"           block "echo $_SOH; cd $_PR; x=\"\$(echo hi > subst-rel.txt)\""
# HIMMEL-4010: a raw marker byte now fails closed anywhere (row 76zz)
_subst_row "75v-W same shape aimed at the worktree (DENY: marker byte)"    block "echo $_SOH; cd $_WR; x=\"\$(echo hi > subst-rel.txt)\""
# A `)` inside a ${...} expansion is text, not the body's closer.
_subst_row "75w-P \${y:-)} must not close the body early"                   block "x=\"\$(echo \${y:-)} > $_PR/f.txt)\""
_subst_row "75x-P \${y#)} must not close the body early"                    block "x=\"\$(echo \${y#)} > $_PR/f.txt)\""
_subst_row "75y-P \${y%)} must not close the body early"                    block "x=\"\$(echo \${y%)} > $_PR/f.txt)\""
_subst_row "75w-W \${y:-)} aimed at the worktree (ALLOW)"                   allow "x=\"\$(echo \${y:-)} > $_WR/f.txt)\""
# The heredoc idiom with target-shaped words in the body text stays ALLOW.
_subst_row "75j commit heredoc idiom, message mentions '> file' and a paren (ALLOW)" allow "git commit -m \"\$(cat <<'EOF'
fix: a > b (and 'it')
EOF
)\""
_subst_row "75k single-quoted \$(echo > P) is literal text (ALLOW)" allow "echo '\$(echo hi > $_P)'"
_subst_row "75l read redirect inside a substitution (ALLOW)" allow "x=\"\$(cat < $FIX/primary/existing.txt)\""
_subst_row "75m fd-dup inside a substitution (ALLOW)" allow "x=\"\$(ls 2>&1)\""

# HIMMEL-4010: three residual gaps in the same substitution scan.
# (1) An ANSI-C `$'…'` span ends only at an UNESCAPED `'`; the plain
#     single-quote rule ended it at `\'` and flipped every later quote.
# (2) A target computed from a substitution: `$(pwd)` is the cwd, any other
#     substitution's static prefix names the directory written into.
# (3) The verb arms (cp/mv/sed -i/tee/rm/touch, git) now see substitution
#     bodies, at the cwd the body runs in.
# DENY rows aim at the primary; each ALLOW twin aims the same shape at the
# worktree, and the read controls must keep allowing.
echo "== HIMMEL-4010 ANSI-C quotes, computed targets, verbs in substitution bodies =="
for _t in "P|block|$_P|$_PR" "W|allow|$_W|$_WR"; do
    _tag="${_t%%|*}"; _rest="${_t#*|}"; _v="${_rest%%|*}"; _rest="${_rest#*|}"; _f="${_rest%%|*}"; _d="${_rest#*|}"
    _subst_row "76a-$_tag \$'\\'' before a redirect (ANSI-C escaped quote)"   "$_v" "echo \$'\\'' > $_f"
    _subst_row "76b-$_tag \$'\\'' inside a dq-quoted body"                    "$_v" "x=\"\$(echo \$'\\'' > $_f)\""
    _subst_row "76c-$_tag \$'a\\'b' mid-word"                                 "$_v" "echo \$'a\\'b' > $_f"
    _subst_row "76d-$_tag ANSI-C quoted target"                               "$_v" "echo x > \$'$_f'"
    _subst_row "76e-$_tag \$(pwd)/ target"                                    "$_v" "echo x > \"\$(pwd)/subst-new.txt\"" "$_d"
    _subst_row "76f-$_tag backtick pwd target"                                "$_v" "echo x > \`pwd\`/subst-new.txt" "$_d"
    _subst_row "76g-$_tag relative name with a \$(date) suffix"               "$_v" "echo x > f\$(date +%s)" "$_d"
    _subst_row "76h-$_tag absolute path with a \$(date) suffix"               "$_v" "echo x > $_f\$(date +%s)"
    _subst_row "76i-$_tag cp to a \$(pwd)/ destination"                       "$_v" "cp $FIX/wt/a.txt \"\$(pwd)/subst-new.txt\"" "$_d"
    _subst_row "76j-$_tag cp in a dq-quoted body"                             "$_v" "x=\"\$(cp $FIX/wt/a.txt $_f)\""
    _subst_row "76k-$_tag mv in a dq-quoted body"                             "$_v" "x=\"\$(mv $FIX/wt/a.txt $_f)\""
    _subst_row "76l-$_tag sed -i in a dq-quoted body"                         "$_v" "x=\"\$(sed -i s/a/b/ $_f)\""
    _subst_row "76m-$_tag tee in a dq-quoted body"                            "$_v" "x=\"\$(tee $_f)\""
    _subst_row "76n-$_tag cp in a backtick body"                              "$_v" "x=\`cp $FIX/wt/a.txt $_f\`"
    _subst_row "76o-$_tag touch in a backtick inside dq"                      "$_v" "echo \"\`touch $_f\`\""
    _subst_row "76p-$_tag rm in a dq-quoted body"                             "$_v" "x=\"\$(rm $_f)\""
    _subst_row "76q-$_tag cd then cp in a body, relative destination"         "$_v" "x=\"\$(cd $_d; cp $FIX/wt/a.txt subst-new.txt)\""
    _subst_row "76r-$_tag git checkout -b in a dq-quoted body"                "$_v" "x=\"\$(git -C $_d checkout -b subst-zz)\""
done
# A cd inside a body stays inside it (its own subshell).
_subst_row "76s-P a body's cd does not leak to the next verb clause"       block "cd $_PR; x=\"\$(cd $_WR)\"; cp a.txt subst-new.txt"
_subst_row "76s-W same shape aimed at the worktree (ALLOW)"               allow "cd $_WR; x=\"\$(cd $_PR)\"; cp a.txt subst-new.txt"
# Read controls: none of these write the primary.
_subst_row "76t ANSI-C quote that closes cleanly, no redirect (ALLOW)"     allow "echo \$'it\\'s > fine'"
_subst_row "76u literal \$'x' inside double quotes (ALLOW)"                allow "echo \"\$'x'\" > $_W"
_subst_row "76v x=\$(cat f) (ALLOW)"                                       allow "x=\$(cat f)" "$_PR"
_subst_row "76w echo \"\$(date)\" > /tmp/x (ALLOW)"                         allow "echo \"\$(date)\" > /tmp/x" "$_PR"
_subst_row "76x ls \$(pwd) in the primary (ALLOW)"                         allow "ls \$(pwd)" "$_PR"
_subst_row "76y cp out of the primary in a body (ALLOW)"                   allow "x=\"\$(cp $_PR/f.txt $_W)\""
_subst_row "76z sed -n in a body (ALLOW)"                                  allow "x=\"\$(sed -n p $_PR/f.txt)\""
_subst_row "76za \$(mktemp) target from the primary (ALLOW)"               allow "echo x > \"\$(mktemp)\"" "$_PR"
_subst_row "76zb \$(date) suffix under /tmp from the primary (ALLOW)"      allow "echo x > /tmp/x\$(date +%s)" "$_PR"
_subst_row "76zc \$(pwd) prefix of a sibling name (ALLOW)"                 allow "echo x > \"\$(pwd)n\"" "$_PR"
_subst_row "76zd git rev-parse in a body, output to /tmp (ALLOW)"          allow "echo \"\$(git -C $_PR rev-parse HEAD)\" > /tmp/h"
_subst_row "76ze \$((1+2)) arithmetic is not a body (ALLOW)"                allow "echo \$((1+2)) > $_W"
_subst_row "76zf \$'…' inside double quotes is a literal name (ALLOW)"     allow "echo x > \"\$'$_P'\""
_subst_row "76zg \$'…' inside single quotes is a literal name (ALLOW)"     allow "echo x > '\$'\"'$_P'\""
_subst_row "76zh quoted \$(pwd) continued into a sibling name (ALLOW)"     allow "echo x > \"\$(pwd)\"n/f" "$_PR"
_subst_row "76zi quoted \$(pwd) then /n (DENY)"                            block "echo x > \"\$(pwd)\"/n" "$_PR"
_subst_row "76zj quoted \`pwd\` at the token end then /n (DENY)"            block "cd $_PR; echo x > \"\`pwd\`\"/n"
_subst_row "76zk \$'…' target with a literal \$ in its name (DENY)"        block "echo x > \$'$_PR/\$HOME-x'"
_subst_row "76zl \$'…' target with a literal * in its name (DENY)"         block "echo x > \$'$_PR/a*b'"
_subst_row "76zm same literal \$ name in the worktree (ALLOW)"              allow "echo x > \$'$_WR/\$HOME-x'"
_subst_row "76zn \$'…' decoded quote makes a sibling name (ALLOW)"         allow "echo x > \$'$_PR\\x22/f'"
ln -s "$_PR" "$_WR/sl\$x"
_subst_row "76zo \$'…' through a worktree symlink named sl\$x (DENY)"     block "echo x > \$'$_WR/sl\$x/n'"
_subst_row "76zp same name, not a symlink: sl_x is absent (ALLOW)"         allow "echo x > \$'$_WR/sl_x/n'"
_subst_row "76zq non-leading \$(pwd) is not the cwd (ALLOW)"               allow "echo x > /tmp/x\$(pwd)/f" "$_PR"
_subst_row "76zr non-leading \$(pwd) under the primary (DENY)"             block "echo x > $_PR/x\$(pwd)/f"
_subst_row "76zs \$(pwd)\"/n\" quote after the slash (DENY)"                block "echo x > \$(pwd)\"/n\"" "$_PR"
ln -s "$_PR" "$_WR/sl"$'\016'
_subst_row "76zu decoded \\x0e is a byte, not a sentinel (DENY)"            block "echo x > \$'$_WR/sl\\x0e/n'"
_subst_row "76zv raw 0x0e byte in a plain target (DENY)"                     block "echo x > $_WR/sl"$'\016'"/n"
ln -s "$_PR" "$_WR/x."
_subst_row "76zt non-leading \$(pwd) never reads as x./ (ALLOW)"           allow "echo x > $_WR/x\$(pwd)/f"
_subst_row "76zw \$\$ is the PID, so \$\$'\\' is a plain quote (DENY)"       block "echo \$\$'\\' > $_PR/f # '"
_subst_row "76zx \$\$\$'…' is PID then ANSI-C (DENY)"                       block "echo \$\$\$'\\'' > $_PR/f"
_subst_row "76zy \$\$'b' in a worktree target (ALLOW)"                       allow "echo x > $_WR/a\$\$'b'"
# raw marker bytes: a decoy `sl_` is what the old byte-to-_ rename resolved to
mkdir -p "$_WR/sl_"
for _b in 001 002 003 004 005 016; do ln -s "$_PR" "$_WR/sl$(printf '%b' "\\0$_b")"; done
_subst_row "76zz raw 0x01 behind a \$(…) redirect (DENY)"   block "echo \$(true) > $_WR/sl"$'\001'"/n"
_subst_row "76zza raw 0x02 in a target (DENY)"              block "echo x > $_WR/sl"$'\002'"/n"
_subst_row "76zzb raw 0x03 in a verb target (DENY)"         block "touch $_WR/sl"$'\003'"/n"
_subst_row "76zzc raw 0x04 in a target (DENY)"              block "echo x > $_WR/sl"$'\004'"/n"
_subst_row "76zzd raw 0x05 behind a \$(…) redirect (DENY)"  block "echo \$(true) > $_WR/sl"$'\005'"/n"
_subst_row "76zze raw 0x0e in a verb target (DENY)"         block "touch $_WR/sl"$'\016'"/n"
_subst_row "76zzf decoy sl_ itself stays a worktree path (ALLOW)" allow "touch $_WR/sl_/n"

echo "== HIMMEL-4397: a large heredoc commit message stays linear =="
# A 10 KB `git commit -m "$(cat <<'EOF' …)"` took ~10 s idle (12-13 s under
# load in J1672c) because every raw reading char-scanned the whole body; the
# member timeout is 15 s. Budget = measured loaded figure x2 (~1 s idle, 3 s
# loaded), never an idle one. Each shape: verdict ALLOW (worktree cwd) in both
# lanes, direct-exec inside the budget.
_big=$(head -c 10000 /dev/zero | tr '\0' x | fold -w 78)
_perf_row() { # label first-body-line opener
    local cmd j t0 t1 got
    cmd=$(printf 'git commit -m "$(cat %s\n%s\n\n%s\nEOF\n)"' "$3" "$2" "$_big")
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | jq -Rs .),\"cwd\":\"$_WR\"}}"
    t0=${EPOCHREALTIME/[.,]/}
    got=$(_run "$DIRECT" "$j")
    t1=${EPOCHREALTIME/[.,]/}
    if [ "$got" = allow ] && [ $(( (t1 - t0) / 1000 )) -lt 6000 ]; then ok "$1 (direct-exec, $(( (t1 - t0) / 1000 )) ms)"
    else bad "$1 (direct-exec) — expected allow under 6000 ms, got $got in $(( (t1 - t0) / 1000 )) ms"; fi
    got=$(_run "$FENCE" "$j")
    if [ "$got" = allow ]; then ok "$1 (sourced/codex)"; else bad "$1 (sourced/codex) — expected allow got $got"; fi
}
_perf_row "4397a 10 KB message, quoted 'EOF' opener (ALLOW, linear)"   "fix: msg"      "<<'EOF'"
_perf_row "4397b 10 KB message, backslash \\EOF opener (ALLOW, linear)" "fix: msg"      '<<\EOF'
_perf_row "4397c 10 KB message with a \$' on its first line (ALLOW, linear)" "fix: msg \$'a" "<<'EOF'"
# The drop of the raw readings must not hide a write: an unquoted delimiter
# expands $(…) in its body, a write after the substitution is still command
# text, and a primary-aimed redirect inside an unquoted body's $(…) denies.
_subst_row "4397d unquoted EOF body \$(touch primary file) inside the message (DENY)" block \
    "$(printf 'git commit -m "$(cat <<EOF\n$(touch %s/a.txt)\nEOF\n)"' "$_PR")"
_subst_row "4397e quoted 'EOF' message, then a write into the primary (DENY)" block \
    "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: msg\nEOF\n)" && echo x > %s/a.txt' "$_PR")"
_subst_row "4397f quoted 'EOF' message, then a write into the worktree (ALLOW)" allow \
    "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: msg\nEOF\n)" && echo x > %s/z.txt' "$_WR")"
_subst_row "4397g backslash \\EOF message, then a write into the primary (DENY)" block \
    "$(printf 'git commit -m "$(cat <<\\EOF\nfix: msg\nEOF\n)" && echo x > %s/a.txt' "$_PR")"
# Only a `git commit -m` message body is inert. A quoted heredoc fed to
# bash -c / eval is CODE, so the flat reading must keep scanning it.
_subst_row "4397h bash -c quoted-heredoc body writes into the primary (DENY)" block \
    "$(printf 'bash -c "$(cat <<'"'"'EOF'"'"'\ntouch %s/a.txt\nEOF\n)"' "$_PR")"
_subst_row "4397i eval quoted-heredoc body writes into the primary (DENY)" block \
    "$(printf 'eval "$(cat <<'"'"'EOF'"'"'\ntouch %s/a.txt\nEOF\n)"' "$_PR")"
# J2249a: a `<<` whose delimiter the opener regex cannot parse (dash, dot,
# digit-led) is never counted, so its body is scanned as code; a lone quote in
# that body must not let the fast path swallow a later real redirect.
_gm=$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: msg\nEOF\n)"')
_subst_row "4397j dashed 'E-X' heredoc with a lone quote, then a primary write (DENY)" block \
    "$(printf '%s\ncat <<'"'"'E-X'"'"'\nit'"'"'s\nE-X\necho x > %s/a.txt' "$_gm" "$_PR")"
_subst_row "4397k dotted \"a.b\" heredoc with a lone quote, then a primary write (DENY)" block \
    "$(printf '%s\ncat <<"a.b"\nsay "hi\na.b\necho x > %s/a.txt' "$_gm" "$_PR")"
_subst_row "4397l digit-led '1Z' heredoc after && with a lone quote, then a primary write (DENY)" block \
    "$(printf '%s && cat <<'"'"'1Z'"'"'\nit'"'"'s\n1Z\necho x > %s/a.txt' "$_gm" "$_PR")"
_subst_row "4397m CONTROL: dashed heredoc with a lone quote, then a worktree write (ALLOW)" allow \
    "$(printf '%s\ncat <<'"'"'E-X'"'"'\nit'"'"'s\nE-X\necho x > %s/z.txt' "$_gm" "$_WR")"
_subst_row "4397n CONTROL: dashed heredoc, no git commit, primary write (DENY)" block \
    "$(printf 'cat <<'"'"'E-X'"'"'\nit'"'"'s\nE-X\necho x > %s/a.txt' "$_PR")"
# J2249b: a SECOND `<<` on the physical line of a recognised opener is not
# counted (one terminator is tracked per line), so its body is scanned as code.
_subst_row "4397o git-commit opener first, second '<<Y' on the same line with a lone quote, then a primary write (DENY)" block \
    "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"' <<'"'"'Y'"'"'\nfix: msg\nEOF\nit'"'"'s\nY\n)"\necho x > %s/a.txt' "$_PR")"
_subst_row "4397p second opener after a plain one on the same line, git-commit opener last, lone quote, primary write (DENY)" block \
    "$(printf 'cat <<'"'"'Y'"'"' ; git commit -m "$(cat <<'"'"'EOF'"'"'\nit'"'"'s\nY\nfix: msg\nEOF\n)"\necho x > %s/a.txt' "$_PR")"
_subst_row "4397q CONTROL: same-line second opener, lone quote, worktree write (ALLOW)" allow \
    "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"' <<'"'"'Y'"'"'\nfix: msg\nEOF\nit'"'"'s\nY\n)"\necho x > %s/z.txt' "$_WR")"
_subst_row "4397r git-commit opener first, same-line second opener, lone quote closed after a primary write (DENY)" block \
    "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"' <<'"'"'Y'"'"'\nfix: msg\nEOF\nit'"'"'s\nY\n)"\necho x > %s/a.txt\necho it'"'"'s' "$_PR")"
_subst_row "4397s plain opener then git-commit opener on one line, lone quote closed after a primary write (DENY)" block \
    "$(printf 'cat <<'"'"'Y'"'"' ; git commit -m "$(cat <<'"'"'EOF'"'"'\nit'"'"'s\nY\nfix: msg\nEOF\n)"\necho x > %s/a.txt\necho it'"'"'s' "$_PR")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
