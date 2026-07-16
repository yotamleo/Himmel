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
#   claude | claude-cli -> ENDPOINT-AWARE (HIMMEL-1049 + codex-adv-1): graphify's
#                      claude backend honors ANTHROPIC_BASE_URL, so classify by
#                      the effective endpoint, not the name -
#                        unset / api.anthropic.com -> anthropic (the operating
#                          harness itself; matrix allows it on every non-salus
#                          corpus, HARD-DENIES salus/PHI, so a claude-only adopter
#                          is WARNED-not-BLOCKED on ordinary corpora, salus blocked)
#                        EXACT host api.z.ai / open.bigmodel.cn (claude-glm sets
#                          ANTHROPIC_BASE_URL=https://api.z.ai/...) -> zai-glm
#                          (matrix cell + ledger apply; no silent
#                          Anthropic-labelled Z.ai egress)
#                        any other host (lookalikes, unknown gateways, the
#                          claude-routed loopback router) -> undeclared -> default
#                          deny. EXACT-host match, not substring (spoof-proof)
#   anything else   -> the literal backend string (undeclared -> default deny)
#
# Test overrides (mirror parity_guard's CLAUDE_GLM_CONFIG_DIR posture; let the
# hermetic suite point at a temp tree without touching real state):
#   CLAUDE_GLM_CONFIG_DIR  - PHI root-list dir (default ~/.config/claude-glm)
#   LUNA_VAULT / LUNA_VAULT_PATH - luna vault root
#   HANDOVER_DIR           - handover state root (via handover-path.sh)
#   GRAPHIFY_HIMMEL_ROOT   - himmel checkout root (default: git toplevel here)
#   GRAPHIFY_LEDGER        - ledger path (default ~/.claude/graphify-egress.jsonl)
#   GRAPHIFY_TOOL_CWD      - the cwd the command will run in (threaded from the
#                            hook payload's .tool_input.cwd; default $PWD).
#                            HIMMEL-779: relative + bare-word targets resolve
#                            against THIS, not the hook process's $PWD.
#   GRAPHIFY_DECLARED_BACKEND - a backend declared out-of-band when the CLI form
#                            carries no --backend (graphify `update` is LLM-free
#                            and takes none). HIMMEL-779: satisfies the no-backend
#                            demand for a non-himmel corpus AND still flows through
#                            the egress matrix (not a bypass). SCOPED (HIMMEL-779 CR
#                            round-1): honored ONLY when (a) the subcommand is one
#                            of the LLM-free set (today: exactly `update`, see
#                            _llm_free_subcmd) AND (b) the corpus is non-himmel -
#                            for himmel-code with no flag the local-ollama default
#                            stands unconditionally; a declared value can NOT
#                            override it. A provider-using (non-LLM-free) subcommand
#                            with no --backend still hits the existing no-backend
#                            deny even when this is set - it is not a substitute for
#                            a real --backend on a subcommand whose CLI accepts one.
#                            Like GRAPHIFY_SALUS_LOCAL_OK/GRAPHIFY_CLIPPINGS_GLM_OK
#                            above, this is a launching-shell-only trust boundary:
#                            set it in the shell that launches the agent, not
#                            per-call. HIMMEL-881: a `.graphify-backend` file
#                            alongside the `.graphify-corpus` marker is a second,
#                            in-session way to satisfy the same declaration (see
#                            the HIMMEL-881 NOW HANDLED note below) - this env var
#                            still wins when BOTH are present.
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
# NOW HANDLED (HIMMEL-779):
#   - Bare-word target swallowed: a bare (no slash/drive/extension) token that
#     EXISTS under the tool-call cwd is a TARGET, classified against the corpus
#     roots - not swallowed as a subcommand word (position 0) nor skipped as a
#     non-path arg (later positions). Before, a bare PHI dir name alongside a
#     safe path (or inside a safe cwd) let the safe path/cwd win -> fail-open.
#   - Hook-cwd relative-path mismatch: the fence resolves relative paths against
#     the TOOL-CALL cwd (GRAPHIFY_TOOL_CWD, threaded from the hook payload's
#     .tool_input.cwd), not its own $PWD. Under hook invocation the fence $PWD is
#     the project root, which is not necessarily the command's cwd - a relative
#     path into a protected corpus otherwise resolved under the project root and
#     missed (fail-open). The block-graphify-egress hook threads .tool_input.cwd.
#   - update-subcommand / --backend: graphify `update` (and other LLM-free
#     subcommands) take NO --backend on the CLI, so a non-himmel corpus could
#     never satisfy the no-backend demand. A declared backend via env
#     (GRAPHIFY_DECLARED_BACKEND) now satisfies it and still flows through the
#     egress matrix (not a bypass). SCOPED (CR round-1): honored only when the
#     subcommand is in the LLM-free set (_llm_free_subcmd; today: exactly
#     `update`) AND the corpus is non-himmel - it previously applied to ANY
#     subcommand/corpus whenever the env var was set, which let a declared
#     backend override the himmel-code local-ollama default and let a
#     provider-using subcommand skip the missing-flag deny. Now a
#     provider-using subcommand with no --backend still denies even with the
#     env var set, and himmel-code with no flag always defaults to ollama
#     regardless of the declaration.
#   - Order-insensitive backend parse: two DISTINCT --backend values in one
#     invocation DENY (was last-wins), so a blocked backend placed before an
#     allowed one can no longer be hidden. The same value repeated is not a
#     conflict. Values are compared lower-cased + quote-stripped.
#   - In-command cd drift: the clause splitter evaluates clauses
#     independently, so a `cd <dir> && graphify update rel.md` clause pair let
#     `cd` land as a silent no-op - the relative target resolved against the
#     stale TOOL_CWD instead of the shell's real (post-cd) cwd (fail-open).
#     CD_SEEN now tracks whether any PRIOR clause's command-position token was
#     cd/pushd/popd; once set, a graphify clause with a relative or bare-word
#     target (or no path arg at all, the TOOL_CWD fallback) DENIES instead of
#     resolving against a cwd the fence can no longer vouch for. An absolute
#     target is cwd-independent and still classifies normally.
#
# NOW HANDLED (HIMMEL-881):
#   - `.graphify-backend` file-declared backend: GRAPHIFY_DECLARED_BACKEND is a
#     launching-shell-only env var (a per-call VAR=x prefix or an in-session
#     export never reaches the PreToolUse hook process), so an in-session/
#     headless `graphify update` on a non-himmel corpus could never satisfy the
#     no-backend policy without a session restart. A `.graphify-backend` file
#     sitting in the EXACT SAME directory as the `.graphify-corpus` marker that
#     declared the corpus (not any other ancestor directory - see
#     _graphify_backend_marker) is a second way to supply the same declaration:
#     single-line, trimmed, non-empty, safe-charset (`[A-Za-z0-9._-]+`) backend
#     name; empty, multiline, unreadable, or invalid-charset content DENIES
#     (fail-closed), same as an invalid `.graphify-corpus` marker. Precedence:
#     GRAPHIFY_DECLARED_BACKEND wins if set; the file is consulted only when the
#     env var is unset. Scoped identically to the env var (LLM-free subcommand +
#     non-himmel corpus only - see _llm_free_subcmd). The file's value flows
#     through the SAME matrix eval as a real --backend token (not a bypass), and
#     every ledger line the declaration touches records a `declared_backend_source`
#     field (`"env"` or `"file"`) so audits can distinguish the two paths.
#     ALL-DIRS-MUST-AGREE (codex-adv-1): when MULTIPLE marker-derived targets
#     appear in one invocation, EVERY marker directory is consulted (not only
#     the rank winner's - equal-rank argument ordering must not pick which
#     `.graphify-backend` gets read): every dir must carry a valid file AND
#     all files must declare the SAME value; any missing/unreadable/invalid
#     file, or two differing values, DENIES regardless of argument order.
#     STAGED-ONLY (codex-adv-2): file declarations are honored ONLY when EVERY
#     classified target in the invocation is a marker-declared staged copy -
#     any target classified via a REAL configured root disables the file path
#     entirely (a staged copy's declaration must not vouch for a real vault
#     path listed beside it); mixed staged+real invocations need --backend or
#     the launching-shell env var.
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
#   (f) in-command cd is DETECTED, not TRACKED: the fence notices a prior
#       cd/pushd/popd clause and denies a relative/bare-word graphify target
#       after it, but it does NOT parse the `cd` argument to compute the
#       actual resulting cwd (that would require modelling arbitrary shell
#       expansion of the cd target). Deny-relative is the deliberate
#       trade-off: a false deny (an absolute-safe cd the agent could have
#       resolved) costs a retry; silently trusting a guessed post-cd cwd would
#       be fail-open.
#   (g) backend DECLARATIONS are assertions, not runtime bindings (HIMMEL-881
#       codex-adv round-3, adjudicated accepted-by-design): for no-backend
#       LLM-free subcommands the fence cannot see which cloud key graphify's
#       auto-detection will actually pick, so BOTH declaration paths - the
#       operator-set GRAPHIFY_DECLARED_BACKEND env var AND the agent-writable
#       `.graphify-backend` file - feed the matrix an unverified claim. The
#       file path widens WHO can assert (agent vs launching shell) but not
#       WHAT is verified; compensating controls: staged-only + all-dirs-must-
#       agree + safe-charset validation, and the ledger records
#       `declared_backend_source` ("env"/"file") so a misattributed run stays
#       auditable. The true fix is upstream: `graphify update --backend` (the
#       G-U issue), at which point the explicit-flag path replaces both
#       declaration substitutes. Relatedly, _graphify_backend_marker's
#       [ -f ]/[ -r ]/cat sequence follows symlinks and has a TOCTOU window -
#       accepted-by-design: the marker dir is agent-controlled staging anyway
#       (a symlink/race asserts nothing the agent couldn't assert by writing
#       the file directly); same pre-existing pattern as _graphify_corpus_marker.
#   (h) a marker directory whose NAME contains an embedded newline corrupts the
#       newline-joined marker-dir list invariant, but degrades to a FALSE DENY
#       (the fragments resolve to no valid `.graphify-backend` -> deny), never a
#       bypass; the command-token path already denies earlier at tokenization -
#       only the cwd-fallback can carry such a name in.
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

