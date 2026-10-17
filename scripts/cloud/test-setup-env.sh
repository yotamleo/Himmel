#!/usr/bin/env bash
# test-setup-env.sh — scripts/cloud/setup-env.sh. Hermetic: every
# case runs --dry-run or a stubbed PATH, so nothing is installed and no network
# is touched. The script is a paste-in for a claude.ai cloud environment, so the
# contract worth pinning is: it plans every step, skips what is already present,
# changes nothing in dry-run, rejects flags it does not know, and never lets the
# plugin step fail the run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/scripts/cloud/setup-env.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$SETUP" ] || { echo "FAIL - $SETUP missing (every case below would pass or fail vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cloud-setup-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A fake repo root: the script must act on HIMMEL_CLOUD_ROOT, never on the real tree.
FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts/jira" "$FAKE/marketplace/plugins/obsidian-triage/tools"
: > "$FAKE/scripts/jira/package.json"

# Stub bin: tools the script probes with `command -v`. An empty PATH dir means
# "nothing installed"; a stub means "already present".
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
HAVE="$TMP/have"; mkdir -p "$HAVE"
for t in shellcheck at pre-commit gitleaks; do printf '#!/bin/sh\nexit 0\n' > "$HAVE/$t"; chmod +x "$HAVE/$t"; done

BASH_BIN="$(command -v bash)"
run() { # run <path-dir> [args...] -> stdout in $OUT, rc in $RC
  local pdir="$1"; shift
  # PATH is ONLY the stub dir: the host's own /usr/bin may already carry shellcheck.
  OUT="$(env -i PATH="$pdir" HIMMEL_CLOUD_ROOT="$FAKE" "$BASH_BIN" "$SETUP" "$@" 2>&1)"
  RC=$?
}

# 1. dry-run plans every step and exits 0.
run "$EMPTY" --dry-run
if [ "$RC" -eq 0 ]; then ok "dry-run exits 0"; else bad "dry-run rc=$RC: $OUT"; fi
for step in shellcheck at pre-commit jira-dist obsidian-deps; do
  case "$OUT" in *"step=$step "*) ok "dry-run plans step $step" ;; *) bad "dry-run omits step $step: $OUT" ;; esac
done

# 2. nothing present -> shellcheck planned as install; present -> skip.
case "$OUT" in *"step=shellcheck action=install"*) ok "absent shellcheck is planned as install" ;; *) bad "absent shellcheck not install: $OUT" ;; esac
run "$HAVE" --dry-run
case "$OUT" in *"step=shellcheck action=skip"*) ok "present shellcheck is skipped" ;; *) bad "present shellcheck not skipped: $OUT" ;; esac

# 3. a built jira dist is skipped (idempotent re-run inside the 5-min cache window).
mkdir -p "$FAKE/scripts/jira/dist"; : > "$FAKE/scripts/jira/dist/index.js"
run "$HAVE" --dry-run
case "$OUT" in *"step=jira-dist action=skip"*) ok "built jira dist is skipped" ;; *) bad "built dist not skipped: $OUT" ;; esac
rm -rf "$FAKE/scripts/jira/dist"

# 3c. gitleaks: the pre-push secret gate needs it and the image lacks it. Pinned
# to the CI version with a checksum; absent -> install, present -> skip.
run "$EMPTY" --dry-run
case "$OUT" in *"step=gitleaks action=install"*"8.30.1"*) ok "absent gitleaks is planned as a pinned install" ;; *) bad "absent gitleaks not a pinned install: $OUT" ;; esac
run "$HAVE" --dry-run
case "$OUT" in *"step=gitleaks action=skip"*) ok "present gitleaks is skipped" ;; *) bad "present gitleaks not skipped: $OUT" ;; esac
if grep -q '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' "$SETUP"; then ok "gitleaks download is checksum-pinned"; else bad "gitleaks download carries no sha256 pin"; fi

# 4. dry-run changes nothing in the tree.
run "$EMPTY" --dry-run
if [ ! -e "$FAKE/scripts/jira/dist" ] && [ ! -e "$FAKE/scripts/jira/node_modules" ]; then ok "dry-run leaves the tree untouched"; else bad "dry-run created files"; fi

