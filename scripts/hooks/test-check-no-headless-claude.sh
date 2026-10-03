#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-no-headless-claude.sh.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-no-headless-claude.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/hooks" "$TMP/docs" "$TMP/handovers" "$TMP/.agents" "$TMP/.claude/commands"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

run_hook() {
    (cd "$TMP" && bash "$HOOK" "$@" >/dev/null 2>&1)
    echo "$?"
}

FAILED=0

# T1: script with claude -p → BLOCK
cat > "$TMP/run.sh" <<'EOF'
#!/usr/bin/env bash
claude -p "summarize this"
EOF
rc=$(run_hook "run.sh")
assert_rc "T1 claude -p in script" 1 "$rc"

# T2: script with claude --print → BLOCK
cat > "$TMP/print.sh" <<'EOF'
#!/usr/bin/env bash
claude --print "summarize this"
EOF
rc=$(run_hook "print.sh")
assert_rc "T2 claude --print" 1 "$rc"

# T3: script with claude --bg → BLOCK
cat > "$TMP/bg.sh" <<'EOF'
#!/usr/bin/env bash
claude --bg "summarize this"
EOF
rc=$(run_hook "bg.sh")
assert_rc "T3 claude --bg" 1 "$rc"

# T4: interactive `claude "$prompt"` (no flag) → CLEAN
cat > "$TMP/interactive.sh" <<'EOF'
#!/usr/bin/env bash
claude "$prompt"
EOF
rc=$(run_hook "interactive.sh")
assert_rc "T4 interactive claude" 0 "$rc"

# T5: same-line opt-in marker → CLEAN
cat > "$TMP/optin_inline.sh" <<'EOF'
#!/usr/bin/env bash
claude -p "$prompt"  # headless-claude-ok: agent-sdk billing intentional
EOF
rc=$(run_hook "optin_inline.sh")
assert_rc "T5 same-line opt-in" 0 "$rc"

# T6: preceding-line opt-in marker → CLEAN
cat > "$TMP/optin_above.sh" <<'EOF'
#!/usr/bin/env bash
# headless-claude-ok: scripted batch job, separate bucket accepted
claude --print "$prompt"
EOF
rc=$(run_hook "optin_above.sh")
assert_rc "T6 preceding-line opt-in" 0 "$rc"

# T7: opt-in 2 lines above (TOO FAR) → BLOCK
cat > "$TMP/optin_far.sh" <<'EOF'
#!/usr/bin/env bash
# headless-claude-ok: scripted batch job
# unrelated comment
claude --print "$prompt"
EOF
rc=$(run_hook "optin_far.sh")
assert_rc "T7 opt-in 2 lines above does NOT cover" 1 "$rc"

# T8: docs/ exempt → CLEAN
cat > "$TMP/docs/billing.md" <<'EOF'
Avoid `claude -p` in scripts unless you've accepted the post-2026-06-15 billing split.
EOF
rc=$(run_hook "docs/billing.md")
assert_rc "T8 docs/ exempt" 0 "$rc"

# T9: handovers/ exempt → CLEAN
cat > "$TMP/handovers/note.md" <<'EOF'
TODO: audit `claude --print` call sites before 2026-06-15.
EOF
rc=$(run_hook "handovers/note.md")
assert_rc "T9 handovers/ exempt" 0 "$rc"

# T10: .agents/ exempt (vendored) → CLEAN
cat > "$TMP/.agents/compress.py" <<'EOF'
subprocess.run(["claude", "--print"], input=prompt)
EOF
rc=$(run_hook ".agents/compress.py")
assert_rc "T10 .agents/ exempt" 0 "$rc"

# T11: .claude/commands/*.md exempt → CLEAN
cat > "$TMP/.claude/commands/oz-offload.md" <<'EOF'
Offload target is `warp agent run`, NOT `claude -p`. `claude -p` is not in normal usage.
EOF
rc=$(run_hook ".claude/commands/oz-offload.md")
assert_rc "T11 .claude/commands/*.md exempt" 0 "$rc"

# T12: CLAUDE.md exempt → CLEAN
cat > "$TMP/CLAUDE.md" <<'EOF'
Headless mode (`claude -p`) bills on the Agent SDK bucket from 2026-06-15.
EOF
rc=$(run_hook "CLAUDE.md")
assert_rc "T12 CLAUDE.md exempt" 0 "$rc"

