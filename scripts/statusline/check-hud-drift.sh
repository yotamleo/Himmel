#!/usr/bin/env bash
# hud-drift: fail when the vendored claude-hud tree diverges from its recorded
# pin (HIMMEL-718 Task 1.2). himmel-contributor-only (gated by .himmel-dev).
#
# Default: verify — recompute the upstream-derived-subtree hash and compare to
# `vendored_tree_hash` in VENDORED.md; on mismatch print offending paths + the
# pin-bump command. `--write`: recompute and record (pin bump / first vendor).
# rc: 0 pass | 1 drift | 2 cannot-evaluate (fail-closed).
#
# Hash scope: every git-tracked file under the vendored dir EXCEPT the
# himmel-owned files (VENDORED.md, VENDORED.manifest, .gitignore, config/**) —
# see VENDORED.md "Drift guard". Per-file `git hash-object` (content-addressed,
# CRLF-filter-aware — platform-stable where raw sha256sum is not under
# autocrlf), sorted by path into VENDORED.manifest; the aggregate sha256 of the
# manifest body is `vendored_tree_hash`. bash 3.2-safe.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HUD_REL="marketplace/plugins/claude-hud"
# himmel-owned paths under $HUD_REL, excluded from the drift hash (keep in
# sync with VENDORED.md "himmel-owned files"). File alternatives are
# right-anchored so e.g. an upstream VENDORED.mdx stays IN the hash scope.
OWNED_RE='^(VENDORED\.md$|VENDORED\.manifest$|\.gitignore$|config/)'

# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ hud-drift: cannot source guardrails/lib.sh — fail-closed" >&2; exit 2
fi
rc=0; is_himmel_dev_repo || rc=$?
[ "$rc" -eq 2 ] && { echo "→ hud-drift: cannot resolve repo root — fail-closed" >&2; exit 2; }
[ "$rc" -eq 1 ] && exit 0   # not a contributor checkout → no-op
if [ "${HUD_DRIFT_OK:-0}" = "1" ]; then
    echo "→ hud-drift: HUD_DRIFT_OK=1 — skipping (verify the vendored tree manually)" >&2; exit 0
fi

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "→ hud-drift: cannot resolve repo root — fail-closed" >&2; exit 2; }
HUD_DIR="$top/$HUD_REL"
VENDORED_MD="$HUD_DIR/VENDORED.md"
MANIFEST="$HUD_DIR/VENDORED.manifest"
[ -d "$HUD_DIR" ] || { echo "→ hud-drift: $HUD_REL missing in a .himmel-dev checkout — fail-closed" >&2; exit 2; }
[ -f "$VENDORED_MD" ] || { echo "→ hud-drift: $HUD_REL/VENDORED.md missing — fail-closed" >&2; exit 2; }

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'
    fi
}

# Enumerate upstream-derived files: tracked (incl. staged-new) under $HUD_REL,
# minus himmel-owned. Paths relative to $HUD_REL so the manifest is stable if
# the vendored dir ever moves.
files=$(git -C "$top" ls-files -- "$HUD_REL" \
    | sed "s|^$HUD_REL/||" \
    | grep -vE "$OWNED_RE" \
    | LC_ALL=C sort) || true
if [ -z "$files" ]; then
    echo "→ hud-drift: no upstream-derived files tracked under $HUD_REL — fail-closed" >&2; exit 2
fi

computed="" ; missing=""
while IFS= read -r f; do
    if [ ! -f "$HUD_DIR/$f" ]; then
        missing="${missing}     MISSING  ${f}"$'\n'
        continue
    fi
    h=$(git -C "$top" hash-object -- "$HUD_REL/$f") || { echo "→ hud-drift: hash-object failed on $f — fail-closed" >&2; exit 2; }
    computed="${computed}${h}  ${f}"$'\n'
done <<EOF
$files
EOF

agg=$(printf '%s' "$computed" | sha256_stdin) \
    || { echo "→ hud-drift: sha256 tool unavailable — fail-closed" >&2; exit 2; }

