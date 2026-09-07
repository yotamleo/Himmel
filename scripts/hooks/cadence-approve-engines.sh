#!/usr/bin/env bash
# Cadence-scoped PreToolUse Bash ALLOW hook (HIMMEL-1682 S2a).
#
# WHY: the daily vault-lint cadence leg (HIMMEL-1386) runs the
# obsidian-triage:vault-lint skill, whose engine is
#   python <himmel-root>/marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py <vault>
# `python` is deliberately NOT in auto-approve-safe-bash.sh's safe set (it is a
# programmable interpreter), so the literal engine command prompts for approval
# — and a prompt at 04:00 with nobody to answer it wastes the run (HIMMEL-1682:
# the vault lint died on a permission plea two nights running, classified as a
# vacuous "complete"). The runner fires claude in the VAULT cwd (not the himmel
# repo), so the model emits an ABSOLUTE engine path; that path's Windows drive
# colon also breaks the allow-list `:*` prefix syntax, so a static
# `permissions.allow` belt is unreliable here. This hook is the authoritative
# fix: it reads the full command TEXT and decides itself, so neither the static
# matcher's metacharacter bail (HIMMEL-203) nor the colon problem can reach it.
#
# This hook grants ONLY the enumerated cadence engine scripts — initially just
# the vault-lint engine. Grow ENGINE_LIST per leg as more cadence engines are
# added (each entry: <binary>:<normalized-path-suffix>, suffix with `\`->`/`).
#
# CONTRACT (inverted vs the block-* hooks; mirrors auto-approve-safe-bash):
#   * NEVER blocks/denies. Worst case it stays silent and the command falls
#     through to the normal permission flow. FAIL-OPEN: missing jq, unparseable
#     input, not-an-enumerated-engine -> silent exit 0, no decision.
#   * Only ever EMITS "allow". The deny-list + block-* deny hooks remain the
#     hard backstop; a deny from them WINS over an allow here (HIMMEL-203).
#   * Wired ONLY in cadence-settings.json (--settings for cadence runs), so
#     interactive sessions are untouched.
#
# SAFETY MODEL — a command is granted ONLY when ALL hold:
#   1. tool_name is Bash.
#   2. No command/process substitution anywhere: no `$(`  `` ` ``  `<(`  `>(`.
#   3. No shell-level redirect to a real file (`>`/`>>` output, `<` input);
#      only /dev/null sinks and fd-dups (`2>&1`, `<&0`) are tolerated — a grant
#      must never reshape the process's I/O at the shell level.
#   4. Every top-level segment (split on unquoted ; | || && & newline) is EITHER
#      an enumerated engine invocation OR a benign nav wrapper (cd/pushd/popd),
#      so a `cd <repo> && python <engine> <vault>` paraphrase is covered. Any
#      other segment -> fall through (do not grant).
#   5. An enumerated engine invocation is:
#        binary == python|python3|node|bash   (bare interpreter name; no path,
#                                    no .exe — a `$cmd`/absolute interpreter
#                                    binary is NOT granted: fail-safe,
#                                    HIMMEL-203 stance). HIMMEL-2124 also grants
#                                    TWO engines (harvest-clip-body-batch.py,
#                                    ig-media-fetch.py) invoked as `uv run
#                                    [--python <ver>] python <script>` — the
#                                    shape their own leg docs use — via
#                                    match_uv_prefix below, optionally preceded
#                                    by the single literal `PYTHONUTF8=1`
#                                    assignment those same docs also use
#                                    (RETASK R2124A: innocuous, unlike
#                                    PYTHONPATH — cannot shadow a module).
#                                    Every other engine still requires the
#                                    bare interpreter with no leading anything.
#        AND the token IMMEDIATELY after the binary (no python interpreter flag
#            such as -c/-m in between, so `python -c "evil" …` is NOT granted)
#            is a LITERAL path (no $ ` or substitution) whose normalised form
#            equals <himmel-root>/<enumerated suffix> EXACTLY, where
#            himmel-root is derived from THIS hook's own location. A tail-only
#            match is not enough (HIMMEL-1682 CR round 2) — see ROOT ANCHOR.
#            Consequently a RELATIVE engine path is never granted: it depends
#            on a cwd the hook cannot vouch for.
#      HIMMEL-2124 follow-up (cache root anchor): the obsidian-triage plugin
#      itself RUNS from the Claude Code plugin cache
#      (~/.claude/plugins/cache/himmel/obsidian-triage/<version>/...), so a
#      leg session's engine path legitimately resolves there, not just under
#      this checkout -- both are sanctioned copies of the same plugin. The
#      grant additionally requires the cache dir basename to be
#      version-shaped AND the specific engine file to actually exist under it
#      -- stricter than the checkout anchor, since a cache install is
#      optional and its presence on disk is the only proof it is real. Every
#      other rule above and below (bare interpreter, literal-path-only,
#      flag/arg constraints) is unchanged; this only widens WHERE the same
#      enumerated file may live.
#   6. Trailing args are constrained too (HIMMEL-1682 leg-16, codex-adv HIGH:
#      an unconstrained trailing-arg grant let an injected `--config <file>`
#      point vault_lint.py's report_path -- join()'d without containment and
#      opened "w" -- at an attacker-writable path riding this hook's auto-allow).
#      Every remaining token after the engine script must be EITHER:
#        - a per-engine safe flag: boolean, no value, cannot redirect I/O (see
#          flag_is_safe; vault-lint's set is `--json`/`--no-report`, derived
#          from its SKILL.md documented flags. `--config` and any future
#          path-valued output flag are deliberately excluded), OR
#        - a path argument that can only ever resolve inside the vault the
#          cadence session is running in: a RELATIVE token with no `..`
#          segment (cannot escape whatever directory it resolves against), or
#          an ABSOLUTE token that names -- or nests under -- the session's own
#          cwd, resolved from this hook's payload `.tool_input.cwd`/`.cwd`
#          field (same field block-graphify-egress.sh / block-terminal-write-
#          fence.sh already trust for their own containment checks; the
#          cadence runner fires claude in the vault cwd -- see the file header
#          above).
#      A token containing `$` (unprovable literal -- the cadence's environment
#      is not something this hook can audit), a leading `~` (tilde expansion),
#      a brace `{`/`}` (brace expansion), a glob metacharacter `*`/`?`/`[`
#      (filename expansion -- all of these are shell-expanded at runtime to a
#      path this hook cannot see from the token text alone), a `..` segment,
#      or an absolute path with no resolvable session cwd is refused:
#      fail-safe, the whole segment (and so the command) falls through
#      ungranted, same posture as every other rule in this file.
#      vault_lint.py's OWN containment (its `--config`/report_path join has
#      none) is a separate, not-yet-fixed engine-side concern -- tracked for a
#      follow-up ticket, out of scope for this hook.
#   7. HIMMEL-2124: a `gh api repos/...` segment is ALSO granted, but ONLY
#      when it is READ-shaped -- the harvest/luna-ingest legs only ever read
#      github metadata through this hook, never write it. Granted iff ALL
#      hold: the (quote-reassembled) endpoint right after `api` starts with
#      `repos/`, carries no `$`, and carries no `..`; AND every other token is
#      one of a small explicit safe-flag ALLOWLIST (`--jq`/`-q`, `--paginate`,
#      `--cache`, `--slurp`, `-H`/`--header`, plus the value immediately after
#      a value-taking one of those). RETASK R2124A: this is deliberately an
#      ALLOWLIST, not a denylist of dangerous flags -- a denylist for an
#      external CLI's flag surface is structurally unwinnable (there is
#      always one more flag, and a mangled/escaped token can evade a literal
#      pattern match). See segment_is_gh_read. Any token not on the allowlist
#      -- a write verb, `--hostname`, a non-`repos/` endpoint, or anything
#      unrecognised, escaped or not -- falls through ungranted by the same
#      default branch, same fail-safe posture as every rule above.
#
# No bypass env var — there is nothing to bypass (the hook only grants).
# To DISABLE, remove it from cadence-settings.json.
# bash 3.2-compatible (no mapfile / associative arrays).
set -uo pipefail

