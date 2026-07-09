#!/usr/bin/env bash
# scripts/guardrails/graphify-fence.sh - structural data-egress fence for
# `graphify` invocations (HIMMEL-621/622 Phase G-F).
#
# Invoked with ONE arg: the shell command string. It acts ONLY when that
# command invokes `graphify` in COMMAND POSITION; a bare mention (a grep/echo
# argument, a substring of a path) exits 0 (not its job). For a real graphify
# invocation it:
#   1. splits the command into clauses (on ;  |  &&  ||  &  newline) and, for
#      each clause whose command-position token is graphify, parses the REAL
#      subcommand grammar `graphify <subcommand> <path...> [--backend=x]`:
#      the subcommand token is skipped (never classified) UNLESS the first
#      positional is itself path-like (then it IS classified, not swallowed as a
#      subcommand word); EVERY subsequent bare (non-flag) path-like token is
#      normalized + classified against the corpus roots; MOST-RESTRICTIVE-WINS
#      across all classified tokens (salus > luna-personal > luna-clippings >
#      handover-state > himmel-code). ANY subcommand carrying a path-like token
#      that does NOT classify -> DENY (fail closed); the extraction-subcommand
#      list is now defense-in-depth commentary, not the gate. If the invocation
#      has NO path-like token (e.g. `query "question"`) the CWD corpus is
#      classified instead (the graph in cwd derives from the corpus around it).
#   2. resolves the backend -> provider. When `--backend` is ABSENT the fence
#      cannot see which provider graphify's own cloud-key auto-detect will pick,
#      so it DENIES unless the effective corpus is himmel-code (which defaults to
#      local-ollama and is allowed); every other corpus demands explicit
#      --backend.
#   3. evaluates scripts/guardrails/egress-matrix.json at purpose="extraction"
#      via egress-matrix-eval.mjs (single source of first-match-wins semantics).
#   4. allow -> continue; allow+log / allowed-conditional -> append a JSONL
#      ledger line to ~/.claude/graphify-egress.jsonl (a failed append DENIES -
#      allow+log requires the ledger line); deny -> print a one-line reason
#      naming the matrix cell and exit 2. ANY denied clause denies overall.
#
# FAIL CLOSED throughout: an unparseable command-position invocation, an
# unclassifiable path-like token, an unclassifiable cwd, an unreadable PHI root
# list, a missing node, an unwritable ledger, a no-backend non-himmel corpus,
# graphify deferred through xargs/find -exec, or any non-allow verdict all DENY.
# An EXIT trap converts any abnormal exit (anything other than 0 or 2) into a
# fail-closed exit 2.
#
# Opt-in env vars (the two `conditional` matrix cells graphify can reach at
# purpose=extraction; set in the launching shell, not per-call):
#   GRAPHIFY_SALUS_LOCAL_OK=1     - allow salus corpus x local-ollama (per-run
#                                   opt-in; PHI stays on-machine but even local
#                                   salus extraction needs an explicit opt-in).
#   GRAPHIFY_CLIPPINGS_GLM_OK=1   - allow luna-clippings corpus x zai-glm
#                                   (the pre-existing narrow clipped-public-web
#                                   content exception).
# Neither flag can flip a hard-deny cell (salus x any cloud, gemini anywhere).
#
# Backend -> provider map (backend name is lower-cased first):
#   ollama          -> local-ollama, UNLESS OLLAMA_HOST points off-box
#                      (not localhost/127.0.0.1/[::1], with or without port) ->
#                      undeclared `ollama` (falls to matrix default deny)
#   deepseek        -> deepseek
#   openai          -> deepseek ONLY when OPENAI_BASE_URL or DEEPSEEK_BASE_URL
#                      points at api.deepseek.com; otherwise the undeclared
#                      `openai` (falls to matrix default deny)
#   glm | zai       -> zai-glm
#   gemini | google -> google-gemini
#   anything else   -> the literal backend string (undeclared -> default deny)
#
# Test overrides (mirror parity_guard's CLAUDE_GLM_CONFIG_DIR posture; let the
# hermetic suite point at a temp tree without touching real state):
#   CLAUDE_GLM_CONFIG_DIR  - PHI root-list dir (default ~/.config/claude-glm)
#   LUNA_VAULT / LUNA_VAULT_PATH - luna vault root
#   HANDOVER_DIR           - handover state root (via handover-path.sh)
#   GRAPHIFY_HIMMEL_ROOT   - himmel checkout root (default: git toplevel here)
#   GRAPHIFY_LEDGER        - ledger path (default ~/.claude/graphify-egress.jsonl)
#
# Exit codes: 0 = allow (ledger written where the matched cell requires it);
# 2 = deny (stderr carries the reason).
#
# NOW HANDLED (closed in the HIMMEL-621 hardening round, no longer limitations):
# command-position wrappers (exec/nohup/timeout/sudo/env -i/stdbuf/nice/time/
# command/builtin, chained), graphify reached via xargs / find -exec (DENIED
# outright as not statically fenceable), a backslash-escaped `\graphify`, and a
# position-0 path-like token (classified, not swallowed as the subcommand).
#
# NOW HANDLED (HIMMEL-778):
#   - MSYS drive-path normalization: `_normalize` translates a leading MSYS-form
#     `/c/...` (or bare `/c`) into drive-lettered `c:/...` so an MSYS candidate
#     and the Bash tool's always-MSYS $PWD match the drive-lettered corpus roots
#     (git prints `C:/...`). Before this, even `graphify --version` in the himmel
#     checkout was denied via the unclassifiable-cwd fallback.
#   - Staged-copy corpus declaration: a `.graphify-corpus` marker file at or above
#     an otherwise-unclassifiable target path declares the ORIGIN corpus of the
#     staged scratchpad COPIES the 621/622 plan runs extraction on (a copy
#     classifies as nothing without it). First line trimmed = one of
#     salus|luna-personal|luna-clippings|handover-state|himmel-code; anything else
#     (empty, unknown) or an unreadable marker DENIES. Precedence: (1) `.salus`/PHI
#     roots beat it, (2) the real luna/handover/himmel roots beat it (a marker
#     inside a real vault can NOT relax classification), (3) it is consulted ONLY
#     for otherwise-unclassifiable paths, (4) no marker -> the pre-existing
#     unclassifiable DENY. An invocation in which ANY classified token was
#     marker-derived (invocation-wide, not only the rank-winning token, so
#     argument ordering cannot suppress the audit) ALWAYS appends a ledger line
#     on every ALLOW-family verdict (allow / allow+log / conditional - a deny
#     already blocks the egress), even on a plain `allow` cell, so a
#     mis-declared marker cannot also dodge the audit trail. The marker is
#     consulted ONLY when a luna root is configured (LUNA_VAULT/LUNA_VAULT_PATH
#     non-empty): precedence rule (2) depends on the fence SEEING the real
#     roots, so an unconfigured luna root makes the marker INERT
#     (unclassifiable -> deny, the pre-marker behavior). Residual: a
#     configured-luna machine with an UNCONFIGURED handover root could still
#     have handover content relabeled by a planted marker - accepted (work
#     artifacts, lower sensitivity than vault content; always-ledgered).
#
# Accepted static-analysis limitations (the load-bearing PHI guard is the
# file-tool fence parity_guard, not this command-text guard):
#   (a) quoted-separator mis-split - a path with embedded spaces, or a quoted
#       `;`/`|`/`&`, is word-split naively, so a truncated token can still land
#       under a corpus root. Two structural margins keep this safe-direction:
#       corpus classification is PREFIX-ANCHORED (a fragment classifies only if
#       it still normalizes UNDER a corpus root), and most-restrictive-wins plus
#       the unconditional unclassifiable-path-like DENY bias every ambiguous
#       split toward deny. Residual: a truncated fragment that happens to
#       normalize under an ALLOW corpus root (himmel-code) - a mis-classify that
#       loosens, though the salus corpus is `.salus`-marker + PHI-root anchored
#       so a partial salus path stays PHI as long as the fragment reaches a
#       marked ancestor.
#   (b) `$GRAPHIFY update ...` - variable indirection of the binary itself is
#       out of static reach and is NOT fenced.
#   (c) PowerShell - the hook routes PowerShell commands here too, but they are
#       parsed with POSIX word-splitting; a PowerShell-only quoting/escaping
#       form can mis-parse. Mis-parses land safe-direction (a mis-split path-like
#       token is unclassifiable -> DENY, not a silent allow).
#   (d) MSYS translation is unconditional (no OS sniff) and applies to the
#       LEXICAL comparison form only: on Linux a genuine `/x/...` single-letter
#       -rooted path translates to `x:/...` on BOTH sides of a root comparison
#       (candidate and configured root normalize identically), so root matching
#       still works; a translated candidate against a non-single-letter POSIX
#       root simply fails to match -> DENY. Filesystem stat-walks (.salus /
#       .graphify-corpus markers) deliberately use the ORIGINAL untranslated
#       path (see classify()), so a PHI marker on a real POSIX `/x/...` root is
#       still found.
#   (e) `.graphify-corpus` is origin-BLIND: a scratchpad copy carries no proof of
#       where it came from, so a marker mis-declaration is possible and accepted.
#       The load-bearing PHI guard is parity_guard / the file-tool fence, not this
#       command-text guard; the always-on ledger line (`"declared":true`) keeps a
#       mis-declaration auditable even when the matrix verdict is a plain allow.
set -uo pipefail
set -f  # no pathname expansion when we word-split the command / a path

