#!/usr/bin/env bash
# HIMMEL-5039: every hook wired in .claude/settings.json and .codex/hooks.json
# must pass hook-integrity's source resolution, transitively.
#
# Why: #2202 added `. "$(dirname "$lib")/load-dotenv.sh"` to 7 hooks.
# hook-integrity.js could not resolve that statement, so it denied every tool
# call of every session running main's hooks until an admin revert (#2211). CI,
# /pr-check and the judge all missed it because nothing ran the REAL hook set
# through the resolver. This suite does: it enumerates the wired hook scripts,
# walks each one's sourced closure with hook-integrity's own sourcedClosure()
# (the function verifyIntegrity uses), and fails on an unresolved source
# statement or a sourced lib that is missing or outside the project.
#
# ponytail: checks the resolution step only, not the per-session pin check
# (that needs a session record); the pin check can only fail after resolution
# succeeds. Upgrade path: also drive verifyProjectHookIntegrity with a
# synthesized record.
#
# Usage: bash scripts/hooks/test-wired-hooks-integrity-resolution.sh
#        bash scripts/hooks/test-wired-hooks-integrity-resolution.sh <tree>   # sweep another tree (RED demos)
set -uo pipefail

ROOT="${1:-${HOOK_SRC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# check_closure <root> <script> -> prints one problem per line, nothing when clean
check_closure() {
  # shellcheck disable=SC2016  # node source, not shell
  node -e '
    const fs = require("fs"), path = require("path");
    const root = fs.realpathSync(process.argv[1]);
    const { sourcedClosure } = require(path.join(root, "scripts/hooks/hook-integrity.js"));
    const queue = [path.resolve(process.argv[2])], seen = new Set(queue);
    const list = [];
    while (queue.length) {
      const file = queue.shift();
      list.push(path.relative(root, file));
      let c;
      try { c = sourcedClosure(file, root); }
      catch (e) { console.log(`${path.relative(root, file)}: unreadable (${e.code || e.message})`); continue; }
      for (const u of c.unresolved) console.log(`${path.relative(root, file)}: unresolved source statement: ${u}`);
      for (const lib of c.libs) {
        const rel = path.relative(root, lib);
        if (rel.startsWith("..") || path.isAbsolute(rel)) { console.log(`${path.relative(root, file)}: sourced lib outside project: ${lib}`); continue; }
        if (!fs.existsSync(lib)) { console.log(`${path.relative(root, file)}: sourced lib missing: ${rel}`); continue; }
        if (!seen.has(lib)) { seen.add(lib); queue.push(lib); }
      }
    }
    if (process.env.CLOSURE_OUT) fs.appendFileSync(process.env.CLOSURE_OUT, list.join("\n") + "\n");
  ' "$1" "$2"
}

# uncovered <root> <paths-file> -> the paths no impacted-suites.sh scan_roots row
# maps to THIS suite, so a change to them would not select it in PR CI
uncovered() {
  local globs g s rest f hit
  globs="$(sed -n '/^scan_roots() {/,/^EOF$/p' "$1/scripts/cr/impacted-suites.sh" |
    while read -r g s rest; do
      [ "$s" = "scripts/hooks/test-wired-hooks-integrity-resolution.sh" ] && printf '%s\n' "$g"
    done)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      # shellcheck disable=SC2254  # the scan_roots glob is a pattern on purpose
      case "$f" in $g) hit=1; break ;; esac
    done <<< "$globs"
    [ "$hit" -eq 1 ] || printf '%s\n' "$f"
  done < "$2"
}