# Enumerated cadence engines. Add legs here as `<bin>:<normalized suffix>`
# pairs. The suffix is the per-leg registry key; it is joined to the ROOT ANCHOR
# below and matched EXACTLY (backslashes folded to `/`, case-insensitively), so
# it stays machine-independent while still naming one specific file on disk.
# List every interpreter binary a leg may use (python AND python3) so a
# paraphrased interpreter name still matches the same engine.
VAULT_LINT_SUFFIX="marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py"
# HIMMEL-2124: harvest/triage/ig-media-enrich cadence legs, enumerated exactly
# as those leg sessions specified. All live under the obsidian-triage plugin's
# tools/ dir (tools/lib/ for evidence-kind.mjs), same ROOT ANCHOR posture as
# vault_lint above -- one specific file beside this hook's own checkout, never
# a same-named file elsewhere.
HARVEST_SUFFIX="marketplace/plugins/obsidian-triage/tools/harvest-clip-body-batch.py"
IS_THIN_SUFFIX="marketplace/plugins/obsidian-triage/tools/is-thin-cli.mjs"
EVIDENCE_KIND_SUFFIX="marketplace/plugins/obsidian-triage/tools/lib/evidence-kind.mjs"
DAILY_TIMELINE_SUFFIX="marketplace/plugins/obsidian-triage/tools/daily-timeline.mjs"
IG_MEDIA_FETCH_SUFFIX="marketplace/plugins/obsidian-triage/tools/ig-media-fetch.py"
ENSURE_DEPS_SUFFIX="marketplace/plugins/obsidian-triage/tools/ensure-deps.sh"
# HIMMEL-2124 acceptance-leg gap (2026-08-26): the harvest-clips.md thin-body
# enrich rungs (~lines 210-211) dispatch these two X/reddit enrichers, but
# they were missing from ENGINE_LIST -- 5 thin X-tweet clips parked as
# retryable partial on a permission plea because of it. Same tools/ root +
# node binary as IS_THIN_SUFFIX/EVIDENCE_KIND_SUFFIX/DAILY_TIMELINE_SUFFIX
# above.
FXTWITTER_SUFFIX="marketplace/plugins/obsidian-triage/tools/fxtwitter-enrich.mjs"
REDDIT_ENRICH_SUFFIX="marketplace/plugins/obsidian-triage/tools/reddit-enrich.mjs"
ENGINE_LIST="python:${VAULT_LINT_SUFFIX} python3:${VAULT_LINT_SUFFIX} \
python:${HARVEST_SUFFIX} python3:${HARVEST_SUFFIX} \
python:${IG_MEDIA_FETCH_SUFFIX} python3:${IG_MEDIA_FETCH_SUFFIX} \
node:${IS_THIN_SUFFIX} node:${EVIDENCE_KIND_SUFFIX} node:${DAILY_TIMELINE_SUFFIX} \
node:${FXTWITTER_SUFFIX} node:${REDDIT_ENRICH_SUFFIX} \
bash:${ENSURE_DEPS_SUFFIX}"

# HIMMEL-2176 (A18): `--print-engine-list` prints ENGINE_LIST one token per
# line, then exits -- placed AFTER the assembly above (so it reflects the
# real value) but BEFORE both the ENGINE_ROOT_POSIX guard below (which would
# otherwise silently `exit 0` and swallow the print on a machine where the
# root cannot be resolved) and stdin is ever read (a PreToolUse invocation of
# this flag passes no JSON payload, so reading stdin first would hang). This
# is so `himmelctl status` (a later PR) can shell out to it instead of a
# copied literal or a JS regex over this file -- the hook stays the SINGLE
# source of the allow-list. `"${1:-}"` is set -u/-o pipefail safe: $1 may be
# unset on a normal PreToolUse invocation.
if [ "${1:-}" = "--print-engine-list" ]; then
    for entry in $ENGINE_LIST; do
        printf '%s\n' "$entry"
    done
    exit 0
fi