# Arm the fail-closed EXIT trap BEFORE any $HOME (or other) expansion so an
# unbound-var abort under `set -u` becomes a clean deny (exit 2) rather than a
# non-blocking rc=1 the hook would let through.
# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT`
_on_exit() {
    local rc=$?
    case "$rc" in
        0|2) exit "$rc" ;;
        *)   echo "graphify-fence: DENY abnormal exit (rc=$rc); fail-closed" >&2; exit 2 ;;
    esac
}
trap _on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_HELPER="$SCRIPT_DIR/egress-matrix-eval.mjs"

CMD="${1:-}"

PHI_CONFIG_DIR="${CLAUDE_GLM_CONFIG_DIR:-$HOME/.config/claude-glm}"
LEDGER="${GRAPHIFY_LEDGER:-$HOME/.claude/graphify-egress.jsonl}"
LUNA_ROOT="${LUNA_VAULT:-${LUNA_VAULT_PATH:-}}"

HANDOVER_ROOT=""
HANDOVER_LIB="$SCRIPT_DIR/../lib/handover-path.sh"
if [ -f "$HANDOVER_LIB" ]; then
    # shellcheck source=../lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$HANDOVER_LIB"
    HANDOVER_ROOT="$(handover_root 2>/dev/null || true)"
fi

