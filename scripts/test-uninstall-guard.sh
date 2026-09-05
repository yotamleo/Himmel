#!/usr/bin/env bash
# Isolated predicate harness for suspicious_rm_path in scripts/uninstall.sh
# (HIMMEL-2503, the rule Ruling 135 wrote down after the 2026-09-03 wipe).
#
# The guard is asserted DIRECTLY: `. uninstall.sh --source-only` defines the
# functions and stops before the banner, so every row below is a return code.
# No uninstall.sh run, no removal, no real path — the worst a broken guard can
# do here is print FAIL. This is where the guard is mutation-proven (drop an
# arm in a scratch copy, the matching rows go red). NEVER prove it by
# reverting the guard in-tree and running scripts/test-uninstall.sh: its wet
# rows rely on this guard as their only protection (HIMMEL-2502).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-guard.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A fake HOME: the guard compares against $HOME, and no row here may depend
# on — or even resolve — the operator's real one.
HOME="$TMP/home"
export HOME
mkdir -p "$HOME/.claude/himmel" "$TMP/deep/cache"

# shellcheck source=uninstall.sh
# shellcheck disable=SC1091
. "$HERE/uninstall.sh" --source-only

refused() {
    if suspicious_rm_path "$1"; then
        echo "PASS refused: '$1'"
    else
        echo "FAIL allowed: '$1'"
        FAILED=$((FAILED + 1))
    fi
}
allowed() {
    if suspicious_rm_path "$1"; then
        echo "FAIL over-refused: '$1'"
        FAILED=$((FAILED + 1))
    else
        echo "PASS allowed: '$1'"
    fi
}

# HIMMEL-2505: protected_path is a SEPARATE predicate from suspicious_rm_path
# (which now calls it first) — exercise it directly so a regression in the
# fixed allowlist shows up here, not only through the combined guard above.
refused_protected() {
    if protected_path "$1"; then
        echo "PASS protected_path refused: '$1'"
    else
        echo "FAIL protected_path allowed: '$1'"
        FAILED=$((FAILED + 1))
    fi
}
allowed_protected() {
    if protected_path "$1"; then
        echo "FAIL protected_path over-refused: '$1'"
        FAILED=$((FAILED + 1))
    else
        echo "PASS protected_path allowed: '$1'"
    fi
}

# ── roots the guard must refuse ─────────────────────────────────────────────
refused ''
refused '/'
refused "$HOME"
refused "$HOME/"
# Windows drive roots by RAW spelling — refused before any `cd`, so these hold
# on every platform, not only where `cd -- "C:/"` succeeds.
for p in 'C:' 'C:/' "C:\\" 'c:/' 'D:/' "Z:\\"; do
    refused "$p"
done
# The MSYS-canonicalized form of a drive root (`C:/` -> `/c`) — only reachable
# where such a mount exists (Git Bash / MSYS); the arm itself is exercised on
# every platform by the one-letter top-level dir below.
if [ -d /c ]; then
    refused '/c'
    refused '/c/'
else
    echo "SKIP /c rows — no /c mount on this platform"
fi
# A one-letter top-level dir on POSIX (`/x`) resolves to the same shape as a
# drive root and is refused by design — fail-closed. Only asserted where one
# exists; never created (that would be a write outside $TMP).
_one_letter=""
for _d in /[A-Za-z]; do
    [ -d "$_d" ] && { _one_letter="$_d"; break; }
done
if [ -n "$_one_letter" ]; then
    refused "$_one_letter"
else
    echo "SKIP one-letter top-level dir row — none present"
fi

# ── positive controls: real subpaths must PASS the guard ────────────────────
# Without these a guard that refused everything would pass every row above.
allowed "$TMP/deep/cache"
allowed "$HOME/.claude/himmel"
allowed 'C:/Users/somebody/.claude/himmel'   # a drive SUBPATH, not a root
allowed "$TMP/does-not-exist"               # absent target: nothing to refuse