# T12b: root CHANGELOG.md exempt (generated from commit subjects) → CLEAN
cat > "$TMP/CHANGELOG.md" <<'EOF'
- [HIMMEL-2178] claude -p headless dispatch wrapper + file-per-session registry (#1990)
EOF
rc=$(run_hook "CHANGELOG.md")
assert_rc "T12b root CHANGELOG.md exempt" 0 "$rc"

# T12c: nested CHANGELOG.md NOT exempt (path-anchored, not basename) → BLOCK
mkdir -p "$TMP/some/dir"
cat > "$TMP/some/dir/CHANGELOG.md" <<'EOF'
- [HIMMEL-2178] claude -p headless dispatch wrapper + file-per-session registry (#1990)
EOF
rc=$(run_hook "some/dir/CHANGELOG.md")
assert_rc "T12c nested CHANGELOG.md still flagged" 1 "$rc"

# T13: self-exempt hook + test → CLEAN
cat > "$TMP/scripts/hooks/check-no-headless-claude.sh" <<'EOF'
PATTERN='claude -p'
EOF
rc=$(run_hook "scripts/hooks/check-no-headless-claude.sh")
assert_rc "T13 self-exempt hook" 0 "$rc"

cat > "$TMP/scripts/hooks/test-check-no-headless-claude.sh" <<'EOF'
echo "claude -p test"
EOF
rc=$(run_hook "scripts/hooks/test-check-no-headless-claude.sh")
assert_rc "T13b self-exempt test" 0 "$rc"

# T14: ATTACKER PATH — basename matches exempt but path doesn't → BLOCK
mkdir -p "$TMP/vendor/evil"
cat > "$TMP/vendor/evil/check-no-headless-claude.sh" <<'EOF'
claude --print "$prompt"
EOF
rc=$(run_hook "vendor/evil/check-no-headless-claude.sh")
assert_rc "T14 attacker basename wrong path BLOCKS" 1 "$rc"

# T15: word-boundary — `claude --printer` (not a real flag) → CLEAN
cat > "$TMP/printer.sh" <<'EOF'
claude --printer "$prompt"
EOF
rc=$(run_hook "printer.sh")
assert_rc "T15 --printer does NOT match --print" 0 "$rc"

# T16: word-boundary — `myclaude -p` (different command) → CLEAN
cat > "$TMP/myclaude.sh" <<'EOF'
myclaude -p "$prompt"
EOF
rc=$(run_hook "myclaude.sh")
assert_rc "T16 myclaude not matched as claude" 0 "$rc"

# T17: no files passed → CLEAN
rc=$(run_hook)
assert_rc "T17 no files" 0 "$rc"

# T18: stderr names file + line
out=$(cd "$TMP" && bash "$HOOK" "run.sh" 2>&1 1>/dev/null) || true
case "$out" in
    *"run.sh:"*) echo "PASS T18 stderr names file:line" ;;
    *) echo "FAIL T18 stderr did not name file:line"; FAILED=$((FAILED + 1)) ;;
esac

# HIMMEL-2195: argv-array spawns of claude (flags live in a separate array)
# T19-T23: unmarked spawn-family call with literal "claude" as program → BLOCK
printf "%s\n" "const r = spawnSync('claude', args, { encoding: 'utf8' });" > "$TMP/spawn.mjs"
rc=$(run_hook "spawn.mjs")
assert_rc "T19 spawnSync('claude', args) unmarked" 1 "$rc"

printf "%s\n" 'const p = Bun.spawn(["claude", ...flags]);' > "$TMP/bun.ts"
rc=$(run_hook "bun.ts")
assert_rc "T20 Bun.spawn([\"claude\", ...]) unmarked" 1 "$rc"

printf "%s\n" 'execFileSync("claude", a);' > "$TMP/efs.js"
rc=$(run_hook "efs.js")
assert_rc "T21 execFileSync(\"claude\", a) unmarked" 1 "$rc"

printf "%s\n" 'subprocess.run(["claude", *a])' > "$TMP/sp.py"
rc=$(run_hook "sp.py")
assert_rc "T22 subprocess.run([\"claude\", *a]) unmarked" 1 "$rc"

printf "%s\n" 'os.execvp("claude", ["claude", *a])' > "$TMP/osexec.py"
rc=$(run_hook "osexec.py")
assert_rc "T23 os.execvp(\"claude\", ...) unmarked" 1 "$rc"