# ROOT ANCHOR (HIMMEL-1682 CR round 2, panel finding codex-1). The suffix above
# is a REGISTRY key, never sufficient on its own: a bare tail match is not tied
# to any particular checkout, so combined with the benign `cd` wrapper below,
#   cd /tmp/evil && python marketplace/.../vault_lint.py
# matched on suffix alone and handed an automatic allow to an ATTACKER-supplied
# vault_lint.py. That is the exact opposite of this hook's contract. The grant
# is therefore pinned to the engine that ships beside THIS hook: the candidate
# must resolve to <himmel-root>/<suffix> exactly, so a relative path (which
# depends on a cwd the hook cannot vouch for) and a same-suffix path under any
# other root are both refused. This matters because the cadence session
# processes untrusted vault clips — prompt injection into the emitted command
# is the threat this anchor closes.
ENGINE_ROOT_POSIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
# An unresolvable root would collapse the anchor to a bare "/<suffix>" match,
# which is a grant this hook must never make. No root -> no decision.
[ -n "$ENGINE_ROOT_POSIX" ] || exit 0
ENGINE_ROOT_MIXED="$ENGINE_ROOT_POSIX"
if command -v cygpath >/dev/null 2>&1; then
    ENGINE_ROOT_MIXED=$(cygpath -m "$ENGINE_ROOT_POSIX" 2>/dev/null || printf '%s' "$ENGINE_ROOT_POSIX")
fi

# Secondary (plugin-cache) anchor (HIMMEL-2124 follow-up). obsidian-triage
# leg sessions actually run the plugin from the Claude Code plugin cache, not
# this checkout, so a cache-rooted engine path is an equally sanctioned copy
# — see SAFETY MODEL point 5 addendum above. Derived from $HOME (same pattern
# as ENGINE_ROOT_POSIX deriving from this hook's own location); no new bypass
# env var — tests override $HOME itself when invoking the hook.
PLUGIN_CACHE_BASE="$HOME/.claude/plugins/cache/himmel/obsidian-triage"

# Lowercase helper — Windows path case (and drive-letter case) differs between
# the cygpath -m form and whatever the model emits, so the anchor compares
# case-insensitively. bash 3.2 has no ${v,,}.
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Is $1 (already normalized) the engine <root>/<suffix> beside this hook?
# EXACT match against both the POSIX (/c/...) and mixed (C:/...) absolute forms.
path_is_rooted_engine() {
    local cand lc_cand lc_b
    cand="$1"
    # POSIX form: EXACT compare. A case-only difference names a different file
    # on a case-sensitive filesystem, so folding case here would widen the grant
    # (HIMMEL-1682 CR round 5 Major).
    [ "$cand" = "${ENGINE_ROOT_POSIX}/$2" ] && return 0
    # Mixed (Windows) form: case-insensitive, per the drive-letter/path-case note
    # — but ONLY when cygpath actually produced a DISTINCT Windows-style root.
    # Without cygpath, ENGINE_ROOT_MIXED is the SAME string as ENGINE_ROOT_POSIX,
    # so a case-insensitive re-compare here would auto-allow a case-twin POSIX
    # path that names a DIFFERENT file on a case-sensitive filesystem
    # (HIMMEL-1682 CR round 8, panel codex-1). Refuse rather than re-compare the
    # identical POSIX string; this keeps every accept branch at most as
    # permissive as the exact POSIX byte-for-byte compare above.
    if [ "$ENGINE_ROOT_MIXED" != "$ENGINE_ROOT_POSIX" ]; then
        lc_cand=$(_lc "$cand")
        lc_b=$(_lc "${ENGINE_ROOT_MIXED}/$2")
        [ "$lc_cand" = "$lc_b" ] && return 0
    fi
    # Checkout anchor missed -- try the plugin-cache secondary anchor
    # (HIMMEL-2124 follow-up) before giving up.
    path_is_cache_rooted_engine "$cand" "$2"
}