# 5. the Bash timeouts come from the environment's env-vars field, not the script:
# a cloud probe showed a profile.d write never reaches the Bash tool.
case "$OUT" in *"TIMEOUT_MS"*) bad "setup still plans a Bash timeout write: $OUT" ;; *) ok "no Bash timeout step (the env-vars field sets them)" ;; esac

# 6. plugin profile: OFF by default; --with-plugins installs the
# lean set; --plugins <list> installs exactly that list; a bad name is skipped.
mkdir -p "$FAKE/marketplace/plugins/himmel-ops" "$FAKE/marketplace/plugins/lean-skills" "$FAKE/marketplace/plugins/qmd"
case "$OUT" in *"step=plugin"*) bad "plugin step planned without a profile" ;; *) ok "plugins step off by default" ;; esac
run "$EMPTY" --dry-run --with-plugins
case "$OUT" in *"step=plugins-marketplace action=add"*) ok "--with-plugins plans the marketplace add" ;; *) bad "--with-plugins no marketplace add: $OUT" ;; esac
case "$OUT" in *"step=plugin:himmel-ops action=install"*"step=plugin:lean-skills action=install"*) ok "--with-plugins plans the lean set" ;; *) bad "--with-plugins not the lean set: $OUT" ;; esac
case "$OUT" in *"step=plugin:qmd "*) bad "--with-plugins installs beyond the lean set" ;; *) ok "--with-plugins stays lean" ;; esac
run "$EMPTY" --dry-run --plugins qmd,himmel-ops
case "$OUT" in *"step=plugin:qmd action=install"*"step=plugin:himmel-ops action=install"*) ok "--plugins installs the named list" ;; *) bad "--plugins list not planned: $OUT" ;; esac
case "$OUT" in *"step=plugin:lean-skills "*) bad "--plugins installs an unlisted plugin" ;; *) ok "--plugins installs only the list" ;; esac
run "$EMPTY" --dry-run --plugins='nosuch,bad;name'
if [ "$RC" -eq 0 ]; then ok "bad plugin names do not fail the run"; else bad "bad plugin names rc=$RC: $OUT"; fi
case "$OUT" in *"step=plugin:nosuch action=skip"*) ok "unknown plugin is skipped" ;; *) bad "unknown plugin not skipped: $OUT" ;; esac
case "$OUT" in *"action=skip"*"invalid"*) ok "invalid plugin name is skipped" ;; *) bad "invalid plugin name not skipped: $OUT" ;; esac
run "$EMPTY" --plugins
if [ "$RC" -eq 2 ]; then ok "--plugins without a list exits 2"; else bad "--plugins without a list rc=$RC"; fi

# 6b. a failing plugin install is NON-fatal: a non-zero setup script stops the
# cloud session from starting. Real (non-dry) run, every other step present.
mkdir -p "$FAKE/scripts/jira/dist" "$FAKE/marketplace/plugins/obsidian-triage/tools/node_modules"
: > "$FAKE/scripts/jira/dist/index.js"
FAILC="$TMP/failclaude"; mkdir -p "$FAILC"
cp "$HAVE"/* "$FAILC/"
printf '#!/bin/sh\necho "$@" >> "%s/claude.log"\nexit 1\n' "$TMP" > "$FAILC/claude"; chmod +x "$FAILC/claude"
ln -s "$(command -v timeout)" "$FAILC/timeout"
OUT="$(env -i PATH="$FAILC" HIMMEL_CLOUD_ROOT="$FAKE" "$BASH_BIN" "$SETUP" --with-plugins 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "failing plugin install keeps rc 0"; else bad "failing plugin install rc=$RC: $OUT"; fi
if grep -q 'install lean-skills@himmel' "$TMP/claude.log" 2>/dev/null; then ok "one failed install does not stop the next"; else bad "lean-skills install not attempted: $(cat "$TMP/claude.log" 2>/dev/null)"; fi
case "$OUT" in *"plugin:himmel-ops"*"non-fatal"*) ok "failed plugin install is reported" ;; *) bad "failed plugin install silent: $OUT" ;; esac
rm -rf "$FAKE/scripts/jira/dist" "$FAKE/marketplace/plugins/obsidian-triage/tools/node_modules"

# 6c. the slow npm builds run LAST: a cloud setup died silently in
# jira-dist and every later step (plugins) was lost with it.
run "$EMPTY" --dry-run --with-plugins
order="$(printf '%s\n' "$OUT" | sed -n 's/^step=\([^ ]*\) .*/\1/p' | tr '\n' ' ')"
case "$order" in *"plugin:lean-skills "*"jira-dist "*"obsidian-deps "*) ok "plugins run before the npm builds" ;; *) bad "step order puts a build before the plugins: $order" ;; esac