# wired_scripts <root> -> repo-relative hook script paths, one per line, deduped
wired_scripts() {
  # shellcheck disable=SC2016  # node source, not shell
  node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1], out = new Set();
    const cmds = (f) => {
      const p = path.join(root, f);
      if (!fs.existsSync(p)) { console.error("missing wiring file: " + f); process.exit(3); }
      const j = JSON.parse(fs.readFileSync(p, "utf8"));
      const r = [];
      const walk = (n) => { if (Array.isArray(n)) n.forEach(walk); else if (n && typeof n === "object") { if (typeof n.command === "string") r.push(n.command); Object.values(n).forEach(walk); } };
      walk(j.hooks || j);
      return r;
    };
    for (const c of cmds(".claude/settings.json"))
      for (const m of c.matchAll(/\$\{?CLAUDE_PROJECT_DIR\}?\/([^"\s;]+\.(?:sh|js))/g)) out.add(m[1]);
    for (const c of cmds(".codex/hooks.json")) {
      const m = c.match(/run-hook\.sh\s+(?:--\S+\s+)*([A-Za-z0-9_.+-]+\.sh(?:\+[A-Za-z0-9_.+-]+\.sh)*)/);
      if (m) for (const n of m[1].split("+")) out.add("scripts/hooks/" + n);
    }
    console.log([...out].sort().join("\n"));
  ' "$1"
}

echo "== fixture rows (the resolver must flag what it flagged on 2026-10-08)"
FX="$(mktemp -d "${TMPDIR:-/tmp}/wired-hooks-integrity.XXXXXX")" || exit 1
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/scripts/hooks" "$FX/scripts/lib"
cp "$ROOT/scripts/hooks/hook-integrity.js" "$FX/scripts/hooks/"
printf '# lib\n' > "$FX/scripts/lib/load-dotenv.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nlib=/x/handover-path.sh\n. "$(dirname "$lib")/load-dotenv.sh"\n' > "$FX/scripts/hooks/bad.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../lib/load-dotenv.sh"\n' > "$FX/scripts/hooks/good.sh"
if [ -n "$(check_closure "$FX" "$FX/scripts/hooks/bad.sh")" ]; then ok "the #2202 source form is reported unresolved"; else bad "the #2202 source form passed the resolver (suite cannot fail)"; fi
if good_out="$(check_closure "$FX" "$FX/scripts/hooks/good.sh" 2>&1)" && [ -z "$good_out" ]; then ok "a dirname-relative source of a real lib resolves"; else bad "a resolvable source form was flagged"; fi

# RED control: a path under a directory no row covers must be reported
printf 'scripts/lib/x.sh\nscripts/newdir/x.sh\n' > "$FX/paths"
if [ "$(uncovered "$ROOT" "$FX/paths")" = "scripts/newdir/x.sh" ]; then ok "an uncovered closure directory is reported, a covered one is not"; else bad "closure-coverage check cannot fail"; fi

echo "== every wired hook script resolves"
N=0
CL="$FX/closure"; : > "$CL"; export CLOSURE_OUT="$CL"
if ! SCRIPTS="$(wired_scripts "$ROOT" 2>&1)"; then bad "wiring enumeration failed: $SCRIPTS"; SCRIPTS=""; fi
if [ -z "$SCRIPTS" ]; then bad "no wired hook scripts found in settings.json / hooks.json"; fi
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    # The launcher itself runs BEFORE hook-integrity (it starts node); it is not
    # a hook script and is never passed through verifyProjectHookIntegrity.
    scripts/lib/run-node.sh) continue ;;
    *.sh) ;;
    *) continue ;;
  esac
  N=$((N + 1))
  # No wired command uses --optional today, so a wired path with no file is a
  # defect (deleted or misspelled hook), not a no-op.
  if [ ! -f "$ROOT/$rel" ]; then bad "$rel (wired but not present)"; continue; fi
  if out="$(check_closure "$ROOT" "$ROOT/$rel" 2>&1)"; then
    if [ -z "$out" ]; then ok "$rel"; else bad "$rel"; printf '       %s\n' "$out"; fi
  else
    bad "$rel (resolver failed to run)"; printf '       %s\n' "$out"
  fi
done <<< "$SCRIPTS"
CLOSURE_OUT="" # the fixture rows above are done; stop recording
# Every file hook-integrity walks must sit where impacted-suites.sh selects this
# suite, else a PR touching only that file (guardrails/lib.sh, queue-lock.sh)
# adds an unresolvable source and CI never runs the sweep.
sort -u "$CL" > "$CL.u"
if unc="$(uncovered "$ROOT" "$CL.u")" && [ -z "$unc" ]; then ok "every closure file is selected by a scan_roots row"; else bad "closure files outside scan_roots coverage (add a row in scripts/cr/impacted-suites.sh): $(printf '%s' "$unc" | tr '\n' ' ')"; fi
if [ "$N" -ge 10 ]; then ok "enumerated $N wired hook scripts"; else bad "only $N wired hook scripts enumerated (parser drift?)"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
