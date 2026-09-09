#!/usr/bin/env bash
# check-doc-terms.sh — the two prose invariants of the v1 adopter docs
# (HIMMEL-2832: llms.txt, docs/setup/install.md, docs/setup/migrating.md).
#
#   1. QUALIFIED "PROFILE". "Profile" names three unrelated things in himmel —
#      the INSTALL profile (which manifest items are desired), the SAVED
#      install-profile file (*.install-profile.json, a preset of wizard
#      answers), and the PLUGIN profile (lean|full marketplace sets). An
#      adopter who reads a bare "profile" has no way to know which. So in these
#      docs every prose occurrence must be qualified: install / saved / plugin.
#      Code spans, fenced blocks and link targets are exempt — a flag really is
#      spelled `--profile` and a directory really is `docs/setup/profiles/`;
#      the rule is about sentences, not identifiers.
#
#   2. REFERENCES EXIST. Every repo path and every env var these docs name in a
#      code span has to be real. A checklist that tells an adopter to set a
#      flag that no longer exists is worse than no checklist.
#
# Platform guard (gitbash-only): pure POSIX bash 3.2+ plus git/grep/sed/awk, so
# it runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/check-doc-terms.sh [<file> ...]
#        (default: the three v1 docs)
# Exit:  0 = both invariants hold, 1 = at least one violation (all are printed).
set -eu

repo_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.git" ]; then
    printf '%s\n' "${CLAUDE_PROJECT_DIR}"
    return 0
  fi
  git rev-parse --show-toplevel
}

ROOT=$(repo_root)
if [ "$#" -gt 0 ]; then
  DOCS="$*"
else
  DOCS="llms.txt docs/setup/install.md docs/setup/migrating.md"
fi

# Env vars that are the platform's, not himmel's — naming one is not a claim
# that himmel defines it, so requiring it in the tree would be wrong.
GENERIC_ENV="PATH HOME USER SHELL TMPDIR PWD LANG"

# The documents under review are excluded from the env-var search below, so a
# knob a doc is the only mention of cannot vacuously satisfy the check against
# itself. Built from $DOCS rather than hardcoded to the three defaults: a doc
# passed as an argument would otherwise validate its own invented variable.
EXCLUDES=""
for doc in $DOCS; do
  EXCLUDES="$EXCLUDES :!$doc"
done

fail=0
report() {
  echo "check-doc-terms: FAIL $*" >&2
  fail=1
}

