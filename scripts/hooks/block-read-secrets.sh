#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell/Read/Grep.
#
# Blocks tool calls that would read or print the contents of secret files
# (.env, .envrc, *.pem, *.key, id_rsa, id_ed25519, credentials.json,
# secrets.y[a]ml, *.p12, *.pfx). Pattern after block-edit-on-main.sh.
#
# Memory: feedback_secrets_handling.md — "never cat .env or secret files;
# ask user to echo specific values via `!` prefix; narrow grep if file
# must be read." Plugs the friction case where an overly-broad grep on
# .env leaked a Jira API token mid-session.
#
# Detection model:
#   * Read tool   → block when file_path matches a secret pattern
#   * Grep tool   → block when path matches a secret pattern
#   * Bash/PS tool → split the command into clauses at shell separators
#                    (; | & ( ) ` newlines); for each clause the first token
#                    that isn't an env-assignment / wrapper (sudo,doas,env,
#                    xargs) / shell keyword is the COMMAND. Block when that
#                    command is a reader (cat/grep/head/jq/sed/awk/…) AND a
#                    secret-file arg follows, OR on a `< secretfile` redirect.
#                    In-place sed/awk (`-i`) is carved out per-clause. This
#                    command-position model (HIMMEL-436) replaced a global
#                    reader-OR-secret scan that false-positived on inline
#                    interpreter bodies (`node -e "…obj.key…file…"`).
#
# Reader command list intentionally narrow: cat/grep/head/jq/sed/awk/etc.
# In-place forms of sed and awk (`sed -i …`, `awk -i inplace …`) are
# carved out below since they rewrite in place without piping content
# to stdout. Interactive editors (`vim`, `nano`, `vi`, `nvim`, `emacs`)
# and the read-only `view` are NOT in the reader list at all — they
# never surface content to Claude as a tool result.
# Write-only ops (echo >, tee, mv, cp, docker -v) are also not blocked.
#
# Known limitations (consciously accepted — gate targets accidental leaks,
# not a determined attacker):
#   * `bash -c 'cat .env'` IS now caught (HIMMEL-440): when the clause command
#     resolves to a shell interpreter (bash/sh/zsh/dash/ksh/ash), the matcher
#     recurses into the `-c '<body>'` and re-runs the reader+secret check on the
#     body's first statement (the body is real shell, so this is FP-free —
#     unlike node -e / python -c non-shell bodies). Remaining `-c` gaps:
#     variable bodies `bash -c "$CMD"` (variable indirection, below), process
#     substitution `bash <(echo 'cat .env')`, and exotic flag interleavings
#     where `-c` follows a non-flag operand. (Multi-statement bodies like
#     `bash -c 'echo hi; cat .env'` already block via the later clause.) A
#     secret passed as a POSITIONAL into the body (`bash -c 'cat "$1"' _ .env`)
#     reaches the reader via `$1` — the same accepted variable-indirection gap
#     below, not a literal arg. Scanning stops at the body's closing quote, so a
#     trailing positional after a NON-secret body read is not over-blocked.
#   * `git show HEAD:.env`, `git cat-file -p HEAD:.env` — git not in
#     reader list (would false-positive on most git commands).
#   * Cross-command exfil: `cp .env /tmp/x; cat /tmp/x` — cp is write-only,
#     and the second command targets a non-secret path.
#   * Variable indirection: `F=.env; cat $F` — no `.env` token after `cat`.
#   * Inline interpreter bodies (`node -e`, `python -c`): command-position
#     fixes the COMMON false positive (coincidental `obj.key` property access
#     and reader-named identifiers like `file`/`type`). A body that literally
#     contains `<separator><reader-name><secretfile>` adjacent (e.g.
#     `node -e "x; cat .env"`) still fragments to a `cat .env` clause and
#     blocks — same class as `bash -c 'cat .env'`.
#   * A reader whose own filter/arg equals a secret name: `jq .env file.json`
#     (filter literally `.env`) blocks — jq is the command, `.env` its arg;
#     command-position can't tell a jq filter path from a filename. grep/rg/
#     sed/awk have the identical ambiguity for their PATTERN/script argument
#     (`grep '.env' file.txt` searches file.txt FOR the text ".env") and it
#     IS fixed for that family (HIMMEL-2213), narrowly: a QUOTED
#     (`'...'`/`"..."`) argument is exempt from the secret-path check ONLY
#     when it is the token IMMEDIATELY after the bare reader command — ZERO
#     flags in between — or, as the one explicit exception, immediately
#     after an `-e`/`--regexp` flag (grep's own explicit-pattern flag; its
#     value is unambiguously always a pattern, at any position) AND ONLY
#     for a grep/sed/awk-family command (round 6: `-e` means something
#     unrelated for other readers — GNU cat's `-e` is `-vE`, and
#     `cat -e .env` genuinely reads .env; an earlier cut applied the -e
#     exemption regardless of command, false-ALLOWing it). ANY other
#     flag before an otherwise-implicit pattern (`-rn '.env'`, `-m 1
#     '.env'`) is NOT exempt and falls back to the ordinary (blocking) scan.
#     This is deliberately narrower than "the first non-flag argument",
#     which rounds 1-4 each tried and each broke in a different way a panel
#     review found: `rg --ignore-file .env TOKEN src/` (round 3) and
#     `rg --ignore-file '.env' TOKEN src/` (round 4) both false-ALLOWED a
#     real secret read (an unrecognised flag's value consumed the
#     exemption), `grep -m 1 '.env' file.txt` (round 3) false-BLOCKED (an
#     unquoted flag VALUE like `-m`'s count consumed the sole exemption
#     before the real pattern arrived), and `grep TOKEN '.env'` (round 5)
#     false-ALLOWED once more (an unquoted IMPLICIT pattern didn't close the
#     slot, leaving a later quoted argument — the real target — free to
#     claim it). Distinguishing "a flag's value operand" from "a genuine
#     positional pattern" requires an arity table per flag per tool
#     (grep/egrep/fgrep/rg/ripgrep/ag/sed/awk/gawk/mawk/nawk each differ),
#     which is unbounded scope; restricting the exemption to position ZERO
#     (or right after -e/--regexp specifically) sidesteps the whole
#     ambiguity class instead of chasing one more instance of it. `-f`/
#     `--file` (grep/sed/awk's pattern/script-FROM-a-file flag) gets its own
#     explicit-state handling too (round 7, below) — always scanned as a
#     real target, never exempt.
#
#     Round 7 (panel review): rounds 5-6 checked `prev` against RAW TEXT
#     ("-e"/"--regexp", or the command's own name for position 0). That is
#     spoofable — `-f`/`--file` accepts ANY string as its value, so
#     `grep -f --regexp .env` makes `-f` consume the literal text
#     "--regexp" as its (nonsense) filename, and `.env` — the real target
#     grep -f left over — was wrongly exempted next, because a text
#     comparison cannot tell "a genuine --regexp flag" from "a token that
#     merely SAYS --regexp because it was crafted as -f's value". Position
#     (0 or not) and "was this token just consumed as -f/--file's value"
#     are now tracked as explicit, one-token-at-a-time ARMED STATE
#     (`at_pos0`/`expect_pattern_val`/`expect_file_val`, and their `rec_`
#     twins for the recursed body) instead of being inferred by comparing a
#     token's text — text an adversarial -f/--file value can always be
#     crafted to collide with, state cannot.
#   * A QUOTED value to some OTHER tool-specific file-reading long option at
#     position zero — i.e. as the reader's ONLY argument with nothing before
#     it, which no real invocation of such a flag looks like (a file-reading
#     flag always takes a value, so it is never the last/only token) — is
#     structurally unreachable; jq/yq's filter-vs-path ambiguity is a
#     separate, deliberately unfixed gap for the same "unbounded per-tool
#     enumeration" reason above.
#   * A quoted PATTERN containing whitespace (`grep 'foo .env' file.txt`)
#     is split into multiple tokens by this tokenizer's naive IFS word-split
#     BEFORE the quote check ever runs (the header above already says
#     "shell quoting is intentionally NOT parsed") — the trailing fragment
#     (`.env'`) is scanned on its own and can still false-block. This is the
#     SAME class of false positive HIMMEL-2213 exists to fix, just for a
#     multi-word pattern instead of a single-word one; closing it needs a
#     real quote-spanning scan across tokens, which is a materially bigger
#     change than this ticket's ask and its own risk (a fragile parser is
#     itself a source of future bugs). Deliberately left as a documented,
#     accepted false positive rather than attempted here — costs a cycle,
#     never a leak (the bypass hint below names the recovery).
#   * Wrappers are carved out only in their bare form, where the command is
#     the wrapper's immediate next token: {sudo,doas,env,xargs,time,nice,
#     command,nohup}. A wrapper with leading ARGS before the command
#     (`timeout 5 cat .env`, `nice -n5 cat .env`, `sudo -u u cat .env`) makes
#     that arg the command token → the read is allowed through. Likewise
#     wrappers outside the set (`strace`, `flatpak-spawn`). Determined-attacker
#     territory; the gate targets the common accidental shapes.
#   * `cat <<< .env` here-string normalises to `cat < < < .env` and trips the
#     `<`-redirect path though it reads no file.
#   * NTFS alternate data streams: `.env:stream` is not matched (low risk —
#     POSIX toolchains don't address ADS via the colon syntax).
#   * 8.3 short names: `ENV~1` is not matched (short-name generation is off
#     by default on modern NTFS volumes).
#   * HIMMEL-2228: glued option tokens. Everything above tokenized whole
#     shell words and matched each one AS a candidate secret path — it never
#     looked INSIDE a token, so a GLUED option — `--file=.env` / `-f.env`
#     (bundled `-rf.env` too) / PowerShell's `-Path:.env` — matched no glob
#     and was ALLOWED, even though `grep -f.env` genuinely opens and reads
#     that file as its pattern source. `glued_opt_secret()` now splits a
#     glued token at its FIRST `=`/`:` (or past a bundled short `f`) and
#     scans the value half, in both the outer clause and the HIMMEL-440
#     recursed `-c` body. It is checked in its own `if`, outside the
#     HIMMEL-2213 exemption chain, so — EXCEPT for the armed-state skip
#     described below — a glued value is scanned UNCONDITIONALLY: including
#     for -e/--regexp, whose separate-token value would be exempt (`grep
#     --regexp=.env file.txt` now denies: an ACCEPTED false positive, named
#     via `glued_hint` on the denial), and for a value that is a glob rather
#     than a file (`--exclude=*.pem`). `sed --in-place=.env file.txt` also
#     now denies for the same reason — a real in-place rewrite that leaks
#     nothing, but the glued value can't be told apart from a real read
#     target without per-tool knowledge. The one exception: a token already
#     consumed as a preceding `-f`/`-e`'s own value (`grep -f --file=.env` —
#     `-f` opens a file literally named `--file=.env`) is skipped, using the
#     same round-7 armed state (`expect_file_val`/`expect_pattern_val`), so
#     the ordinary consumption rule still wins there. Because the short-glue
#     split (`-*f?*`) matches at the FIRST `f` in the token regardless of
#     what precedes it, a bundle whose earlier letter would really have
#     consumed the rest (`grep -m1f.env` — plain getopt bundling reads this
#     as `-m 1f.env`, `-m`'s own value) still gets split and denied anyway:
#     over-blocking, never a leak, so it needs no fix. The genuine residual,
#     same "unbounded per-tool arity table" class the rest of this header
#     already declines to enter: a glued value on a single-letter
#     file-taking flag that is NOT `f` (the short-glue split recognises only
#     `f`) is never split and falls back to the ordinary whole-token scan.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: set READ_SECRETS_OK=1 in the shell that launched Claude Code
# (Claude cannot inject env vars into hooks). Session-sticky; restart to
# re-enable. Or comment the hook in .claude/settings.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "block-read-secrets: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-read-secrets: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi

# HIMMEL-2123: bash builtin `read` instead of `$(cat)` drops one spawn, and
# every field this hook might need (tool_name + the three per-tool payload
# fields) is pulled in ONE jq call via `<<<` (no printf fork) instead of up
# to two separate `printf | jq` pipelines.
#
# RETASK R2123A (independent review): the field separator is a raw SOH byte
# ($'\001', bash ANSI-C quoting — plain portable source text, not a literal
# control character sitting in this file), passed to jq as `--arg sep`
# rather than spelled as a unicode escape inside the jq program text itself
# (a literal escape sequence there kept getting silently decoded back into
# a raw embedded control byte by this editing pipeline — passing it as a
# runtime arg sidesteps that entirely).
# NOT `\n`: two independent bugs with a `\n` separator, both closed by this:
#   * Windows jq.exe writes CRLF for every "\n" a multi-field filter emits,
#     so every field but the last comes back with an embedded trailing \r
#     that needed an explicit strip (the shape require-quiet-run.sh,
#     HIMMEL-2060, still uses for its one non-final field).
#   * a `\n` INSIDE file_path/path (a path component containing a literal
#     newline — POSIX-legal, if rare) truncated that field early at the
#     split, so is_secret_path never saw the real basename. SOH cannot
#     legitimately appear in a path OR get CRLF-translated, so no field
#     needs stripping and the split is exact regardless of field content.
#     `command` is still read out LAST (the tail past the third separator),
#     so its own legitimate embedded "\n"s (a heredoc body) stay intact.
#
# NOTE: each fallback is `// ""` (an empty STRING), not `// empty` (a
# zero-output jq GENERATOR) — a `+`-concatenation is the cross product of
# every operand's output count, so ONE missing field spelled `// empty`
# collapses the WHOLE expression to zero outputs, silently emptying every
# other field too. Caught empirically while writing this (HIMMEL-2123): a
# Bash command has neither file_path nor path, so with `// empty` this
# hook's tool/cmd extraction went silently blank for every Bash/PowerShell
# call and the guard stopped firing entirely.
#
# RETASK R2123A (independent review): `|tostring` on every operand. Without
# it, a NON-STRING but present sibling field (e.g. Read with a numeric
# `"path":42` alongside its `file_path`) made jq's `+` a type error — a
# DIFFERENT failure than "field is null", not covered by `// ""` — and the
# `|| true` on the whole call swallowed it, blanking every field (tool
# included) and silently disabling the guard for that call. `tostring` is a
# no-op on an already-string value.
# RETASK R2123A (panel, codex-1): the SOH delimiter is a security hole, not
# just a Windows-CRLF/embedded-newline fix -- a model-influenced Read/Grep
# `file_path`/`path` LEGITIMATELY-TYPED-JSON string CAN contain a literal
# SOH byte (prompt-injected model output is explicitly in this fence's
# threat model), and that desyncs the split exactly like an embedded "\n"
# did: `"file_path":"/tmp/<SOH>/.env"` would parse as file_path="/tmp/" with
# ".env" shifted into `path`, and the real secret path never reaches
# is_secret_path. No real filename ever contains SOH, so rejecting it costs
# nothing legitimate. `command` is deliberately NOT checked: it is the LAST
# field (read out as "everything after the third separator", never split
# further), so an embedded SOH there cannot shift any OTHER field -- it just
# becomes part of $cmd's own text, same as any other stray byte a shell
# command can legally contain.
#
# The check runs INSIDE the jq call, before the fields are joined: any
# collision makes jq `error(...)`, which now (unlike the old bare `|| true`)
# is caught by `if ! result=$(...)` below and fails CLOSED -- the correct
# direction for a secrets fence, matching the "malformed JSON" case
# block-destructive-commands.sh/block-git-stash.sh already fail closed on.
input=""
IFS= read -r -d '' input 2>/dev/null || true
# RETASK R2123A (CodeRabbit App, PR #1912): empty/whitespace-only stdin must
# fail CLOSED -- this is a secrets FENCE (scripts/hooks/CLAUDE.md's
# fail-direction table). `jq <<<""` (or whitespace-only input) emits zero
# values with zero errors, so `if ! result=$(...)` below never fires and
# every field comes back empty -- the case statement then falls through to
# its `*) exit 0` default, a silent ALLOW. Same guard already applied to
# block-destructive-commands.sh/block-git-stash.sh: catch it here, before
# jq ever runs.
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-read-secrets: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
SOH=$'\001'
if ! result=$(jq -r --arg sep "$SOH" '
    def chk: if contains($sep) then error("delimiter-collision") else . end;
    ((.tool_name // "")|tostring|chk) + $sep +
    ((.tool_input.file_path // "")|tostring|chk) + $sep +
    ((.tool_input.path // "")|tostring|chk) + $sep +
    ((.tool_input.command // "")|tostring)
' <<<"$input" 2>/dev/null); then
    echo "block-read-secrets: unparseable input or field-delimiter collision — failing closed" >&2
    exit 2
fi
tool="${result%%$'\001'*}"
_rd_rest="${result#*$'\001'}"
_rd_fp="${_rd_rest%%$'\001'*}"
_rd_rest="${_rd_rest#*$'\001'}"
_rd_gpath="${_rd_rest%%$'\001'*}"
_rd_cmd="${_rd_rest#*$'\001'}"

# is_secret_path: this hook's name for the shared is_secret_basename predicate
# (scripts/guardrails/lib.sh, HIMMEL-879 — pattern list + case-fold rationale
# live there; also shared with block-edit-on-main.sh). Kept as a thin wrapper
# so the many call sites below don't need to change name.
is_secret_path() {
    is_secret_basename "$@"
}

is_reader_cmd() {
    # ONLY commands that exfiltrate file contents to stdout (i.e. would
    # leak the secret into Claude's tool result). Interactive editors
    # (vim, nano, vi, nvim, emacs, view) and write-only ops (echo >,
    # tee, mv, cp) are NOT readers — they don't surface content to
    # Claude. sed/awk ARE readers by default (they print to stdout);
    # the in-place forms are carved out by is_inplace_cmd below.
    case "$1" in
        cat|bat|tac|head|tail|less|more|most)  return 0 ;;
        grep|egrep|fgrep|rg|ripgrep|ag)        return 0 ;;
        sed|awk|gawk|mawk|nawk)                return 0 ;;
        jq|yq)                                 return 0 ;;
        xxd|od|hexdump|strings|base64|file)    return 0 ;;
        # PowerShell readers (Bash matcher may still see these via pwsh -c).
        Get-Content|gc|Select-String|sls|type) return 0 ;;
    esac
    return 1
}

is_interp_cmd() {
    # Shell interpreters whose `-c '<body>'` body IS shell — so re-running the
    # matcher on the body is correct and FP-free (HIMMEL-440). Deliberately
    # EXCLUDES node/python/etc.: their `-e`/`-c` bodies are NOT shell, and
    # scanning them is exactly what caused the HIMMEL-436 false positives.
    case "$1" in
        bash|sh|zsh|dash|ksh|ash) return 0 ;;
    esac
    return 1
}

is_pattern_arg_cmd() {
    # Commands whose first non-flag ARGUMENT is a PATTERN/script the command
    # searches or transforms WITH, not a path it reads (HIMMEL-2213): a
    # `grep '.env' file.txt` searches file.txt FOR the literal text ".env" —
    # the pattern is data, and the env-glob arm of is_secret_basename must
    # not fire on it. Scoped to the ticket's named class only (grep-family +
    # sed/awk-family); jq/yq share the same filter-vs-path ambiguity but are
    # a separate, already-documented limitation (see header) and deliberately
    # NOT touched here — narrowing further than the ticket asks risks a
    # false negative this fence cannot afford (fail-closed is non-negotiable).
    case "$1" in
        grep|egrep|fgrep|rg|ripgrep|ag) return 0 ;;
        sed|awk|gawk|mawk|nawk)         return 0 ;;
    esac
    return 1
}

