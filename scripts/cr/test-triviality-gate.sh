#!/usr/bin/env bash
# Smoke test for scripts/cr/triviality-gate.sh (HIMMEL-737, unwired).
# The suite is the spec: override > safety > docs-only > one-liner > substantive,
# with empty stdin failing closed. Mirrors scripts/cr/test-lane-classify.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cr/triviality-gate.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$DIR/triviality-gate.sh"
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: got '$1' want '$2'"; fail=1; }; }
# verdict half of the function's 'verdict<TAB>reason' return line
vverdict() { printf '%s' "${1%%$'\t'*}"; }

# Hermetic diff fixtures (no real files, no real git).
docs_multi="diff --git a/docs/a.md b/docs/a.md
+docs a line
diff --git a/README.md b/README.md
+readme line"
code_one="diff --git a/src/foo.py b/src/foo.py
@@ -1 +1,2 @@
 existing
+one new line"
code_three="diff --git a/src/foo.py b/src/foo.py
@@ -1 +1,4 @@
 existing
+a
+b
+c"
mixed="diff --git a/docs/a.md b/docs/a.md
+doc line
diff --git a/src/foo.py b/src/foo.py
+code line"
hooks_one="diff --git a/scripts/hooks/foo.sh b/scripts/hooks/foo.sh
+one line"
claude_md="diff --git a/CLAUDE.md b/CLAUDE.md
+text"

# 1. multi-file docs-only -> trivial
check "$(vverdict "$(classify_triviality "$docs_multi")")" trivial
# 2. single-file 1-line code change -> trivial
check "$(vverdict "$(classify_triviality "$code_one")")" trivial
# 3. single-file 3-line code change -> nontrivial
check "$(vverdict "$(classify_triviality "$code_three")")" nontrivial

# HIMMEL-1950 — the boundary everyone gets wrong. The rule counts +/- BODY
# lines, not edited lines: a ONE-line edit is 2 diff lines and IS trivial, a
# TWO-line edit is 4 diff lines and is NOT. Getting this backwards is what makes
# people believe a small change "should" have been cheap-pathed when it was not.
code_one_edited='diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,1 +1,1 @@
-old line
+new line'
check "$(vverdict "$(classify_triviality "$code_one_edited")")" trivial

code_two_edited='diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,2 +1,2 @@
-old one
-old two
+new one
+new two'
check "$(vverdict "$(classify_triviality "$code_two_edited")")" nontrivial
# 4. mixed docs+code -> nontrivial
check "$(vverdict "$(classify_triviality "$mixed")")" nontrivial
# 5. 1-line change to scripts/hooks/foo.sh -> nontrivial
check "$(vverdict "$(classify_triviality "$hooks_one")")" nontrivial
# 6. CLAUDE.md-only diff -> nontrivial
check "$(vverdict "$(classify_triviality "$claude_md")")" nontrivial
# 7. docs-only with CR_TRIVIALITY_OVERRIDE=full -> nontrivial
check "$(vverdict "$(CR_TRIVIALITY_OVERRIDE=full classify_triviality "$docs_multi")")" nontrivial
# 8. code diff with CR_TRIVIALITY_OVERRIDE=trivial -> trivial
check "$(vverdict "$(CR_TRIVIALITY_OVERRIDE=trivial classify_triviality "$code_three")")" trivial
# 8b. override=trivial CANNOT beat the safety carve-out (codex-adv): a hooks
#     diff stays nontrivial even under the trivial override.
check "$(vverdict "$(CR_TRIVIALITY_OVERRIDE=trivial classify_triviality "$hooks_one")")" nontrivial
# 8d. the hermes invocation path the panel rides is safety surface too.
hermes_one="diff --git a/scripts/hermes/invoke.sh b/scripts/hermes/invoke.sh
+one line"
check "$(vverdict "$(classify_triviality "$hermes_one")")" nontrivial
# 8c. override=trivial cannot beat the empty-diff fail-closed contract either.
check "$(vverdict "$(CR_TRIVIALITY_OVERRIDE=trivial classify_triviality "")")" nontrivial
# 10. unknown override value falls through to heuristic (docs-only -> trivial)
check "$(vverdict "$(CR_TRIVIALITY_OVERRIDE=garbage classify_triviality "$docs_multi" 2>/dev/null)")" trivial