# Is $1 (already normalized) an obsidian-triage engine rooted under a
# VERSION-SHAPED dir of PLUGIN_CACHE_BASE, where the engine file actually
# exists on disk? Suffix $2 must live under
# marketplace/plugins/obsidian-triage/ -- only that plugin's engines get
# cache anchoring; every other suffix (there are none today, but the guard
# stays fail-safe against a future non-obsidian-triage entry) is refused
# outright. Mirrors path_is_rooted_engine's dual-form (exact POSIX,
# case-insensitive mixed-only-when-distinct) compare, per version dir.
path_is_cache_rooted_engine() {
    local cand="$1" suf="$2" tail _vd _b vd_posix vd_mixed lc_cand lc_b
    tail="${suf#marketplace/plugins/obsidian-triage/}"
    [ "$tail" != "$suf" ] || return 1
    for _vd in "$PLUGIN_CACHE_BASE"/*/; do
        [ -d "$_vd" ] || continue
        _b="$(basename "$_vd")"
        # Version-shaped basename only: digits and dots, no empty/leading/
        # trailing/doubled dot. Same fail-safe pattern style as
        # match_uv_prefix's version check below.
        case "$_b" in ''|*[!0-9.]*|.*|*.|*..*) continue ;; esac
        # The engine file must actually exist under this version dir -- pins
        # the grant to a real installed engine (stricter than the checkout
        # anchor, deliberately: a cache install is optional).
        [ -f "${_vd%/}/$tail" ] || continue
        vd_posix="$(cd "$_vd" 2>/dev/null && pwd)"
        [ -n "$vd_posix" ] || continue
        [ "$cand" = "${vd_posix}/$tail" ] && return 0
        vd_mixed="$vd_posix"
        if command -v cygpath >/dev/null 2>&1; then
            vd_mixed=$(cygpath -m "$vd_posix" 2>/dev/null || printf '%s' "$vd_posix")
        fi
        # Same HIMMEL-1682 CR round 8 guard: only re-compare case-insensitively
        # when cygpath produced a DISTINCT mixed form.
        [ "$vd_mixed" != "$vd_posix" ] || continue
        lc_cand=$(_lc "$cand")
        lc_b=$(_lc "${vd_mixed}/$tail")
        [ "$lc_cand" = "$lc_b" ] && return 0
    done
    return 1
}

is_engine_binary() {
    case "$1" in
        python|python3|node|bash) return 0 ;;
    esac
    return 1
}

# Optional `uv run [--python <ver>] python` prefix ahead of the script token
# (HIMMEL-2124) -- the one shape harvest-clip-body-batch.py's own leg docs use
# (ig-media-enrich.md/x-media-enrich.md). Only this segment's own caller
# (segment_is_engine) may treat a match as an engine invocation, and it does
# so ONLY for the harvest suffix -- see the via_uv guard there. `--python`'s
# value must be a literal digits-and-dots version string (no $, no glob): same
# fail-safe posture as every other literal-token check in this file. Sets
# UV_PREFIX_LEN to the number of tokens the matched prefix consumed. Returns 1
# (no match, do not grant) on anything else, including a bare `uv` with no
# `run` or no trailing `python`.
match_uv_prefix() {
    local -a w=("$@")
    local n=${#w[@]}
    UV_PREFIX_LEN=0
    [ "$n" -ge 3 ] || return 1
    [ "${w[0]}" = "uv" ] && [ "${w[1]}" = "run" ] || return 1
    local idx=2 ver
    if [ "$idx" -lt "$n" ] && [ "${w[$idx]}" = "--python" ]; then
        ver="${w[$((idx + 1))]:-}"
        # Digits-and-dots only (rejects $, globs, an absent value), AND a real
        # numeric version shape -- RETASK R2124A codex-3: the digits-and-dots
        # charset check alone still let `.`/`..` through (neither contains a
        # char outside 0-9.). Equivalent to ^[0-9]+(\.[0-9]+)*$: also refuses
        # empty, a leading or trailing dot, and a doubled dot.
        case "$ver" in
            ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
        esac
        idx=$((idx + 2))
    fi
    [ "$idx" -lt "$n" ] && [ "${w[$idx]}" = "python" ] || return 1
    UV_PREFIX_LEN=$((idx + 1))
    return 0
}

# Is $1 (already normalized) the session's own cwd -- SESSION_CWD_POSIX /
# SESSION_CWD_MIXED, computed later in the main flow from the hook payload's
# `.tool_input.cwd`/`.cwd` -- or nested under it? Mirrors path_is_rooted_engine's
# dual-form (exact POSIX, case-insensitive mixed) compare and the same
# cygpath-less guard (HIMMEL-1682 CR round 8): without a cygpath-produced
# DISTINCT mixed root, re-comparing the identical POSIX string case-
# insensitively would auto-allow a case-twin POSIX path naming a DIFFERENT
# file on a case-sensitive filesystem.
path_is_under_session_cwd() {
    local cand="$1" lc_cand lc_root
    [ "$cand" = "$SESSION_CWD_POSIX" ] && return 0
    case "$cand" in "$SESSION_CWD_POSIX"/*) return 0 ;; esac
    [ "$SESSION_CWD_MIXED" != "$SESSION_CWD_POSIX" ] || return 1
    lc_cand=$(_lc "$cand")
    lc_root=$(_lc "$SESSION_CWD_MIXED")
    [ "$lc_cand" = "$lc_root" ] && return 0
    case "$lc_cand" in "$lc_root"/*) return 0 ;; esac
    return 1
}

# Strip ONE surrounding quote pair (single or double) and fold backslashes to
# forward slashes. The token comes from a quote-naive `read -ra` split, so a
# quoted script path still carries its delimiters. The single-quote char is held
# in a variable so the patterns/expansions stay shellcheck-clean.
norm_path() {
    local p="$1" sq="'" dq="\""
    case "$p" in
        "$sq"*) p="${p#"$sq"}"; p="${p%"$sq"}" ;;
        "$dq"*) p="${p#"$dq"}"; p="${p%"$dq"}" ;;
    esac
    # Fold backslashes to forward slashes so a Windows engine path matches the
    # suffix. `'\\'` is correct: single quotes pass two backslashes literally and
    # tr unescapes them to one (SC1003 is a false positive on this idiom).
    # shellcheck disable=SC1003
    printf '%s' "$p" | tr '\\' '/'
}

# Is `flag` a known-safe boolean flag for the engine matched at suffix `esuf`?
# Safe = takes no value and cannot redirect input/output outside the vault.
# Per-engine, keyed by suffix so a future leg's flags stay scoped to its own
# engine. vault-lint's set is derived from its SKILL.md documented flags
# (marketplace/plugins/obsidian-triage/skills/vault-lint/SKILL.md):
#   --json       prints full detail to stdout only; no file I/O change.
#   --no-report  suppresses the written report; removes a write, adds none.
# `--config PATH` is deliberately EXCLUDED (HIMMEL-1682 leg-16, codex-adv
# HIGH): it points the engine at an attacker-choosable JSON file whose
# `report_path` is join()'d without containment and opened "w" in
# vault_lint.py -- an arbitrary-file-write primitive riding this hook's
# auto-allow. vault_lint.py's argparse defines no other path-valued flag, so
# none is added here; a future one would need its own containment check, not
# a bare inclusion in this list.
#
# HIMMEL-2124 addendum: several of the newly-enumerated engines document
# VALUE-taking flags (`--limit N`, `--scan-only FILE`, ...). This function only
# ever judges the FLAG TOKEN itself -- segment_is_engine's tail loop checks
# each token independently, so a flag's value is a SEPARATE token that still
# has to clear arg_is_vault_safe on its own merits (path containment, no `..`,
# no `$`/glob/tilde). That is exactly the same one-hop safety vault_lint's
# --json/--no-report get; it differs from vault_lint's excluded --config only
# in that none of these tools re-read their path argument as a config file
# with a SECOND, uncontained embedded path (the two-hop risk --config carries)
# -- each value here is used directly, so containing the CLI token is enough.
flag_is_safe() {
    local esuf="$1" flag="$2"
    case "$esuf" in
        "$VAULT_LINT_SUFFIX")
            case "$flag" in
                --json|--no-report) return 0 ;;
            esac
            return 1 ;;
        "$HARVEST_SUFFIX")
            case "$flag" in
                --dry-run|--rescan-flags|--firecrawl-thin| \
                --limit|--date|--scan-only|--firecrawl-budget) return 0 ;;
            esac
            return 1 ;;
        "$IG_MEDIA_FETCH_SUFFIX")
            case "$flag" in
                --dry-run|--include-evidence| \
                --limit|--whisper-model|--apply-digest|--digest-file| \
                --flag-screen|--detail) return 0 ;;
            esac
            return 1 ;;
        "$EVIDENCE_KIND_SUFFIX")
            case "$flag" in
                --type|--url|--tags) return 0 ;;
            esac
            return 1 ;;
        "$DAILY_TIMELINE_SUFFIX")
            case "$flag" in
                --vault|--date|--daily) return 0 ;;
            esac
            return 1 ;;
        "$FXTWITTER_SUFFIX")
            # HIMMEL-2124 acceptance-leg gap: --vault/--limit are value-taking
            # but the value is a SEPARATE token still gated by
            # arg_is_vault_safe (same one-hop pattern as DAILY_TIMELINE_SUFFIX's
            # --vault / HARVEST_SUFFIX's --limit above); --dry-run/--reflag take
            # no value at all. No --config-shaped (embedded second path) or
            # output-redirect flag exists in fxtwitter-enrich.mjs's parser
            # (tools/fxtwitter-enrich.mjs argv loop) -- nothing to exclude.
            case "$flag" in
                --vault|--limit|--dry-run|--reflag) return 0 ;;
            esac
            return 1 ;;
        "$REDDIT_ENRICH_SUFFIX")
            # Same one-hop reasoning as FXTWITTER_SUFFIX above; reddit-enrich.mjs's
            # own argv loop defines --vault/--limit/--dry-run/--include-evidence
            # and nothing path-valued beyond --vault. No --config-shaped flag to
            # exclude.
            case "$flag" in
                --vault|--limit|--dry-run|--include-evidence) return 0 ;;
            esac
            return 1 ;;
    esac
    return 1
}

# Is $1 a token that can only ever resolve inside the vault the cadence
# session is running in? A RELATIVE token with no `..` segment can never
# escape whatever directory it is resolved against, so it is safe regardless
# of what that directory actually is. An ABSOLUTE token (POSIX or Windows
# drive-letter) is trusted only when it names -- or nests under -- the
# session's own cwd (SESSION_CWD_POSIX/SESSION_CWD_MIXED, resolved in the
# main flow). No resolvable session cwd -> an absolute token is refused
# outright: fail-safe, mirrors the ROOT ANCHOR's "no root -> no grant".
arg_is_vault_safe() {
    local tok="$1" norm
    # Unprovable literal -- a shell variable can resolve to anything the
    # cadence's environment holds, which this hook cannot audit (same
    # fail-safe rule already applied to the engine script token).
    case "$tok" in *'$'*) return 1 ;; esac
    norm=$(norm_path "$tok")
    [ -n "$norm" ] || return 1
    # Same fail-safe for the other shell-expansion forms (HIMMEL-1682
    # leg-16, gate panel + codex-adv): a literal-looking relative token
    # still expands OUTSIDE the vault at shell runtime via tilde expansion
    # (`~/private-vault`), brace expansion (`{a,b}`), or glob metacharacters
    # (`*`, `?`, `[`) -- none of those are provable from the token text
    # alone, so refuse rather than trust the literal reading. Checked on the
    # quote-stripped `norm` (not the raw `tok`) so a quoted `"~/foo"` -- whose
    # leading char is the quote, not the tilde -- is still caught.
    case "$norm" in '~'*) return 1 ;; esac
    case "$norm" in *'{'*|*'}'*|*'*'*|*'?'*|*'['*) return 1 ;; esac
    case "/$norm/" in */../*) return 1 ;; esac
    case "$norm" in
        /*|[A-Za-z]:/*)
            [ -n "$SESSION_CWD_POSIX" ] || return 1
            path_is_under_session_cwd "$norm" ;;
        *)
            return 0 ;;
    esac
}

# Does `script` end with any enumerated suffix for binary `bin`? The list is
# <bin>:<suffix> pairs; we match the bin explicitly so a future leg's suffix
# cannot be reached via the wrong interpreter.
script_matches_engine() {
    local bin="$1" script="$2" norm entry ebin esuf
    norm=$(norm_path "$script")
    [ -n "$norm" ] || return 1
    local OLDIFS="$IFS"
    IFS=' '
    for entry in $ENGINE_LIST; do
        ebin="${entry%%:*}"
        esuf="${entry#*:}"
        [ "$ebin" = "$bin" ] || continue
        if path_is_rooted_engine "$norm" "$esuf"; then
            # Consumed by segment_is_engine to scope flag_is_safe to the
            # engine that actually matched (HIMMEL-1682 leg-16).
            MATCHED_SUFFIX="$esuf"
            IFS="$OLDIFS"; return 0
        fi
    done
    IFS="$OLDIFS"
    return 1
}

# Quote-aware reassembly of a token the caller's naive whitespace split may
# have shredded (HIMMEL-1682 S2b, panel finding codex-1). A quoted script path
# CONTAINING SPACES survives `IFS=' ' read -ra` as multiple array elements
# (`"C:/spaced` `path/vault_lint.py"`), so norm_path's single-quote-pair strip
# never sees the whole path and the suffix match silently fails-closed —
# which is the correct failure direction, but wrong for any adopter whose
# checkout lives under a spaced path (common on Windows).
#
# $1 is the first token of the (possibly split) quoted path; "$@" after the
# shift are the tokens that follow it in the segment. If $1 does not open a
# quote, or opens and closes a quote within itself, it is already whole:
# REASM_TOKEN=$1, REASM_CONSUMED=1. Otherwise absorb subsequent tokens
# (rejoined with single spaces) until one's LAST character closes the same
# quote. Sets REASM_TOKEN (joined, quotes NOT stripped) and REASM_CONSUMED
# (how many of the passed-in tokens were absorbed, >=1). Returns 1 iff no
# token before the list is exhausted closes the quote (unterminated, or the
# quote closes somewhere other than a token boundary) — fail-safe: no grant.
reassemble_token() {
    local first="$1" sq="'" dq="\"" qc="" last joined tok consumed
    case "$first" in
        "$dq"*) qc="$dq" ;;
        "$sq"*) qc="$sq" ;;
        *) REASM_TOKEN="$first"; REASM_CONSUMED=1; return 0 ;;
    esac
    if [ "${#first}" -ge 2 ]; then
        last="${first:$((${#first} - 1)):1}"
        if [ "$last" = "$qc" ]; then
            REASM_TOKEN="$first"; REASM_CONSUMED=1; return 0
        fi
    fi
    joined="$first"; consumed=1
    shift
    while [ "$#" -gt 0 ]; do
        tok="$1"; shift
        joined="$joined $tok"
        consumed=$((consumed + 1))
        [ -n "$tok" ] || continue
        last="${tok:$((${#tok} - 1)):1}"
        if [ "$last" = "$qc" ]; then
            REASM_TOKEN="$joined"; REASM_CONSUMED="$consumed"
            return 0
        fi
    done
    return 1
}

# Is this one segment an enumerated engine invocation? Tokenise on whitespace
# (quote-naive per-token: quotes are preserved so a quoted flag stays literal,
# and the global tripwire above already rejected command substitution). Returns
# 0 = this segment is an allowed engine call.
segment_is_engine() {
    local seg="$1"
    local -a w
    # shellcheck disable=SC2206 # intentional word split for tokenisation
    IFS=' ' read -ra w <<< "$seg"
    local n=${#w[@]}
    [ "$n" -ge 2 ] || return 1
    local i=0
    # A leading VAR=val assignment is deliberately NOT skipped (HIMMEL-1682,
    # panel finding codex-1). An earlier revision skipped them on the premise
    # that an assignment "cannot turn vault_lint.py into code exec" — that
    # premise is FALSE: PYTHONPATH shadows a stdlib module the engine imports,
    # so `PYTHONPATH=/tmp python vault_lint.py` reaches arbitrary code execution
    # while collecting an automatic allow. The cadence never needs an env
    # prefix, so the fail-safe posture in this hook's header applies: the FIRST
    # token must be the interpreter itself, and an env-prefixed invocation falls
    # through ungranted to the normal permission flow.
    #
    # ONE exception (HIMMEL-2124 RETASK R2124A): the EXACT literal assignment
    # `PYTHONUTF8=1`, and ONLY when it immediately precedes the `uv run` chain,
    # is allowed. This is the documented invocation shape for the two
    # uv-capable engines (commands/ig-media-enrich.md:88 etc, README.md:118) --
    # unlike PYTHONPATH, PYTHONUTF8 is a text-encoding runtime knob; it cannot
    # shadow a module or redirect an import, so it carries none of the hijack
    # risk the rule above exists to close. Any other name, any other value, or
    # a bare-interpreter (non-uv) invocation still falls through ungranted.
    local start=0
    if [ "${w[0]}" = "PYTHONUTF8=1" ] && [ "${w[1]:-}" = "uv" ]; then
        start=1
    fi
    local bin script_idx via_uv=0
    if [ "${w[$start]}" = "uv" ]; then
        # HIMMEL-2124: `uv run [--python <ver>] python <script>` -- the shape
        # harvest-clip-body-batch.py's and ig-media-fetch.py's own leg docs
        # use. Restricted to those two engines below (after
        # script_matches_engine resolves MATCHED_SUFFIX), not opened up to
        # every python-based engine.
        match_uv_prefix "${w[@]:$start}" || return 1
        bin="python"
        script_idx=$((start + UV_PREFIX_LEN))
        via_uv=1
    else
        is_engine_binary "${w[$i]}" || return 1
        bin="${w[$i]}"
        script_idx=$((i + 1))
    fi
    [ "$script_idx" -lt "$n" ] || return 1
    # Reassemble a script token a quoted, spaced path shattered across several
    # array elements. An unterminated quote -> do not grant.
    reassemble_token "${w[@]:$script_idx}" || return 1
    local script="$REASM_TOKEN"
    local script_consumed="$REASM_CONSUMED"
    # The script must be a non-empty LITERAL path. A variable token ($ENGINE)
    # cannot be proven to be the enumerated engine, so do not grant. (The fuller
    # substitution tripwires — $(, backtick, <(, >( — are already rejected on
    # the whole command above, so only a bare `$` variable needs re-checking
    # here on the reassembled script token.)
    [ -n "$script" ] || return 1
    # shellcheck disable=SC2016 # '$' is a literal dollar-sign match pattern
    case "$script" in
        *'$'*) return 1 ;;
    esac
    script_matches_engine "$bin" "$script" || return 1
    # The uv-run prefix (with or without the PYTHONUTF8=1 lead-in above) is
    # granted ONLY for the two engines documented as using it (HIMMEL-2124) --
    # a match against any other python-bin suffix (e.g. vault_lint) via
    # `uv run ... python <script>` is refused: that leg's own docs invoke it
    # with the bare interpreter, so widening this to "any python engine, via
    # uv" is not something any leg actually needs.
    if [ "$via_uv" -eq 1 ]; then
        case "$MATCHED_SUFFIX" in
            "$HARVEST_SUFFIX"|"$IG_MEDIA_FETCH_SUFFIX") ;;
            *) return 1 ;;
        esac
    fi
    # Trailing args are constrained too (HIMMEL-1682 leg-16, codex-adv HIGH —
    # see the file header SAFETY MODEL point 6). MATCHED_SUFFIX was set by
    # script_matches_engine above. Every remaining token must be a per-engine
    # safe flag or a path that can only resolve inside the vault; ANY other
    # token -> do not grant (fall through to the normal permission flow).
    #
    # RETASK R2124A IMPORTANT: `tok` is quote-normalized (norm_path) BEFORE
    # the `-*` dispatch, not after. reassemble_token deliberately does NOT
    # strip quotes (its own contract: "quotes NOT stripped"), so a quoted
    # excluded flag like `"--config"` doesn't start with `-` raw, skips
    # flag_is_safe entirely, and would otherwise fall to arg_is_vault_safe --
    # which DOES quote-strip internally and would then wave it through as a
    # harmless-looking relative path. Same root cause as segment_is_gh_read's
    # fix above; norm_path is idempotent, so re-applying it inside
    # arg_is_vault_safe on an already-stripped token is a no-op.
    local idx=$((script_idx + script_consumed))
    local tok
    while [ "$idx" -lt "$n" ]; do
        reassemble_token "${w[@]:$idx}" || return 1
        tok=$(norm_path "$REASM_TOKEN")
        idx=$((idx + REASM_CONSUMED))
        case "$tok" in
            -*) flag_is_safe "$MATCHED_SUFFIX" "$tok" || return 1 ;;
            *)  arg_is_vault_safe "$tok" || return 1 ;;
        esac
    done
    return 0
}

# A benign nav wrapper that may prefix the engine call (changes cwd only).
# Tightened (HIMMEL-1682 panel finding codex-1, Suggestion): a judge review
# confirmed the previous "cmd + arbitrary trailing tokens" shape was not
# exploitable (extras become invalid cd args; bash rejects >1 arg, nothing
# executes) — but a grant shouldn't cover more shape than the cadence needs.
# Require cmd + AT MOST one dir argument, allowing that argument to be a
# quoted, spaced path via the same reassembly used for the engine script.
segment_is_nav() {
    local seg="$1"
    local -a w
    IFS=' ' read -ra w <<< "$seg"
    local n=${#w[@]}
    case "${w[0]}" in
        cd|pushd|popd) ;;
        *) return 1 ;;
    esac
    [ "$n" -eq 1 ] && return 0
    reassemble_token "${w[@]:1}" || return 1
    [ $((1 + REASM_CONSUMED)) -eq "$n" ]
}

# Is this segment a READ-shaped `gh api repos/...` call (HIMMEL-2124 — see
# SAFETY MODEL point 7)? The endpoint is the (quote-reassembled) token
# immediately after `api` (every documented cadence usage puts it there, e.g.
# `gh api repos/cli/cli` / `gh api "repos/${owner}/${repo}/issues/${n}"`);
# it must start with `repos/`, carry no `$`, and carry no `..` (same
# fail-safe stance as the engine script/arg tokens — a variable endpoint
# cannot be vouched for, and `..` has no legitimate reason to appear in a
# repo-scoped API path).
#
# RETASK R2124A (3rd review round, root-cause fix): every OTHER token must be
# in an explicit ALLOWLIST of known-safe `gh api` flags -- ANYTHING else
# refuses the whole segment. This replaced a DENYLIST (name each dangerous
# flag) after that shape failed three review rounds in a row (-X/-f/--method/
# --hostname enumerated one at a time, then --raw-field missed, then a
# backslash-escaped `--met\hod` evaded the literal-string comparison). A
# denylist for an external CLI's flag surface is structurally unwinnable --
# there is always one more flag. An allowlist closes the whole family at
# once: `--raw-field`, `--hostname`, a future gh write flag, AND a
# backslash-escaped or otherwise mangled token are all just "not in the
# allowlist" -> refused by the same default branch, with no need to model
# how the mangling works. Safe flags (gh api's own docs):
#   --jq/-q <expr>     read-only local JSON filtering
#   --paginate         follows pagination links (still GET-only under this
#                      gate, since -X/--method aren't on the allowlist at all)
#   --cache <dur>      client-side response caching
#   --slurp            wraps paginated --jq results in an array
#   -H/--header <val>  a request header; cannot induce a write or change host
# The value immediately after a value-taking safe flag is consumed as ITS
# value without being separately classified (it's free-form content, e.g. a
# jq expression -- not a flag to allowlist against); a bare token that is
# NOT one of the flags above, and was NOT consumed as such a value, refuses
# the segment. Every token (endpoint and flags alike) is quote-normalized
# (norm_path: strip one quote layer, fold backslashes) before comparison --
# bash strips quotes before argv reaches a real process, so a quoted safe
# flag (`"--jq"`) must still match, exactly as a quoted UNSAFE one must still
# fail to match anything on the allowlist.
segment_is_gh_read() {
    local seg="$1"
    local -a w
    IFS=' ' read -ra w <<< "$seg"
    local n=${#w[@]}
    [ "$n" -ge 3 ] || return 1
    [ "${w[0]}" = "gh" ] && [ "${w[1]}" = "api" ] || return 1
    # Reassemble the endpoint the same way segment_is_engine reassembles its
    # script/arg tokens (RETASK R2124A minor, earlier round): a raw `read -ra`
    # split can leave a stray trailing quote/separator char on a naively-split
    # token even though the real shell kept it one literal argument. Not
    # exploitable today (the real process never sees the phantom split), but
    # this keeps the hook's own view of "the endpoint" matching what actually
    # runs instead of drifting from it.
    reassemble_token "${w[@]:2}" || return 1
    local endpoint="$REASM_TOKEN"
    local endpoint_consumed="$REASM_CONSUMED"
    endpoint=$(norm_path "$endpoint")
    [ -n "$endpoint" ] || return 1
    # shellcheck disable=SC2016 # '$' is a literal dollar-sign match pattern
    case "$endpoint" in *'$'*) return 1 ;; esac
    case "$endpoint" in repos/*) ;; *) return 1 ;; esac
    case "$endpoint" in *'..'*) return 1 ;; esac
    local idx=$((2 + endpoint_consumed)) tok
    while [ "$idx" -lt "$n" ]; do
        reassemble_token "${w[@]:$idx}" || return 1
        tok=$(norm_path "$REASM_TOKEN")
        idx=$((idx + REASM_CONSUMED))
        case "$tok" in
            --paginate|--slurp) ;;
            --jq|-q|--cache|-H|--header)
                # Value-taking safe flag: consume the NEXT token as its value,
                # unexamined (free-form content, not itself a flag to
                # allowlist). Missing value -> refuse (fail-safe).
                [ "$idx" -lt "$n" ] || return 1
                reassemble_token "${w[@]:$idx}" || return 1
                idx=$((idx + REASM_CONSUMED)) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Quote-aware structural scan (modelled on auto-approve-safe-bash's scan_cmd,
# HIMMEL-209). Walks char by char tracking single/double-quote state so command
# separators (; | || && & newline) and `>` redirects INSIDE quotes stay literal.
# Produces two globals, returns 1 (do not grant) on unbalanced quotes OR an
# unquoted bare `&` (backgrounding — HIMMEL-1682 CR round 5):
#   SCAN_SEGS — top-level segments (ORIGINAL text, one per line) split ONLY at
#               UNQUOTED separators.
#   SCAN_MASK — the command with every quoted span (+ quote delims + escaped
#               chars) replaced by spaces, so the redirect detector sees only
#               UNQUOTED '>'.
# bash 3.2-safe: only ${s:i:1}, ${#s}, arithmetic.
split_and_mask() {
    local s="$1" n i c nx p st seg NL
    NL=$'\n'
    n=${#s}; i=0; st=0; seg=""; SCAN_SEGS=""; SCAN_MASK=""
    while [ "$i" -lt "$n" ]; do
        c="${s:$i:1}"
        if [ "$st" = 1 ]; then                       # inside single quotes
            seg="$seg${c/"$NL"/ }"; SCAN_MASK="$SCAN_MASK "
            [ "$c" = "'" ] && st=0
            i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                       # inside double quotes
            if [ "$c" = "\\" ]; then                 # \<x> keeps next char literal
                nx="${s:$((i + 1)):1}"
                seg="$seg${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK="$SCAN_MASK  "
                i=$((i + 2)); continue
            fi
            seg="$seg${c/"$NL"/ }"; SCAN_MASK="$SCAN_MASK "
            [ "$c" = '"' ] && st=0
            i=$((i + 1)); continue
        fi
        # --- unquoted ---
        nx="${s:$((i + 1)):1}"
        case "$c" in
            "'") st=1; seg="$seg$c"; SCAN_MASK="$SCAN_MASK "; i=$((i + 1)); continue ;;
            '"') st=2; seg="$seg$c"; SCAN_MASK="$SCAN_MASK "; i=$((i + 1)); continue ;;
            "\\") seg="$seg${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK="$SCAN_MASK  "; i=$((i + 2)); continue ;;
            ';'|"$NL")                               # statement separator
                SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                SCAN_MASK="$SCAN_MASK$c"; i=$((i + 1)); continue ;;
            '|')                                     # | or || -> one break
                SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                SCAN_MASK="$SCAN_MASK|"
                if [ "$nx" = '|' ]; then SCAN_MASK="$SCAN_MASK|"; i=$((i + 2)); else i=$((i + 1)); fi
                continue ;;
            '&')
                if [ "$nx" = '&' ]; then             # && logical-AND -> break
                    SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                    SCAN_MASK="$SCAN_MASK&&"; i=$((i + 2)); continue
                fi
                if [ "$nx" = '>' ]; then             # &> redirect form -> keep
                    seg="$seg$c"; SCAN_MASK="$SCAN_MASK&"; i=$((i + 1)); continue
                fi
                p=""; [ "$i" -gt 0 ] && p="${s:$((i - 1)):1}"
                case "$p" in                         # fd-dup 2>&1 / >&2 -> keep
                    '>'|'<'|'&') seg="$seg$c"; SCAN_MASK="$SCAN_MASK&"; i=$((i + 1)); continue ;;
                esac
                # HIMMEL-1682 CR round 5 Major: a bare (unquoted) & backgrounds the
                # preceding segment. Splitting it into a segment break left a
                # trailing "python <engine> vault &" producing an engine segment
                # plus an EMPTY tail; the main loop skips empty tails, so the hook
                # allowed while the shell ran the engine detached in the
                # background — defeating this PR's own run_in_background deny.
                # The cadence never needs backgrounding, so refuse outright
                # rather than split.
                return 1 ;;
        esac
        seg="$seg$c"; SCAN_MASK="$SCAN_MASK$c"; i=$((i + 1))
    done
    [ "$st" = 0 ] || return 1                        # unbalanced quote -> no grant
    SCAN_SEGS="$SCAN_SEGS$seg"
    return 0
}

emit_allow() {
    local reason
    reason=$(printf 'cadence-approve-engines: %s' "$1" | jq -Rs . 2>/dev/null) || reason='"enumerated cadence engine"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
    exit 0
}

# --- Fail open on anything we cannot evaluate ---
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Session cwd (HIMMEL-1682 leg-16), same field + fallback order
# block-graphify-egress.sh / block-terminal-write-fence.sh already trust: the
# tool call's own cwd wins over the session-level one, since that is where the
# agent will actually run the command. This is the vault root arg_is_vault_safe
# containment-checks an absolute trailing arg against — the cadence runner
# fires claude in the vault cwd (see file header). Unresolvable/absent ->
# both stay empty, and arg_is_vault_safe refuses every absolute arg (fail-safe;
# relative, `..`-free args need no cwd and are unaffected).
cwd_raw=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
SESSION_CWD_POSIX=""
SESSION_CWD_MIXED=""
if [ -n "$cwd_raw" ]; then
    # shellcheck disable=SC1003 # '\\' is tr's two-char escape for one backslash
    cwd_folded=$(printf '%s' "$cwd_raw" | tr '\\' '/')
    SESSION_CWD_POSIX="$(cd "$cwd_folded" 2>/dev/null && pwd)"
    if [ -n "$SESSION_CWD_POSIX" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            SESSION_CWD_MIXED=$(cygpath -m "$SESSION_CWD_POSIX" 2>/dev/null || printf '%s' "$SESSION_CWD_POSIX")
        else
            SESSION_CWD_MIXED="$SESSION_CWD_POSIX"
        fi
    fi
fi

# --- Global tripwires: never grant dynamic execution / substitution ---
# shellcheck disable=SC2016 # the single-quoted $( etc. are literal match patterns
case "$cmd" in
    *'$('*|*'`'*|*'<('*|*'>('*)        exit 0 ;;
esac

# Quote-aware scan -> segments + redirect mask. Unbalanced quote -> no grant.
split_and_mask "$cmd" || exit 0

# Heredocs turn following lines into redirection data, but the segment scanner
# treats those lines as commands. Reject the unquoted forms outright rather
# than risk granting a body/delimiter made entirely of benign-nav tokens.
case "$SCAN_MASK" in
    *'<<'*) exit 0 ;;
esac

# Shell-level redirect to a real file -> not granted. A grant must enable ONLY
# the enumerated engine + its arg list, never reshape the process's I/O at the
# shell level, so BOTH output (`>`/`>>`) and unquoted INPUT (`<`) redirection
# are rejected (HIMMEL-1682 CR r3 nitpick: an unquoted `< file` formerly slipped
# past a `>`-only check). /dev/null sinks + fd-dups are stripped first as
# benign; the heredoc and process-substitution forms (`<<`, `<(`) are already
# rejected above, so a surviving unquoted `<`/`>` is a real file redirect.
# shellcheck disable=SC2001 # sed is needed for the bracketed /dev/null anchors
rd=$(printf '%s' "$SCAN_MASK" | sed -E \
    -e 's@&?>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>&[0-9]@ @g' \
    -e 's@[0-9]*<&[0-9-]@ @g')
case "$rd" in
    *'>'*|*'<'*) exit 0 ;;
esac

# --- Every segment must be an enumerated engine or a benign nav wrapper,
# AND at least one segment must actually BE an enumerated engine (HIMMEL-1688
# item 2). Without this, a nav-only command (e.g. a bare `cd /tmp`) satisfied
# the "every segment is engine-or-nav" test vacuously and collected an
# allow with a false "vault-lint engine" reason, even though no engine was
# present. Harmless in effect (cd executes nothing), but contradicts this
# hook's contract of granting only enumerated cadence engines.
saw_engine=0
while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    [ -z "$seg" ] && continue
    if segment_is_engine "$seg"; then
        saw_engine=1
    elif segment_is_gh_read "$seg"; then
        saw_engine=1
    elif ! segment_is_nav "$seg"; then
        exit 0
    fi
done <<< "$SCAN_SEGS"
[ "$saw_engine" -eq 1 ] || exit 0

emit_allow "enumerated cadence engine or read-only gh api call (HIMMEL-1386/2124)"
