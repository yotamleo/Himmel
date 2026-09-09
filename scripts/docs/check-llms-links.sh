#!/usr/bin/env bash
# check-llms-links.sh — the executable half of llms.txt's contract (HIMMEL-2832).
#
# llms.txt is the machine-readable router an LLM reads when it is pointed at
# himmel. It ships to the PUBLIC repo, so a relative link that resolves only in
# the private working tree becomes a 404 for every reader who actually uses it.
# Three invariants, all mechanical:
#
#   1. BUDGET   — <= 60 lines and <= 700 words. A router that grows an essay
#                 stops being a router; the word cap is the one that bites (the
#                 current file passed a naive line count while carrying ~600
#                 words about one subsystem).
#   2. FORBIDDEN — no private-repo name, no handovers/ path, no absolute
#                 operator-personal path. These are the leak classes the
#                 pre-commit gate scans for, restated as a doc rule.
#   3. LINKS    — every relative link resolves in the PUBLIC projection: the
#                 path is tracked at HEAD, is not carved out of the public repo
#                 by scripts/lib/public-clone-paths.sh's PRIVATE_PATHS /
#                 DETECTOR_DROP, and does not reach into docs/internals/.
#                 Checking mere on-disk existence would validate against the
#                 private tree and is worthless — precisely the failure that
#                 ships a public llms.txt full of 404s. The internals rule lives
#                 here because it is only decidable after a `../` link has been
#                 resolved against the document's own directory.
#
# Platform guard (gitbash-only): pure POSIX bash 3.2+ plus git/grep/sed/wc, so
# it runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/check-llms-links.sh [<file>]   (default: llms.txt)
# Exit:  0 = all invariants hold, 1 = at least one violation (all are printed).
set -eu

MAX_LINES=60
MAX_WORDS=700

repo_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.git" ]; then
    printf '%s\n' "${CLAUDE_PROJECT_DIR}"
    return 0
  fi
  git rev-parse --show-toplevel
}