# ── protected_path (HIMMEL-2505): the fixed hard-refuse allowlist ───────────
# Every entry in the fixed set must refuse, independent of suspicious_rm_path.
for p in '/' "$HOME" "$HOME/.claude" "$HOME/.claude.json" "$HOME/.claude/.credentials.json" \
         "$HOME/.claude/settings.json" "$HOME/.claude/plugins" "$HOME/.claude/projects" \
         "$HOME/.codex" "$HOME/.ssh" "$HOME/.gitconfig" "$HOME/.config" "$HOME/.local" \
         "$HOME/.cache" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc" "$HOME/Documents" \
         '/etc' '/usr' '/bin' '/var' '/opt'; do
    refused_protected "$p"
done
# $HOME/.claude/.. resolves to $HOME (canonicalization must survive traversal,
# not just a literal-string alias).
refused_protected "$HOME/.claude/.."

# The three fixed removal targets stay allowed — descendants of the
# protected $HOME/.claude, not ancestors of it.
allowed_protected "$HOME/.claude/himmel"
allowed_protected "$HOME/.claude/channels/telegram"
allowed_protected "$HOME/.claude/handover/bridge"
# A non-existent target under $HOME/.claude that is NOT one of the three
# documented removal targets is a descendant of protected $HOME/.claude and
# is refused (HIMMEL-2505 gap 2, below) — the tail-reappension property this
# row used to exercise (canonicalize a nearest EXISTING ancestor and
# re-append the missing tail, rather than collapsing to the ancestor alone)
# is still covered by the two non-existent ALLOWED targets above
# ($HOME/.claude/channels/telegram, $HOME/.claude/handover/bridge).
refused_protected "$HOME/.claude/himmel-not-created-yet"
# /tmp is an ancestor of this suite's own $TMP fixture and must NOT be added
# to the protected set — a fixture path under /tmp stays allowed.
allowed_protected "/tmp/uninstall-guard-protected-fixture-$$"

# ── HIMMEL-2505 gap 2: a DESCENDANT of a protected path is refused too,
# unless it names exactly one of the three documented removal targets ────
mkdir -p "$HOME/.ssh/keys"
refused_protected "$HOME/.ssh/keys"
refused_protected "$HOME/Documents/project"
refused_protected "$HOME/.claude/plugins/x"
refused_protected "$HOME/.config/x"
# The three documented targets stay allowed even though each is a descendant
# of protected $HOME/.claude — re-asserted here alongside the gap-2 rows
# above (also covered as positive controls earlier in this file).
allowed_protected "$HOME/.claude/himmel"
allowed_protected "$HOME/.claude/channels/telegram"
allowed_protected "$HOME/.claude/handover/bridge"
# A fixture under /tmp (not a descendant of any protected path) stays
# allowed by the gap-2 descendant check too.
allowed_protected "$TMP/anything"

# ── HIMMEL-2505 gap A (revised): the allowed-target exemption is now TWO
# conditions, both required — (1) LEXICAL identity (normalize_lexical, pure
# string, no filesystem access) against one of the three documented
# suffixes, AND (2) no path component between $HOME (exclusive) and the
# leaf (inclusive) is, on disk, a symlink. Neither condition alone is
# enough: a symlinked ANCESTOR between $HOME and the leaf (row a, and again
# outside $HOME entirely in row a2) still routes a lexically-matching
# target into real user data unless the walk catches it; row (b) proves the
# same hazard one component higher, a symlinked $HOME/.claude itself. A
# symlinked $HOME itself is deliberately out of scope: the walk starts at
# $HOME and only inspects components below it, since a relocated home moves
# the whole profile consistently and isn't the gap-A hazard of a documented
# target being routed into OTHER user data. Row (c) proves the lexical half
# in isolation (plain real dirs, so the walk never fires) and row (d) is
# the pre-existing "outside $HOME entirely" control.

# (a) $HOME/.claude/channels is a symlink to $HOME/Documents — a symlinked
# ANCESTOR of the documented telegram target. Both the override that
# literally names the real destination, and the documented target itself
# (which walks through the same symlinked parent), must refuse.
SYMA_HOME="$TMP/syma-home"
mkdir -p "$SYMA_HOME/.claude" "$SYMA_HOME/Documents"
ln -s "$SYMA_HOME/Documents" "$SYMA_HOME/.claude/channels"
_sym_saved_home="$HOME"
HOME="$SYMA_HOME"
export HOME
refused_protected "$HOME/Documents/telegram"
refused_protected "$HOME/.claude/channels/telegram"
HOME="$_sym_saved_home"
export HOME