# T24: same-line marker on an argv spawn → CLEAN
printf "%s\n" "const r = spawnSync('claude', args); // headless-claude-ok: probe" > "$TMP/spawn_ok.mjs"
rc=$(run_hook "spawn_ok.mjs")
assert_rc "T24 argv spawn, same-line marker" 0 "$rc"

# T25: preceding-line marker on an argv spawn → CLEAN
printf "%s\n%s\n" "// headless-claude-ok: probe" "const r = spawnSync('claude', args);" > "$TMP/spawn_above.mjs"
rc=$(run_hook "spawn_above.mjs")
assert_rc "T25 argv spawn, preceding-line marker" 0 "$rc"

# T26: claude is an ARGUMENT, not the program → CLEAN
printf "%s\n" "spawnSync('git', ['claude']);" > "$TMP/git.mjs"
rc=$(run_hook "git.mjs")
assert_rc "T26 claude not the program" 0 "$rc"

# T27: a different program whose name merely contains claude → CLEAN
printf "%s\n" "spawnSync('myclaude', args);" > "$TMP/myspawn.mjs"
rc=$(run_hook "myspawn.mjs")
assert_rc "T27 spawnSync('myclaude') not matched" 0 "$rc"

# T29: multiline call — program on the line after the open paren → BLOCK
printf "%s\n%s\n%s\n" "const r = spawnSync(" "  'claude'," "  args);" > "$TMP/ml.mjs"
rc=$(run_hook "ml.mjs")
assert_rc "T29 multiline spawnSync( newline 'claude' unmarked" 1 "$rc"

printf "%s\n%s\n%s\n" "// headless-claude-ok: probe" "const r = spawnSync(" "  'claude', args);" > "$TMP/ml_ok.mjs"
rc=$(run_hook "ml_ok.mjs")
assert_rc "T29b multiline argv spawn, marker above call line" 0 "$rc"

printf "%s\n%s\n" "const r = spawnSync(" "  'git', ['claude']);" > "$TMP/ml_git.mjs"
rc=$(run_hook "ml_git.mjs")
assert_rc "T29c multiline, claude not the program" 0 "$rc"

# T31: call, array bracket and program on three separate lines → BLOCK
printf "%s\n%s\n%s\n%s\n" "const p = Bun.spawn(" "  [" '    "claude", ...flags' "  ]);" > "$TMP/ml3.ts"
rc=$(run_hook "ml3.ts")
assert_rc "T31 three-line Bun.spawn( [ claude unmarked" 1 "$rc"

printf "%s\n%s\n%s\n%s\n%s\n" "// headless-claude-ok: probe" "const p = Bun.spawn(" "  [" '    "claude", ...flags' "  ]);" > "$TMP/ml3_ok.ts"
rc=$(run_hook "ml3_ok.ts")
assert_rc "T31b three-line argv spawn, marker above" 0 "$rc"

# T32 (judge I1): marker on the program line of a multi-line call → CLEAN
printf "%s\n%s\n" "const r = spawnSync(" "  'claude', args); // headless-claude-ok: x" > "$TMP/ml_inline.mjs"
rc=$(run_hook "ml_inline.mjs")
assert_rc "T32 multiline, same-line marker on the program line" 0 "$rc"

printf "%s\n%s\n%s\n%s\n" "const p = Bun.spawn(" "  [" '    "claude", ...flags // headless-claude-ok: x' "  ]);" > "$TMP/ml3_inline.ts"
rc=$(run_hook "ml3_inline.ts")
assert_rc "T32b three-line, marker on the program line" 0 "$rc"

# T33 (judge I2): os.spawn* with a mode argument across lines → BLOCK / marker → CLEAN
printf "%s\n%s\n%s\n" "os.spawnlp(" "    os.P_WAIT," '    "claude", "claude", *a)' > "$TMP/osml.py"
rc=$(run_hook "osml.py")
assert_rc "T33 multiline os.spawnlp(mode, claude) unmarked" 1 "$rc"

printf "%s\n%s\n%s\n%s\n" "# headless-claude-ok: x" "os.spawnlp(" "    os.P_WAIT," '    "claude", "claude", *a)' > "$TMP/osml_ok.py"
rc=$(run_hook "osml_ok.py")
assert_rc "T33b multiline os.spawnlp, marker above the call" 0 "$rc"

