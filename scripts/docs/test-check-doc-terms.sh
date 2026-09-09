#!/usr/bin/env bash
# Suite for scripts/docs/check-doc-terms.sh (HIMMEL-2832).
#
# Each case builds a throwaway git repo and points the script at it through
# CLAUDE_PROJECT_DIR, which is how repo_root() resolves ROOT. Both invariants
# need a repo rather than a bare file: the reference check asks `git ls-files`
# and `git grep` whether a path or an env var is real.
#
# The exemptions carry as much weight as the violations here. A "profile" rule
# that also fires on `--profile` or on a fenced example would be turned off
# within a week, so the code-span, fenced-block and path-shaped-link-text
# exemptions each get a case, as does the hard-wrap carry that keeps
# "plugin\nprofile" from reading as a violation.
#
# Platform guard (gitbash-only): pure POSIX bash 3.2+ plus git/mktemp, so it
# runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-check-doc-terms.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-doc-terms.sh"

# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

# setup_repo — a repo carrying the few real references the cases point at: one
# script, one doc directory, and one env var defined somewhere in the tree.
setup_repo() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  mkdir -p "$R/scripts/hooks" "$R/docs/setup/profiles"
  echo '#!/usr/bin/env bash' > "$R/scripts/hooks/check-commit-msg.sh"
  echo 'TICKET_ID_PATTERN=HIMMEL-[0-9]+' > "$R/scripts/hooks/env-defaults.sh"
  echo 'preset' > "$R/docs/setup/profiles/README.md"
  git -C "$R" add scripts docs
  git -C "$R" commit -q -m init
}

# write_doc <relative-path> — body on stdin, so a case reads as the document it
# is testing rather than as a printf escape sequence.
write_doc() {
  mkdir -p "$(dirname "$R/$1")"
  cat > "$R/$1"
}

# run_check <relative-doc>... — output to $OUT, rc to $RC.
run_check() {
  RC=0
  OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT" "$@" 2>&1) || RC=$?
}

expect() {
  if [ "$RC" -eq "$1" ]; then
    ok
  else
    bad "$2: expected rc=$1, got rc=$RC"
    printf '%s\n' "$OUT" | sed 's/^/    /' >&2
  fi
}

expect_says() {
  case "$OUT" in
    *"$1"*) ok ;;
    *)
      bad "$2: output does not mention '$1'"
      printf '%s\n' "$OUT" | sed 's/^/    /' >&2
      ;;
  esac
}

expect_silent_about() {
  case "$OUT" in
    *"$1"*)
      bad "$2: output should not mention '$1'"
      printf '%s\n' "$OUT" | sed 's/^/    /' >&2
      ;;
    *) ok ;;
  esac
}

# ---------------------------------------------------- 1. qualified "profile"

setup_repo || exit 1
write_doc doc.md <<'DOC'
Pick an install profile at install time. The plugin profile is a different
axis, and a saved install-profile file is a preset of wizard answers.
DOC
run_check doc.md
expect 0 "green: every occurrence carries one of the three qualifiers"

setup_repo || exit 1
write_doc doc.md <<'DOC'
Pick a profile at install time.
DOC
run_check doc.md
expect 1 "RED profile: a bare qualifier-less occurrence in prose"
expect_says 'unqualified "profile" in prose' "RED profile: names the rule"

# Line numbers must point into the ORIGINAL file. The blanking pass replaces
# stripped content with empty lines rather than deleting them precisely so a
# reported line is one the author can open.
setup_repo || exit 1
write_doc doc.md <<'DOC'
one
two
three
a bare profile here
DOC
run_check doc.md
expect_says "line 4:" "RED profile: reports the line number of the original file"

# The qualifier can sit on the previous line — markdown hard-wraps, and a
# line-at-a-time scan would report this as a violation.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The lean and full sets are selected by the plugin
profile, which is unrelated to the install profile.
DOC
run_check doc.md
expect 0 "profile: a hard-wrapped 'plugin\\nprofile' is qualified, not a violation"

# The carry is preceding-word CONTEXT for the next line, never a token of it.
# Re-validating it as one reports a properly qualified "plugin profile" all
# over again, one line too late and against a line that never said the word.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The lean and full sets are selected by the plugin profile
and nothing on this line mentions the word at all.
DOC
run_check doc.md
expect 0 "profile: a qualified end-of-line occurrence is not re-reported on the next line"

# The rule is about sentences, not identifiers: a flag really is spelled
# --profile and a directory really is docs/setup/profiles/.
setup_repo || exit 1
write_doc doc.md <<'DOC'
Run `himmelctl profile --profile lean` to switch the plugin profile.
DOC
run_check doc.md
expect 0 "profile: code spans are exempt"

setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile is chosen once:

```bash
himmelctl profile
# profile switching, a bare word inside a fence
```
DOC
run_check doc.md
expect 0 "profile: fenced blocks are exempt"

# Path-shaped link TEXT is navigation, not a sentence.
setup_repo || exit 1
write_doc doc.md <<'DOC'
See [docs/setup/profiles/README.md](docs/setup/profiles/README.md).
DOC
run_check doc.md
expect 0 "profile: path-shaped link text is dropped whole"