# (a2) $HOME/.claude/channels is a symlink to a location OUTSIDE $HOME
# entirely ($TMP/syma2-elsewhere) — unlike (a), the link target isn't even
# a protected destination, so only the outright refusal (not a fallthrough
# to the protected-destination checks) catches it. Only the documented leaf
# target (.claude/channels/telegram, the only thing any real caller ever
# passes to protected_path — see CHANNEL_DIR) is asserted here: the bare
# ".claude/channels" ancestor itself is not one of the three exempted
# suffixes, so it never reaches the outright-refusal branch at all and is
# out of scope for this exemption.
SYMA2_HOME="$TMP/syma2-home"
mkdir -p "$SYMA2_HOME/.claude" "$TMP/syma2-elsewhere"
ln -s "$TMP/syma2-elsewhere" "$SYMA2_HOME/.claude/channels"
_sym_saved_home="$HOME"
HOME="$SYMA2_HOME"
export HOME
refused_protected "$HOME/.claude/channels/telegram"
HOME="$_sym_saved_home"
export HOME

# (b) $HOME/.claude itself is a symlink to $HOME/Documents/claude-elsewhere
# — a symlinked component one level higher than (a). The documented himmel
# target must still refuse.
SYMB_HOME="$TMP/symb-home"
mkdir -p "$SYMB_HOME/Documents/claude-elsewhere"
ln -s "$SYMB_HOME/Documents/claude-elsewhere" "$SYMB_HOME/.claude"
_sym_saved_home="$HOME"
HOME="$SYMB_HOME"
export HOME
refused_protected "$HOME/.claude/himmel"
HOME="$_sym_saved_home"
export HOME

# (c) plain real dirs, no symlinks anywhere: the three documented targets
# stay allowed, including through lexical ".." and collapsed "//" spellings
# that normalize_lexical must resolve without touching disk; a lexical ".."
# escape to a protected path must still refuse.
SYMC_HOME="$TMP/symc-home"
mkdir -p "$SYMC_HOME/.claude/himmel" "$SYMC_HOME/.claude/channels/telegram" \
         "$SYMC_HOME/.claude/handover/bridge" "$SYMC_HOME/Documents"
_sym_saved_home="$HOME"
HOME="$SYMC_HOME"
export HOME
allowed_protected "$HOME/.claude/himmel"
allowed_protected "$HOME/.claude/channels/telegram"
allowed_protected "$HOME/.claude/handover/bridge"
allowed_protected "$HOME/.claude/himmel/../himmel"
refused_protected "$HOME/.claude/channels/../../Documents"
allowed_protected "$HOME//.claude//himmel/"
HOME="$_sym_saved_home"
export HOME

# (d) a fixture under $TMP, outside $HOME entirely, stays allowed.
allowed_protected "$TMP/uninstall-guard-lexical-fixture-$$"

# (e) HIMMEL-2505 gap A's own gap: normalize_lexical pops ".." PURELY as a
# string, so a target spelled with a "link/.." segment can lexically
# collapse to one of the three allowed suffixes while the REAL `rm -rf`
# follows the ORIGINAL spelling — the kernel resolves "link" to wherever it
# points FIRST, then applies ".." relative to THAT, landing on whatever the
# link's parent actually contains, not the documented target. The walk must
# inspect the as-spelled components in order (link tested BEFORE the ".."
# pops it), not the lexically-collapsed ones.
SYME_HOME="$TMP/syme-home"
mkdir -p "$SYME_HOME/.claude/himmel" "$SYME_HOME/.claude/handover/bridge" \
         "$SYME_HOME/Documents/elsewhere" "$TMP/e-elsewhere"