HIMMEL_ROOT="${GRAPHIFY_HIMMEL_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

# Extraction-shaped subcommands (defense-in-depth commentary, NOT the gate as of
# HIMMEL-621): update label cluster-only add merge-graphs merge-driver path.
# ANY subcommand carrying an unclassifiable path-like token now DENIES.

deny() { # <reason>
    echo "graphify-fence: DENY $1" >&2
    exit 2
}

# --- path helpers (pure bash, bash 3.2-safe) --------------------------------

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _strip_wrap <token> -> strip one layer of surrounding quotes/backticks (the
# tokeniser is quote-naive; a path token may arrive as `"path` or `path"`).
_strip_wrap() {
    local p="$1"
    p="${p%\"}"; p="${p#\"}"
    p="${p%\'}"; p="${p#\'}"
    p="${p%\`}"; p="${p#\`}"
    printf '%s' "$p"
}

# _strip_cmd <token> -> aggressive strip for COMMAND-POSITION identification:
# remove every quote / backtick / `$` / `(` / `)` / backslash so a wrapped,
# command-substituted, or backslash-escaped binary (`"graphify`, `\graphify`,
# `$(which graphify)`, backtick form) is compared on its bare name.
_strip_cmd() {
    local t="$1"
    t="${t//\"/}"; t="${t//\'/}"; t="${t//\`/}"
    t="${t//\$/}"; t="${t//(/}";  t="${t//)/}"
    t="${t//\\/}"
    printf '%s' "$t"
}

# _abs <path> -> absolute path (expanduser + anchor a relative path to PWD).
_abs() {
    local p; p="$(_strip_wrap "$1")"
    # Backslashes -> forward slashes BEFORE the absolute/relative split
    # (HIMMEL-808): on POSIX a backslash-form target ('\tmp\x' or 'C:\x')
    # matches neither /* nor [A-Za-z]:* below, gets anchored to cwd, and
    # normalizes to a non-corpus path -> allow. Windows-payload parity on
    # every host; fail-closed for the rare POSIX filename containing a
    # literal backslash (_normalize already collapses them the same way).
    p="${p//\\//}"
    # shellcheck disable=SC2088 # the "~/" is a literal case-pattern, not an expansion
    case "$p" in
        "~")   p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*)          : ;;             # POSIX absolute
        [A-Za-z]:/*) : ;;             # Windows drive-ROOTED absolute (C:/...)
        [A-Za-z]:*)  p="$PWD/${p#?:}" ;;
                     # Windows drive-RELATIVE (C:foo = foo relative to the
                     # cwd on drive C). HIMMEL-808: the old [A-Za-z]:* arm
                     # classified this absolute, and _normalize mangled it
                     # into a synthetic non-corpus path. Anchor to the
                     # current cwd instead - exact when cwd is on that drive
                     # (the attack shape), and a fail-closed lexical
                     # approximation otherwise.
        *)           p="$PWD/$p" ;;   # relative -> anchor to cwd
    esac
    printf '%s' "$p"
}

# _normalize <abs-path> -> lexically normalized, forward-slashed (collapse
# `.` / `..` segments so a `Clippings/../../salus` traversal cannot mis-match a
# corpus by raw string prefix). Lexical only - no symlink resolution.
_normalize() {
    local p="$1"
    p="${p//\\//}"   # backslashes -> forward slashes (Windows paths)
    # MSYS drive-path form -> drive-lettered form: `/c/Users` -> `c:/Users`,
    # bare `/c` -> `c:/`. Corpus roots resolve drive-lettered (git prints
    # `C:/...`) and the Bash tool's $PWD is always MSYS-form on Windows, so an
    # untranslated MSYS candidate never matches a root. Unconditional (no OS
    # sniff): on Linux a genuine `/x/...` path is translated then simply fails
    # to match POSIX roots -> deny, the same fail-closed outcome as today
    # (accepted limitation, see header). bash 3.2-safe substring ops.
    case "$p" in
        /[A-Za-z]/*) p="${p:1:1}:/${p:3}" ;;
        /[A-Za-z])   p="${p:1:1}:/" ;;
    esac
    local prefix=""
    case "$p" in
        [A-Za-z]:/*) prefix="${p%%:*}:"; p="${p#[A-Za-z]:}" ;;
    esac
    local seg result="" oldIFS="$IFS"
    IFS='/'
    # shellcheck disable=SC2086 # intentional split on '/'
    set -- $p
    IFS="$oldIFS"
    for seg in "$@"; do
        case "$seg" in
            ''|.) : ;;
            ..)   result="${result%/*}" ;;
            *)    result="$result/$seg" ;;
        esac
    done
    printf '%s%s' "$prefix" "${result:-/}"
}

# _under_root <path> <root> -> 0 if path == root or a descendant of root.
_under_root() {
    local p r
    p="$(_lc "$(_normalize "$1")")"
    r="$(_lc "$(_normalize "$2")")"
    [ -n "$r" ] || return 1
    r="${r%/}"
    case "$p/" in "$r/"*) return 0 ;; esac
    return 1
}

# _salus_marked <abs-path> -> 0 if a `.salus` marker sits at the path or any
# ancestor directory (a path anywhere inside a PHI vault is PHI).
_salus_marked() {
    local d="$1" prev=""
    [ -d "$d" ] || d="${d%/*}"
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
        if [ -e "$d/.salus" ]; then return 0; fi
        prev="$d"
        d="${d%/*}"
    done
    return 1
}

# _graphify_corpus_marker <abs-path> -> ancestor-walk (exactly like _salus_marked:
# from the path, or its parent dir if not a directory, up to filesystem root)
# for a `.graphify-corpus` marker that declares the ORIGIN corpus of a staged
# scratchpad copy (621/622 mandates extraction runs on copies, never live
# vaults; a copy classifies as nothing without this). First marker found wins.
# Echoes ONE of:
#   ""                                      no marker found
#   "declared<TAB><corpus>"                 first line is a valid corpus name
#   "__marker_unreadable__<TAB><markerpath>" marker exists but is not a readable regular file
#   "__marker_bad__<TAB><markerpath><TAB><content>" empty / unknown first line
_graphify_corpus_marker() {
    local d="$1" prev="" mk line
    [ -d "$d" ] || d="${d%/*}"
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
        mk="$d/.graphify-corpus"
        if [ -e "$mk" ]; then
            if ! { [ -f "$mk" ] && [ -r "$mk" ]; }; then
                printf '__marker_unreadable__\t%s' "$mk"; return
            fi
            # `read` exits non-zero on a final line lacking a trailing newline
            # but still populates the variable - do NOT clear it on failure (a
            # `printf 'luna-personal' >` marker is valid). Pre-clear instead.
            line=""
            IFS= read -r line < "$mk" || :
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
            line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
            case "$line" in
                salus|luna-personal|luna-clippings|handover-state|himmel-code)
                    printf 'declared\t%s' "$line" ;;
                *)  printf '__marker_bad__\t%s\t%s' "$mk" "$line" ;;
            esac
            return
        fi
        prev="$d"
        d="${d%/*}"
    done
    return 0
}

# _under_any_list <abs-path> <listfile> -> echoes hit | miss | unreadable.
_under_any_list() {
    local p="$1" listfile="$2" root
    [ -e "$listfile" ] || { echo miss; return; }
    { [ -f "$listfile" ] && [ -r "$listfile" ]; } || { echo unreadable; return; }
    while IFS= read -r root || [ -n "$root" ]; do
        root="${root%$'\r'}"
        root="${root%/}"; root="${root%\\}"
        [ -n "$root" ] || continue
        if _under_root "$p" "$root"; then echo hit; return; fi
    done < "$listfile"
    echo miss
}

# classify <target-path> -> echoes corpus, "__unreadable__", or "" (unclassifiable).
classify() {
    local apfs ap name rc mk
    # Two forms of the same path: apfs = the ORIGINAL absolute form, used for
    # every FILESYSTEM check (.salus / .graphify-corpus ancestor stat-walks -
    # on a POSIX box a real `/c/...` path only exists in this form; the
    # drive-translated `c:/...` string would stat nothing and silently skip a
    # PHI marker). ap = the lexically normalized form, used for STRING root
    # comparison only (_under_root/_under_any_list normalize both sides, so
    # the comparison stays consistent).
    apfs="$(_abs "$1")"
    ap="$(_normalize "$apfs")"
    if _salus_marked "$apfs"; then echo salus; return; fi
    for name in phi-roots egress-denylist; do
        rc="$(_under_any_list "$ap" "$PHI_CONFIG_DIR/$name")"
        if [ "$rc" = unreadable ]; then echo "__unreadable__"; return; fi
        if [ "$rc" = hit ]; then echo salus; return; fi
    done
    if [ -n "$LUNA_ROOT" ] && _under_root "$ap" "$LUNA_ROOT"; then
        if _under_root "$ap" "$LUNA_ROOT/Clippings"; then
            echo luna-clippings
        else
            echo luna-personal
        fi
        return
    fi
    if [ -n "$HANDOVER_ROOT" ] && _under_root "$ap" "$HANDOVER_ROOT"; then echo handover-state; return; fi
    if [ -n "$HIMMEL_ROOT" ] && _under_root "$ap" "$HIMMEL_ROOT"; then echo himmel-code; return; fi
    # LAST RESORT ONLY (precedence: .salus/PHI beat everything above; the real
    # luna/handover/himmel roots beat this - a marker inside a CONFIGURED vault
    # can NOT relax classification). Consult a `.graphify-corpus` staging marker
    # so a scratchpad COPY can declare its origin corpus. Marker-derived hits
    # carry an `@declared` suffix (callers strip it, but always ledger the
    # invocation).
    # GATED on a configured luna root (silent-failure CR round): the real-root-
    # beats-marker guarantee for the most sensitive non-PHI corpus depends on
    # LUNA_VAULT/LUNA_VAULT_PATH being set - with it EMPTY the luna branch above
    # is skipped and a marker planted inside the (invisible) vault could relax
    # luna content to an allow corpus. No luna root -> the marker is INERT and
    # the path stays unclassifiable -> deny (exact pre-marker behavior).
    # (.salus/PHI-root protection above is env-independent and unaffected.)
    if [ -n "$LUNA_ROOT" ]; then
        mk="$(_graphify_corpus_marker "$apfs")"
        case "$mk" in
            declared$'\t'*)          echo "${mk#declared$'\t'}@declared"; return ;;
            __marker_unreadable__*)  echo "$mk"; return ;;
            __marker_bad__*)         echo "$mk"; return ;;
        esac
    fi
    echo ""
}

# _rank <corpus> -> restrictiveness rank (higher = more restrictive).
_rank() {
    case "$1" in
        salus)          echo 5 ;;
        luna-personal)  echo 4 ;;
        luna-clippings) echo 3 ;;
        handover-state) echo 2 ;;
        himmel-code)    echo 1 ;;
        *)              echo 0 ;;
    esac
}

# is_path_like <stripped-token> -> 0 if the token looks like a filesystem path
# (NOT a URL, which is remote content pulled IN, not a corpus path).
is_path_like() {
    local t="$1"
    case "$t" in
        *://*) return 1 ;;                       # scheme://host - a URL, not a path
    esac
    case "$t" in
        */*|*\\*)     return 0 ;;              # any slash (covers ~/foo too)
        "."|"..")     return 0 ;;
        [A-Za-z]:*)   return 0 ;;
        *.md|*.markdown|*.json|*.txt|*.py|*.js|*.ts|*.sh|*.html|*.htm|*.csv|*.yaml|*.yml|*.toml|*.rs|*.go|*.java|*.rb|*.c|*.h|*.cpp)
                      return 0 ;;
    esac
    return 1
}