# HIMMEL-737 header-miscount regressions. Real file-header lines carry a space
# ('--- a/...', '+++ b/...'); body changes whose CONTENT starts with '--'/'++'
# arrive as '---...'/'+++...' (no space) and MUST be counted.
# (a) 3 removed lines all starting with '--' -> substantive (pre-fix: swallowed
#     by '---*' -> nlines=0 -> one-liner trivial; post-fix: counted -> nontrivial).
removed_dashes="diff --git a/src/opts.py b/src/opts.py
--- a/src/opts.py
+++ b/src/opts.py
@@ -1,3 +0,0 @@
---opt-alpha
---opt-beta
---opt-gamma"
check "$(vverdict "$(classify_triviality "$removed_dashes")")" nontrivial
# (b) 3 added lines all starting with '++' -> substantive (pre-fix: swallowed by
#     '+++*'; post-fix: counted).
added_plus="diff --git a/src/opts.py b/src/opts.py
--- a/src/opts.py
+++ b/src/opts.py
@@ -0,0 +1,3 @@
+++opt-alpha
+++opt-beta
+++opt-gamma"
check "$(vverdict "$(classify_triviality "$added_plus")")" nontrivial
# (c) real header lines are NOT counted: 1 body line + a/ and b/ headers must stay
#     a one-liner trivial (if headers were counted -> nlines=3 -> substantive).
header_not_counted="diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,1 +1,2 @@
 existing
+added one"
check "$(vverdict "$(classify_triviality "$header_not_counted")")" trivial
# (d) /dev/null header forms (new file) are NOT counted either: 3 added body
#     lines -> substantive; the '--- /dev/null' + '+++ b/' headers must not add
#     to nlines (else 5, still substantive here, so assert the count via a 2-line
#     new file staying one-liner trivial).
devnull_headers="diff --git a/src/new.py b/src/new.py
new file mode 100644
--- /dev/null
+++ b/src/new.py
@@ -0,0 +1,2 @@
+first
+second"
check "$(vverdict "$(classify_triviality "$devnull_headers")")" trivial

# HIMMEL-737 CR: the safety carve-out covers the CR pipeline itself - a
# one-line change to the panel scripts, the lane registry, or the backend
# router registry must never classify trivial (the gate cannot blind the
# pipeline that runs it). Assert reason too: these must hit safety-path.
cr_one="diff --git a/scripts/cr/critic-panel.sh b/scripts/cr/critic-panel.sh
+one line"
check "$(classify_triviality "$cr_one")" "$(printf 'nontrivial\tsafety-path')"
lanes_one="diff --git a/scripts/lanes/lanes.json b/scripts/lanes/lanes.json
+one line"
check "$(classify_triviality "$lanes_one")" "$(printf 'nontrivial\tsafety-path')"
backends_one="diff --git a/scripts/backends.json b/scripts/backends.json
+one line"
check "$(classify_triviality "$backends_one")" "$(printf 'nontrivial\tsafety-path')"

# CRLF-terminated diffs (Windows tooling) must classify identically to LF
# (the gate strips a trailing \r per line).
crlf_one="$(printf '%s' "$code_one" | sed 's/$/\r/')"
check "$(vverdict "$(classify_triviality "$crlf_one")")" trivial
crlf_docs="$(printf '%s' "$docs_multi" | sed 's/$/\r/')"
check "$(vverdict "$(classify_triviality "$crlf_docs")")" trivial

