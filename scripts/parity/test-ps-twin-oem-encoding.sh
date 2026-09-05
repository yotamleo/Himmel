#!/usr/bin/env bash
# test-ps-twin-oem-encoding.sh -- guard against the HIMMEL-2256 encoding class:
# PowerShell decodes a CAPTURED native command's stdout using
# [Console]::OutputEncoding, which on a default Windows install is the legacy
# OEM codepage (cp437/cp850), not UTF-8. Any non-ASCII byte git/gh/node/jq/
# pwsh/etc. write is silently mis-decoded the moment a .ps1 twin captures it,
# and a twin that writes the captured text back out corrupts the file it was
# asked to edit (proven on this branch: scripts/lib/unwire-handover-dir.ps1
# was rewriting env.LUNA_VAULT_PATH into mojibake). 57 .ps1 files were fixed
# with one line; 2 more already carried it. The fix, byte-exact:
#
#     [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#
# This suite is TWO halves on purpose, and the split is load-bearing:
#
#   HALF 1 (structural, pure bash, below): scans every tracked .ps1 for a
#   high-signal native-stdout-capture shape. Any file that shape-matches must
#   either carry the fix line or be a reviewed exemption with a reason. This
#   is what catches a NEW affected twin landing later -- it needs no pwsh and
#   MUST run on every host, including plain Linux CI.
#
#   HALF 2 (behavioural, needs pwsh): runs the existing
#   scripts/parity/test-ps-twin-oem-encoding.ps1, which reproduces the actual
#   cp437 mis-decode against scripts/lib/unwire-handover-dir.ps1 and proves
#   (via its own negative control) that the fixture can detect the bug at
#   all. It self-skips loudly where pwsh is unavailable.
#
# This suite is DELIBERATELY NOT registered in run-shell-tests.sh's
# SUITE_REQUIRE_TOOL table. That table skips a WHOLE suite where the tool is
# missing -- which would take Half 1's pure-bash structural guard down with it
# on every host that lacks pwsh (i.e. most Linux CI). Half 1 must run
# everywhere regardless of what Half 2 can do; only Half 2 self-skips.
#
# bash 3.2-safe (no associative arrays, no mapfile).
set -uo pipefail

# grepq <text> [grep-args...] -- a `grep -q` test against <text> with NO
# pipeline, so `set -o pipefail` cannot see a producer SIGPIPE as failure
# (HIMMEL-1430; see scripts/parity/test-guard-conformance.sh for the same
# trap documented in full).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAIL=0

# sha256hex -- reads stdin, prints a hex sha256 digest. Tries sha256sum, then
# shasum -a 256, then openssl dgst -sha256 (macOS/minimal-image fallbacks). If
# NONE is available, fail loudly rather than silently skipping exemption
# fingerprint verification -- a guard that cannot verify must say so.
if command -v sha256sum >/dev/null 2>&1; then
  sha256hex() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256hex() { shasum -a 256 | cut -d' ' -f1; }
elif command -v openssl >/dev/null 2>&1; then
  sha256hex() { openssl dgst -sha256 | sed 's/^.* //'; }
else
  echo "FAIL: no sha256 tool found (sha256sum, shasum, openssl all missing) -- cannot compute HIMMEL-2256 exemption fingerprints in $0. Install one of them; this guard refuses to silently skip exemption verification." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# HALF 1 -- structural (pure bash, runs on every host).
# ---------------------------------------------------------------------------
# Byte-exact fix line. Matching is line-anchored (the line, minus leading
# whitespace, must BE the assignment and nothing else) rather than a
# fixed-string substring search: a file's own explanatory comment can
# legitimately mention "Console]::OutputEncoding" without carrying the actual
# assignment (scripts/statusline/check-hud-drift.ps1 does exactly this), and a
# string literal quoting the fix (this file's own $FIXLINE below, or
# test-ps-twin-oem-encoding.ps1's) is not a fix either -- a substring check
# would false-pass both.
FIXLINE='[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
FIXLINE_RE='^[[:space:]]*\[Console\]::OutputEncoding[[:space:]]*=[[:space:]]*\[System\.Text\.Encoding\]::UTF8[[:space:]]*$'