# NO-BACKEND policy (HIMMEL-621): when `--backend` is absent the fence cannot
# see which provider graphify's own cloud-key auto-detect will select (the key
# list DEEPSEEK_API_KEY/ZAI_API_KEY/DASHSCOPE_API_KEY/OPENAI_API_KEY/... is
# graphify-internal). So the rule is corpus-based, not key-sniffing: no-backend
# is allowed ONLY for the himmel-code corpus (defaults to local-ollama); every
# other corpus DENIES and demands an explicit --backend. See apply_verdict.

# _ollama_local -> 0 if OLLAMA_HOST is unset or points at the local box.
_ollama_local() {
    local h="${OLLAMA_HOST:-}"
    [ -n "$h" ] || return 0
    h="$(_lc "$h")"
    h="${h#http://}"; h="${h#https://}"
    case "$h" in
        localhost|localhost:*|127.0.0.1|127.0.0.1:*|'[::1]'|'[::1]:'*|::1|::1:*) return 0 ;;
        *) return 1 ;;
    esac
}

# map_provider <backend(lowercased)> -> echoes provider (may be undeclared literal).
map_provider() {
    local b="$1" hit=0
    case "$b" in
        ollama)
            if _ollama_local; then echo local-ollama; else echo ollama; fi
            ;;
        deepseek)      echo deepseek ;;
        openai)
            case "${OPENAI_BASE_URL:-}"   in *api.deepseek.com*) hit=1 ;; esac
            case "${DEEPSEEK_BASE_URL:-}" in *api.deepseek.com*) hit=1 ;; esac
            if [ "$hit" = 1 ]; then echo deepseek; else echo openai; fi
            ;;
        glm|zai)       echo zai-glm ;;
        gemini|google) echo google-gemini ;;
        *)             echo "$b" ;;
    esac
}