# TOOL_CWD: the cwd the graphify COMMAND will actually run in. Under hook
# invocation the fence process's own $PWD is the project root, which is NOT
# necessarily the command's cwd (the agent may have cd'd). The hook threads
# the payload's .tool_input.cwd here as GRAPHIFY_TOOL_CWD so relative targets
# and bare-word targets resolve against the REAL command cwd, not the hook
# process cwd (HIMMEL-779: a relative path into a protected corpus otherwise
# resolves under the project root and misses -> fail-open). Defaults to $PWD
# for direct/check-mode invocation (and an empty GRAPHIFY_TOOL_CWD falls back
# to $PWD via the :- expansion, so a no-cwd payload stays correct).
TOOL_CWD="${GRAPHIFY_TOOL_CWD:-$PWD}"

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

# _record_backend <raw-value> -> stash the backend for verdict eval and flag
# conflicting distinct values (HIMMEL-779). Reads/writes the caller's
# backend/backend_norm/backend_set/backend_conflict locals (bash dynamic scope,
# so this must be called from evaluate_invocation). Values are compared
# lower-cased + quote-stripped, so `--backend GLM` and `--backend glm` are NOT a
# conflict; two different values ARE (a blocked backend must stay blocked in
# every flag order, instead of the old last-wins). The raw value is preserved
# in `backend` for the verdict path (which lower-cases it again itself).
_record_backend() {
    local nv; nv="$(_lc "$(_strip_wrap "$1")")"
    if [ "$backend_set" = 1 ] && [ "$backend_norm" != "$nv" ]; then
        backend_conflict=1
    fi
    backend="$1"; backend_norm="$nv"; backend_set=1
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

# _abs <path> -> absolute path (expanduser + anchor a relative path to TOOL_CWD).
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
        [A-Za-z]:*)  p="$TOOL_CWD/${p#?:}" ;;
                     # Windows drive-RELATIVE (C:foo = foo relative to the
                     # cwd on drive C). HIMMEL-808: the old [A-Za-z]:* arm
                     # classified this absolute, and _normalize mangled it
                     # into a synthetic non-corpus path. Anchor to the
                     # current cwd instead - exact when cwd is on that drive
                     # (the attack shape), and a fail-closed lexical
                     # approximation otherwise. HIMMEL-779: anchor to the
                     # TOOL-CALL cwd (GRAPHIFY_TOOL_CWD), not the hook $PWD.
        *)           p="$TOOL_CWD/$p" ;;   # relative -> anchor to tool-call cwd
    esac
    printf '%s' "$p"
}