# Literal native executable names only -- deliberately NOT `& $someVar`, which
# would flood the exempt list with PowerShell-to-PowerShell calls and dilute
# the signal.
N='git|gh|node|npm|npx|jq|qmd|claude|codex|pwsh|powershell|python3?|bun|curl|docker|cmd|bash|schtasks|taskkill|icacls|rtk|winget|gemini|cygpath'
# P1 assignment from a native call: `$x = git ...`, `$x = & git ...`, `$x = (git ...`
P1="\\\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\\(?[[:space:]]*(&[[:space:]]*)?($N)(\\.exe)?[[:space:]]"
# P2 native piped into a consuming cmdlet
P2="(^|[^A-Za-z0-9_.\$-])($N)(\\.exe)?[[:space:]][^|#]*\\|[[:space:]]*(Out-String|Out-File|ForEach-Object|Select-Object|Select-String|Where-Object|Measure-Object|Sort-Object|ConvertFrom-Json)"
# P3 subexpression capture: `$( git ...`, `$( & git ...`
P3="\\\$\\([[:space:]]*(&[[:space:]]*)?($N)(\\.exe)?[[:space:]]"
# P4 .NET process-stream capture -- same decode path, different mechanism
P4='StandardOutput\.ReadToEnd|StandardError\.ReadToEnd|StandardOutput\.ReadToEndAsync|StandardError\.ReadToEndAsync|Receive-Job'
# P5 assignment whose RHS is a pipeline ENDING in a native command: `$out =
# $raw | jq ...`. Neither P1 (wants the native immediately after `=`) nor P2
# (wants the native piped INTO a consuming cmdlet) sees this -- here the
# native sits at the END of the pipe, consuming a variable, not the other way
# round. This is not a corner case: it is the exact shape used by all ten
# scripts/lib/{,un}wire-*.ps1 libraries, which pipe a whole settings.json
# through jq and capture the result (`$out = $raw | jq --indent 2 $filter`) --
# the most severe instances of the HIMMEL-2256 class in the repo, since they
# write the mis-decoded capture back over a real user's config. Anchored to an
# assignment so a bare validation call whose stdout is discarded, not
# captured (`$raw | jq -e . > $null`, present in these same files), does NOT
# match.
P5="\\\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[^|#]*\\|[[:space:]]*(&[[:space:]]*)?($N)([[:space:]]|$)"

# Reviewed-exempt table: files the detector flags that are genuinely NOT in
# the class, each with a content FINGERPRINT of the file's detector-matching
# lines at review time and a one-line reason (path|fingerprint|reason). The
# fingerprint -- not just a count -- is pinned: an exemption is file-wide, so
# without one, a capture line SUBSTITUTED for another (e.g. swapping an
# ASCII-only `bun --version` capture for a `git log --format=%s` capture)
# would leave the line count unchanged and bypass the guard silently forever,
# even though the capture shape changed. The fingerprint is a sha256 (12 hex
# chars) of the file's detector-matching line TEXT (not line numbers -- a
# matching line that merely moves within the file is not a shape change),
# whitespace-trimmed and sorted so reordering doesn't trip it either. If the
# actual fingerprint ever differs from the pin -- a capture added, removed, OR
# substituted -- that is a capture-shape change since review and must be
# looked at consciously, never slide through. A new unilateral exemption must
# be added CONSCIOUSLY too -- house precedent is EXPECT_BASH_ONLY in
# scripts/parity/test-launcher-twin-parity.sh.
EXEMPT_ENTRIES=(
  "scripts/codex/test-reap-mcp-fleet.ps1|b112081bc922|dot-sources the helper -AsLibrary (in-process); its fixtures use Start-Process -RedirectStandardOutput to a FILE, decoded by Get-Content, not by [Console]::OutputEncoding"
  "scripts/himmelctl/bootstrap.ps1|9cdb280b3250|winget/node run uncaptured (console-bound); nothing reads their stdout"
  "scripts/hooks/test-doc-guard.ps1|d0840fceda44|the Process capture is explicitly discarded via [void]\$proc.StandardOutput.ReadToEnd(); only \$proc.ExitCode is used"
  "scripts/hooks/test-end-session-wiki.ps1|d0840fceda44|same shape: captured stdout is [void]-discarded, only the exit code and the written file are asserted on"
  "scripts/hooks/test-gen-changelog.ps1|ab426cb2e589|pwsh captures are matched against fixed English gate messages; its non-ASCII case deliberately asserts via ReadAllBytes + UTF8.GetString, bypassing console capture on purpose"
  "scripts/lib/test-detect-hook-dup.ps1|7a60fa4f32c2|captures are matched against hook basenames from detect-hook-dup.ps1's own hardcoded ASCII list"
  "scripts/machine-setup/win11.ps1|a2f586628b44|the one capture is node --version, a semver string, ASCII by construction"
  "scripts/observability/agent-runtime-census.ps1|052947551066|captures are --version strings; the poolmon dump is written by poolmon to a FILE and read with Get-Content (out of class)"
  "scripts/parity/test-ps-twin-oem-encoding.ps1|803fb1df1a65|the child-pwsh probe captures [Console]::OutputEncoding.CodePage, a numeric codepage string ASCII by construction, to check whether a fresh child even inherits cp437 before trusting the negative control -- nothing non-ASCII is ever captured"
  "scripts/qmd/register-qmd-daemon-logon.ps1|b1f09e3332c2|Get-Command pwsh is a cmdlet, not a native-stdout capture; scheduling goes through Register-ScheduledTask"
  "scripts/setup/onboard-telegram.ps1|105ef190faf2|the one capture is bun --version, ASCII by construction"
  "scripts/telegram/restart-bridge.ps1|a8248b332a87|bun/cmd launches redirect to a log FILE via Start-Process; the & \$Action calls are injectable PowerShell scriptblocks, not native captures"
)