# _json_escape <string> -> JSON-safe (backslash, quote, and control chars).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ledger_append <path> <corpus> <backend> <provider> <verdict> [declared] -> 0 on
# a durable write, 1 on any failure (unwritable dir / file). Callers DENY on
# failure: an allow+log verdict without its ledger line is not allowed. When the
# optional 6th arg is "1" (ANY token in the invocation classified via a
# `.graphify-corpus` marker - invocation-wide, not just the winning token) an
# extra `"declared":true` field is emitted so a mis-declared marker cannot dodge
# audit.
ledger_append() {
    local dir ts ep decl=""
    [ "${6:-}" = 1 ] && decl=',"declared":true'
    dir="$(dirname "$LEDGER")"
    mkdir -p "$dir" || return 1
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%s)"
    ep="$(_json_escape "$1")"
    printf '{"ts":"%s","path":"%s","corpus":"%s","backend":"%s","provider":"%s","verdict":"%s","tool":"graphify"%s}\n' \
        "$ts" "$ep" "$2" "$3" "$4" "$5" "$decl" >> "$LEDGER" || return 1
    return 0
}

# apply_verdict <corpus> <target> <backend-raw> [declared] -> return 0 (allow,
# ledger written where required) or DENY (exit 2). When <declared> is 1 ANY
# classified token in the invocation came from a `.graphify-corpus` marker
# (invocation-wide - not only the rank-winning token, so argument ordering
# cannot suppress the audit): ALWAYS ledger the run, even on a plain `allow`
# cell (a mis-declared marker must not also dodge audit).
apply_verdict() {
    local corpus="$1" target="$2" backend_raw="$3" declared="${4:-0}"
    local backend_effective provider verdict everr eout emsg optvar optval

    if [ -z "$backend_raw" ]; then
        if [ "$corpus" != "himmel-code" ]; then
            deny "pass --backend explicitly (graphify auto-detects cloud keys; the fence cannot see which) [corpus=$corpus]"
        fi
        backend_effective="ollama"
    else
        backend_effective="$(_lc "$(_strip_wrap "$backend_raw")")"
    fi
    provider="$(map_provider "$backend_effective")"

    command -v node >/dev/null 2>&1 || deny "node not found; cannot evaluate the egress matrix (fail-closed)"

    everr="$(mktemp 2>/dev/null || echo "")"
    if [ -n "$everr" ]; then
        if eout="$(node "$EVAL_HELPER" "$corpus" "$provider" extraction 2>"$everr")"; then
            :
        else
            emsg="$(tr '\n' ' ' < "$everr" 2>/dev/null)"
            rm -f "$everr"
            deny "egress matrix eval failed for $corpus x $provider x extraction: $emsg (fail-closed)"
        fi
        rm -f "$everr"
    else
        eout="$(node "$EVAL_HELPER" "$corpus" "$provider" extraction 2>&1)" \
            || deny "egress matrix eval failed for $corpus x $provider x extraction: $eout (fail-closed)"
    fi
    verdict="${eout%%$'\t'*}"

    case "$verdict" in
        allow)
            if [ "$declared" = 1 ]; then
                ledger_append "$target" "$corpus" "$backend_effective" "$provider" "allow" 1 \
                    || deny "declared-corpus audit requires the ledger line (ledger unwritable): $corpus x $provider"
            fi
            return 0
            ;;
        allow+log)
            ledger_append "$target" "$corpus" "$backend_effective" "$provider" "allow+log" "$declared" \
                || deny "allow+log requires the ledger line (ledger unwritable): $corpus x $provider"
            return 0
            ;;
        conditional)
            case "$corpus/$provider" in
                salus/local-ollama)     optvar="GRAPHIFY_SALUS_LOCAL_OK";   optval="${GRAPHIFY_SALUS_LOCAL_OK:-}" ;;
                luna-clippings/zai-glm) optvar="GRAPHIFY_CLIPPINGS_GLM_OK"; optval="${GRAPHIFY_CLIPPINGS_GLM_OK:-}" ;;
                *) deny "$corpus x $provider x extraction is conditional with no known opt-in (fail-closed)" ;;
            esac
            if [ "$optval" = "1" ]; then
                ledger_append "$target" "$corpus" "$backend_effective" "$provider" "conditional" "$declared" \
                    || deny "conditional requires the ledger line (ledger unwritable): $corpus x $provider"
                return 0
            fi
            deny "$corpus x $provider x extraction requires opt-in $optvar=1 (matrix conditional cell)"
            ;;
        *)
            deny "$corpus x $provider x extraction -> $verdict (egress matrix)"
            ;;
    esac
}