# prose_of <file> — the document with everything that is not a sentence blanked
# out: fenced code blocks, inline code spans, and markdown link targets. Blanked
# rather than deleted, so grep -n still reports the line number in the ORIGINAL
# file — a violation report that points at the wrong line is a report nobody
# can act on. A link whose TEXT is itself a path (`[docs/setup/profiles/…](…)`)
# is dropped whole: that is navigation, not a sentence. Link text that reads as
# prose is kept, so "[the plugin profile](…)" is still checked.
# shellcheck disable=SC2016  # the backticks in the sed script are markdown
# code-span delimiters, not a command substitution — single quotes are correct.
prose_of() {
  awk '
    /^[ \t]*```/ { fenced = !fenced; print ""; next }
    fenced { print ""; next }
    { print }
  ' "$1" \
    | sed -e 's/`[^`]*`//g' \
          -e 's/\[[^]]*\/[^]]*\]([^)]*)//g' \
          -e 's/](\([^)]*\))//g'
}

# ------------------------------------------------- 1. qualified "profile"
for doc in $DOCS; do
  path="$ROOT/$doc"
  [ -f "$path" ] || { report "no such document: $doc"; continue; }

  # Every prose occurrence of profile/profiles whose preceding word is not one
  # of the three qualifiers. Done in awk rather than grep because the qualifier
  # can sit on the PREVIOUS line: markdown hard-wraps, and "plugin\nprofile" is
  # qualified prose that a line-at-a-time grep would report as a violation.
  # Tokens keep their hyphens, so "install-profile" is one already-qualified
  # token; "install profile" is two and matches on the preceding word.
  # The carry is preceding-word CONTEXT only, never a token to validate: it
  # occupies w[1], and validating it there would re-report a line that ended in
  # a properly qualified "plugin profile" as a violation of the NEXT line. When
  # there is no carry the concatenation starts with the separator, so w[1] is
  # empty — either way the current line's own tokens start at w[2].
  bad=$(prose_of "$path" | awk '
    {
      n = split(carry " " $0, w, /[^A-Za-z-]+/)
      for (i = 2; i <= n; i++) {
        t = tolower(w[i])
        if (t ~ /^(install|saved|plugin)-profiles?$/) continue
        if (t !~ /^profiles?$/) continue
        p = (i > 1) ? tolower(w[i - 1]) : ""
        if (p != "install" && p != "saved" && p != "plugin")
          printf "%d: %s\n", NR, w[i]
      }
      carry = (n > 1) ? w[n] : ""
    }
  ')
  if [ -n "$bad" ]; then
    report "$doc: unqualified \"profile\" in prose (needs install-/saved-/plugin-):"
    printf '%s\n' "$bad" | sed 's/^/  line /' >&2
  fi
done

# ------------------------------------------------- 2. references exist
for doc in $DOCS; do
  path="$ROOT/$doc"
  [ -f "$path" ] || continue

  # Every whitespace-separated word inside a code span, trailing sentence
  # punctuation stripped.
  # shellcheck disable=SC2016  # markdown code-span delimiters, as above.
  tokens=$(grep -o '`[^`]*`' "$path" \
    | sed -e 's/^`//' -e 's/`$//' \
    | tr ' ' '\n' \
    | sed -e 's/[.,;:)]*$//' -e 's/^(//' \
    | sort -u)

  # A code span can hold a glob (`docs/setup/*.md`) meant as literal prose, not
  # a pattern to expand — set -f so the unquoted split below never lets the
  # invoking cwd's contents change which token gets tested.
  set -f
  for tok in $tokens; do
    case "$tok" in
      # Repo paths: anything rooted at a real top-level directory must exist.
      scripts/*|docs/*|templates/*|marketplace/*|plugins/*|.claude/*|.github/*)
        # A trailing slash means "this directory"; strip it before the test.
        p=${tok%/}
        if [ ! -e "$ROOT/$p" ]; then
          report "$doc: names \`$tok\`, which does not exist in the tree"
        fi
        ;;
      # Env vars / flags spelled in SCREAMING_SNAKE must appear somewhere in
      # the tracked tree — the doc must not invent a knob.
      [A-Z][A-Z0-9_]*)
        # A code span may show an assignment (`KNOB=value`) rather than a bare
        # identifier — split at the first `=` before the existence test, so
        # the check asks whether KNOB is real, not whether the literal
        # "KNOB=value" string appears anywhere.
        name=${tok%%=*}
        case " $GENERIC_ENV " in *" $name "*) continue ;; esac
        # Two-plus segments, or long enough to not be an English word in caps.
        case "$name" in
          *_*)
            # -w, not a bare substring search: without identifier boundaries a
            # misspelled TICKET_ID_PATTER validates against the real
            # TICKET_ID_PATTERN, which is precisely the typo this check exists
            # to catch. git grep's word characters include _, so a prefix of a
            # longer knob is not a whole word and no longer counts as evidence.
            # shellcheck disable=SC2086  # $EXCLUDES is a deliberate word list
            if ! git -C "$ROOT" grep -qIw --fixed-strings -- "$name" -- $EXCLUDES 2>/dev/null; then
              report "$doc: names env var \`$tok\`, which appears nowhere else in the tree"
            fi
            ;;
        esac
        ;;
    esac
  done
  set +f
done

if [ "$fail" -eq 0 ]; then
  echo "check-doc-terms: OK — qualified \"profile\" + live references in: $DOCS"
fi
exit "$fail"