is_exempt() {
  local target="$1" entry path
  for entry in "${EXEMPT_ENTRIES[@]}"; do
    path="${entry%%|*}"
    [ "$path" = "$target" ] && return 0
  done
  return 1
}

# fingerprint_detector_lines <file> -- a 12-hex-char sha256 fingerprint of the
# TEXT of every distinct line matching ANY of P1..P5 (deduped by line number
# so a line matching two patterns counts once, not twice), whitespace-trimmed
# and sorted before hashing so neither reordering nor line-number movement
# affects the result -- only the actual set of matching line content does.
fingerprint_detector_lines() {
  local file="$1"
  {
    grep -nE "$P1" "$file"
    grep -nE "$P2" "$file"
    grep -nE "$P3" "$file"
    grep -nE "$P4" "$file"
    grep -nE "$P5" "$file"
  } 2>/dev/null | sort -t: -k1,1n -u | cut -d: -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | sort | sha256hex | cut -c1-12
}

flagged=0
unexempt_fail=0
fixline_count=0

PS1_FILES="$(cd "$REPO" && git ls-files '*.ps1')"
for f in $PS1_FILES; do
  full="$REPO/$f"
  [ -f "$full" ] || continue

  if grep -qE "$FIXLINE_RE" "$full"; then
    fixline_count=$((fixline_count + 1))
  fi

  hit=0
  grep -qE "$P1" "$full" && hit=1
  grep -qE "$P2" "$full" && hit=1
  grep -qE "$P3" "$full" && hit=1
  grep -qE "$P4" "$full" && hit=1
  grep -qE "$P5" "$full" && hit=1
  [ "$hit" -eq 0 ] && continue
  flagged=$((flagged + 1))

  if grep -qE "$FIXLINE_RE" "$full"; then
    # Carries the fix line -- but presence alone isn't correctness: the fix
    # must also PRECEDE the first capture it's meant to guard, or it's a
    # no-op for that capture (exactly the bug that escaped this guard in
    # templates/luna-second-brain/scripts/setup.ps1 -- HIMMEL-2256).
    fixline_ln=$(grep -nE "$FIXLINE_RE" "$full" | head -1 | cut -d: -f1)
    first_capture_ln=$({ grep -nE "$P1" "$full"; grep -nE "$P2" "$full"; grep -nE "$P3" "$full"; grep -nE "$P4" "$full"; grep -nE "$P5" "$full"; } 2>/dev/null | cut -d: -f1 | sort -n | head -1)
    if [ "$fixline_ln" -gt "$first_capture_ln" ]; then
      capture_text="$(sed -n "${first_capture_ln}p" "$full" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      echo "FAIL: $f carries the HIMMEL-2256 fix line at L$fixline_ln but it lands AFTER the first native-stdout capture at L$first_capture_ln ($capture_text) -- the fix is a no-op for that capture. Move the fix line above L$first_capture_ln in $f." >&2
      FAIL=$((FAIL + 1))
      unexempt_fail=$((unexempt_fail + 1))
    fi
    continue   # carries the fix -- clean (order checked above)
  fi

  if is_exempt "$f"; then
    continue   # reviewed exemption on file -- clean
  fi

  echo "FAIL: $f captures native stdout (HIMMEL-2256 detector match) but carries neither the fix line ($FIXLINE) nor a reviewed exemption. Add the fix line, or if this capture is genuinely out of class, add a reviewed exemption entry to EXEMPT_ENTRIES in $0 with a one-line reason." >&2
  FAIL=$((FAIL + 1))
  unexempt_fail=$((unexempt_fail + 1))