# _deny_on_classify_sentinel <classify-output> - DENY (exit 2) for any fail-closed
# sentinel classify can echo. MUST be called from the main shell body, never in a
# $(...) subshell (deny's exit would only leave the subshell otherwise).
_deny_on_classify_sentinel() {
    local rest mkpath mkcontent
    case "$1" in
        __unreadable__)
            deny "a PHI root list under $PHI_CONFIG_DIR exists but is not readable (fail-closed)" ;;
        __marker_unreadable__$'\t'*)
            deny ".graphify-corpus marker ${1#__marker_unreadable__$'\t'} exists but is not a readable regular file (fail-closed)" ;;
        __marker_bad__$'\t'*)
            rest="${1#__marker_bad__$'\t'}"; mkpath="${rest%%$'\t'*}"; mkcontent="${rest#*$'\t'}"
            deny ".graphify-corpus marker $mkpath declares an invalid corpus: '$mkcontent' (must be salus|luna-personal|luna-clippings|handover-state|himmel-code)" ;;
    esac
}

# evaluate_invocation <arg-tokens...> - args are the tokens AFTER the graphify
# command word. Skips the subcommand, classifies path-like tokens
# (most-restrictive-wins), applies the CWD fallback, then applies the verdict.
evaluate_invocation() {
    local have_sub=0 subcmd="" want_backend=0 backend=""
    local unclassifiable=0 best_rank=-1 best_corpus="" best_target="" any_declared=0
    local tok st c r declared skip_redir_target=0

    for tok in "$@"; do
        if [ "$skip_redir_target" = 1 ]; then skip_redir_target=0; continue; fi
        case "$tok" in
            '>'|'>>'|'<'|[0-9]'>')
                # Standalone redirection: the NEXT token is its filename
                # target, not a graphify arg - skip both.
                skip_redir_target=1; continue ;;
            '>'*|'<'*|[0-9]'>'*)
                # Attached redirection ('>/tmp/out', '2>/dev/null', '>>log')
                # carries its own target: skip, do not classify (previously
                # read as an unclassifiable path -> false deny).
                # ('&>' can't occur: '&' is a clause splitter.)
                continue ;;
        esac
        if [ "$want_backend" = 1 ]; then backend="$tok"; want_backend=0; continue; fi
        case "$tok" in
            --backend)   want_backend=1; continue ;;
            --backend=*) backend="${tok#--backend=}"; continue ;;
        esac
        case "$tok" in
            -*) continue ;;                    # other flag
        esac
        if [ "$have_sub" = 0 ]; then
            st="$(_strip_wrap "$tok")"
            # Position-0 path (HIMMEL-621): if the first positional is itself
            # path-like it is a target, NOT a subcommand word - classify it
            # (fall through) instead of swallowing it. Otherwise it is the
            # subcommand token: record + skip (never classified).
            if ! is_path_like "$st"; then
                subcmd="$(_lc "$st")"; have_sub=1; continue
            fi
            have_sub=1
        fi
        st="$(_strip_wrap "$tok")"
        [ -n "$st" ] || continue
        is_path_like "$st" || continue          # non-path arg (node name, question, model)
        c="$(classify "$st")"
        _deny_on_classify_sentinel "$c"
        # The declared bit is INVOCATION-WIDE: ANY marker-derived token forces
        # the always-ledger audit, regardless of whether it wins the rank
        # comparison (else a real-root token of equal/higher rank listed first
        # would suppress the ledger line - argument ordering must not dodge audit).
        case "$c" in *@declared) c="${c%@declared}"; any_declared=1 ;; esac
        if [ -n "$c" ]; then
            r="$(_rank "$c")"
            if [ "$r" -gt "$best_rank" ]; then
                best_rank="$r"; best_corpus="$c"; best_target="$st"
            fi
        else
            # Unconditional (HIMMEL-621): an unclassifiable path-like token
            # denies for ANY subcommand, not only the extraction-shaped ones.
            unclassifiable=1
        fi
    done

    if [ "$unclassifiable" = 1 ]; then
        deny "unclassifiable path in graphify '$subcmd' invocation (fail-closed): $CMD"
    fi

    if [ -n "$best_corpus" ]; then
        apply_verdict "$best_corpus" "$best_target" "$backend" "$any_declared"
        return
    fi

    # No classified path-like token -> the corpus is the one around the CWD.
    c="$(classify "$PWD")"
    _deny_on_classify_sentinel "$c"
    declared=0
    case "$c" in *@declared) c="${c%@declared}"; declared=1 ;; esac
    [ -n "$c" ] || deny "unclassifiable cwd for graphify '$subcmd' (no classifiable path arg): $PWD"
    apply_verdict "$c" "$PWD" "$backend" "$declared"
}