# T34: Windows program literal claude.exe → BLOCK; a lookalike stays clean
printf "%s\n" "spawnSync('claude.exe', args);" > "$TMP/exe.mjs"
rc=$(run_hook "exe.mjs")
assert_rc "T34 spawnSync('claude.exe') unmarked" 1 "$rc"

printf "%s\n" "spawnSync('claude.exe.bak', args);" > "$TMP/exebak.mjs"
rc=$(run_hook "exebak.mjs")
assert_rc "T34b claude.exe.bak not matched" 0 "$rc"

# T35: Bun object form { cmd: ["claude", ...] } → BLOCK
printf "%s\n" 'const p = Bun.spawn({ cmd: ["claude", ...a] });' > "$TMP/bobj.ts"
rc=$(run_hook "bobj.ts")
assert_rc "T35 Bun.spawn({ cmd: [\"claude\"] }) unmarked" 1 "$rc"

printf "%s\n%s\n%s\n" "const p = Bun.spawn({" '  cmd: ["claude", ...a],' "});" > "$TMP/bobj_ml.ts"
rc=$(run_hook "bobj_ml.ts")
assert_rc "T35b multiline Bun.spawn({ cmd: [claude] }) unmarked" 1 "$rc"

# T36: error text says where the marker goes for a multi-line call
out=$(cd "$TMP" && bash "$HOOK" "ml.mjs" 2>&1 1>/dev/null) || true
case "$out" in
    *"multi-line"*) echo "PASS T36 error text covers multi-line marker placement" ;;
    *) echo "FAIL T36 error text silent on multi-line marker placement"; FAILED=$((FAILED + 1)) ;;
esac

# T37 (HIMMEL-3980): a pure-comment line between the open paren and the program
# literal must not hide the call from the join → BLOCK; marker → CLEAN
printf "%s\n%s\n%s\n" "const r = spawnSync(" "  // run it" "  'claude', args);" > "$TMP/cm.mjs"
rc=$(run_hook "cm.mjs")
assert_rc "T37 comment line between ( and program, unmarked" 1 "$rc"

printf "%s\n%s\n%s\n" "const r = spawnSync(" "  // step 1 run it" "  'claude', args);" > "$TMP/cm_unbal.mjs"
rc=$(run_hook "cm_unbal.mjs")
assert_rc "T37b bracket-free // comment between ( and program, unmarked" 1 "$rc"

printf "%s\n%s\n%s\n" "subprocess.run(" "    # run it" '    ["claude", *a])' > "$TMP/cm.py"
rc=$(run_hook "cm.py")
assert_rc "T37c python # comment line before program, unmarked" 1 "$rc"

# T37p (codex-1 r7): a leading # in JS/TS is a private-field sigil, not a comment → BLOCK
printf "%s\n%s\n%s\n" "  #worker = spawnSync(" "  'claude', args);" "}" > "$TMP/cm_priv.mjs"
rc=$(run_hook "cm_priv.mjs")
assert_rc "T37p JS #private field initializer spawn, unmarked" 1 "$rc"

# T37q (judge J1644): `#` is a comment only in an allowlist of `#`-comment languages, so
# JS-hosting files (.vue .svelte .astro .html .mdx) keep it as code → BLOCK
for ext in vue svelte astro html mdx; do
    printf "%s\n%s\n%s\n%s\n" "class A {" "  #worker = spawnSync(" '    "claude", args);' "}" > "$TMP/cm_priv.$ext"
    rc=$(run_hook "cm_priv.$ext")
    assert_rc "T37q #private field spawn in .$ext, unmarked" 1 "$rc"
done
# T37r (codex-1 r9): an extensionless file is not classified, so `#` stays code → BLOCK
printf "%s\n%s\n%s\n%s\n" "class A {" "  #worker = spawnSync(" '    "claude", args);' "}" > "$TMP/cm_priv_noext"
rc=$(run_hook "cm_priv_noext")
assert_rc "T37r #private field spawn in an extensionless file, unmarked" 1 "$rc"

