# shellcheck shell=bash
# Shared argv-spawn detection for the two headless commit gates (HIMMEL-4124):
# scripts/hooks/check-no-headless-claude.sh and check-no-headless-gemini.sh.
# Sourced, never run. Each gate passes its own program literal and opt-in marker,
# so the spawn pattern and the multi-line join are written once and cannot drift.

# headless_spawn_pattern <program-ERE>
# Prints the SPAWN_PATTERN for one program (e.g. `claude(\.exe)?`). Deny-leaning
# by design, no variable tracing: any spawn-family call whose program argument is
# the literal program needs the opt-in marker, wherever the flags are. Covers
# spawn/exec/execFile[Sync], Bun.spawn[Sync], child_process.*, python
# subprocess.{run,call,check_call,check_output,Popen} and os.exec*/spawn*. The
# program must be the first argument (optionally the first array element), so
# `spawnSync('git', [<program>])` and `spawnSync('my<program>', …)` stay clean.
# Bun's object form `Bun.spawn({ cmd: [<program>, …] })` is covered.
headless_spawn_pattern() {
    local q='["'"'"']'
    printf '%s' "(^|[^A-Za-z0-9_])(spawn|spawnSync|exec|execSync|execFile|execFileSync|fork|Popen|run|call|check_call|check_output|execv|execvp|execve|execvpe|execl|execlp|execle|execlpe)[[:space:]]*\\([[:space:]]*(\\{[^)]*cmd[[:space:]]*:[[:space:]]*)?\\[?[[:space:]]*${q}$1${q}|(^|[^A-Za-z0-9_])spawn(v|l)p?e?[[:space:]]*\\([^,)]*,[[:space:]]*${q}$1${q}"
}

# headless_spawn_join <file> <spawn-ERE> <window> <marker>
# A call may span lines. Joins a window that starts at a line with an unclosed
# `(` / `[` / `{` and runs while the depth stays open (bounded to <window> code
# lines), tests the joined text, and prints `lineno:line` for the line carrying
# the program literal. A <marker> anywhere from the line above the window through
# that program line covers the call.
#
# HIMMEL-3980: a leading `#` is a comment ONLY in known `#`-comment languages
# (allowlist). Anywhere else — JS/TS and the files that host them (.vue, .svelte,
# .astro, .html, .mdx) — it is a private-field sigil (`#worker = spawnSync(`) and
# must stay code, so an unknown type fails toward catching the call. An
# extensionless file is not classified (it may be a Node script), so it stays code.
headless_spawn_join() {
    local f="$1" hash_cmt
    case "${f##*/}" in
        *.py|*.sh|*.bash|*.zsh|*.rb|*.yaml|*.yml|*.toml|*.pl|*.r|*.R|*.ps1) hash_cmt=1 ;;
        *) hash_cmt=0 ;;
    esac
    HASH_CMT="$hash_cmt" SPAWN_RE="$2" SPAWN_WIN="$3" SPAWN_MARK="$4" awk '
        BEGIN { re = ENVIRON["SPAWN_RE"]; win = ENVIRON["SPAWN_WIN"] + 0; hash = ENVIRON["HASH_CMT"] + 0; mark = ENVIRON["SPAWN_MARK"] }
        function depth(s,   t, o, c) {
            t = s; o = gsub(/[(\[{]/, "&", t)
            t = s; c = gsub(/[)\]}]/, "&", t)
            return o - c
        }
        # Pass 0 (HIMMEL-3980): a pure-comment line (`//`, `#`, or a one-line `/* … */`
        # block comment) is not code, so it neither opens/closes depth nor joins the
        # window — otherwise it can sit between the open paren and the program literal
        # and hide the call. Code AFTER a closing `*/` on the same line is kept (C0[]
        # holds the code remainder, L[] the raw line). Comments are judged per line: a
        # `/*` with no `*/` on its line stays code, so a stray one (e.g. inside a
        # string) can never blank later lines.
        # ponytail: a MULTI-line block comment is not recognised (its lines stay code),
        # so a `)` inside one can still close the depth early; fixing it needs
        # per-language lexing, no ticket (trigger: a reported evasion).
        {
            L[NR] = $0; s = $0; cmt = 0
            # peel leading comments until real code (or nothing) is left
            while (1) {
                # EVERY comment skip applies only to a line holding NO bracket character
                # at all. A comment marker is code in some host language (`//` is floor
                # division in Python/YAML, `#` a private-field sigil in JS), and a line
                # like `// b); run(` nets to depth 0 yet closes one paren and opens the
                # spawn paren. A bracket-free line cannot touch the paren structure, so
                # any line with a bracket stays code in this pass.
                if ((s ~ /^[[:space:]]*\/\// || (hash && s ~ /^[[:space:]]*#/)) && s !~ /[(\[{)\]}]/) { s = ""; cmt = 1; break }
                if (s !~ /^[[:space:]]*\/\*/) break
                t = s; sub(/^[[:space:]]*\/\*/, "", t)
                if (!match(t, /\*\//) || substr(t, 1, RSTART - 1) ~ /[(\[{)\]}]/) break
                s = substr(t, RSTART + 2); cmt = 1
            }
            skip0[NR] = (cmt && s ~ /^[[:space:]]*$/)
            C0[NR] = s
            # Pass 1 (HIMMEL-4123): the same line with ALL comment text cut — one-line
            # `/* … */` blocks, `//` and (allowlisted types) `#` to end of line, each
            # at a word start — so a comment holding an unbalanced bracket cannot shift
            # the depth or split the spawn from its program, and blank lines do not use
            # up the window. It may misread code or string text as a comment, which is
            # why it never REPLACES pass 0: a call either pass catches is reported, so
            # the union refuses everything pass 0 alone refused.
            s = $0
            gsub(/\/\*([^*]|\*+[^*\/])*\*+\//, " ", s)
            sub(/(^|[[:space:]])\/\/.*$/, "", s)
            if (hash) sub(/(^|[[:space:]])#.*$/, "", s)
            skip1[NR] = (s ~ /^[[:space:]]*$/)
            C1[NR] = s
        }
        function scan(pass,   i, j, J, d, hit, n, ok, k, c) {
            for (i = 1; i <= NR; i++) {
                if (pass ? skip1[i] : skip0[i]) continue
                c = pass ? C1[i] : C0[i]
                d = depth(c); if (d <= 0) continue
                j = i; J = c; hit = 0; n = 0
                # the window counts CODE lines only, so interleaved comments cannot exhaust it
                while (d > 0 && j < NR && n < win) {
                    j++
                    if (pass ? skip1[j] : skip0[j]) continue
                    n++
                    c = pass ? C1[j] : C0[j]
                    J = J " " c; d += depth(c)
                    if (!hit && J ~ re) { hit = j }
                }
                if (!hit) continue
                ok = 0
                for (k = (i > 1 ? i - 1 : 1); k <= hit; k++)
                    if (index(L[k], mark)) ok = 1
                if (!ok) print hit ":" L[hit]
            }
        }
        END { scan(0); scan(1) }' 2>/dev/null <"$f" ||
        # A join that could not run (awk missing or erroring) proves nothing clean:
        # report line 0, which no marker can cover, so the gate fails closed.
        echo "0:headless spawn join failed"
}