# classify_clause <clause-tokens...> - resolve the command-position token of one
# clause; if it is graphify (bare, wrapped, substituted, or reached via
# bash -c/sh -c), dispatch its args to evaluate_invocation. A non-command-position
# mention is a no-op (return without evaluating).
classify_clause() {
    local n=$# i=0 raw s j k found fs inner seen_exec
    local -a toks args
    toks=("$@")

    # Skip leading env-var assignments (X=y) and command wrappers (HIMMEL-621),
    # so a wrapper set placed before graphify - exec / nohup / timeout 600 /
    # sudo / env -i / stdbuf -oL / ... - does not hide the invocation from the
    # command-position walk. Wrappers may chain (`sudo nohup timeout 600 ...`).
    while [ "$i" -lt "$n" ]; do
        raw="${toks[$i]}"; s="$(_strip_cmd "$raw")"
        case "$s" in
            [A-Za-z_]*=*)
                i=$((i+1)); continue ;;                    # leading VAR=val assignment
            command|exec|builtin|nohup|time|nice)
                i=$((i+1)); continue ;;                    # transparent wrapper (no args to consume)
            env)
                i=$((i+1))                                 # env [-i|-|-u VAR|X=y]... CMD
                while [ "$i" -lt "$n" ]; do
                    case "$(_strip_cmd "${toks[$i]}")" in
                        -u|--unset)   i=$((i+2)) ;;        # flag + VAR value
                        [A-Za-z_]*=*) i=$((i+1)) ;;        # env-local assignment
                        -*)           i=$((i+1)) ;;        # -i / - / --ignore-environment / ...
                        *)            break ;;
                    esac
                done
                continue ;;
            timeout)
                i=$((i+1))                                 # timeout [flags] DURATION CMD
                while [ "$i" -lt "$n" ]; do
                    case "$(_strip_cmd "${toks[$i]}")" in
                        -k|-s|--kill-after|--signal) i=$((i+2)) ;;  # flag + value
                        -*)                          i=$((i+1)) ;;  # -v / --preserve-status / =-form
                        *)                           break ;;
                    esac
                done
                [ "$i" -lt "$n" ] && i=$((i+1))            # consume the DURATION positional
                continue ;;
            stdbuf)
                i=$((i+1))                                 # stdbuf [-i|-o|-e MODE]... CMD
                while [ "$i" -lt "$n" ]; do
                    case "$(_strip_cmd "${toks[$i]}")" in
                        -i|-o|-e) i=$((i+2)) ;;            # bare short opt + separate MODE value
                        -*)       i=$((i+1)) ;;            # -oL combined / other flag
                        *)        break ;;
                    esac
                done
                continue ;;
            sudo)
                i=$((i+1))                                 # sudo [flags] CMD
                while [ "$i" -lt "$n" ]; do
                    case "$(_strip_cmd "${toks[$i]}")" in
                        -u|-g|-U|-p|-C|-r|-t|-h) i=$((i+2)) ;;       # flag + value
                        --)                      i=$((i+1)); break ;;  # end of sudo options
                        [A-Za-z_]*=*)            i=$((i+1)) ;;        # sudo-local VAR=val
                        -*)                      i=$((i+1)) ;;        # -n / -E / -H / -i / -s / ...
                        *)                       break ;;
                    esac
                done
                continue ;;
        esac
        break
    done
    [ "$i" -lt "$n" ] || return 0

    raw="${toks[$i]}"; s="$(_strip_cmd "$raw")"

    # xargs / find -exec (HIMMEL-621): graphify reached as a DEFERRED target of
    # xargs or find -exec/-execdir is not statically fenceable (the real arg
    # list is materialised at runtime). Fail closed - DENY outright rather than
    # attempt to parse the deferred invocation. A bare mention that is NOT the
    # deferred command (`find . -name graphify`) is left alone.
    case "$s" in
        xargs|*/xargs)
            j=$((i+1))
            while [ "$j" -lt "$n" ]; do
                case "$(_strip_cmd "${toks[$j]}")" in
                    graphify|*/graphify)
                        deny "graphify via xargs/find -exec is not statically fenceable; invoke graphify directly" ;;
                esac
                j=$((j+1))
            done
            return 0
            ;;
        find|*/find)
            j=$((i+1)); seen_exec=0
            while [ "$j" -lt "$n" ]; do
                case "$(_strip_cmd "${toks[$j]}")" in
                    -exec|-execdir) seen_exec=1 ;;
                    graphify|*/graphify)
                        [ "$seen_exec" = 1 ] && \
                            deny "graphify via xargs/find -exec is not statically fenceable; invoke graphify directly" ;;
                esac
                j=$((j+1))
            done
            return 0
            ;;
    esac

    # bash -c / sh -c: unwrap the inner command string and re-resolve it.
    case "$s" in
        bash|sh|*/bash|*/sh)
            j=$((i+1))
            while [ "$j" -lt "$n" ]; do
                fs="$(_strip_cmd "${toks[$j]}")"
                case "$fs" in
                    -c)
                        j=$((j+1)); inner=""
                        while [ "$j" -lt "$n" ]; do inner="$inner ${toks[$j]}"; j=$((j+1)); done
                        inner="$(_strip_cmd "$inner")"
                        # shellcheck disable=SC2086 # intentional re-split of the unwrapped command
                        set -- $inner
                        classify_clause ${1+"$@"}
                        return
                        ;;
                    -*) j=$((j+1)); continue ;;
                    *)  break ;;
                esac
            done
            return 0
            ;;
    esac

    # Command substitution in command position: $(which graphify) / `which graphify`.
    # shellcheck disable=SC2016 # literal `$(` / backtick case-patterns, not expansions
    case "$raw" in
        '$('*|'`'*)
            k="$i"; found=0
            while [ "$k" -lt "$n" ]; do
                case "$(_strip_cmd "${toks[$k]}")" in graphify|*/graphify) found=1 ;; esac
                case "${toks[$k]}" in *')'|*'`') k=$((k+1)); break ;; esac
                k=$((k+1))
            done
            if [ "$found" = 1 ]; then
                args=()
                while [ "$k" -lt "$n" ]; do args+=("${toks[$k]}"); k=$((k+1)); done
                evaluate_invocation ${args[@]+"${args[@]}"}
            fi
            return 0
            ;;
    esac

    # Plain command position.
    case "$s" in
        graphify|*/graphify)
            args=()
            j=$((i+1))
            while [ "$j" -lt "$n" ]; do args+=("${toks[$j]}"); j=$((j+1)); done
            evaluate_invocation ${args[@]+"${args[@]}"}
            ;;
    esac
    return 0
}

# --- main: split into clauses, evaluate every graphify command-position clause -
# Separators ;  |  &  (and && / ||, which collapse) and newlines become clause
# boundaries. Any denied clause exits 2 immediately; reaching the end = allow.
# Over-splitting here is safe: corpus classification is prefix-anchored, so a
# fragment produced by an aggressive split classifies only if it still lands
# under a corpus root; anything ambiguous falls to the unclassifiable DENY.
tmp="$CMD"
tmp="${tmp//;/$'\n'}"
tmp="${tmp//|/$'\n'}"
tmp="${tmp//&/$'\n'}"

while IFS= read -r clause || [ -n "$clause" ]; do
    [ -n "$clause" ] || continue
    # shellcheck disable=SC2086 # intentional word split for tokenisation
    set -- $clause
    [ "$#" -gt 0 ] || continue
    classify_clause "$@"
done <<< "$tmp"

exit 0
