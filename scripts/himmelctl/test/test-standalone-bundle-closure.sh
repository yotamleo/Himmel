#!/usr/bin/env bash
# test-standalone-bundle-closure.sh — drift guard for
# scripts/himmelctl/lib/standalone-bundle.js's BUNDLE_FILES_POSIX (HIMMEL-3312
# S13 item 8). Re-runs the design §3.2 closure walk transitively from
# scripts/uninstall.sh (its own grep commands, plus the `for helper in …`
# loop expanded by hand) and fails if a reached file is missing from
# BUNDLE_FILES_POSIX, a listed file does not exist, or the loop parse finds
# zero helper names. Node-entry additions (standalone.js, lib/*.js, VERSION)
# and the deliberate exclusions (scripts/telegram/*, the runtime
# $REPO_ROOT/bundle.json marker check) are not part of uninstall.sh's own
# shell closure, so they are allow-listed rather than walked.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
entry="$repo_root/scripts/uninstall.sh"
bundle_js="$repo_root/scripts/himmelctl/lib/standalone-bundle.js"
[ -f "$entry" ] || { echo "FAIL: $entry not found" >&2; exit 1; }
[ -f "$bundle_js" ] || { echo "FAIL: $bundle_js not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# Known: not part of the shell closure, deliberately excluded (design §3.2
# "referenced but not carried"), or a runtime marker path uninstall.sh reads
# to detect it's running from a bundle -- not a file it sources.
is_excluded() {
  case "$1" in
    scripts/telegram|scripts/telegram/*|bundle.json) return 0 ;;
    *) return 1 ;;
  esac
}

# normalize_ref <raw match> -- turns a $SCRIPT_DIR/... or $REPO_ROOT/...
# (or ${_PROV_LIB_DIR}/... / ${_PROVREAD_LIB_DIR}/..., both == scripts/lib)
# match into a repo-relative path, or prints nothing if it's not a concrete
# file reference (a bare directory, no trailing name).
normalize_ref() {
  local raw="$1" rel
  rel="${raw#\$\{SCRIPT_DIR\}/}"; rel="${rel#\$SCRIPT_DIR/}"
  rel="${rel#\$\{REPO_ROOT\}/}"; rel="${rel#\$REPO_ROOT/}"
  rel="${rel#\$\{_PROV_LIB_DIR\}/}"; rel="${rel#\$_PROV_LIB_DIR/}"
  rel="${rel#\$\{_PROVREAD_LIB_DIR\}/}"; rel="${rel#\$_PROVREAD_LIB_DIR/}"
  case "$raw" in
    \$\{SCRIPT_DIR\}/*|\$SCRIPT_DIR/*) rel="scripts/$rel" ;;
    \$\{_PROV_LIB_DIR\}/*|\$_PROV_LIB_DIR/*|\$\{_PROVREAD_LIB_DIR\}/*|\$_PROVREAD_LIB_DIR/*) rel="scripts/lib/$rel" ;;
  esac
  [ -n "$rel" ] && [ "${rel%/}" = "$rel" ] && printf '%s\n' "$rel"
}

# walk_broad <file> -- design §3.2 step 1: every $SCRIPT_DIR/$REPO_ROOT path
# the file references at all (source, exec, or just a printed/derived path).
walk_broad() {
  grep -ohE '\$\{?(SCRIPT_DIR|REPO_ROOT)\}?/[A-Za-z0-9_./-]+' "$1" 2>/dev/null || true
}

# walk_narrow <file> -- design §3.2 step 2: only paths reached via a source
# or an exec call (`. "$…"`, `source "$…"`, `bash "$…"`, `node "$…"`).
walk_narrow() {
  grep -ohE '(\.|source) "\$\{?(SCRIPT_DIR|REPO_ROOT|_PROV_LIB_DIR|_PROVREAD_LIB_DIR)\}?/[A-Za-z0-9_./-]+|(bash|node) "\$\{?(SCRIPT_DIR|REPO_ROOT|_PROV_LIB_DIR|_PROVREAD_LIB_DIR)\}?/[A-Za-z0-9_./-]+' "$1" 2>/dev/null \
    | grep -oE '\$\{?(SCRIPT_DIR|REPO_ROOT|_PROV_LIB_DIR|_PROVREAD_LIB_DIR)\}?/[A-Za-z0-9_./-]+' || true
}

# Expand the dynamic `for helper in … ; do` loop by hand (design §3.2's own
# instruction). A parse finding zero names is itself a failure -- the loop
# line may have moved or been reworded, silently dropping every unwire-* file
# from the walk.
loop_line=$(grep -n '^[[:space:]]*for helper in ' "$entry" | head -1 || true)
[ -n "$loop_line" ] || fail "no 'for helper in …' loop found in $entry -- did it move or get reworded?"
helper_names=$(printf '%s\n' "$loop_line" | sed -E 's/^[0-9]+:[[:space:]]*for helper in ([^;]+);.*/\1/')
helper_names=$(printf '%s\n' "$helper_names" | tr -s ' ')
[ -n "$helper_names" ] || fail "helper-loop parse found zero names in: $loop_line"
helper_count=$(printf '%s\n' "$helper_names" | wc -w | tr -d ' ')
[ "$helper_count" -gt 0 ] || fail "helper-loop parse found zero names in: $loop_line"

reached=()
for name in $helper_names; do
  reached+=("scripts/lib/${name}.sh")
done

# Level 0: uninstall.sh itself, broad pattern.
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  rel=$(normalize_ref "$raw") || true
  [ -n "$rel" ] || continue
  is_excluded "$rel" && continue
  reached+=("$rel")
done < <(walk_broad "$entry" | sort -u)

# Transitive: narrow pattern (source/exec only) from every file discovered
# so far, following the chain until nothing new turns up.
seen_file=" scripts/uninstall.sh "
queue=("${reached[@]}")
while [ "${#queue[@]}" -gt 0 ]; do
  next=()
  for rel in "${queue[@]}"; do
    case "$seen_file" in *" $rel "*) continue ;; esac
    seen_file="$seen_file$rel "
    fpath="$repo_root/$rel"
    [ -f "$fpath" ] || continue
    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      child=$(normalize_ref "$raw") || true
      [ -n "$child" ] || continue
      is_excluded "$child" && continue
      case "$seen_file" in *" $child "*) continue ;; esac
      reached+=("$child")
      next+=("$child")
    done < <(walk_narrow "$fpath" | sort -u)
  done
  queue=(${next[@]+"${next[@]}"})