# T37s/t/u (judge J1644b): JS hosted INSIDE an allowlisted file — a `#` line that OPENS a
# paren is code, not a comment (a `#` line is skipped only at net bracket depth 0) → BLOCK
printf "%s\n%s\n%s\n%s\n%s\n" "script: |" "  class A {" "    #worker = spawnSync(" '      "claude", args);' "  }" > "$TMP/cm_host.yml"
rc=$(run_hook "cm_host.yml")
assert_rc "T37s JS #private spawn in a .yml github-script block, unmarked" 1 "$rc"
printf "%s\n%s\n%s\n%s\n%s\n" "cat > x.js <<EOF" "class A {" "  #worker = spawnSync(" '    "claude", args);' "}" > "$TMP/cm_host.sh"
rc=$(run_hook "cm_host.sh")
assert_rc "T37t JS #private spawn in a .sh heredoc, unmarked" 1 "$rc"
printf "%s\n%s\n%s\n%s\n%s\n" 'JS = """' "class A {" "  #worker = spawnSync(" '    "claude", args);' "}" > "$TMP/cm_host.py"
rc=$(run_hook "cm_host.py")
assert_rc "T37u JS #private spawn in a .py triple-quoted string, unmarked" 1 "$rc"

printf "%s\n%s\n%s\n" "const r = spawnSync(" "  /* run it */" "  'claude', args);" > "$TMP/cm_blk.mjs"
rc=$(run_hook "cm_blk.mjs")
assert_rc "T37d block-comment line before program, unmarked" 1 "$rc"

printf "%s\n%s\n%s\n%s\n" "const r = spawnSync(" "  // headless-claude-ok: probe" "  // run it" "  'claude', args);" > "$TMP/cm_ok.mjs"
rc=$(run_hook "cm_ok.mjs")
assert_rc "T37e marker inside the interleaved comments covers the call" 0 "$rc"

printf "%s\n%s\n%s\n" "// headless-claude-ok: probe" "const r = spawnSync(" "  // run it" > "$TMP/cm_ok2.mjs"
printf "%s\n" "  'claude', args);" >> "$TMP/cm_ok2.mjs"
rc=$(run_hook "cm_ok2.mjs")
assert_rc "T37f marker above the call line, comment between, covers it" 0 "$rc"

printf "%s\n%s\n%s\n" "const r = spawnSync(" "  // run it" "  'git', ['claude']);" > "$TMP/cm_git.mjs"
rc=$(run_hook "cm_git.mjs")
assert_rc "T37g comment between, claude not the program" 0 "$rc"

# T37h (codex-1): code AFTER a closing */ on the comment's own line is still code → BLOCK
printf "%s\n%s\n%s\n" "const r = spawnSync(" "  /* note */ 'claude'," "  args);" > "$TMP/cm_tail.mjs"
rc=$(run_hook "cm_tail.mjs")
assert_rc "T37h block comment then program on the same line, unmarked" 1 "$rc"

printf "%s\n%s\n%s\n%s\n%s\n" "const r = spawnSync(" "  /* headless-claude-ok: x" "     still comment */" "  'claude', args);" "" > "$TMP/cm_ml_ok.mjs"
rc=$(run_hook "cm_ml_ok.mjs")
assert_rc "T37j marker inside a multi-line block comment covers the call" 0 "$rc"

# T37k (codex-1 r2): a trailing comment after a closing */ must not feed depth
printf "%s\n%s\n%s\n" "const r = spawnSync(" "  /* note */ // x" "  'claude', args);" > "$TMP/cm_trail.mjs"
rc=$(run_hook "cm_trail.mjs")
assert_rc "T37k block comment then bracket-free line comment, unmarked" 1 "$rc"

# T37v/w (judge J1644c): a leading `//` in .py is floor division, so a wrapped line that
# starts with it and opens a paren is code, not a comment → BLOCK
printf "%s\n%s\n%s\n%s\n%s\n" "width = (" "    total" "    // len(subprocess.run(" '        ["claude", "-p", q], capture_output=True).stdout)' ")" > "$TMP/fd2.py"
rc=$(run_hook "fd2.py")
assert_rc "T37v python // floor division opening subprocess.run(, unmarked" 1 "$rc"
printf "%s\n%s\n%s\n" "n = (total" "    // subprocess.run(" '        ["claude", "-p"]).returncode)' > "$TMP/floordiv.py"
rc=$(run_hook "floordiv.py")
assert_rc "T37w python // floor division then program, unmarked" 1 "$rc"