done

# ---------------------------------------------------------------------------
# Start-Job scriptblocks: a SEPARATE runspace/process. A file-scope
# [Console]::OutputEncoding assignment does not reach code running inside a
# `Start-Job -ScriptBlock { ... }` body -- scripts/qmd/ensure-qmd-daemon.ps1
# needed the fix line a SECOND time, right inside its Start-Job block, for
# exactly this reason (HIMMEL-2256). So for every Start-Job scriptblock that
# itself contains a native-stdout capture, the fix line must ALSO appear
# inside that same block, before the capture -- the file-wide check above
# cannot see this, since a file-scope fix line before the whole block still
# satisfies it.
#
# P1..P5 only match a LITERAL native command name. A scriptblock commonly
# resolves its target through a variable first and invokes it with the call
# operator (`& $argv[0] ...`, exactly the ensure-qmd-daemon.ps1 shape), which
# the literal-name patterns can't see through. JOBCALL_RE catches that
# call-operator-on-a-variable shape; it is scoped to job-block scanning only
# and does not change the file-wide P1..P5 scan above.
JOBCALL_RE='(^|[^A-Za-z0-9_.$-])&[[:space:]]*\$[A-Za-z_][A-Za-z0-9_]*'

# find_job_blocks <file> -- prints "jobline:blockstart:blockend" (1-based,
# inclusive) for every Start-Job scriptblock in <file>: from the first `{` on
# or after a `Start-Job` line, tracking BRACE DEPTH until it returns to zero.
# Plain-text scan -- a `{`/`}` inside a string or comment would throw it off
# -- acceptable for this fleet; it is not a real PowerShell parser.
find_job_blocks() {
  awk '
    state == 0 && /Start-Job/ { state = 1; jobline = NR }
    {
      if (state == 1 || state == 2) {
        line = $0
        n = length(line)
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (state == 1) {
            if (c == "{") { state = 2; depth = 1; blockstart = NR }
          } else if (state == 2) {
            if (c == "{") depth++
            else if (c == "}") {
              depth--
              if (depth == 0) { print jobline ":" blockstart ":" NR; state = 0 }
            }
          }
        }
      }
    }
  ' "$1"
}

for f in $PS1_FILES; do
  full="$REPO/$f"
  [ -f "$full" ] || continue
  grep -qE 'Start-Job' "$full" || continue

  while IFS=: read -r job_ln blk_s blk_e; do
    [ -n "${blk_s:-}" ] || continue
    job_capture_ln=$({
      grep -nE "$P1" "$full"
      grep -nE "$P2" "$full"
      grep -nE "$P3" "$full"
      grep -nE "$P4" "$full"
      grep -nE "$P5" "$full"
      grep -nE "$JOBCALL_RE" "$full"
    } 2>/dev/null | cut -d: -f1 | sort -n | awk -v s="$blk_s" -v e="$blk_e" '$1 >= s && $1 <= e {print; exit}')
    [ -n "$job_capture_ln" ] || continue   # block has no native-stdout capture -- nothing to require

    job_fixline_ln=$(grep -nE "$FIXLINE_RE" "$full" | cut -d: -f1 | sort -n | awk -v s="$blk_s" -v e="$blk_e" '$1 >= s && $1 <= e {print; exit}')
    if [ -z "$job_fixline_ln" ] || [ "$job_fixline_ln" -gt "$job_capture_ln" ]; then
      job_capture_text="$(sed -n "${job_capture_ln}p" "$full" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      echo "FAIL: $f has a Start-Job scriptblock (L$job_ln) that captures native stdout at L$job_capture_ln ($job_capture_text) but does not carry the HIMMEL-2256 fix line inside that block before the capture -- a separate runspace does not inherit the file-scope [Console]::OutputEncoding setting. Add \"$FIXLINE\" as the first statement inside that scriptblock in $f." >&2
      FAIL=$((FAIL + 1))
    fi
  done < <(find_job_blocks "$full")