ROOT=$(repo_root)
TARGET=${1:-llms.txt}
case "$TARGET" in
  /*) FILE="$TARGET" ;;
  *) FILE="$ROOT/$TARGET" ;;
esac

if [ ! -f "$FILE" ]; then
  echo "check-llms-links: no such file: $FILE" >&2
  exit 1
fi

fail=0
report() {
  echo "check-llms-links: FAIL $*" >&2
  fail=1
}

# ---------------------------------------------------------------- 1. budget
# The budget is llms.txt's own contract — a router, not a guide. The other two
# invariants are about the public projection and apply to any doc, so this
# script is reusable on docs/setup/install.md and docs/setup/migrating.md; only
# the budget is skipped there.
lines=$(wc -l < "$FILE" | tr -d ' ')
words=$(wc -w < "$FILE" | tr -d ' ')
budget="n/a (not llms.txt)"
if [ "$(basename "$FILE")" = "llms.txt" ]; then
  budget="${lines}/${MAX_LINES} lines, ${words}/${MAX_WORDS} words"
  [ "$lines" -le "$MAX_LINES" ] || report "budget: $lines lines exceeds $MAX_LINES"
  [ "$words" -le "$MAX_WORDS" ] || report "budget: $words words exceeds $MAX_WORDS"
fi

# ------------------------------------------------------------- 2. forbidden
# One row per class: <label>|<extended regex>. The private repo name is not
# spelled here — this file ships publicly too; it is derived from the public
# remote instead, so the rule stays true after the HIMMEL-2705 cutover.
forbidden_hit() {
  label=$1
  pattern=$2
  if grep -Eqn "$pattern" "$FILE"; then
    hits=$(grep -Ecn "$pattern" "$FILE" | tr -d ' ')
    report "forbidden ($label): $hits line(s) match /$pattern/"
  fi
}

forbidden_hit "handover state path" '(^|[^A-Za-z0-9_/-])handovers/'
forbidden_hit "absolute home path" '(/home/|/Users/|[A-Za-z]:\\Users\\)'

# The private repo's own name. Derived at runtime from origin rather than
# spelled here, because this file ships publicly: the header promises the rule
# and the promise has to be kept by code, not by a comment. When origin already
# IS the public remote — the public clone, or a fork of it — there is no private
# name to leak and the class is skipped. The names are compared case-folded
# because GitHub treats them that way, and the name is never echoed back into
# the report: a leak report that repeats the leak is its own violation.
private_repo_name=""
if origin_url=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null); then
  private_repo_name=$(basename "$origin_url" .git)
fi
public_repo_name=$(basename "${HIMMEL_PUBLIC_REMOTE:-yotamleo/Himmel}" .git)
if [ -n "$private_repo_name" ] &&
   [ "$(printf '%s' "$private_repo_name" | tr '[:upper:]' '[:lower:]')" != \
     "$(printf '%s' "$public_repo_name" | tr '[:upper:]' '[:lower:]')" ] &&
   grep -Fiq -- "$private_repo_name" "$FILE"; then
  hits=$(grep -Fic -- "$private_repo_name" "$FILE" | tr -d ' ')
  report "forbidden (private repo name): $hits line(s) name the private remote's repo"
fi

# ----------------------------------------------------------------- 3. links
# path_in_token_list — membership with the SAME anchoring PRIVATE_PATHS uses in
# propagate-public.sh's scan_private_path_tokens: a trailing-slash token matches
# the directory's contents, a bare token matches that exact path or anything
# under it. Prefix matching without the anchor would let the token `archive`
# claim `marketplace/.../archive-clips.md`.
path_in_token_list() {
  _p=$1
  _list=$2
  for _tok in $_list; do
    case "$_tok" in
      */) case "$_p" in "$_tok"*) return 0 ;; esac ;;
      *)
        [ "$_p" = "$_tok" ] && return 0
        case "$_p" in "$_tok"/*) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

# The carve-out lists live in the private-only propagation lib. In the PUBLIC
# clone that file is absent by construction — and so is everything it carves
# out, so plain tracked-ness IS the public test there. Fail-soft, and say so.
PRIVATE_PATHS=""
DETECTOR_DROP=""
carve_source="none (public clone: tracked-ness is the whole test)"
if [ -f "$ROOT/scripts/lib/public-clone-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/public-clone-paths.sh"
  carve_source="scripts/lib/public-clone-paths.sh"
fi

# Every markdown link target in the file, deduped. Absolute URLs are the
# caller's problem, not ours: this check is about the public PROJECTION.
links=$(grep -o '](\([^)]*\))' "$FILE" | sed 's/^](//; s/)$//' | sort -u)

# Markdown links are relative to the DOCUMENT, not the repo root — this script
# is reused on docs/setup/*.md, where every link starts with `../`. Resolve
# against the document's own directory and fold away . and .. segments, so the
# tracked-ness test asks about the path the reader will actually follow.
doc_dir=$(dirname "${FILE#"$ROOT"/}")
[ "$doc_dir" = "." ] && doc_dir=""

# A `..` with nothing left to pop escapes the repository root, and silently
# clamping it there is worse than not resolving at all: `../../docs/x.md` in a
# root-level llms.txt would fold to `docs/x.md` and pass against an unrelated
# tracked file, certifying a link that 404s for every reader. Say so instead.
ESCAPES_ROOT='!escapes-root'
normalize() {
  printf '%s\n' "$1" | awk -F/ -v esc_marker="$ESCAPES_ROOT" '
    {
      n = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") continue
        if ($i == "..") {
          if (n > 0) { n--; continue }
          print esc_marker
          next
        }
        out[++n] = $i
      }
      s = ""
      for (i = 1; i <= n; i++) s = s (i > 1 ? "/" : "") out[i]
      print s
    }'
}

for link in $links; do
  case "$link" in
    http://*|https://*|mailto:*|'#'*) continue ;;
  esac
  # Strip an anchor fragment: the file has to exist, the anchor does not.
  path=${link%%#*}
  [ -n "$path" ] || continue
  if [ -n "$doc_dir" ]; then
    path=$(normalize "$doc_dir/$path")
  else
    path=$(normalize "$path")
  fi
  [ -n "$path" ] || continue
  if [ "$path" = "$ESCAPES_ROOT" ]; then
    report "link '$link' traverses above the repository root — it resolves in no clone"
    continue
  fi

  # The internals prohibition is tested HERE, on the normalized path, rather
  # than as a literal `](…docs/internals/` row above: the docs this script also
  # runs on live in docs/setup/, where the same forbidden link is spelled
  # `../internals/…` and the literal row never sees it.
  case "$path" in
    docs/internals/*)
      report "forbidden (internal docs link): '$link' resolves into docs/internals/"
      continue
      ;;
  esac

  if path_in_token_list "$path" "$PRIVATE_PATHS"; then
    report "link '$link' targets a PRIVATE_PATHS entry — it does not exist in the public repo"
    continue
  fi
  if path_in_token_list "$path" "$DETECTOR_DROP"; then
    report "link '$link' targets a DETECTOR_DROP path — it is not mirrored publicly"
    continue
  fi
  if [ -z "$(git -C "$ROOT" ls-files -- "$path")" ]; then
    report "link '$link' is not tracked at HEAD — it cannot reach the public clone"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "check-llms-links: OK ${TARGET} — budget ${budget}, carve-outs from ${carve_source}"
fi
exit "$fail"