# T37x (judge J1644c): for EVERY comment kind, a line that OPENS the paren is never skipped
# (a skip applies only to a line with no bracket character) → BLOCK
for kind in "//:mjs" "#:py" "/* ( */ spawnSync(:mjs"; do
    case "$kind" in
        "//:mjs") first="    // spawnSync(" ;;
        "#:py") first="    # spawnSync(" ;;
        *) first="    /* ( */ spawnSync(" ;;
    esac
    ext=${kind##*:}
    printf "%s\n%s\n%s\n" "x = [" "$first" "    'claude', args);" > "$TMP/cm_open.$ext"
    rc=$(run_hook "cm_open.$ext")
    assert_rc "T37x comment kind '${kind%:*}' opening a paren is not skipped" 1 "$rc"
done

# T37y (judge J1644d): a line that nets to depth 0 but CLOSES the outer paren and then OPENS
# the spawn paren (`// b); run(`) holds brackets, so it is never skipped, for every kind → BLOCK
printf "%s\n%s\n%s\n" "total = (a" "         // b) + subprocess.run(" '    ["claude", "-p"]).returncode' > "$TMP/fdclose.py"
printf "%s\n%s\n%s\n" "x = (a" "    // b); subprocess.run(" '    ["claude", "-p"])' > "$TMP/fdsemi.py"
printf "%s\n%s\n%s\n" "const ok = (o" "  #x in o); spawnSync(" '  "claude", ["-p"])' > "$TMP/priv.yml"
printf "%s\n%s\n%s\n" "total = (a" "    /* b) */ + subprocess.run(" '    ["claude", "-p"]).returncode' > "$TMP/blockclose.py"
for name in fdclose.py fdsemi.py priv.yml blockclose.py; do
    rc=$(run_hook "$name")
    assert_rc "T37y close-then-open comment line in $name is not skipped" 1 "$rc"
done

printf "%s\n%s\n%s\n" "const r = spawnSync(" "  /* a */ /* b */ 'claude'," "  args);" > "$TMP/cm_two.mjs"
rc=$(run_hook "cm_two.mjs")
assert_rc "T37l two block comments then program, unmarked" 1 "$rc"

# T37m (codex-1 r3): ten interleaved comment lines must not exhaust the window → BLOCK
{
    echo "const r = spawnSync("
    for n in 1 2 3 4 5 6 7 8 9 10; do echo "  // c$n"; done
    echo "  'claude', args);"
} > "$TMP/cm_many.mjs"
rc=$(run_hook "cm_many.mjs")
assert_rc "T37m ten comment lines between ( and program, unmarked" 1 "$rc"

# T37n (codex-1 r4): a stray unterminated /* (e.g. inside a template literal) must not
# blank the rest of the file — a later unmarked spawn is still caught → BLOCK
{
    echo 'const s = `'
    echo "/* not a comment, never closed"
    echo '`;'
    for n in 1 2 3 4 5 6 7 8 9 10; do echo "x$n();"; done
    echo "const r = spawnSync("
    echo "  'claude', args);"
} > "$TMP/cm_unterm.mjs"
rc=$(run_hook "cm_unterm.mjs")
assert_rc "T37n unterminated /* does not hide a later unmarked spawn" 1 "$rc"

# T30: os.spawn* takes a mode argument before the program → BLOCK
printf "%s\n" 'os.spawnlp(os.P_WAIT, "claude", "claude", *a)' > "$TMP/osspawn.py"
rc=$(run_hook "osspawn.py")
assert_rc "T30 os.spawnlp(mode, \"claude\") unmarked" 1 "$rc"

# T28: existing scoping kept — markdown under docs/ exempt → CLEAN
printf "%s\n" "Do not spawnSync('claude', args) without a marker." > "$TMP/docs/spawn.md"
rc=$(run_hook "docs/spawn.md")
assert_rc "T28 docs/ still exempt for argv form" 0 "$rc"

# T38a-T38g (HIMMEL-4123): comment text and blank lines must not break the join → BLOCK
printf "%s\n" 'subprocess.run(' '    # note )' '    ["claude", *a])' > "$TMP/u_hash.py"
rc=$(run_hook "u_hash.py")
assert_rc "T38a # comment with ) between ( and [\"claude\" unmarked" 1 "$rc"

printf "%s\n" 'subprocess.run(  # (' '    ["claude", *a])' > "$TMP/u_trail.py"
rc=$(run_hook "u_trail.py")
assert_rc "T38b trailing # ( comment on the open line unmarked" 1 "$rc"

printf "%s\n" 'const r = spawnSync(  // )' '  "claude", args);' > "$TMP/u_trail.mjs"
rc=$(run_hook "u_trail.mjs")
assert_rc "T38c trailing // ) comment on the open line unmarked" 1 "$rc"

printf "%s\n" 'const p = Bun.spawn({ // )' '  cmd: ["claude", "-p"],' '});' > "$TMP/u_bun.ts"
rc=$(run_hook "u_bun.ts")
assert_rc "T38d Bun.spawn({ // ) / cmd: [\"claude\" unmarked" 1 "$rc"

printf "%s\n" 'os.spawnv(os.P_WAIT,  # )' '    "claude", args)' > "$TMP/u_spawnv.py"
rc=$(run_hook "u_spawnv.py")
assert_rc "T38e os.spawnv(mode, # ) / \"claude\" unmarked" 1 "$rc"

{
    echo "const r = spawnSync("
    for n in 1 2 3 4 5 6 7 8 9 10; do echo ""; done
    echo "  'claude', args);"
} > "$TMP/u_blank.mjs"
rc=$(run_hook "u_blank.mjs")
assert_rc "T38f ten blank lines between ( and program, unmarked" 1 "$rc"

printf "%s\n" 'const r = spawnSync( /* ) */' '  "claude", args);' > "$TMP/u_block.mjs"
rc=$(run_hook "u_block.mjs")
assert_rc "T38g trailing /* ) */ comment on the open line unmarked" 1 "$rc"

# T38h-T38j: the comment-stripped pass adds no false deny → CLEAN
printf "%s\n" 'subprocess.run(  # "claude" is not run here' '    ["git", "log"])' > "$TMP/u_ok_name.py"
rc=$(run_hook "u_ok_name.py")
assert_rc "T38h binary named only in a comment" 0 "$rc"

printf "%s\n" '# headless-claude-ok: batch job' 'subprocess.run(  # (' '    ["claude", *a])' > "$TMP/u_ok_mark.py"
rc=$(run_hook "u_ok_mark.py")
assert_rc "T38i marker still covers a call with a bracketed comment" 0 "$rc"

printf "%s\n" 'x = a // b; run(  // (' '  "git", ["claude"]);' > "$TMP/u_ok_arg.mjs"
rc=$(run_hook "u_ok_arg.mjs")
assert_rc "T38j claude as an argument after a stripped comment" 0 "$rc"

# T39 (HIMMEL-4124): the shared join lib missing → fail closed, even on a clean file → BLOCK
mkdir -p "$TMP/nolib"
cp "$HOOK" "$TMP/nolib/check-no-headless-claude.sh"
rc=$(cd "$TMP" && bash "$TMP/nolib/check-no-headless-claude.sh" "interactive.sh" >/dev/null 2>&1; echo "$?")
assert_rc "T39 missing lib/headless-spawn-join.sh fails closed" 1 "$rc"

# T40 (HIMMEL-4124 CR): the join itself failing (awk missing or erroring) → fail closed, even on a clean file → BLOCK
mkdir -p "$TMP/badawk"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$TMP/badawk/awk"
chmod +x "$TMP/badawk/awk"
rc=$(cd "$TMP" && PATH="$TMP/badawk:$PATH" bash "$HOOK" "interactive.sh" >/dev/null 2>&1; echo "$?")
assert_rc "T40 a failing join (awk rc!=0) fails closed" 1 "$rc"

# T41 (HIMMEL-4132): a name=value staged filename must not read as an awk
# assignment (awk would read stdin and the multi-line join would pass) → BLOCK
printf "%s\n" 'const r = spawnSync(' '  "claude",' '  args)' > "$TMP/claude_x=1.js"
rc=$(run_hook "claude_x=1.js" </dev/null)
assert_rc "T41 multi-line spawn in a name=value filename unmarked" 1 "$rc"

# T42 (HIMMEL-4132): a file named '-' must not read as stdin → BLOCK
printf "%s\n" 'claude -p "summarize"' > "$TMP/-"
rc=$(run_hook "-" </dev/null)
assert_rc "T42 headless call in a file named - unmarked" 1 "$rc"
rm -f "$TMP/-"

# T43 (HIMMEL-4137): a correctly MARKED file named -lead.js must read as ALLOW,
# not as an option (pins the leading-dash false-positive fix) → CLEAN
printf "%s\n" 'spawnSync("claude", ["-p", prompt]); // headless-claude-ok: batch job' > "$TMP/-lead.js"
rc=$(run_hook "-lead.js" </dev/null)
assert_rc "T43 marked headless call in a file named -lead.js" 0 "$rc"
rm -f "$TMP/-lead.js"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