if [ "${1:-}" = "--write" ]; then
    if [ -n "$missing" ]; then
        echo "⛔ hud-drift: refusing --write, tracked vendored files missing on disk:" >&2
        printf '%s' "$missing" >&2
        exit 1
    fi
    # sed substitution on a missing line is a silent no-op — require the line
    # up front so --write cannot claim success without recording the pin.
    if ! grep -q '^vendored_tree_hash:' "$VENDORED_MD"; then
        echo "→ hud-drift: VENDORED.md has no vendored_tree_hash: line to record into — fail-closed" >&2
        exit 2
    fi
    printf '%s' "$computed" > "$MANIFEST" \
        || { echo "→ hud-drift: manifest write failed — fail-closed" >&2; exit 2; }
    tmp="$VENDORED_MD.tmp.$$"
    sed "s|^vendored_tree_hash:.*|vendored_tree_hash:   $agg  # sha256 over VENDORED.manifest|" \
        "$VENDORED_MD" > "$tmp" || { rm -f "$tmp"; echo "→ hud-drift: sed rewrite failed — fail-closed" >&2; exit 2; }
    mv "$tmp" "$VENDORED_MD" \
        || { rm -f "$tmp"; echo "→ hud-drift: mv rewrite failed — fail-closed" >&2; exit 2; }
    grep -q "^vendored_tree_hash:   $agg" "$VENDORED_MD" \
        || { echo "→ hud-drift: pin not recorded after rewrite — fail-closed" >&2; exit 2; }
    echo "→ hud-drift: recorded vendored_tree_hash=$agg (+ $(printf '%s' "$computed" | grep -c .) files in VENDORED.manifest)"
    echo "  Commit $HUD_REL/VENDORED.md + $HUD_REL/VENDORED.manifest with the pin bump."
    exit 0
fi

# grep -m1 + awk (awk drains grep's output — no head-closes-early SIGPIPE
# under pipefail).
recorded=$(grep -m1 '^vendored_tree_hash:' "$VENDORED_MD" | awk '{print $2}') || true
[ -n "$recorded" ] || { echo "→ hud-drift: vendored_tree_hash line missing or empty in VENDORED.md — fail-closed" >&2; exit 2; }

if ! printf '%s' "$recorded" | grep -qE '^[0-9a-f]{64}$'; then
    echo "⛔ hud-drift: vendored_tree_hash is unset ($recorded)." >&2
    echo "   Record the pin:  bash scripts/statusline/check-hud-drift.sh --write" >&2
    exit 1
fi

if [ "$agg" = "$recorded" ] && [ -z "$missing" ]; then
    exit 0
fi

echo "⛔ hud-drift: vendored claude-hud tree diverges from the recorded pin." >&2
[ -n "$missing" ] && printf '%s' "$missing" >&2
if [ -f "$MANIFEST" ]; then
    # Offending paths: manifest lines that changed in either direction. The
    # stored manifest is already in canonical path order (written by --write) —
    # do NOT re-sort it here: `sort` on "hash  path" lines keys on the HASH and
    # would reorder the whole file, making diff report every line as changed.
    tmp_new="$(mktemp)"
    printf '%s' "$computed" > "$tmp_new"
    echo "   offending paths (vs VENDORED.manifest):" >&2
    # sed (not awk field-print) so paths containing spaces survive intact.
    # Hash width 40 (SHA-1) or 64 (SHA-256 object repos) — mirrors the .ps1
    # twin's hash-length-agnostic split so both list offending paths either way.
    diff "$MANIFEST" "$tmp_new" | sed -n -E 's/^< [0-9a-f]{40,64}  /     pinned   /p; s/^> [0-9a-f]{40,64}  /     on-disk  /p' | LC_ALL=C sort -u -k2 >&2 || true
    rm -f "$tmp_new"
else
    echo "   (VENDORED.manifest missing — cannot list offending paths)" >&2
fi
cat >&2 <<EOF
   If this is an INTENTIONAL pin bump / re-vendor:
     bash scripts/statusline/check-hud-drift.sh --write   # then commit VENDORED.md + VENDORED.manifest
   Otherwise restore the file(s) to the pinned content (see VENDORED.md).
   Bypass (rare):  HUD_DRIFT_OK=1 git commit ...  (per-session env, not a prefix).
EOF
exit 1