done

# Dedup the reached set.
deduped=()
while IFS= read -r _r; do deduped+=("$_r"); done < <(printf '%s\n' "${reached[@]}" | sort -u)
reached=("${deduped[@]}")
[ "${#reached[@]}" -gt 0 ] || fail "closure walk from $entry reached zero files -- grep patterns likely stale"

# Pull BUNDLE_FILES_POSIX's own list of quoted repo-relative paths out of the
# source (between the array literal's brackets), one path per line.
bundle_files=$(awk '/const BUNDLE_FILES_POSIX = \[/{f=1;next} f && /\]/{f=0} f' "$bundle_js" \
  | grep -oE "'[^']+'" | tr -d "'")
[ -n "$bundle_files" ] || fail "could not parse BUNDLE_FILES_POSIX out of $bundle_js"

missing=()
for rel in "${reached[@]}"; do
  case $'\n'"$bundle_files"$'\n' in
    *$'\n'"$rel"$'\n'*) : ;;
    *) missing+=("$rel") ;;
  esac
done
if [ "${#missing[@]}" -gt 0 ]; then
  fail "closure walk from scripts/uninstall.sh reaches file(s) missing from BUNDLE_FILES_POSIX: ${missing[*]}"
fi

# Every listed file must actually exist -- catches a stale/renamed entry the
# walk itself would never notice (nothing reaches a file that no longer
# exists under its old name).
listed_missing=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$repo_root/$rel" ] || listed_missing+=("$rel")
done <<< "$bundle_files"
if [ "${#listed_missing[@]}" -gt 0 ]; then
  fail "BUNDLE_FILES_POSIX lists file(s) that do not exist: ${listed_missing[*]}"
fi

echo "ok: closure walk (${#reached[@]} files reached from scripts/uninstall.sh, $helper_count unwire-* helpers) all present in BUNDLE_FILES_POSIX"
echo "ok: every BUNDLE_FILES_POSIX entry exists on disk"
echo
echo "ALL PASS"