# 9. empty stdin -> nontrivial, exit 0 (CLI form).
set +e
empty_out=$(printf '' | bash "$DIR/triviality-gate.sh" 2>/dev/null)
empty_rc=$?
set -e
check "$empty_out" nontrivial
[ "$empty_rc" -eq 0 ] || { echo "FAIL: empty stdin exit $empty_rc want 0"; fail=1; }

# CLI form: verdict on stdout (one line), exit 0.
set +e
cli_out=$(printf '%s\n' "$code_one" | bash "$DIR/triviality-gate.sh" 2>/dev/null)
cli_rc=$?
set -e
check "$cli_out" trivial
[ "$cli_rc" -eq 0 ] || { echo "FAIL: cli exit $cli_rc want 0"; fail=1; }

# HIMMEL-2420: sweep across the ~64 KiB here-string deadlock band instead of
# pinning one fixture size. `done <<< "$diff_text"` wedges MSYS bash forever
# when the content sits between the real pipe capacity (65,536 B) and bash's
# own switch-to-tempfile threshold (~65,670 B on this host): bash writes the
# here-string into a pipe, and the reader is the SAME process, so nothing
# ever drains it. That threshold is host-specific, so a single magic size is
# vacuous elsewhere - step 5 fixtures by one body-line width (65 B) instead,
# so at least one always lands inside the band wherever it sits.
#
# Each probe runs the CLI form in a SUBPROCESS, fixture on a FILE via stdin,
# under a guaranteed-kill deadline: a regression must FAIL this suite, not
# hang it. `-k` is load-bearing - SIGTERM is not delivered to a shell blocked
# this way, so a plain `timeout 30` would never return either; `-k 5 30` sends
# TERM at 30s and a guaranteed SIGKILL 5s later. `timeout` is GNU/Linux-only;
# macOS coreutils ships it as `gtimeout` (both accept `-k` the same way).
tbin="$(command -v timeout 2>/dev/null)" || tbin=""
[ -n "$tbin" ] || tbin="$(command -v gtimeout 2>/dev/null)" || tbin=""
if [ -z "$tbin" ]; then
  echo "SKIP: HIMMEL-2420 deadlock sweep needs 'timeout' or 'gtimeout' (macOS: brew install coreutils) -- skipped"
else
  sweep_files=()
  for sweep_n in 1005 1006 1007 1008 1009; do
    f="$(mktemp -t "cr-triviality-sweep-$sweep_n.XXXXXX")"
    {
      printf 'diff --git a/scripts/example_module.py b/scripts/example_module.py\n'
      printf -- '--- a/scripts/example_module.py\n'
      printf '+++ b/scripts/example_module.py\n'
      printf '@@ -1,0 +1,%d @@\n' "$sweep_n"
      printf '+%063d\n' $(seq 1 "$sweep_n")
    } > "$f"
    sweep_bytes=$(wc -c < "$f")
    echo "HIMMEL-2420 sweep: N=$sweep_n -> $sweep_bytes B"
    set +e
    sweep_out=$("$tbin" -k 5 30 bash "$DIR/triviality-gate.sh" < "$f" 2>/dev/null)
    sweep_rc=$?
    set -e
    if [ "$sweep_rc" -ne 0 ]; then
      echo "FAIL: sweep fixture N=$sweep_n ($sweep_bytes B) did not classify: rc=$sweep_rc (124 = TERM deadline fired, 137 = SIGKILL deadline fired = the HIMMEL-2420 wedge)"
      fail=1
    elif [ "$sweep_out" != "nontrivial" ]; then
      echo "FAIL: sweep fixture N=$sweep_n ($sweep_bytes B) rc=0 but got '$sweep_out' want nontrivial"
      fail=1
    fi
    sweep_files+=("$f")
  done
  rm -f "${sweep_files[@]}"
fi

[ "$fail" -eq 0 ] && echo "PASS test-triviality-gate" || exit 1