# 6d. a failing jira build is NON-fatal and says why: a FAILED line with the
# reason, the npm stderr tail, and the next step still runs.
NPMF="$TMP/npmfail"; mkdir -p "$NPMF"
cp "$HAVE"/* "$NPMF/"
for t in timeout sh tail mkdir bash; do ln -s "$(command -v "$t")" "$NPMF/$t"; done
printf '#!/bin/sh\necho "npm ERR! registry hang" >&2\nexit 124\n' > "$NPMF/npm"; chmod +x "$NPMF/npm"
printf '#!/bin/sh\necho ensure-deps-ran\nexit 0\n' > "$FAKE/marketplace/plugins/obsidian-triage/tools/ensure-deps.sh"
OUT="$(env -i PATH="$NPMF" HIMMEL_CLOUD_ROOT="$FAKE" TMPDIR="$TMP" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "failing jira build keeps rc 0"; else bad "failing jira build rc=$RC: $OUT"; fi
case "$OUT" in *"step=jira-dist FAILED"*"timed out"*) ok "jira build failure names its reason" ;; *) bad "no 'step=jira-dist FAILED ... timed out' line: $OUT" ;; esac
case "$OUT" in *"npm ERR! registry hang"*) ok "jira build failure shows the npm stderr" ;; *) bad "npm stderr not surfaced: $OUT" ;; esac
if grep -q ensure-deps-ran "$TMP/himmel-setup-logs/obsidian-deps.log" 2>/dev/null; then ok "a failed jira build does not stop the next step"; else bad "obsidian-deps did not run after the jira failure: $OUT"; fi
rm -f "$FAKE/marketplace/plugins/obsidian-triage/tools/ensure-deps.sh"

# 6e. graphify + repo-only qmd. graphify installs at the in-repo
# pin and builds AST-only; qmd indexes this repo as `himmel` and nothing else,
# BM25 only (no model pull, no embed).
mkdir -p "$FAKE/scripts/lib"
cp "$ROOT/scripts/lib/qmd-bounded.sh" "$FAKE/scripts/lib/qmd-bounded.sh"
printf '%s\n' 'qmd_cmd() { qmd "$@"; }' > "$FAKE/scripts/lib/qmd-bin.sh"
# shellcheck disable=SC2016  # literal fixture text, expanded by nothing
printf '%s\n' '_graphify_version() { printf '"'"'%s\n'"'"' "${GRAPHIFY_VERSION:-9.8.7}"; }' > "$FAKE/scripts/lib/graphify-bin.sh"
run "$EMPTY" --dry-run
for step in graphify graphify-graph qmd qmd-index; do
  case "$OUT" in *"step=$step "*) ok "dry-run plans step $step" ;; *) bad "dry-run omits step $step: $OUT" ;; esac
done
case "$OUT" in *"step=graphify action=install graphifyy==9.8.7 "*) ok "graphify installs at the in-repo pin" ;; *) bad "graphify not at the in-repo pin: $OUT" ;; esac
case "$OUT" in *"graphifyy["*) bad "graphify installs a backend extra: $OUT" ;; *) ok "graphify installs no semantic-backend extra" ;; esac
case "$OUT" in *"step=graphify-graph action=build graphify update "*) ok "graph build is the AST-only update" ;; *) bad "graph build is not 'graphify update': $OUT" ;; esac
case "$OUT" in *"--backend"*|*"/graphify "*) bad "setup plans a semantic graphify run: $OUT" ;; *) ok "no semantic graphify run planned" ;; esac
case "$OUT" in *"step=qmd-index action=add $FAKE --name himmel"*) ok "qmd indexes only this repo as himmel" ;; *) bad "qmd-index not the repo-only himmel collection: $OUT" ;; esac
case "$OUT" in *luna*|*vault*|*HANDOVER*) bad "setup plans a vault or handover path: $OUT" ;; *) ok "no vault or handover path planned" ;; esac
case "$OUT" in *"qmd pull"*|*"qmd embed"*) bad "setup plans a model pull or embed: $OUT" ;; *) ok "qmd stays BM25-only (no pull, no embed)" ;; esac
order="$(printf '%s\n' "$OUT" | sed -n 's/^step=\([^ ]*\) .*/\1/p' | tr '\n' ' ')"
case "$order" in *"graphify graphify-graph "*"qmd qmd-index "*) ok "graph build follows its install, index follows qmd" ;; *) bad "graphify/qmd step order: $order" ;; esac
# present tools skip their install; an existing himmel collection skips the add.
GQ="$TMP/gq"; mkdir -p "$GQ"; cp "$HAVE"/* "$GQ/"
ln -s "$(command -v timeout)" "$GQ/timeout"   # the collection probe is timeout-bounded
ln -s "$(command -v dirname)" "$GQ/dirname"
printf '#!/bin/sh\nexit 0\n' > "$GQ/graphify"
# shellcheck disable=SC2016  # $1/$2 belong to the stub script
printf '#!/bin/sh\n[ "$1 $2" = "collection list" ] && echo "himmel (qmd://himmel/)"\nexit 0\n' > "$GQ/qmd"
chmod +x "$GQ/graphify" "$GQ/qmd"
run "$GQ" --dry-run
case "$OUT" in *"step=graphify action=skip"*) ok "present graphify is skipped" ;; *) bad "present graphify not skipped: $OUT" ;; esac
case "$OUT" in *"step=qmd action=skip"*) ok "present qmd is skipped" ;; *) bad "present qmd not skipped: $OUT" ;; esac
case "$OUT" in *"step=qmd-index action=refresh $FAKE --name himmel"*) ok "an existing himmel collection is rebuilt from this clone" ;; *) bad "existing himmel collection not refreshed (stale index): $OUT" ;; esac
# The cloud image shipped graphify 0.9.77 while the pin was 0.9.80
# and "present" skipped the install, so the version drifted from the pin. A
# present graphify at another version is reinstalled at the pin; at the pin, or
# with an unparseable version, it is skipped.
GV="$TMP/gver"; mkdir -p "$GV"; cp "$GQ"/* "$GV/"
for t in head grep; do ln -s "$(command -v "$t")" "$GV/$t"; done   # the version parse
printf '#!/bin/sh\necho "graphify 9.8.6"\n' > "$GV/graphify"; chmod +x "$GV/graphify"
run "$GV" --dry-run
case "$OUT" in *"step=graphify action=install graphifyy==9.8.7 "*) ok "graphify off the pin is reinstalled at the pin" ;; *) bad "graphify off the pin not reinstalled: $OUT" ;; esac
printf '#!/bin/sh\necho "graphify 9.8.7"\n' > "$GV/graphify"
run "$GV" --dry-run
case "$OUT" in *"step=graphify action=skip"*) ok "graphify at the pin is skipped" ;; *) bad "graphify at the pin not skipped: $OUT" ;; esac
# a failing graphify / qmd install is NON-fatal and does not stop the next step.
GF="$TMP/gfail"; mkdir -p "$GF"; cp "$HAVE"/* "$GF/"
for t in timeout sh tail mkdir bash; do ln -s "$(command -v "$t")" "$GF/$t"; done
printf '#!/bin/sh\necho "pip boom" >&2\nexit 1\n' > "$GF/python3"; chmod +x "$GF/python3"
printf '#!/bin/sh\nexit 0\n' > "$GF/qmd"; chmod +x "$GF/qmd"
mkdir -p "$FAKE/scripts/jira/dist" "$FAKE/marketplace/plugins/obsidian-triage/tools/node_modules"; : > "$FAKE/scripts/jira/dist/index.js"
OUT="$(env -i PATH="$GF" HIMMEL_CLOUD_ROOT="$FAKE" TMPDIR="$TMP" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "failing graphify install keeps rc 0"; else bad "failing graphify install rc=$RC: $OUT"; fi
case "$OUT" in *"step=graphify FAILED"*) ok "graphify install failure is reported" ;; *) bad "graphify install failure silent: $OUT" ;; esac
case "$OUT" in *"step=graphify-graph action=skip"*) ok "no graph build without graphify" ;; *) bad "graph build attempted without graphify: $OUT" ;; esac
case "$OUT" in *"step=qmd-index action=add"*) ok "a failed graphify install does not stop qmd" ;; *) bad "qmd-index not reached after the graphify failure: $OUT" ;; esac
# The installer succeeds without a qmd shim on PATH. Resolve the
# installed tool through qmd-bounded, and verify the collection after adding it.
cp "$ROOT/scripts/lib/qmd-bounded.sh" "$FAKE/scripts/lib/qmd-bounded.sh"
cat > "$FAKE/scripts/lib/qmd-bin.sh" <<EOF
qmd_cmd() { /bin/sh "$TMP/installed-qmd" "\$@"; }
EOF
cat > "$TMP/installed-qmd" <<EOF
case "\$1 \$2" in
  'collection list') [ ! -f "$TMP/qmd-no-register" ] && [ -f "$TMP/qmd-registered" ] && echo 'himmel (qmd://himmel/)' ;;
  'collection add') printf '%s\\n' "\$3" > "$TMP/qmd-registered" ;;
esac
exit 0
EOF
rm -f "$GF/qmd"
for t in dirname sleep mktemp rm; do ln -s "$(command -v "$t")" "$GF/$t"; done
OUT="$(env -i PATH="$GF" HOME="$TMP/home" HIMMEL_CLOUD_ROOT="$FAKE" TMPDIR="$TMP" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
if [ -f "$TMP/qmd-registered" ] && [ "$(cat "$TMP/qmd-registered")" = "$FAKE" ]; then ok "off-PATH installed qmd registers only the repo"; else bad "off-PATH qmd never registers himmel: $OUT"; fi
: > "$TMP/qmd-no-register"
OUT="$(env -i PATH="$GF" HOME="$TMP/home" HIMMEL_CLOUD_ROOT="$FAKE" TMPDIR="$TMP" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
case "$OUT" in *"step=qmd-index FAILED"*"himmel collection missing after setup"*) ok "missing collection fails setup step loudly" ;; *) bad "missing collection silently succeeds: $OUT" ;; esac
# The same setup runs in the session checkout (4811), never a hardcoded /tmp
# graph. The graphify stub records the actual cwd and materializes its output.
rm -f "$TMP/qmd-no-register"
cat > "$GF/graphify" <<EOF
#!/bin/sh
/bin/pwd > "$TMP/graph-cwd"
mkdir -p graphify-out
printf '{}\\n' > graphify-out/graph.json
EOF
chmod +x "$GF/graphify"
OUT="$(env -i PATH="$GF" HOME="$TMP/home" HIMMEL_CLOUD_ROOT="$FAKE" TMPDIR="$TMP" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/graph-cwd")" = "$FAKE" ] && [ -f "$FAKE/graphify-out/graph.json" ]; then ok "setup builds graph inside the session checkout"; else bad "graph not built inside checkout: $OUT"; fi
rm -rf "$FAKE/scripts/jira/dist" "$FAKE/marketplace/plugins/obsidian-triage/tools/node_modules" "$FAKE/scripts/lib"

# 6f. git gate hooks: the cloud clone has none installed, so the
# pre-commit, commit-msg (attestation trailers, ticket ID) and pre-push gates
# would not fire. A bare `pre-commit install` installs only the first, so all
# three types are named. Hermetic: a stub pre-commit records its arguments.
GT="$TMP/gitrepo"; mkdir -p "$GT/.git/hooks" "$GT/scripts/jira"
: > "$GT/scripts/jira/package.json"
GTB="$TMP/gtbin"; mkdir -p "$GTB"
for t in timeout sh mkdir bash dirname pwd cat; do ln -s "$(command -v "$t")" "$GTB/$t"; done
printf '#!/bin/sh\nexit 0\n' > "$GTB/shellcheck"; cp "$GTB/shellcheck" "$GTB/at"
# shellcheck disable=SC2016  # stub script text, expanded when the stub runs
printf '#!/bin/sh\npwd > "$HIMMEL_HOOK_LOG"\necho "$*" >> "$HIMMEL_HOOK_LOG"\nexit "${HIMMEL_HOOK_RC:-0}"\n' > "$GTB/pre-commit"
chmod +x "$GTB/shellcheck" "$GTB/at" "$GTB/pre-commit"
gt_run() { OUT="$(env -i PATH="$GTB" HIMMEL_CLOUD_ROOT="$GT" TMPDIR="$TMP" HIMMEL_HOOK_LOG="$TMP/hook.log" HIMMEL_HOOK_RC="${GT_RC:-0}" GT_HOOKSPATH="${GT_HOOKSPATH:-}" "$BASH_BIN" "$SETUP" $GT_ARGS 2>&1)"; RC=$?; }
GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=install"*"commit-msg"*"pre-push"*) ok "git gate hooks planned for all three stages" ;; *) bad "git-hooks step missing or incomplete: $OUT" ;; esac
rm -f "$TMP/hook.log"; GT_ARGS="" gt_run
if [ -f "$TMP/hook.log" ] && [ "$(sed -n 1p "$TMP/hook.log")" = "$GT" ]; then ok "hooks installed inside the session checkout"; else bad "pre-commit install not run in the checkout: $(cat "$TMP/hook.log" 2>/dev/null)"; fi
case "$(sed -n 2p "$TMP/hook.log" 2>/dev/null)" in *"install"*"--hook-type pre-commit"*"--hook-type commit-msg"*"--hook-type pre-push"*) ok "all three hook types installed (a bare install gates only pre-commit)" ;; *) bad "hook types: $(sed -n 2p "$TMP/hook.log" 2>/dev/null)" ;; esac
rm -f "$TMP/hook.log"; GT_RC=1 GT_ARGS="" gt_run
if [ "$RC" -eq 0 ]; then ok "failing hook install keeps rc 0"; else bad "failing hook install rc=$RC: $OUT"; fi
for h in pre-commit commit-msg pre-push; do : > "$GT/.git/hooks/$h"; done
# git ignores a hook that is not executable, so present-but-not-executable is NOT installed
GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=install"*) ok "non-executable hook files are reinstalled" ;; *) bad "non-executable hooks read as installed: $OUT" ;; esac
for h in pre-commit commit-msg pre-push; do chmod +x "$GT/.git/hooks/$h"; done
GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=skip"*) ok "installed git hooks are skipped" ;; *) bad "installed hooks not skipped: $OUT" ;; esac
# core.hooksPath redirects git away from .git/hooks and `pre-commit install` refuses
# while it is set, so the .git/hooks check says nothing about what git will run
rm -f "$GT/.git/hooks/pre-push"
# shellcheck disable=SC2016  # stub script text, expanded when the stub runs
printf '#!/bin/sh\n[ -n "$GT_HOOKSPATH" ] && { echo "$GT_HOOKSPATH"; exit 0; }\nexit 1\n' > "$GTB/git"; chmod +x "$GTB/git"
GT_HOOKSPATH=/elsewhere/hooks GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=skip"*"core.hooksPath"*) ok "core.hooksPath set skips the hook install and names it" ;; *) bad "core.hooksPath not honoured: $OUT" ;; esac
GT_HOOKSPATH="" GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=install"*) ok "core.hooksPath unset still installs" ;; *) bad "unset core.hooksPath: $OUT" ;; esac
rm -f "$GTB/git"
rm -rf "$GT/.git"
GT_ARGS="--dry-run" gt_run
case "$OUT" in *"step=git-hooks action=skip"*"not a git work tree"*) ok "no git work tree skips the hook step" ;; *) bad "no-git case: $OUT" ;; esac

# 7. an unknown flag is refused (rc 2) rather than silently ignored.
run "$EMPTY" --nope
if [ "$RC" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag rc=$RC"; fi

# 7b. every documented paste ends `|| true`: a non-zero setup script stops the
# cloud session from starting, and the clone itself can fail before the script runs.
TEMPLATE="$ROOT/docs/handover/cloud-brief-template.md"
RECIPE="$ROOT/docs/setup/cloud-environment.md"  # the operator's environment recipe
if [ -f "$RECIPE" ]; then ok "environment recipe exists"; else bad "environment recipe $RECIPE missing"; fi
# the recipe's paste is rendered by check-env.sh --print, not inlined
case "$(grep -h 'setup-env.sh' "$ROOT/scripts/cloud/check-env.sh" 2>/dev/null)" in *"--with-plugins || true"*) ok "recipe paste installs the plugin profile" ;; *) bad "recipe paste lacks '--with-plugins || true'" ;; esac
pastes="$(grep -h 'bash /tmp/himmel-setup/scripts/cloud/setup-env.sh' "$SETUP" "$TEMPLATE" "$RECIPE" 2>/dev/null)"
unsafe="$(grep -v '|| true$' <<< "$pastes")"
if [ -z "$pastes" ]; then
  bad "no setup paste line found in the header or $TEMPLATE"
elif [ -n "$unsafe" ]; then
  bad "a setup paste line does not end with '|| true': $unsafe"
else
  ok "every setup paste line ends with '|| true' ($(printf '%s\n' "$pastes" | wc -l | tr -d ' ') lines)"
fi

# The operator probe rebuilds in the classified session
# checkout and searches through the bounded repo-only path.
recipe_text="$(cat "$RECIPE")"
case "$recipe_text" in *'bash scripts/cloud/setup-env.sh'*'graphify query "cloud route classification" --graph graphify-out/graph.json'*) ok "probe builds and queries the classified session graph" ;; *) bad "probe still queries the unclassified cached graph" ;; esac
case "$recipe_text" in *'bash scripts/lib/qmd-bounded.sh search "cloud environment" -c himmel'*) ok "probe searches through bounded repo-only qmd" ;; *) bad "probe does not use bounded scoped search" ;; esac

# 7b. Paths reach `sh -c` as positional args, never interpolated into
# its source. A clone path with a quote, a space and `$x` must be entered verbatim
# by both sh -c steps (jira build, graphify update) and must not run as shell.
HOST="$TMP/it's a \$x dir"
mkdir -p "$HOST/scripts/jira" "$HOST/scripts/lib" "$HOST/marketplace/plugins/obsidian-triage/tools/node_modules"
: > "$HOST/scripts/jira/package.json"
cp "$FAKE/scripts/lib/"* "$HOST/scripts/lib/"
HB="$TMP/hostile"; mkdir -p "$HB"; cp "$HAVE"/* "$HB/"
for t in timeout sh tail mkdir bash dirname pwd; do ln -s "$(command -v "$t")" "$HB/$t"; done
# shellcheck disable=SC2016  # stub script text, expanded when the stub runs
printf '#!/bin/sh\necho "jira:$(pwd)" >> "$HIMMEL_PWD_LOG"\nexit 0\n' > "$HB/npm"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "graphify:$(pwd)" >> "$HIMMEL_PWD_LOG"\nexit 0\n' > "$HB/graphify"
printf '#!/bin/sh\nexit 0\n' > "$HB/qmd"
chmod +x "$HB/npm" "$HB/graphify" "$HB/qmd"
: > "$TMP/pwd.log"
OUT="$(env -i PATH="$HB" HIMMEL_CLOUD_ROOT="$HOST" TMPDIR="$TMP" HIMMEL_PWD_LOG="$TMP/pwd.log" "$BASH_BIN" "$SETUP" 2>&1)"; RC=$?
case "$OUT" in *"step=jira-dist FAILED"*) bad "jira build broke on a hostile clone path: $OUT" ;; *) ok "jira build survives a quote/space/\$ clone path" ;; esac
case "$OUT" in *"step=graphify-graph FAILED"*) bad "graphify update broke on a hostile clone path: $OUT" ;; *) ok "graphify update survives a quote/space/\$ clone path" ;; esac
if grep -qxF "graphify:$HOST" "$TMP/pwd.log"; then ok "graphify ran in the verbatim clone path"; else bad "graphify did not run in the verbatim path: $(cat "$TMP/pwd.log")"; fi
if grep -qxF "jira:$HOST/scripts/jira" "$TMP/pwd.log"; then ok "jira build ran in the verbatim jira dir"; else bad "jira build did not run in the verbatim path: $(cat "$TMP/pwd.log")"; fi

# 8. syntax + lint.
if bash -n "$SETUP"; then ok "bash -n clean"; else bad "bash -n failed"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SETUP" >/dev/null 2>&1; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
else
  echo "SKIP - shellcheck not installed here"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