is_quoted_pattern_tok() {
    # True iff the token is wrapped in a matching pair of quote chars — i.e.
    # it was written as a QUOTED shell argument (`'.env'`, `".env"`), which
    # is exactly the shape HIMMEL-2213 asks for ("a token inside a QUOTED
    # argument... is data, not a read target"). Quoting is only HALF the
    # exemption rule — the call sites also require the token be at a
    # specific POSITION (immediately after the bare command, or after
    # -e/--regexp) before this predicate is even consulted; see the header
    # "Known limitations" section for why position matters too.
    case "$1" in
        \'*\') return 0 ;;
        \"*\") return 0 ;;
    esac
    return 1
}

is_inplace_token() {
    # True for tokens that indicate sed/awk are operating in-place
    # (rewriting the file without piping content to stdout). Covers:
    #   sed -i        (GNU)
    #   sed -i ''     (BSD — '' is its own token, shell strips quotes
    #                  so we just match the bare `-i`)
    #   sed -i.bak    (BSD — backup-suffix glued to the flag)
    #   sed --in-place
    #   awk -i inplace (gawk extension; `inplace` is its own token)
    #   awk --in-place
    case "$1" in
        -i|--in-place|inplace) return 0 ;;
        -i.*)                  return 0 ;;
    esac
    return 1
}