ln -s "$SYME_HOME/Documents/elsewhere" "$SYME_HOME/.claude/link"
ln -s "$TMP/e-elsewhere" "$SYME_HOME/.claude/link2"
_sym_saved_home="$HOME"
HOME="$SYME_HOME"
export HOME
refused_protected "$HOME/.claude/link/../himmel"
refused_protected "$HOME/.claude/link/../channels/telegram"
# link2 points OUTSIDE $HOME entirely — same hazard, different destination.
refused_protected "$HOME/.claude/link2/../himmel"
# Positive controls: plain ".." through REAL (non-symlinked) dirs must stay
# allowed — the walk refusing every ".." spelling, not just symlinked ones,
# would be an over-refusal.
allowed_protected "$HOME/.claude/himmel/../himmel"
allowed_protected "$HOME/.claude/handover/../handover/bridge"
HOME="$_sym_saved_home"
export HOME

# (f) HIMMEL-2505 gap A's gap's gap: the walk returned 1 ("no symlink" =
# not blocked) whenever the AS-SPELLED target didn't literally start with
# "$HOME/" at all — but protected_path only calls the walk once the LEXICAL
# form already matched an allowed suffix, so "can't even tell if this
# reaches $HOME" must mean REFUSE, not "safe to proceed": a spelling like
# "$TMP/symf-link/../symf-home/.claude/himmel" (symf-link a SIBLING symlink
# outside $HOME entirely) lexically collapses to the allowed
# $HOME/.claude/himmel while the real removal follows "symf-link" first —
# wherever that points, not into $HOME at all. Also: a ".." that would pop
# above $HOME (not just to it) must refuse even with no symlink anywhere —
# conservative by design, since nothing above $HOME is ever in scope for
# this exemption. Popping back down to exactly $HOME stays fine.
SYMF_HOME="$TMP/symf-home"
mkdir -p "$SYMF_HOME/.claude/himmel" "$TMP/symf-elsewhere"
ln -s "$TMP/symf-elsewhere" "$TMP/symf-link"
_sym_saved_home="$HOME"
HOME="$SYMF_HOME"
export HOME
refused_protected "$TMP/symf-link/../symf-home/.claude/himmel"
refused_protected "$TMP/symf-link/../symf-home/.claude/channels/telegram"
# Escapes above $HOME via ".." even without any symlink in the spelling.
refused_protected "$HOME/../symf-home/.claude/himmel"
# Positive control: plain ".." that only ever pops back down to exactly
# $HOME (never above it), through real (non-symlinked) dirs, stays allowed.
allowed_protected "$HOME/.claude/../.claude/himmel"
HOME="$_sym_saved_home"
export HOME

# (g) HIMMEL-2505 gap 2's gap: the equality/ancestor/descendant loop over
# _protected_paths compared only the RESOLVED target — so a non-exempt
# override like "$HOME/.claude/link/data", with "$HOME/.claude/link" a
# symlink to somewhere OUTSIDE $HOME, resolves to that somewhere-else and
# matches no protected path even though, AS SPELLED, it is a strict
# descendant of protected $HOME/.claude — and the real removal follows the
# link. The same three checks (equality, target-is-ancestor-of-protected,
# target-is-strict-descendant-of-protected) must ALSO run against the pure-
# LEXICAL spelling of both the target and each protected path's own literal
# "$HOME/..." string, refusing if either form hits.
SYMG_HOME="$TMP/symg-home"
mkdir -p "$SYMG_HOME/.claude" "$SYMG_HOME/Documents" "$TMP/g-elsewhere" "$TMP/g-elsewhere2"
ln -s "$TMP/g-elsewhere" "$SYMG_HOME/.claude/link"
ln -s "$TMP/g-elsewhere2" "$SYMG_HOME/Documents/link2"
_sym_saved_home="$HOME"
HOME="$SYMG_HOME"
export HOME
refused_protected "$HOME/.claude/link/data"
refused_protected "$HOME/Documents/link2/x"
# The SAME real location, reached by its OWN spelling (not through the
# ancestor symlink), stays allowed.
allowed_protected "$TMP/g-elsewhere/data"
# The three documented targets stay allowed — the exemption branch above
# still returns before this loop ever runs.
allowed_protected "$HOME/.claude/himmel"
allowed_protected "$HOME/.claude/channels/telegram"
allowed_protected "$HOME/.claude/handover/bridge"
HOME="$_sym_saved_home"
export HOME

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