done

# ---------------------------------------------------------------------------
# HALF 1b -- structural: a P5 pipe-into-native also needs $OutputEncoding.
# ---------------------------------------------------------------------------
# [Console]::OutputEncoding (the FIXLINE checked above) governs only the
# CAPTURE direction -- decoding a native command's stdout. Piping TEXT INTO a
# native command's stdin is a SEPARATE direction governed by the
# $OutputEncoding preference variable, which defaults to ASCIIEncoding on
# Windows PowerShell 5.1: every non-ASCII character is silently replaced with
# `?` before the native command ever sees it (HIMMEL-2256 twin bug). P5's
# shape (`$out = $raw | jq ...`) is exactly this direction, so a file matching
# P5 must ALSO carry an assignment of $OutputEncoding to UTF8 -- at
# $global: scope if the assignment sits inside a function, since a bare
# $OutputEncoding there is function-local and never reaches the pipeline --
# or be a reviewed exemption below. Either the BOM-emitting
# [System.Text.Encoding]::UTF8 or the BOM-less [System.Text.UTF8Encoding]::new($false)
# satisfies this: both encode as UTF-8, but the BOM-less form is preferred for
# stdin since a leading EF BB BF is rejected by older jq (jq 1.6).
# shellcheck disable=SC2016  # literal $OutputEncoding text IS the regex — never expand
OUTENC_RE='^[[:space:]]*\$(global:)?OutputEncoding[[:space:]]*=[[:space:]]*(\[System\.Text\.Encoding\]::UTF8|\[System\.Text\.UTF8Encoding\]::new\([[:space:]]*\$false[[:space:]]*\))[[:space:]]*$'

# Reviewed-exempt table for THIS check only -- independent of EXEMPT_ENTRIES
# above, since a file can legitimately need the FIXLINE but not this one (or
# vice versa): the two directions are separate concerns. Same
# path|fingerprint|reason shape and fingerprint semantics as EXEMPT_ENTRIES.
OUTENC_EXEMPT_ENTRIES=(
  "scripts/setup/test-onboard-telegram.ps1|c5fd895f4703|the only text piped into the captured pwsh call is a literal empty string (\`'' | & pwsh ...\`) -- ASCII by construction, so nothing non-ASCII ever reaches native stdin"
)

is_outenc_exempt() {
  local target="$1" entry path
  for entry in "${OUTENC_EXEMPT_ENTRIES[@]}"; do
    path="${entry%%|*}"
    [ "$path" = "$target" ] && return 0
  done
  return 1
}

for f in $PS1_FILES; do
  full="$REPO/$f"
  [ -f "$full" ] || continue
  grep -qE "$P5" "$full" || continue

  if grep -qE "$OUTENC_RE" "$full"; then
    continue   # carries the $OutputEncoding fix too -- clean
  fi
  if is_outenc_exempt "$f"; then
    continue   # reviewed exemption -- pipe-into-native content is out of class
  fi

  p5_ln=$(grep -nE "$P5" "$full" | head -1 | cut -d: -f1)
  p5_text="$(sed -n "${p5_ln}p" "$full" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  echo "FAIL: $f pipes text INTO a native command's stdin at L$p5_ln ($p5_text) but does not set \$OutputEncoding to UTF8, and carries no reviewed exemption. [Console]::OutputEncoding covers only the CAPTURE direction; stdin encoding uses the \$OutputEncoding preference variable, which defaults to ASCIIEncoding on Windows PowerShell 5.1 and silently replaces every non-ASCII char with '?' before the native command ever sees it. Add \"\$global:OutputEncoding = [System.Text.Encoding]::UTF8\" (or \$OutputEncoding at file scope, outside any function) alongside the existing [Console]::OutputEncoding assignment in $f, or add a reviewed exemption to OUTENC_EXEMPT_ENTRIES in $0." >&2
  FAIL=$((FAIL + 1))
  unexempt_fail=$((unexempt_fail + 1))
done