# Link text that reads as prose is still prose, and still checked.
setup_repo || exit 1
write_doc doc.md <<'DOC'
See [the profile page](docs/setup/profiles/README.md).
DOC
run_check doc.md
expect 1 "profile: prose link text is NOT exempt"

# The already-hyphenated single token is qualified on its own.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The saved install-profile files live beside the manifest.
DOC
run_check doc.md
expect 0 "profile: a hyphenated install-profile token is already qualified"

# Plural too — "profiles" is the same word with the same ambiguity.
setup_repo || exit 1
write_doc doc.md <<'DOC'
There are three profiles to choose from.
DOC
run_check doc.md
expect 1 "RED profile: the plural is caught as well"

# ------------------------------------------------------ 2. references exist

setup_repo || exit 1
write_doc doc.md <<'DOC'
The plugin profile hook is `scripts/hooks/check-commit-msg.sh` and the knob is
`TICKET_ID_PATTERN`; the presets live under `docs/setup/profiles/`.
DOC
run_check doc.md
expect 0 "green: every named path and env var exists in the tree"

setup_repo || exit 1
write_doc doc.md <<'DOC'
Run the install profile hook `scripts/hooks/check-commit-msg-renamed.sh`.
DOC
run_check doc.md
expect 1 "RED reference: a renamed script path that no longer exists"
expect_says "which does not exist in the tree" "RED reference: names the dead path"

setup_repo || exit 1
write_doc doc.md <<'DOC'
Set the install profile knob `TICKET_ID_REQUIRED_RENAMED` to opt out.
DOC
run_check doc.md
expect 1 "RED reference: an env var that appears nowhere in the tree"
expect_says "appears nowhere else in the tree" "RED reference: names the invented knob"

# Platform env vars are the platform's — naming one is not a claim that himmel
# defines it, so requiring it in the tree would be wrong.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile is written under `HOME`, on your `PATH`.
DOC
run_check doc.md
expect 0 "reference: generic platform env vars are exempt"

# A single-segment SCREAMING word is an English word in caps often enough that
# requiring it in the tree would be noise; only multi-segment knobs are checked.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile is `NEVER` written by hand.
DOC
run_check doc.md
expect 0 "reference: a single-segment caps word is not treated as a knob"

# The doc under review is excluded from the env-var search, so a knob it is the
# only mention of does not vacuously satisfy the check against itself.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile knob is `TICKET_ID_PATTERN`.
DOC
run_check doc.md
expect 0 "reference: an env var defined elsewhere in the tree resolves"

# ...and the exclusion is built from the documents actually under review, not
# from the three defaults. A TRACKED document naming only itself would
# otherwise be its own evidence and could validate a knob it invented.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile knob is `TICKET_ID_INVENTED_HERE`.
DOC
git -C "$R" add doc.md
git -C "$R" commit -q -m doc
run_check doc.md
expect 1 "RED reference: a tracked document cannot validate its own invented knob"
expect_says "appears nowhere else in the tree" "RED reference: names the self-referential knob"

# Identifier boundaries. A typo that is a strict PREFIX of a real knob is the
# single most likely way this check gets a false green, and a substring search
# hands it one: TICKET_ID_PATTER "exists" inside TICKET_ID_PATTERN.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile knob is `TICKET_ID_PATTER`.
DOC
run_check doc.md
expect 1 "RED reference: a misspelled prefix of a real knob is not evidence of itself"
expect_says "appears nowhere else in the tree" "RED reference: names the misspelled knob"

# A trailing slash means "this directory" — the same path, spelled the way a
# doc naturally writes a directory.
setup_repo || exit 1
write_doc doc.md <<'DOC'
The install profile presets live in `docs/setup/profiles/`.
DOC
run_check doc.md
expect 0 "reference: a trailing slash is stripped before the existence test"

# --------------------------------------------------------------- multi-doc

setup_repo || exit 1
write_doc a.md <<'DOC'
The install profile is fine here.
DOC
write_doc b.md <<'DOC'
But this profile is not.
DOC
run_check a.md b.md
expect 1 "multi-doc: a violation in the second document still fails the run"
expect_says "b.md:" "multi-doc: the report names the offending document"
expect_silent_about "a.md: unqualified" "multi-doc: the clean document is not blamed"

setup_repo || exit 1
write_doc a.md <<'DOC'
The install profile is fine here.
DOC
run_check a.md nope.md
expect 1 "misuse: a missing document is an error, not a silent skip"
expect_says "no such document: nope.md" "misuse: names the missing document"

# Both invariants report in one pass — a check that stops at the first failure
# costs a full round trip per finding.
setup_repo || exit 1
write_doc doc.md <<'DOC'
A bare profile, plus `scripts/hooks/gone.sh`.
DOC
run_check doc.md
expect 1 "reporting: both invariants violated in one document"
expect_says 'unqualified "profile" in prose' "reporting: the profile violation printed"
expect_says "which does not exist in the tree" "reporting: the reference violation printed too"

echo "test-check-doc-terms: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