# _is_abs_target <stripped-token> -> 0 if the token is POSIX-absolute or
# Windows drive-rooted absolute (cwd-independent); 1 for anything else
# (relative, bare, drive-relative, ~-relative). Used by the in-command-cd
# drift guard (HIMMEL-779 FIX 2, see CD_SEEN): once a prior clause in the same
# invocation ran cd/pushd/popd, the fence cannot know the shell's real cwd, so
# only an absolute target is safe to classify - anything else is denied.
_is_abs_target() {
    local p="${1//\\//}"
    case "$p" in
        /*)          return 0 ;;
        [A-Za-z]:/*) return 0 ;;
        *)           return 1 ;;
    esac
}

# _exists_under_cwd <bare-token> -> 0 if <tool-call-cwd>/<token> exists on disk.
# A bare-word (no slash/drive/extension) target the agent dropped without a ./
# prefix (HIMMEL-779): used to keep it from being swallowed as a subcommand word
# at position 0, or skipped as a non-path arg at a later position. Only ever
# called for tokens is_path_like already rejected (no slash), so the append is a
# clean single segment. Resolves against the TOOL-CALL cwd, not the hook $PWD.
# Note: a token that happens to share a name with a real graphify subcommand
# (e.g. `update`) but ALSO exists on disk under the cwd is still treated as a
# target, not swallowed as the subcommand word - safe direction (over-classifies
# toward fencing, never under-classifies toward a silent bypass).
_exists_under_cwd() {
    [ -e "$TOOL_CWD/$1" ]
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
#   "declared<TAB><corpus><TAB><dir>"       first line is a valid corpus name;
#                                            <dir> is the marker's own directory
#                                            (HIMMEL-881: so a caller can look for
#                                            a co-located `.graphify-backend` file
#                                            in the SAME dir, not any ancestor)
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
                    printf 'declared\t%s\t%s' "$line" "$d" ;;
                *)  printf '__marker_bad__\t%s\t%s' "$mk" "$line" ;;
            esac
            return
        fi
        prev="$d"
        d="${d%/*}"
    done
    return 0
}

# _graphify_backend_marker <dir> -> checks EXACTLY <dir> (NO ancestor walk - a
# `.graphify-backend` file elsewhere in the tree does not count, only the SAME
# directory as the `.graphify-corpus` marker that declared the corpus, see the
# HIMMEL-881 header note) for a file declaring a backend name that satisfies the
# GRAPHIFY_DECLARED_BACKEND substitution in apply_verdict when the env var is
# unset. Same fail-closed contract as `.graphify-corpus`: single-line, trimmed,
# non-empty, safe-charset content only. Echoes ONE of:
#   ""                                        no `.graphify-backend` in <dir>
#   "declared<TAB><backend>"                  single-line, non-empty, safe backend name
#   "__backend_unreadable__<TAB><path>"       exists but not a readable regular file
#   "__backend_bad__<TAB><path><TAB><reason>" empty / multiline / invalid-charset content
_graphify_backend_marker() {
    local d="$1" mk content trimmed
    mk="$d/.graphify-backend"
    [ -e "$mk" ] || { printf ''; return; }
    if ! { [ -f "$mk" ] && [ -r "$mk" ]; }; then
        printf '__backend_unreadable__\t%s' "$mk"; return
    fi
    # Command substitution strips ALL trailing newlines, so a multiline check on
    # the result only needs to look for an EMBEDDED newline (a trailing-newline-
    # only file, the common `printf 'x\n' >` shape, still reduces to one line).
    content="$(cat "$mk" 2>/dev/null)"
    content="${content%$'\r'}"
    case "$content" in
        *$'\n'*)
            printf '__backend_bad__\t%s\t%s' "$mk" "multiline content"; return ;;
    esac
    trimmed="${content#"${content%%[![:space:]]*}"}"   # trim leading whitespace
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"   # trim trailing whitespace
    if [ -z "$trimmed" ]; then
        printf '__backend_bad__\t%s\t%s' "$mk" "empty"; return
    fi
    case "$trimmed" in
        *[!A-Za-z0-9._-]*)
            printf '__backend_bad__\t%s\t%s' "$mk" "invalid characters"; return ;;
    esac
    printf 'declared\t%s' "$trimmed"
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
    local apfs ap name rc mk rest mcorpus mdir
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
    # carry an `@declared` suffix plus a tab-separated marker directory
    # (callers strip the suffix, but always ledger the invocation; HIMMEL-881:
    # the directory lets apply_verdict look for a co-located `.graphify-backend`
    # file in that SAME directory, not any other ancestor).
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
            declared$'\t'*)
                rest="${mk#declared$'\t'}"
                mcorpus="${rest%%$'\t'*}"
                mdir="${rest#*$'\t'}"
                printf '%s@declared\t%s' "$mcorpus" "$mdir"
                return ;;
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

# _map_anthropic_endpoint -> resolve the claude/claude-cli backend to a provider
# by its EFFECTIVE endpoint (HIMMEL-1049 codex-adv-1). graphify's `claude`
# backend honors ANTHROPIC_BASE_URL ("claude also reaches custom
# Anthropic-compatible endpoints (LiteLLM proxy, gateways): set
# ANTHROPIC_BASE_URL and ANTHROPIC_MODEL"), so the backend NAME alone does not
# prove the traffic reaches Anthropic: the claude-glm / claude-routed launchers
# set ANTHROPIC_BASE_URL to a Z.ai/GLM gateway (scripts/claude-glm; parity_guard
# checks `api.z.ai in ANTHROPIC_BASE_URL`). Mirror the openai->deepseek endpoint
# check so a claude extraction under those launchers is classified by its REAL
# provider (zai-glm) and hits the matrix's zai-glm cell + ledger, instead of
# being waved through as anthropic. Fail-closed on an unknown custom gateway.
# Classification is by EXACT hostname (CodeRabbit-critical on HIMMEL-1049):
# substring matching on the raw URL is spoofable - `api.anthropic.com.evil/`
# and `evil/api.anthropic.com` both CONTAIN "api.anthropic.com" yet reach an
# attacker. So parse the URL down to its hostname (pure-bash, bash-3.2 idiom
# like _abs/_normalize: strip scheme, path, query, fragment, userinfo, port,
# lowercase) and allowlist EXACT hosts; anything else fails closed.
#   unset                              -> anthropic (graphify's default endpoint)
#   host == api.anthropic.com          -> anthropic
#   host in {api.z.ai, open.bigmodel.cn} -> zai-glm (the GLM gateway
#                                         scripts/claude-glm points at; the
#                                         matrix zai-glm cell + ledger apply)
#   any other host (incl. lookalikes, the claude-routed 127.0.0.1 loopback
#     router, unknown gateways, a scheme-less/malformed value) -> the literal
#     "anthropic-custom" (undeclared -> matrix default deny; fail-closed)
_map_anthropic_endpoint() {
    local u host
    u="${ANTHROPIC_BASE_URL:-}"
    [ -n "$u" ] || { echo anthropic; return; }
    u="$(_lc "$u")"
    # Reject any backslash BEFORE host classification (CodeRabbit-major on
    # HIMMEL-1049): a backslash is never valid in a URL authority, but some HTTP
    # clients (WHATWG URL parsing) fold `\` into `/`, so
    # `https://evil.com\@api.anthropic.com` could resolve to evil.com while the
    # `${u##*@}` userinfo strip below sees api.anthropic.com. Fail closed.
    case "$u" in *\\*) echo anthropic-custom; return ;; esac
    # Require an explicit HTTPS scheme. A plaintext http:// endpoint would egress
    # corpus content in cleartext; a scheme-less (`api.anthropic.com`) or
    # arbitrary-scheme (`file://`, `evil://`) value is malformed/ambiguous. All of
    # these fail closed to anthropic-custom (CodeRabbit-major on HIMMEL-1049), so a
    # bare/plaintext trusted hostname can never be waved through as anthropic (the
    # real gateways — api.anthropic.com, api.z.ai — are HTTPS).
    case "$u" in
        https://*) : ;;
        *) echo anthropic-custom; return ;;
    esac
    u="${u#*://}"       # strip the (validated) https:// scheme
    u="${u%%/*}"        # authority = up to the first '/'
    u="${u%%\?*}"       # strip ?query   (scheme-/path-less forms)
    u="${u%%#*}"        # strip #fragment
    host="${u##*@}"     # drop userinfo (user:pass@)
    host="${host%%:*}"  # drop :port
    case "$host" in
        api.anthropic.com)          echo anthropic ;;
        api.z.ai|open.bigmodel.cn)  echo zai-glm ;;
        *)                          echo anthropic-custom ;;
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
        claude|claude-cli) _map_anthropic_endpoint ;;
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

# ledger_append <path> <corpus> <backend> <provider> <verdict> [declared]
#   [backend_source] -> 0 on a durable write, 1 on any failure (unwritable dir /
# file). Callers DENY on failure: an allow+log verdict without its ledger line
# is not allowed. When the optional 6th arg is "1" (ANY token in the invocation
# classified via a `.graphify-corpus` marker - invocation-wide, not just the
# winning token) an extra `"declared":true` field is emitted so a mis-declared
# marker cannot dodge audit. When the optional 7th arg is non-empty ("env" or
# "file", HIMMEL-881: which path supplied a backend for the no-backend
# GRAPHIFY_DECLARED_BACKEND substitution) an extra `"declared_backend_source"`
# field is emitted so audits can distinguish env-declared vs file-declared runs;
# apply_verdict's allow branch calls this for EVERY declaration-reached run
# (declared corpus OR declared backend), even on a plain `allow` cell.
ledger_append() {
    local dir ts ep decl="" bsrc=""
    [ "${6:-}" = 1 ] && decl=',"declared":true'
    [ -n "${7:-}" ] && bsrc=",\"declared_backend_source\":\"$(_json_escape "${7}")\""
    dir="$(dirname "$LEDGER")"
    mkdir -p "$dir" || return 1
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%s)"
    ep="$(_json_escape "$1")"
    printf '{"ts":"%s","path":"%s","corpus":"%s","backend":"%s","provider":"%s","verdict":"%s","tool":"graphify"%s%s}\n' \
        "$ts" "$ep" "$2" "$3" "$4" "$5" "$decl" "$bsrc" >> "$LEDGER" || return 1
    return 0
}

# _llm_free_subcmd <subcommand> -> 0 if the subcommand is LLM-free (does local,
# non-provider work; today: exactly `update`). GRAPHIFY_DECLARED_BACKEND
# (HIMMEL-779) is honored ONLY for one of these - a case pattern, not a fixed
# string, so a future LLM-free subcommand extends by adding one arm here.
_llm_free_subcmd() {
    case "$1" in
        update) return 0 ;;
        *)      return 1 ;;
    esac
}

# apply_verdict <corpus> <target> <backend-raw> [declared] [subcmd] [marker_dir]
#   [any_real_root]
# -> return 0 (allow, ledger written where required) or DENY (exit 2). When
# <declared> is 1 ANY classified token in the invocation came from a
# `.graphify-corpus` marker (invocation-wide - not only the rank-winning
# token, so argument ordering cannot suppress the audit): ALWAYS ledger the
# run, even on a plain `allow` cell (a mis-declared marker must not also dodge
# audit). The same always-ledger applies to ANY declared-backend substitution
# (env or file): a run whose backend came from a declaration rather than an
# explicit --backend leaves a ledger line on every allow-family verdict, even
# a plain `allow` cell on a real (non-marker) root, so limitation (g)'s audit
# guarantee holds for both declaration paths. <subcmd> (HIMMEL-779 CR round-1) is the recorded graphify subcommand
# token, used to scope GRAPHIFY_DECLARED_BACKEND (and, HIMMEL-881, the
# `.graphify-backend` file) to the LLM-free set - empty when the invocation had
# no genuine subcommand word (a position-0 path-like token). <marker_dir>
# (HIMMEL-881) is a NEWLINE-SEPARATED dedup'd list of the directory of EVERY
# `.graphify-corpus` marker that classified a token in the invocation (the
# cwd-fallback path passes its single dir as a 1-entry list) - the ONLY
# directories apply_verdict will check for co-located `.graphify-backend`
# files (never any other ancestor). ALL listed dirs must carry a valid file
# and agree on one value (codex-adv-1: equal-rank argument ordering must not
# pick which declaration gets read - fail closed on any missing/invalid/
# conflicting entry). <any_real_root> (codex-adv-2) is 1 when ANY classified
# token in the invocation resolved via a REAL configured root rather than a
# `.graphify-corpus` marker: file declarations are then disabled outright
# (STAGED-ONLY - a staged copy's declaration must not vouch for a real vault
# path listed beside it). Defaults to 1 (fail-closed) when omitted.
apply_verdict() {
    local corpus="$1" target="$2" backend_raw="$3" declared="${4:-0}" subcmd="${5:-}" marker_dir="${6:-}" any_real_root="${7:-1}"
    local backend_effective provider verdict everr eout emsg optvar optval
    local declared_backend_source="" no_backend_msg bm rest bpath breason
    local agreed agreed_dir mdir_i val

    if [ -z "$backend_raw" ] && [ "$corpus" != "himmel-code" ]; then
        # graphify's `update` (and other LLM-free subcommands, see
        # _llm_free_subcmd) take NO --backend on the CLI (re-extraction is
        # local), yet this fence needs a declared provider to apply the matrix
        # for any non-himmel corpus. Accept a declared backend ONLY when the
        # subcommand is LLM-free - for himmel-code with no flag the
        # local-ollama default stands unconditionally (this whole block is
        # skipped, see the outer `&&`); a declared value must NOT override it
        # (HIMMEL-779 CR round-1). A provider-using (non-LLM-free) subcommand
        # with no --backend still hits the deny below even when a declaration
        # is available - declaration cannot substitute for a real --backend on
        # a subcommand whose CLI actually accepts one. Either declared value
        # flows through the SAME matrix eval + provider map as a real
        # --backend token (it is NOT a bypass). Two declaration paths, in
        # precedence order (HIMMEL-881 adds the second):
        #   1. GRAPHIFY_DECLARED_BACKEND env var (launching-shell-only; a
        #      per-call VAR=x prefix or in-session export never reaches this
        #      hook process).
        #   2. `.graphify-backend` files in the EXACT SAME directories as the
        #      `.graphify-corpus` markers that classified tokens in this
        #      invocation (marker_dir, a newline-separated dedup'd list) - a
        #      per-run, in-session-settable alternative for headless/in-
        #      session `graphify update` runs that cannot restart the session
        #      to set the env var. Consulted ONLY when the env var is unset.
        #      ALL-DIRS-MUST-AGREE (codex-adv-1): EVERY listed dir must carry
        #      a valid file and all files must declare the SAME value - a
        #      missing/unreadable/invalid file in ANY dir, or two differing
        #      values, DENIES regardless of argument order (a safe copy's
        #      declaration must not vouch for a co-listed copy that lacks or
        #      contradicts its own).
        no_backend_msg="pass --backend explicitly, set GRAPHIFY_DECLARED_BACKEND in the launching shell, or add a .graphify-backend file next to the .graphify-corpus marker (GRAPHIFY_DECLARED_BACKEND / .graphify-backend only apply to LLM-free subcommands (update)) (graphify auto-detects cloud keys; the fence cannot see which) [corpus=$corpus subcommand=${subcmd:-<none>}]"
        if _llm_free_subcmd "$subcmd"; then
            if [ -n "${GRAPHIFY_DECLARED_BACKEND:-}" ]; then
                backend_raw="$GRAPHIFY_DECLARED_BACKEND"
                declared_backend_source="env"
            elif [ -n "$marker_dir" ]; then
                # STAGED-ONLY (codex-adv-2): a file declaration is honored
                # ONLY when EVERY classified target is a marker-declared
                # staged copy. Any real-root target in the same invocation
                # disables the file path outright - deny before reading any
                # file (the staged copy's declaration must not vouch for the
                # real path; the winning corpus here may well BE the real
                # path's).
                if [ "$any_real_root" = 1 ]; then
                    deny "$no_backend_msg (.graphify-backend file declarations apply only when EVERY classified target is a marker-declared staged copy - this invocation mixes staged and real-root targets; use --backend or set GRAPHIFY_DECLARED_BACKEND in the launching shell)"
                fi
                agreed=""; agreed_dir=""
                while IFS= read -r mdir_i; do
                    [ -n "$mdir_i" ] || continue
                    bm="$(_graphify_backend_marker "$mdir_i")"
                    case "$bm" in
                        declared$'\t'*)
                            val="${bm#declared$'\t'}"
                            if [ -n "$agreed" ] && [ "$(_lc "$val")" != "$(_lc "$agreed")" ]; then
                                deny "conflicting .graphify-backend declarations across staged corpus markers ($agreed_dir=$agreed $mdir_i=$val); all marker dirs must agree (fail-closed)"
                            fi
                            if [ -z "$agreed" ]; then agreed="$val"; agreed_dir="$mdir_i"; fi
                            ;;
                        __backend_unreadable__$'\t'*)
                            deny ".graphify-backend marker ${bm#__backend_unreadable__$'\t'} exists but is not a readable regular file (fail-closed)" ;;
                        __backend_bad__$'\t'*)
                            rest="${bm#__backend_bad__$'\t'}"; bpath="${rest%%$'\t'*}"; breason="${rest#*$'\t'}"
                            deny ".graphify-backend marker $bpath declares an invalid backend ($breason); must be a single-line, non-empty backend name (fail-closed)" ;;
                        '')
                            deny "no .graphify-backend file in staged corpus marker dir $mdir_i (every marker dir in the invocation needs one); $no_backend_msg" ;;
                    esac
                done <<< "$marker_dir"
                if [ -n "$agreed" ]; then
                    backend_raw="$agreed"
                    declared_backend_source="file"
                fi
            fi
        fi
        [ -n "$backend_raw" ] || deny "$no_backend_msg"
    fi
    if [ -z "$backend_raw" ]; then
        backend_effective="ollama"      # himmel-code, no flag, no declaration -> local default
    else
        backend_effective="$(_lc "$(_strip_wrap "$backend_raw")")"
    fi
    provider="$(map_provider "$backend_effective")"

    # HARD-DENY the unverified-endpoint sentinel BEFORE the matrix eval
    # (CodeRabbit-major on HIMMEL-1049). `anthropic-custom` is what
    # _map_anthropic_endpoint returns when it CANNOT vouch for the claude
    # backend's endpoint (unknown/lookalike host, plaintext http, scheme-less,
    # backslash authority). Letting it reach the matrix would hand it to the
    # `himmel-code x * x *` wildcard -> ALLOW: but that wildcard exists for
    # RATIFIED providers (codex/GLM/alibaba/anthropic/deepseek), NOT for an
    # arbitrary host an attacker can point ANTHROPIC_BASE_URL at. An endpoint we
    # cannot verify must fail closed on EVERY corpus, public code included.
    if [ "$provider" = "anthropic-custom" ]; then
        # Do NOT echo the raw ANTHROPIC_BASE_URL (CodeRabbit-major): it can carry
        # userinfo/credentials/query tokens (https://user:SECRET@host/...), and
        # this message lands on stderr + in the hook trail. Name the VARIABLE, not
        # its value; the operator can inspect it themselves.
        deny "claude backend points at an unverified endpoint (ANTHROPIC_BASE_URL is set to an unrecognized/unsupported value - not echoed, it may carry credentials); refusing on every corpus (fail-closed). Fix: unset ANTHROPIC_BASE_URL, or point it at https://api.anthropic.com or the ratified gateway https://api.z.ai (https only, exact host); or pick a backend that does not read it (e.g. --backend ollama for local extraction)"
    fi

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
            # Always ledger a run reached via ANY declaration, even on a plain
            # `allow` cell: a marker-declared corpus (declared=1) OR a
            # declared-backend substitution (declared_backend_source non-empty
            # - env or file; HIMMEL-881 final CR: an env-declared run on a
            # real root previously left NO ledger line here, contradicting
            # limitation (g)'s audit guarantee). Same principle as the
            # declared-marker always-ledger; a failed write DENIES.
            if [ "$declared" = 1 ] || [ -n "$declared_backend_source" ]; then
                ledger_append "$target" "$corpus" "$backend_effective" "$provider" "allow" "$declared" "$declared_backend_source" \
                    || deny "declared-corpus/declared-backend audit requires the ledger line (ledger unwritable): $corpus x $provider"
            fi
            return 0
            ;;
        allow+log)
            ledger_append "$target" "$corpus" "$backend_effective" "$provider" "allow+log" "$declared" "$declared_backend_source" \
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
                ledger_append "$target" "$corpus" "$backend_effective" "$provider" "conditional" "$declared" "$declared_backend_source" \
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
    local have_sub=0 subcmd="" want_backend=0 backend="" backend_norm="" backend_set=0 backend_conflict=0
    local unclassifiable=0 best_rank=-1 best_corpus="" best_target="" any_declared=0 marker_dirs="" any_real_root=0
    local tok st c r declared marker_dir tok_marker_dir skip_redir_target=0

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
        if [ "$want_backend" = 1 ]; then _record_backend "$tok"; want_backend=0; continue; fi
        case "$tok" in
            --backend)   want_backend=1; continue ;;
            --backend=*) _record_backend "${tok#--backend=}"; continue ;;
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
            # HIMMEL-779: a BARE word (no slash/drive/extension) that EXISTS
            # under the tool-call cwd is likewise a target the agent dropped
            # without a ./ prefix, not a subcommand word - classify it so a
            # bare PHI dir name cannot be swallowed and let the cwd fallback
            # or a co-present safe path win (fail-open).
            if ! is_path_like "$st" && ! _exists_under_cwd "$st"; then
                subcmd="$(_lc "$st")"; have_sub=1; continue
            fi
            have_sub=1
        fi
        st="$(_strip_wrap "$tok")"
        [ -n "$st" ] || continue
        # A path-like token, OR a bare word that exists under the tool-call
        # cwd, is a target (HIMMEL-779: bare-word targets were previously
        # skipped as "non-path args", so a bare PHI dir name alongside a safe
        # path let the safe path win the rank). is_path_like is checked first
        # so _exists_under_cwd only ever stats a clean single bare segment.
        is_path_like "$st" || _exists_under_cwd "$st" || continue
        # FIX 2 (HIMMEL-779 CR round-1): a PRIOR clause in this invocation ran
        # cd/pushd/popd (CD_SEEN, set below the clause loop) - a relative or
        # bare-word target can no longer be trusted to resolve against
        # TOOL_CWD (the shell may have moved). Deny rather than guess; an
        # absolute target is cwd-independent and still classifies normally.
        if [ "$CD_SEEN" = 1 ] && ! _is_abs_target "$st"; then
            deny "relative graphify target after an in-command cd - the fence cannot track the shell's cwd; use absolute paths ($st)"
        fi
        c="$(classify "$st")"
        _deny_on_classify_sentinel "$c"
        # The declared bit is INVOCATION-WIDE: ANY marker-derived token forces
        # the always-ledger audit, regardless of whether it wins the rank
        # comparison (else a real-root token of equal/higher rank listed first
        # would suppress the ledger line - argument ordering must not dodge audit).
        tok_marker_dir=""
        case "$c" in
            *@declared$'\t'*)
                tok_marker_dir="${c#*@declared$'\t'}"
                c="${c%%@declared*}"
                any_declared=1
                ;;
        esac
        # Collect the marker dir of EVERY @declared token (codex-adv-1) - not
        # only the rank winner's, since equal-rank argument ordering must not
        # pick which `.graphify-backend` file apply_verdict reads. Dedup'd,
        # newline-separated (bash 3.2-safe containment check).
        if [ -n "$tok_marker_dir" ]; then
            case "$'\n'$marker_dirs$'\n'" in
                *$'\n'"$tok_marker_dir"$'\n'*) : ;;
                *) marker_dirs="${marker_dirs:+$marker_dirs$'\n'}$tok_marker_dir" ;;
            esac
        elif [ -n "$c" ]; then
            # A token classified via a REAL configured root (no @declared
            # suffix). STAGED-ONLY (codex-adv-2): its presence disables the
            # `.graphify-backend` file path in apply_verdict entirely - a
            # staged copy's file declaration must not vouch for a real vault
            # path listed beside it.
            any_real_root=1
        fi
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

    # HIMMEL-779: order-insensitive backend parse. Two DISTINCT backend values
    # in one invocation DENY (instead of last-wins) so a blocked backend placed
    # before an allowed one cannot be hidden. The same value repeated is not a
    # conflict. Checked after the unclassifiable deny; either way it fails closed.
    if [ "$backend_conflict" = 1 ]; then
        deny "conflicting --backend values in one graphify invocation (a blocked backend must stay blocked in every flag order): $CMD"
    fi

    if [ -n "$best_corpus" ]; then
        apply_verdict "$best_corpus" "$best_target" "$backend" "$any_declared" "$subcmd" "$marker_dirs" "$any_real_root"
        return
    fi

    # No classified path-like token -> the corpus is the one around the CWD
    # (the TOOL-CALL cwd; HIMMEL-779). FIX 2 (HIMMEL-779 CR round-1): if a
    # PRIOR clause in this invocation changed directory (cd/pushd/popd, see
    # CD_SEEN below the clause loop), the tool-call cwd captured before the
    # whole command ran no longer reflects where THIS clause actually
    # executes - falling back to it here would silently trust a stale cwd.
    # Deny instead of guessing (fail-closed; cd is not tracked, see header
    # limitation (f)).
    if [ "$CD_SEEN" = 1 ]; then
        deny "relative graphify target after an in-command cd - the fence cannot track the shell's cwd; use absolute paths (no path arg, cwd fallback)"
    fi
    c="$(classify "$TOOL_CWD")"
    _deny_on_classify_sentinel "$c"
    declared=0
    marker_dir=""
    case "$c" in
        *@declared$'\t'*)
            marker_dir="${c#*@declared$'\t'}"
            c="${c%%@declared*}"
            declared=1
            ;;
    esac
    [ -n "$c" ] || deny "unclassifiable cwd for graphify '$subcmd' (no classifiable path arg): $TOOL_CWD"
    # STAGED-ONLY consistency (codex-adv-2): the single cwd classification is
    # either marker-declared (any_real_root=0) or real-root (=1; the file
    # branch is unreachable then anyway since marker_dir is empty).
    if [ "$declared" = 1 ]; then any_real_root=0; else any_real_root=1; fi
    apply_verdict "$c" "$TOOL_CWD" "$backend" "$declared" "$subcmd" "$marker_dir" "$any_real_root"
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

# CD_SEEN (HIMMEL-779 CR round-1, FIX 2): 1 once a PRIOR clause's
# command-position token was a cwd-changing builtin (cd/pushd/popd). The while
# loop below is NOT subshelled (here-string redirection, not a pipe), so this
# mutation is visible to every later iteration in this same process - a
# graphify clause evaluated after that point cannot trust TOOL_CWD or a
# relative target (see the CD_SEEN checks in evaluate_invocation).
CD_SEEN=0

while IFS= read -r clause || [ -n "$clause" ]; do
    [ -n "$clause" ] || continue
    # shellcheck disable=SC2086 # intentional word split for tokenisation
    set -- $clause
    [ "$#" -gt 0 ] || continue
    classify_clause "$@"
    # Same _strip_cmd normalization as the graphify command-position match
    # (quotes/backticks/$/(/)/backslash stripped), checked on the clause's own
    # first token - a cd/pushd/popd here means every LATER clause runs in an
    # untracked cwd.
    case "$(_strip_cmd "$1")" in
        cd|pushd|popd) CD_SEEN=1 ;;
    esac
done <<< "$tmp"

exit 0