# Every exemption must point at a file that still exists and is still tracked
# -- a stale exemption for a deleted/renamed file hides silently otherwise.
# Independently of that (and of whether the file is even still flagged above
# -- captures dropping to none must be caught too), its pinned fingerprint
# must still match reality: a mismatch means the capture shape changed since
# review (addition, removal, OR substitution) and needs a conscious re-look,
# not a silent pass-through.
for entry in "${OUTENC_EXEMPT_ENTRIES[@]}"; do
  path="${entry%%|*}"
  rest="${entry#*|}"
  pinned_fp="${rest%%|*}"
  if [ ! -f "$REPO/$path" ] || ! grepq "$PS1_FILES" -F -x "$path"; then
    echo "FAIL: OUTENC reviewed-exempt entry '$path' no longer resolves to a tracked .ps1 file -- remove the stale entry from OUTENC_EXEMPT_ENTRIES in $0." >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  actual_fp="$(fingerprint_detector_lines "$REPO/$path")"
  if [ "$actual_fp" != "$pinned_fp" ]; then
    echo "FAIL: $path is an OUTENC reviewed exemption pinned at fingerprint $pinned_fp but now fingerprints as $actual_fp -- its native-output captures changed since review (added, removed, or substituted). Re-review $path: fix any newly-in-class pipe-into-native with \$OutputEncoding, or if it's still genuinely out of class, update the pinned fingerprint in OUTENC_EXEMPT_ENTRIES in $0." >&2
    FAIL=$((FAIL + 1))
  fi
done

for entry in "${EXEMPT_ENTRIES[@]}"; do
  path="${entry%%|*}"
  rest="${entry#*|}"
  pinned_fp="${rest%%|*}"
  if [ ! -f "$REPO/$path" ] || ! grepq "$PS1_FILES" -F -x "$path"; then
    echo "FAIL: reviewed-exempt entry '$path' no longer resolves to a tracked .ps1 file -- remove the stale entry from EXEMPT_ENTRIES in $0." >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  actual_fp="$(fingerprint_detector_lines "$REPO/$path")"
  if [ "$actual_fp" != "$pinned_fp" ]; then
    echo "FAIL: $path is a reviewed exemption pinned at fingerprint $pinned_fp but now fingerprints as $actual_fp -- its native-output captures changed since review (added, removed, or substituted). Re-review $path: fix any newly-in-class capture with the fix line ($FIXLINE), or if it's still genuinely out of class, update the pinned fingerprint in EXEMPT_ENTRIES in $0 with a reason." >&2
    FAIL=$((FAIL + 1))
  fi
done

# Canary floor -- today's count of .ps1 files carrying the fix line is 59.
# Must be lowered only CONSCIOUSLY (a genuine removal of affected twins), so a
# mass revert or a bulk file deletion that silently takes the fix line with it
# trips this even though the detector itself would stay satisfied (the files
# would simply stop matching too).
EXPECT_MIN_FIXLINE_COUNT=59
if [ "$fixline_count" -lt "$EXPECT_MIN_FIXLINE_COUNT" ]; then
  echo "FAIL: only $fixline_count .ps1 file(s) carry the HIMMEL-2256 fix line, floor is $EXPECT_MIN_FIXLINE_COUNT -- if fixed twins were genuinely removed, lower EXPECT_MIN_FIXLINE_COUNT in $0 consciously; otherwise the fix line regressed somewhere." >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: $fixline_count .ps1 file(s) carry the fix line (floor $EXPECT_MIN_FIXLINE_COUNT)"
fi

if [ "$unexempt_fail" -eq 0 ]; then
  echo "ok: all $flagged detector-flagged .ps1 file(s) carry the fix line or a reviewed exemption"
fi

# ---------------------------------------------------------------------------
# HALF 2 -- behavioural (needs pwsh; self-skips loudly without it).
# ---------------------------------------------------------------------------
BEHAVIOURAL="$SCRIPT_DIR/test-ps-twin-oem-encoding.ps1"
if ! command -v pwsh >/dev/null 2>&1; then
  echo "[SKIP] test-ps-twin-oem-encoding.sh -- pwsh not found on PATH; the behavioural HIMMEL-2256 coverage (the actual cp437 mis-decode reproduction against scripts/lib/unwire-handover-dir.ps1, including its own negative control) did NOT run on this host."
else
  pwsh -NoProfile -NonInteractive -File "$BEHAVIOURAL"
  ps_rc=$?
  if [ "$ps_rc" -ne 0 ]; then
    echo "FAIL: $BEHAVIOURAL exited $ps_rc" >&2
    FAIL=$((FAIL + 1))
  fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: $FAIL failure(s)" >&2
  exit 1
fi
echo "OK: all cases passed"
exit 0