glued_opt_secret() {
    # HIMMEL-2228. True iff the token is a GLUED option whose VALUE half is a
    # secret path: `--opt=<value>` / `-f<value>` (bundled `-rf<value>` too) /
    # PowerShell's `-Param:<value>`. The tokenizer only ever fed WHOLE tokens
    # to is_secret_path, so `grep --file=.env` and `grep -f.env` — both of
    # which make grep genuinely OPEN and read that file as its pattern source
    # — matched no secret glob and were ALLOWED (a false NEGATIVE in a
    # secrets fence). A leading quote left by the quote-naive splitter is
    # stripped first; is_secret_path strips the trailing one itself.
    local v="${1#\"}"; v="${v#\'}"
    case "$v" in
        -*=*)  v="${v#*=}" ;;   # --file=<value>, and any other long opt: split at the FIRST '='
        -*:*)  v="${v#*:}" ;;   # PowerShell -Path:<value>
        --*)   return 1 ;;      # a bare long flag has no glued value (the state machine owns it)
        -*f?*) v="${v#*f}" ;;   # -f<value>, and bundles like -rf<value>
        *)     return 1 ;;
    esac
    is_secret_path "$v"
}

bypass_hint() {
    cat >&2 <<'EOF'

To bypass intentionally, set READ_SECRETS_OK=1 in the shell that launched
Claude Code (env vars can't be injected per-call). Example:
    READ_SECRETS_OK=1 claude
Session-sticky. Restart Claude without it to re-enable the guard.

Prefer: ask the user to echo the specific value via the `!` prefix in the
prompt, or narrow the read to one key (e.g. `grep '^FOO=' .env | cut -d= -f2-`
under bypass).
EOF
}

pattern_hint() {
    # HIMMEL-2213: the quoted-pattern exemption is POSITIONAL (see "Known
    # limitations" in the header) — a flag before an implicit pattern falls
    # back to blocking, so a perfectly innocent `grep -rn '<pat>' dir/` still
    # denies whenever <pat> happens to look like a secret name. That false
    # positive is the ACCEPTED half of a fail-closed tradeoff, but the agent
    # that trips it has no way to know the shape it should have used. Naming
    # the two shapes that DO pass turns a lost cycle into a lost message —
    # the ticket's own sanctioned remedy for the cases we keep blocking.
    cat >&2 <<'EOF'

If the quoted token above is a grep/sed/awk PATTERN and not a file you meant to
read, note that a quoted pattern is exempt only in two positions: immediately
after the bare command, or as the value of `-e`/`--regexp`. Move it there and
the same search passes, unchanged and un-bypassed:
    grep '.env' -rn scripts/       # pattern first, flags after it
    grep -e '.env' -rn scripts/    # explicit -e, flags anywhere
Or put the command in a script file and run that file instead.
EOF
}

glued_hint() {  # $1 = the glued token that tripped the scan
    echo "" >&2
    echo "The token \`$1\` glues an option to its value. A glued value is scanned as a" >&2
    echo "real read target UNCONDITIONALLY — including for -e/--regexp, whose" >&2
    echo "separate-token value would be exempt, and for a value that is a glob rather" >&2
    echo "than a file (\`--exclude=*.pem\`). If it was a PATTERN and not a file, that is" >&2
    echo "an ACCEPTED false positive: a glued -f/--file value IS a real file read and no" >&2
    echo "token-shape rule can tell the two apart, so this fence errs toward scanning." >&2
    echo "Split the option from its value and the ordinary rules apply again:" >&2
    echo "    grep -e '<pattern>' file.txt      # instead of --regexp=<pattern>" >&2
    echo "Or put the command in a script file and run that file." >&2
}

pattern_hint_applies() {  # $1 = the raw command string
    # Only when the command names a pattern-family reader AND some token in it
    # is a QUOTED secret-looking name — i.e. the denial could plausibly BE the
    # positional-pattern false positive the hint describes. Both halves are
    # load-bearing: without the family check the hint is noise on `cat .env`;
    # without the quoted-secret check it also fires on `grep 'x' < .env`, a
    # genuine redirect read where moving the pattern cannot possibly help, and
    # a hint that points at the wrong recovery costs the same cycle it exists
    # to save.
    # Subshell + `set -f`: the word-split below is intentional, but globbing
    # is not — an unquoted `*` in the command must not expand to filenames.
    # shellcheck disable=SC2086 # intentional word split for tokenisation
    (
        set -f
        _ph_fam=0
        _ph_quoted_secret=0
        for _ph_w in $1; do
            if is_pattern_arg_cmd "$_ph_w"; then _ph_fam=1; fi
            if is_quoted_pattern_tok "$_ph_w" && is_secret_path "$_ph_w"; then
                _ph_quoted_secret=1
            fi
        done
        if [ "$_ph_fam" = "1" ] && [ "$_ph_quoted_secret" = "1" ]; then exit 0; fi
        exit 1
    )
}

case "$tool" in
    Read)
        fp="$_rd_fp"
        [ -z "$fp" ] && exit 0
        if is_secret_path "$fp"; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing Read of secret file: $fp" >&2
            bypass_hint
            exit 2
        fi
        ;;

    Grep)
        gpath="$_rd_gpath"
        [ -z "$gpath" ] && exit 0
        if is_secret_path "$gpath"; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing Grep on secret path: $gpath" >&2
            bypass_hint
            exit 2
        fi
        ;;

    Bash|PowerShell)
        cmd="$_rd_cmd"
        [ -z "$cmd" ] && exit 0

        # Split the command into CLAUSES at shell separators so a reader and a
        # secret in UNRELATED parts of the command don't cross-trip (the old
        # global-OR did — it blocked any reader-named token anywhere plus any
        # secret-glob token anywhere, which false-positived on inline
        # interpreter bodies like `node -e "…cfg.key…file…"`). Separators
        # ; | & ( ) ` and newlines each become a clause boundary — a literal
        # newline via a POSIX backslash-newline sed replacement (works on BSD
        # and GNU sed; do NOT use GNU-only `\n` in the replacement). `<`/`>`
        # are spaced into their own tokens so a `< secretfile` redirect stays
        # detectable. Shell quoting is intentionally NOT parsed (see header).
        # HIMMEL-2123: sed reads via `<<<` (no `printf` fork feeding it).
        normalized=$(sed -e 's/[;|&()`]/\
/g' -e 's/</ < /g' -e 's/>/ > /g' <<<"$cmd")

        block=0
        # HIMMEL-2228: the glued token that tripped glued_opt_secret, named in
        # the denial via glued_hint. Declared once (not per-clause) so it
        # survives to the denial block below — the loop is fed by a <<EOF
        # heredoc, not a pipe, so it runs in the current shell and this
        # assignment persists.
        glued_tok=""
        # Iterate clause-by-clause. bash 3.2-safe: a while-read heredoc, NOT
        # mapfile (bash 4) and NOT a for-loop over unquoted $normalized (which
        # would re-split on spaces and destroy clause boundaries).
        while IFS= read -r clause; do
            if [ -z "$clause" ]; then continue; fi
            cmdtok=""
            reader=0
            secret_after=0
            inplace=0
            prev=""
            pattern_cmd=0     # cmdtok is grep/sed/awk-family (HIMMEL-2213)
            at_pos0=0             # the NEXT token is the one right after cmdtok
            expect_pattern_val=0  # the NEXT token is -e/--regexp's value (always data)
            expect_file_val=0     # the NEXT token is -f/--file's value (always a real file)
            # HIMMEL-440 recursion state (interpreter `-c` body re-resolution):
            interp=0          # cmdtok resolved to a shell interpreter
            found_c=0         # a -c / -*c flag has been seen
            rec_cmd=""        # the recursed command (body's first token)
            rec_reader=0
            rec_secret=0
            rec_inplace=0
            rec_pattern_cmd=0    # rec_cmd is grep/sed/awk-family (HIMMEL-2213)
            rec_at_pos0=0
            rec_expect_pattern_val=0
            rec_expect_file_val=0
            bodyq=""          # the -c body's outer quote char (' or "), if any
            bodyclosed=0      # past the body's closing quote → tokens are $0/$1…
            # shellcheck disable=SC2086 # intentional word split for tokenisation
            for tok in $clause; do
                # HIMMEL-2525: bash's default $IFS (space/tab/newline) does
                # NOT include CR (0x0D), so a CR glued onto this token —
                # trailing (`cat .env<CR>`, the tail of a Windows CRLF
                # one-liner) or embedded MID-token (`.en<CR>v`) — survives
                # this word-split attached to $tok, unchanged, and every
                # comparison below (is_reader_cmd/is_interp_cmd/
                # is_pattern_arg_cmd on cmdtok; is_secret_path/
                # glued_opt_secret/is_quoted_pattern_tok/is_inplace_token on
                # an argument; the HIMMEL-440 recursed -c body's mirrored
                # checks, which reuse this same $tok) then compares against
                # the WRONG string and MISSES — a false ALLOW in a secrets
                # fence. Strip every CR from $tok HERE, once, before ANY of
                # those comparisons run this iteration: one match-site strip
                # covers every call site below because they all read this
                # one variable. Deliberately scoped to $tok alone — $cmd,
                # $normalized and $clause are never touched, so a CR that is
                # legitimate DATA inside a heredoc body (its own $clause,
                # untouched by this loop; see the SOH-tail comment in the
                # header) is never mutated, and the raw command this hook
                # echoes back on denial stays byte-for-byte what was received
                # (test-crlf-boundary.sh's heredoc positive control pins
                # this). A blanket `tr -d '\r'` on $cmd/$normalized would
                # "fix" the same three bypass rows but corrupt exactly that
                # heredoc content — the WRONG fix, ruled out by design, not
                # by oversight.
                #
                # Stated behaviour for a token-INTERNAL CR: stripping ALL
                # CRs (not just a trailing one) means `.en<CR>v` normalises
                # to `.env` and is DENIED. Deliberate: no legitimate filename
                # argument the model would ever emit contains a literal CR,
                # so collapsing it to the clean name costs nothing real and
                # keeps this fence fail-closed. A CR that is its OWN token
                # (real whitespace on both sides, e.g. `cat <CR> .env`) is
                # the discriminator this strip must NOT change the verdict
                # of: `.env` there was already clean before this line ever
                # ran, so it denies before and after — proving this fix is
                # the narrow per-token strip the ticket asks for, not a
                # blanket strip that would happen to pass the same probe.
                tok="${tok//$'\r'/}"
                # Redirect-from-secret: authoritative for `<`-redirects and
                # independent of command position (e.g. `done <.env`).
                if [ "$prev" = "<" ] && is_secret_path "$tok"; then
                    block=1
                fi
                if [ -z "$cmdtok" ]; then
                    # Still hunting the command token: skip leading redirect
                    # tokens, env-assignments (VAR=val), common reader-wrapping
                    # commands, and shell keywords.
                    case "$tok" in
                        "<"|">")                            prev="$tok"; continue ;;
                        [A-Za-z_]*=*)                       prev="$tok"; continue ;;
                        sudo|doas|env|xargs|time|nice|command|nohup)
                                                            prev="$tok"; continue ;;
                        if|while|until|then|else|elif|"!")  prev="$tok"; continue ;;
                    esac
                    cmdtok="$tok"
                    if is_reader_cmd "$cmdtok"; then reader=1; fi
                    if is_interp_cmd "$cmdtok"; then interp=1; fi
                    if is_pattern_arg_cmd "$cmdtok"; then pattern_cmd=1; fi
                    at_pos0=1
                    prev="$tok"
                    continue
                fi
                # Past the command token: scan its arguments.
                this_at_pos0="$at_pos0"; at_pos0=0
                if is_inplace_token "$tok"; then inplace=1; fi
                # HIMMEL-2228: scan INSIDE a glued option token. Independent of the
                # exemption chain below (a glued value is never exempt — see header).
                # Gated on expect_pattern_val/expect_file_val (still holding the
                # PREVIOUS token's armed state here, before the chain below updates
                # them): a token already consumed as -f/-e's own value is an opaque
                # string to the target command, not itself parsed for a nested
                # flag=value — `grep -f --file=.env` must open a file literally
                # named `--file=.env`, not treat it as a second glued -f/--file.
                if [ "$expect_pattern_val" != "1" ] && [ "$expect_file_val" != "1" ] \
                    && glued_opt_secret "$tok"; then
                    secret_after=1; glued_tok="$tok"
                fi
                # HIMMEL-2213 round 5 (panel review of rounds 1-4): every
                # earlier cut tried to recognise "the flag before this token
                # doesn't consume a value" — -m/-A/-B/-C take a separate
                # numeric value, -f/-e take a separate file/pattern value,
                # and every other reader's own flags have their own arity —
                # and each attempt to special-case one more flag (-f, -e)
                # either left a still-unhandled flag free to leak a real
                # secret (`rg --ignore-file .env ...`, `rg --ignore-file
                # '.env' ...`) or wrongly treated a boring flag VALUE (`-m`'s
                # count) as though it were the pattern, stealing the
                # exemption before the real pattern arrived. There is no
                # bounded flag-arity table across grep/egrep/fgrep/rg/
                # ripgrep/ag/sed/awk/gawk/mawk/nawk that closes this for
                # good, so this cut stops trying: the exemption now applies
                # ONLY to the token immediately following the reader command
                # itself, with ZERO flags in between — a `<reader> '<pat>'
                # ...` shape has no room for "which flag consumes what" to
                # go wrong, because there is no flag to reason about. Any
                # flag before an otherwise-implicit pattern (`-rn '.env'`,
                # `-m 1 '.env'`) now falls back to the ordinary scan and may
                # false-block — the documented, ACCEPTED tradeoff (a false
                # positive costs a cycle; every false negative this design
                # ever had leaked). `-e`/`--regexp` is the one narrow,
                # unambiguous exception kept: by definition ITS VALUE is
                # ALWAYS a pattern, at whatever position it appears, so
                # exempting the token immediately after it (not just after
                # the bare command) is still fail-closed-safe — but ONLY for
                # a grep/sed/awk-family command (`pattern_cmd`): `-e` means
                # something else entirely (or nothing) for other readers —
                # `cat -e .env` (GNU cat's -e = -vE, display non-printing
                # chars) genuinely reads .env, and an earlier cut of this
                # gate applied the -e exemption unconditionally, false-
                # ALLOWing it (panel review, HIMMEL-2213 round 6).
                #
                # Round 7 (panel review): the round-5/6 cuts checked `prev`
                # against RAW TEXT ("-e"/"--regexp", or cmdtok's own name for
                # position 0). That is spoofable: `grep -f --regexp .env` —
                # `-f` consumes "--regexp" as ITS (nonsense) filename value,
                # but the text comparison couldn't tell that from a REAL
                # `--regexp` flag, so `.env` (the actual file grep -f left
                # over as a target) got wrongly exempted next. Position and
                # "was this token consumed as -f's value" are now tracked as
                # explicit STATE (at_pos0/expect_pattern_val/expect_file_val,
                # armed and consumed one token at a time) instead of being
                # inferred from a token's text — text an adversarial -f/-e
                # value can always be crafted to match, state cannot.
                if [ "$expect_pattern_val" = "1" ]; then
                    expect_pattern_val=0  # -e/--regexp's own value is always a pattern — data, never scanned.
                elif [ "$expect_file_val" = "1" ]; then
                    expect_file_val=0
                    is_secret_path "$tok" && secret_after=1  # -f/--file's own value is always a real read target.
                elif [ "$pattern_cmd" = "1" ] && { [ "$tok" = "-e" ] || [ "$tok" = "--regexp" ]; }; then
                    expect_pattern_val=1
                    is_secret_path "$tok" && secret_after=1  # "-e"/"--regexp" itself never matches a secret glob; harmless.
                elif [ "$tok" = "-f" ] || [ "$tok" = "--file" ]; then
                    expect_file_val=1
                    is_secret_path "$tok" && secret_after=1  # "-f"/"--file" itself never matches a secret glob; harmless.
                elif [ "$pattern_cmd" = "1" ] && [ "$this_at_pos0" = "1" ] \
                    && is_quoted_pattern_tok "$tok"; then
                    :  # the token right after the bare command, if quoted, is the implicit inline pattern.
                elif is_secret_path "$tok"; then
                    secret_after=1
                fi

                # HIMMEL-440: when the command is a shell interpreter, recurse
                # into its `-c '<body>'`. The body is real shell, so re-running
                # the reader+secret check on it is correct (and FP-free, unlike
                # node -e / python -c non-shell bodies). Only the FIRST
                # statement of the body needs this — any `;`/`|`/`&`-separated
                # later statements are already their own clauses.
                if [ "$interp" = "1" ]; then
                    if [ -z "$rec_cmd" ]; then
                        if [ "$found_c" = "0" ]; then
                            # Hunt for -c: skip interpreter flags; a -c or a
                            # combined trailing-c bundle (-lc, -ic, -xc) arms
                            # the next operand as the recursed command. A
                            # non-flag operand BEFORE any -c (`bash run.sh`)
                            # means this isn't a -c invocation → abort recursion.
                            case "$tok" in
                                --*)    : ;;
                                -c|-*c) found_c=1 ;;
                                -*)     : ;;
                                *)      interp=0 ;;
                            esac
                        else
                            # -c seen; the first non-flag operand is the body's
                            # command. Note the body's outer quote char so we can
                            # stop scanning at its close (everything after is
                            # $0/$1… positionals the body does not read). Strip
                            # ONE leading quote glued on by the quote-naive
                            # tokeniser (`'cat` → `cat`); bash-3.2-safe.
                            case "$tok" in
                                -*) : ;;
                                *)
                                    case "$tok" in
                                        \'*) bodyq="'" ;;
                                        \"*) bodyq='"' ;;
                                    esac
                                    rtok="${tok#\'}"; rtok="${rtok#\"}"
                                    rec_cmd="$rtok"
                                    if is_reader_cmd "$rec_cmd"; then rec_reader=1; fi
                                    if is_pattern_arg_cmd "$rec_cmd"; then rec_pattern_cmd=1; fi
                                    rec_at_pos0=1
                                    # Unquoted single-word body (`bash -c cat .env`)
                                    # has no args of its own — the rest are
                                    # positionals. Mark the body already closed.
                                    [ -z "$bodyq" ] && bodyclosed=1
                                    ;;
                            esac
                        fi
                    elif [ "$bodyclosed" = "0" ]; then
                        # Inside the body: scan ITS args. is_secret_path already
                        # strips one trailing quote (`.env'` → `.env`).
                        this_rec_at_pos0="$rec_at_pos0"; rec_at_pos0=0
                        if is_inplace_token "$tok"; then rec_inplace=1; fi
                        # HIMMEL-2228: same glued-token scan as the outer clause loop,
                        # applied to the recursed -c body, same armed-state gate (see
                        # the outer loop's comment above).
                        if [ "$rec_expect_pattern_val" != "1" ] && [ "$rec_expect_file_val" != "1" ] \
                            && glued_opt_secret "$tok"; then
                            rec_secret=1; glued_tok="$tok"
                        fi
                        # HIMMEL-2213 round 7: same explicit-STATE rule as the
                        # outer clause above (position + "was this token just
                        # consumed as -f/--file's value" tracked as state, not
                        # inferred from a token's spoofable raw text).
                        if [ "$rec_expect_pattern_val" = "1" ]; then
                            rec_expect_pattern_val=0
                        elif [ "$rec_expect_file_val" = "1" ]; then
                            rec_expect_file_val=0
                            is_secret_path "$tok" && rec_secret=1
                        elif [ "$rec_pattern_cmd" = "1" ] && { [ "$tok" = "-e" ] || [ "$tok" = "--regexp" ]; }; then
                            rec_expect_pattern_val=1
                            is_secret_path "$tok" && rec_secret=1
                        elif [ "$tok" = "-f" ] || [ "$tok" = "--file" ]; then
                            rec_expect_file_val=1
                            is_secret_path "$tok" && rec_secret=1
                        elif [ "$rec_pattern_cmd" = "1" ] && [ "$this_rec_at_pos0" = "1" ] \
                            && is_quoted_pattern_tok "$tok"; then
                            :  # the token right after the bare body command, if quoted, is the implicit inline pattern.
                        elif is_secret_path "$tok"; then
                            rec_secret=1
                        fi
                        # A token bearing the body's closing quote ends the body;
                        # subsequent tokens are positionals (`bash -c 'cat x' .env`
                        # — the `.env` is $0, never read). Quote-naive: matches the
                        # outer quote only (escaped/nested quotes are accepted gaps).
                        case "$tok" in
                            *\') [ "$bodyq" = "'" ] && bodyclosed=1 ;;
                            *\") [ "$bodyq" = '"' ] && bodyclosed=1 ;;
                        esac
                    fi
                fi
                prev="$tok"
            done
            # A clause leaks only when its COMMAND is a reader and a secret
            # follows as an arg. In-place sed/awk rewrites (carved per-clause,
            # so a global `-i` can't mask a separate read clause) don't leak.
            if [ "$reader" = "1" ] && [ "$secret_after" = "1" ] && [ "$inplace" = "0" ]; then
                block=1
            fi
            # HIMMEL-440: the recursed interpreter `-c` body leaked a secret.
            if [ "$rec_reader" = "1" ] && [ "$rec_secret" = "1" ] && [ "$rec_inplace" = "0" ]; then
                block=1
            fi
        done <<EOF
$normalized
EOF

        if [ "$block" = "1" ]; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing $tool command that reads a secret file:" >&2
            echo "    $cmd" >&2
            bypass_hint
            if [ -n "$glued_tok" ]; then glued_hint "$glued_tok"; fi
            # `if`, not `&& pattern_hint`: under `set -e` a top-level `a && b`
            # whose left side fails takes the whole list's non-zero status and
            # would exit 1 here, turning a deny (2) into a wrong rc.
            if pattern_hint_applies "$cmd"; then pattern_hint; fi
            exit 2
        fi
        ;;

    *)
        exit 0
        ;;
esac

exit 0
