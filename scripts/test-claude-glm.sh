#!/usr/bin/env bash
# Hermetic tests for scripts/claude-glm. bash 3.2-safe.
# shellcheck disable=SC2015  # && || pattern is intentional for ternary-like behavior
set -u
FAILS=0
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/claude-glm"

# Each setup() mktemp -d's three dirs; accumulate them and rm -rf once at EXIT so
# repeated runs don't leak sandboxes. The `-eq 0 ||` short-circuits the array
# expansion while it is still empty, which is bash-3.2 set -u safe.
SANDBOXES=()
cleanup() { [ "${#SANDBOXES[@]}" -eq 0 ] || rm -rf "${SANDBOXES[@]}"; }
trap cleanup EXIT

t() { # t <name> <expected-exit> — runs launcher in the prepared sandbox
  local name="$1" want="$2"; shift 2
  ( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" ZAI_API_KEY="${KEY-}" \
      CLAUDE_GLM_DOTENV_ROOT="$WORK" \
      bash "$LAUNCHER" "$@" >"$WORK/out.txt" 2>&1 )
  local got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $name (exit $got, want $want)"; cat "$WORK/out.txt"; FAILS=$((FAILS+1))
  else
    echo "ok: $name"
  fi
}

setup() { # fresh sandbox: fake HOME with minimal ~/.claude, mock claude in BIN
  FAKEHOME="$(mktemp -d)"; WORK="$(mktemp -d)"; BIN="$(mktemp -d)"
  SANDBOXES+=("$FAKEHOME" "$WORK" "$BIN")
  mkdir -p "$FAKEHOME/.claude"
  # Fixture carries the keys the OLD sanitizer missed (CR): CLAUDE_CODE_USE_* (any
  # case) and a lowercase anthropic_* — both must be stripped from the seed, since
  # the seeded settings.json is an overlay that could otherwise redirect the lane.
  printf '{"model":"claude-fable-5[1m]","env":{"ANTHROPIC_MODEL":"x","anthropic_base_url":"http://evil","CLAUDE_CODE_USE_BEDROCK":"1","Claude_Code_Use_Vertex":"1","HIMMEL_INITIATIVE":"1"}}' \
    > "$FAKEHOME/.claude/settings.json"
  printf 'secret' > "$FAKEHOME/.claude/.credentials.json"
  mkdir -p "$FAKEHOME/.claude/plugins/claude-hud"
  printf '{"hud":true}\n' > "$FAKEHOME/.claude/plugins/claude-hud/config.json"
  cat > "$BIN/claude" <<'MOCK'
#!/usr/bin/env bash
# Launch dumps env AND records the full passthrough argv to a separate sink (T13
# asserts the claude flags arrived verbatim). A magic --mock-exit-N arg makes the
# mock exit N so T14 can prove the launcher propagates claude's exit code.
env > "${MOCK_ENV_OUT:?}"
printf '%s\n' "$*" >> "${MOCK_ARGV_OUT:?}"
for a in "$@"; do
  case "$a" in --mock-exit-*) exit "${a#--mock-exit-}" ;; esac
done
exit 0
MOCK
  chmod +x "$BIN/claude"
  export MOCK_ENV_OUT="$WORK/child-env.txt"
  export MOCK_ARGV_OUT="$WORK/claude-argv.txt"
}

# --- T1: missing key -> exit 2, claude never launched
setup; KEY=""
t "missing key exits 2" 2
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched without key"; FAILS=$((FAILS+1)); }

# --- T2: key set -> exit 0 and all eight env vars reach the child
setup; KEY="zai-test-123"
t "launch with key" 0
for pair in \
  "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic" \
  "ANTHROPIC_AUTH_TOKEN=zai-test-123" \
  "ANTHROPIC_MODEL=glm-5.2[1m]" \
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7" \
  "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2[1m]" \
  "ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]" \
  "CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000" \
  "CLAUDE_CONFIG_DIR=$FAKEHOME/.claude-glm"; do
  grep -qF "$pair" "$WORK/child-env.txt" || { echo "FAIL: child env missing $pair"; FAILS=$((FAILS+1)); }
done

# --- T3: key never echoed to stdout/stderr
grep -q "zai-test-123" "$WORK/out.txt" && { echo "FAIL: key echoed"; FAILS=$((FAILS+1)); }

# --- T3b: key resolvable from a repo .env ONLY (the load_dotenv path)
# gitleaks flags key-shaped assignments even with dummy values; the
# `# gitleaks:allow` markers are required.
setup; KEY=""
printf 'ZAI_API_KEY=from-dotenv-456\n' > "$WORK/.env"  # gitleaks:allow
t "key from .env launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=from-dotenv-456" "$WORK/child-env.txt" || { echo "FAIL: .env key did not reach child"; FAILS=$((FAILS+1)); }  # gitleaks:allow

# --- T4: first launch seeds config dir; credentials NEVER copied
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands" "$FAKEHOME/.claude/plugins/marketplaces"
printf 'x' > "$FAKEHOME/.claude/CLAUDE.md"
printf '{}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
t "seed on first launch" 0
[ -f "$FAKEHOME/.claude-glm/plugins/claude-hud/config.json" ] || { echo "FAIL: claude-hud config not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/plugins/installed_plugins.json" ] || { echo "FAIL: plugin registry not seeded"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-glm/.credentials.json" ] || { echo "FAIL: credentials copied"; FAILS=$((FAILS+1)); }

# --- T5: seeded settings.json sanitized (no model key; no env.ANTHROPIC_* /
# CLAUDE_CODE_USE_* in ANY case — the seed must strip what the arg screen rejects)
node -e "
const s=require(process.argv[1]+'/.claude-glm/settings.json');
if('model' in s) { console.error('model key survived'); process.exit(1); }
for (const k of Object.keys(s.env||{})) {
  const u=k.toUpperCase();
  if (u.startsWith('ANTHROPIC_') || u.startsWith('CLAUDE_CODE_USE_')) { console.error('env.'+k+' survived'); process.exit(1); }
}
if ((s.env||{}).HIMMEL_INITIATIVE!=='1') { console.error('non-forbidden env entry lost'); process.exit(1); }
" "$FAKEHOME" || { echo "FAIL: settings sanitization"; FAILS=$((FAILS+1)); }

# --- T5b: sanitizer-generation migration — a sentinel stamped by an OLDER
# sanitizer re-seeds once, so a previously-persisted forbidden key cannot survive.
printf 'old-generation\n' > "$FAKEHOME/.claude-glm/.seeded"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","HIMMEL_INITIATIVE":"1"}}' > "$FAKEHOME/.claude-glm/settings.json"
t "stale sanitizer generation re-seeds" 0
grep -q "CLAUDE_CODE_USE_BEDROCK" "$FAKEHOME/.claude-glm/settings.json" && { echo "FAIL: forbidden key survived the generation migration"; FAILS=$((FAILS+1)); }

# --- T5c: the generation migration is NOT bypassable by the freshness opt-out.
# CLAUDE_LANE_AUTO_RESEED=0 is an escape hatch for churn; it must never keep a
# v1 seed's forbidden env key loaded (that key reroutes the lane off z.ai).
setup; KEY="zai-test-123"
t "seed before opt-out migration check" 0
printf 'old-generation\n' > "$FAKEHOME/.claude-glm/.seeded"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","HIMMEL_INITIATIVE":"1"}}' > "$FAKEHOME/.claude-glm/settings.json"
export CLAUDE_LANE_AUTO_RESEED=0
t "stale generation re-seeds even under the opt-out" 0
unset CLAUDE_LANE_AUTO_RESEED
grep -q "CLAUDE_CODE_USE_BEDROCK" "$FAKEHOME/.claude-glm/settings.json" && { echo "FAIL: opt-out let a v1 forbidden key survive"; FAILS=$((FAILS+1)); }
# ...while the opt-out still suppresses ORDINARY freshness churn (same generation:
# the migration above just rewrote the sentinel to the current SEED_VERSION).
printf '{"env":{"HIMMEL_INITIATIVE":"1"},"marker":"churn-should-not-land"}' > "$FAKEHOME/.claude/settings.json"
export CLAUDE_LANE_AUTO_RESEED=0
t "opt-out still skips ordinary freshness churn" 0
unset CLAUDE_LANE_AUTO_RESEED
grep -q "churn-should-not-land" "$FAKEHOME/.claude-glm/settings.json" && { echo "FAIL: opt-out no longer suppresses ordinary drift"; FAILS=$((FAILS+1)); }

# --- T6: no key material anywhere under the seeded dir
grep -R "zai-test-123" "$FAKEHOME/.claude-glm" >/dev/null 2>&1 && { echo "FAIL: key leaked into config dir"; FAILS=$((FAILS+1)); }

# --- T7: --reseed refreshes seeded files, never resurrects denied files
printf 'updated' > "$FAKEHOME/.claude/CLAUDE.md"
printf 'secret' > "$FAKEHOME/.claude/history.jsonl"
t "reseed" 0 --reseed
grep -q updated "$FAKEHOME/.claude-glm/CLAUDE.md" || { echo "FAIL: reseed did not refresh"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-glm/history.jsonl" ] || { echo "FAIL: denied file seeded"; FAILS=$((FAILS+1)); }

# --- T7b: stale seed auto-refreshes on plain launch (HIMMEL-819) — source
# settings.json newer than the sentinel triggers a reseed without --reseed.
touch -t 202001010000 "$FAKEHOME/.claude-glm/.seeded"
printf '{"env":{"HIMMEL_INITIATIVE":"1"},"marker":"lean-profile-v2"}' > "$FAKEHOME/.claude/settings.json"
t "stale seed auto-refreshes" 0
grep -q "lean-profile-v2" "$FAKEHOME/.claude-glm/settings.json" || { echo "FAIL: stale seed not refreshed on plain launch"; FAILS=$((FAILS+1)); }

# --- T7c: fresh sentinel -> plain launch does NOT reseed (no churn) — sources
# older than the sentinel leave the config dir untouched. (HIMMEL-828 Part B: the
# subtree sources are aged too, so the widened check keeps its no-churn guarantee.)
printf '{"local":"tamper-survives"}' > "$FAKEHOME/.claude-glm/settings.json"
touch -t 202001010000 "$FAKEHOME/.claude/settings.json" "$FAKEHOME/.claude/plugins/installed_plugins.json" \
  "$FAKEHOME/.claude/commands" "$FAKEHOME/.claude/plugins/marketplaces" 2>/dev/null
touch "$FAKEHOME/.claude-glm/.seeded"
t "fresh sentinel skips reseed" 0
grep -q "tamper-survives" "$FAKEHOME/.claude-glm/settings.json" || { echo "FAIL: fresh sentinel still reseeded"; FAILS=$((FAILS+1)); }

# --- T7d: deleted source triggers reseed and the lane copy is removed (true
# mirror — a stale settings copy must not keep steering the lane).
rm -f "$FAKEHOME/.claude/settings.json"
t "deleted source triggers reseed" 0
[ ! -f "$FAKEHOME/.claude-glm/settings.json" ] || { echo "FAIL: stale settings copy survived source deletion"; FAILS=$((FAILS+1)); }

# --- T7e: CLAUDE_LANE_AUTO_RESEED=0 opt-out — stale state is left alone on
# plain launch (only first seed / --reseed run the seed).
printf '{"env":{"HIMMEL_INITIATIVE":"1"},"marker":"optout-should-not-land"}' > "$FAKEHOME/.claude/settings.json"
touch -t 202001010000 "$FAKEHOME/.claude-glm/.seeded"
export CLAUDE_LANE_AUTO_RESEED=0
t "opt-out skips auto-reseed" 0
unset CLAUDE_LANE_AUTO_RESEED
[ ! -f "$FAKEHOME/.claude-glm/settings.json" ] || { echo "FAIL: opt-out still auto-reseeded"; FAILS=$((FAILS+1)); }
# restore a sane settings source + fresh sentinel for the tests below
printf '{"env":{"HIMMEL_INITIATIVE":"1"}}' > "$FAKEHOME/.claude/settings.json"
t "restore reseed" 0 --reseed

# --- T7f: plugin-manifest sources participate in staleness AND deletion
# mirroring (2nd/3rd tracked file — not just settings.json).
printf '{"m":1}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
printf '{"k":1}' > "$FAKEHOME/.claude/plugins/known_marketplaces.json"
t "manifest newer triggers reseed" 0
[ -f "$FAKEHOME/.claude-glm/plugins/installed_plugins.json" ] || { echo "FAIL: installed_plugins not reseeded on manifest change"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/plugins/known_marketplaces.json" ] || { echo "FAIL: known_marketplaces not reseeded on manifest change"; FAILS=$((FAILS+1)); }
rm -f "$FAKEHOME/.claude/plugins/known_marketplaces.json"
t "deleted manifest mirrors removal" 0
[ ! -f "$FAKEHOME/.claude-glm/plugins/known_marketplaces.json" ] || { echo "FAIL: stale known_marketplaces copy survived source deletion"; FAILS=$((FAILS+1)); }

# --- T7g: explicit --reseed still seeds while the opt-out is set (the escape
# hatch does not disable the manual path).
printf '{"local":"tamper2"}' > "$FAKEHOME/.claude-glm/settings.json"
export CLAUDE_LANE_AUTO_RESEED=0
t "explicit reseed wins over opt-out" 0 --reseed
unset CLAUDE_LANE_AUTO_RESEED
grep -q "tamper2" "$FAKEHOME/.claude-glm/settings.json" && { echo "FAIL: --reseed under opt-out did not reseed"; FAILS=$((FAILS+1)); }

# --- T8: .salus marker -> refuse exit 3, --force does NOT override
setup; KEY="zai-test-123"; touch "$WORK/.salus"
t "salus refuses" 3
t "salus refuses despite --force" 3 --force

# --- T9: denylisted cwd -> refuse without --force, proceed with it
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "denylist refuses" 3
t "denylist + --force proceeds" 0 --force

# --- T10: PHI root file -> absolute refuse even with --force
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-root refuses despite --force" 3 --force

# --- T10b: config roots are normalized (trailing slash + CRLF) before matching
# Trailing-slash root: a config line like "/x/phi/" must still block descendants.
# t() always runs the launcher from $WORK, so point phi-roots at $WORK's PARENT
# WITH a trailing slash -> $WORK is a strict descendant -> absolute refuse.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s/\n' "$(dirname "$WORK")" > "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-root trailing-slash still refuses descendant despite --force" 3 --force

# CRLF denylist line (himmel targets Windows): "$WORK" + CRLF must still match.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\r\n' "$WORK" > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "denylist CRLF line still refuses" 3

# --- T11: clean cwd proceeds silently
setup; KEY="zai-test-123"
t "clean proceeds" 0

# --- T12: launch output contains an off-peak annotation line
setup; KEY="zai-test-123"
t "annotation present" 0
grep -q "GLM peak window" "$WORK/out.txt" || { echo "FAIL: no off-peak annotation"; FAILS=$((FAILS+1)); }

# --- T13: claude flags pass through verbatim; leading --reseed is consumed
setup; KEY="zai-test-123"
t "passthrough launch" 0 --reseed -p hello -d
grep -qF -- "-p hello -d" "$WORK/claude-argv.txt" || { echo "FAIL: claude flags not passed verbatim"; FAILS=$((FAILS+1)); }
grep -qF -- "--reseed" "$WORK/claude-argv.txt" && { echo "FAIL: --reseed leaked to claude argv"; FAILS=$((FAILS+1)); }

# --- T14: launcher propagates claude's exit code (exec by construction; test it)
setup; KEY="zai-test-123"
t "exit code propagates from claude" 7 --mock-exit-7

# --- T14a-d: --settings env-injection screen (HIMMEL-1040). A benign
# enabledPlugins payload (the profile-injection channel) passes through to claude
# verbatim; any --settings that would inject env.ANTHROPIC_*/CLAUDE_CODE_USE_* (or
# is unparseable) refuses with exit 3 BEFORE any launch.
setup; KEY="zai-test-123"
t "benign --settings passes through" 0 --settings '{"enabledPlugins":{"qmd@himmel":true}}'
grep -qF -- '--settings {"enabledPlugins":{"qmd@himmel":true}}' "$WORK/claude-argv.txt" || { echo "FAIL: benign --settings not passed verbatim"; FAILS=$((FAILS+1)); }
setup; KEY="zai-test-123"
t "malicious --settings (ANTHROPIC_*) refuses" 3 --settings '{"env":{"ANTHROPIC_BASE_URL":"http://evil"}}'
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched despite refused --settings"; FAILS=$((FAILS+1)); }
setup; KEY="zai-test-123"
t "malicious --settings= (CLAUDE_CODE_USE_*) refuses" 3 --settings='{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}'
setup; KEY="zai-test-123"
t "unparseable --settings fails closed" 3 --settings 'not json'
setup; KEY="zai-test-123"
t "empty --settings= fails closed" 3 --settings=
setup; KEY="zai-test-123"
t "trailing bare --settings refuses" 3 --settings
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched despite trailing --settings"; FAILS=$((FAILS+1)); }

# --- T14e-g: file-backed --settings is MATERIALIZED to inline JSON (TOCTOU fix).
# The caller-controlled PATH must never reach claude — otherwise claude re-reads it
# after the screen passed and a swap in that window defeats the check. ---
setup; KEY="zai-test-123"
printf '{"enabledPlugins":{"qmd@himmel":true}}\n' > "$WORK/lean.json"
t "file --settings launches" 0 --settings "$WORK/lean.json"
grep -qF -- '"enabledPlugins":{"qmd@himmel":true}' "$WORK/claude-argv.txt" || { echo "FAIL: file --settings not materialized inline"; FAILS=$((FAILS+1)); }
grep -qF -- "$WORK/lean.json" "$WORK/claude-argv.txt" && { echo "FAIL: caller-controlled path forwarded to claude (TOCTOU)"; FAILS=$((FAILS+1)); }
# a malicious FILE payload refuses just like an inline one
setup; KEY="zai-test-123"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://evil"}}\n' > "$WORK/evil.json"
t "malicious file --settings refuses" 3 --settings "$WORK/evil.json"
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched despite malicious file --settings"; FAILS=$((FAILS+1)); }
# unreadable/missing file fails closed
setup; KEY="zai-test-123"
t "missing --settings file fails closed" 3 --settings "$WORK/nope.json"

# --- T15: phi-roots file WITHOUT a trailing newline still blocks the final
# line (read || [ -n "$root" ] guard) — otherwise the PHI tier fails open.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s' "$WORK" > "$FAKEHOME/.config/claude-glm/phi-roots"   # NO trailing newline
t "phi-root no-trailing-newline still refuses" 3

# --- T16: seeding is transactional — a sanitize failure exits 4, launches
# nothing, writes no sentinel; the NEXT launch (node restored) self-heals.
setup; KEY="zai-test-123"
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
exit 1
NODESHIM
chmod +x "$BIN/node"
t "sanitize failure exits 4" 4
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched despite failed seed"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: sentinel written despite failed seed"; FAILS=$((FAILS+1)); }
rm -f "$BIN/node"
t "second launch self-heals after node restored" 0
[ -f "$FAKEHOME/.claude-glm/settings.json" ] || { echo "FAIL: settings.json not seeded on self-heal"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: sentinel not written on self-heal"; FAILS=$((FAILS+1)); }

# --- T17: phi-roots that is a DIRECTORY (not a readable file) fails
# CLOSED with exit 3, never silently allows egress.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-roots as directory fails closed" 3

# --- T18: a quoted .env value has its surrounding quotes stripped in the
# launcher before reaching the child (bash otherwise sends literal quotes).
setup; KEY=""
printf 'ZAI_API_KEY="quoted-val-789"\n' > "$WORK/.env"  # gitleaks:allow
t "quoted .env key launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=quoted-val-789" "$WORK/child-env.txt" || { echo "FAIL: surrounding quotes not stripped from key"; FAILS=$((FAILS+1)); }  # gitleaks:allow

# --- T19: a FAILED --reseed clears the stale sentinel, so a later plain launch
# re-seeds (and fails again while node is broken) instead of proceeding with the
# stale tree; node restored -> plain launch self-heals. Regression for the
# "sentinel written LAST but never removed at seeder START" gap.
setup; KEY="zai-test-123"
t "initial seed ok" 0                                   # sentinel written
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
exit 1
NODESHIM
chmod +x "$BIN/node"
t "reseed with broken node exits 4" 4 --reseed
[ ! -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: stale sentinel survived failed reseed"; FAILS=$((FAILS+1)); }
rm -f "$WORK/child-env.txt"
t "plain launch after failed reseed still exits 4" 4    # NOT 0 with a stale sentinel
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched with a stale-sentinel tree"; FAILS=$((FAILS+1)); }
rm -f "$BIN/node"
t "plain launch self-heals after node restored" 0
[ -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: sentinel not written on self-heal"; FAILS=$((FAILS+1)); }

# --- T20: a blank CRLF-only line in a guard config must NOT over-refuse every
# workspace. Pre-fix the empty-after-CR-strip line became a "/" root matching
# every absolute path. denylist = one unrelated root + one blank CRLF line.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '/some/unrelated/root\r\n\r\n' > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "blank CRLF guard line does not over-refuse clean cwd" 0

# --- T21: 'claude' absent from PATH -> exit 5 with a clear message, before exec.
# Drop the mock claude and restrict PATH to the sandbox bin + coreutils + node
# (the launcher still needs node to seed and date for the annotation) so no real
# claude on the host PATH is reachable and the pre-exec check fires hermetically.
# The restricted PATH keeps /usr/bin (coreutils) + NODE_DIR — if a host claude
# lives in either, the guard cannot be exercised there: SKIP instead of flaking.
setup; KEY="zai-test-123"
rm -f "$BIN/claude"
NODE_DIR="$(dirname "$(command -v node)")"
if PATH="$BIN:/usr/bin:$NODE_DIR" command -v claude >/dev/null 2>&1; then
  echo "skip: T21 — host claude resolvable inside the restricted PATH"
else
  ( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:/usr/bin:$NODE_DIR" ZAI_API_KEY="$KEY" \
      CLAUDE_GLM_DOTENV_ROOT="$WORK" bash "$LAUNCHER" >"$WORK/out.txt" 2>&1 )
  noclaude_rc=$?
  [ "$noclaude_rc" -eq 5 ] && echo "ok: missing claude exits 5" \
    || { echo "FAIL: missing claude (exit $noclaude_rc, want 5)"; cat "$WORK/out.txt"; FAILS=$((FAILS+1)); }
  grep -qF "claude-glm: 'claude' not found on PATH" "$WORK/out.txt" \
    || { echo "FAIL: missing 'claude not found' message"; FAILS=$((FAILS+1)); }
fi

# --- T22: --reseed re-mirrors seeded subtrees — a file left stale in the dest is
# dropped, and cp -R does not nest a second copy (commands/commands on BSD cp).
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands"
printf 'a' > "$FAKEHOME/.claude/commands/keep.md"
t "seed before re-mirror" 0
[ -f "$FAKEHOME/.claude-glm/commands/keep.md" ] || { echo "FAIL: commands not seeded"; FAILS=$((FAILS+1)); }
printf 'stale' > "$FAKEHOME/.claude-glm/commands/stale.md"   # never in source
t "reseed re-mirrors subtree" 0 --reseed
[ ! -f "$FAKEHOME/.claude-glm/commands/stale.md" ] || { echo "FAIL: stale file survived reseed"; FAILS=$((FAILS+1)); }
[ ! -d "$FAKEHOME/.claude-glm/commands/commands" ] || { echo "FAIL: nested commands/commands after reseed"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/commands/keep.md" ] || { echo "FAIL: kept file lost after reseed"; FAILS=$((FAILS+1)); }

# --- T23: --reseed re-mirrors plugins/marketplaces too — a SEPARATE statement
# from the commands/skills/hooks/agents loop, so T22 does not cover it.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/plugins/marketplaces"
printf 'a' > "$FAKEHOME/.claude/plugins/marketplaces/keep.json"
t "seed marketplaces before re-mirror" 0
[ -f "$FAKEHOME/.claude-glm/plugins/marketplaces/keep.json" ] || { echo "FAIL: marketplaces not seeded"; FAILS=$((FAILS+1)); }
printf 'stale' > "$FAKEHOME/.claude-glm/plugins/marketplaces/stale.json"   # never in source
t "reseed re-mirrors marketplaces" 0 --reseed
[ ! -f "$FAKEHOME/.claude-glm/plugins/marketplaces/stale.json" ] || { echo "FAIL: stale marketplaces file survived reseed"; FAILS=$((FAILS+1)); }
[ ! -d "$FAKEHOME/.claude-glm/plugins/marketplaces/marketplaces" ] || { echo "FAIL: nested marketplaces/marketplaces after reseed"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/plugins/marketplaces/keep.json" ] || { echo "FAIL: kept marketplaces file lost after reseed"; FAILS=$((FAILS+1)); }

# --- T24 (HIMMEL-828 Part B): a half-seeded tree self-heals on a plain launch — the
# sentinel is present but a copied subtree is missing (interrupted reseed / external
# removal), which the pre-828 settings+manifest check missed. Fixture: seed with a
# commands subtree, delete the DEST subtree while leaving a FRESH sentinel + old
# sources; a plain launch detects the source-present/dest-missing mismatch and reseeds.
# FAILS on pre-828 code (fresh sentinel + old tracked files => not stale => no reseed).
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands"
printf 'a' > "$FAKEHOME/.claude/commands/keep.md"
t "seed before half-seed simulation" 0
rm -rf "$FAKEHOME/.claude-glm/commands"   # dest subtree vanishes
touch -t 202001010000 "$FAKEHOME/.claude/settings.json" "$FAKEHOME/.claude/commands" 2>/dev/null
touch "$FAKEHOME/.claude-glm/.seeded"     # fresh sentinel
t "half-seeded tree triggers reseed on plain launch" 0
[ -f "$FAKEHOME/.claude-glm/commands/keep.md" ] || { echo "FAIL: missing subtree NOT restored (half-seed not detected)"; FAILS=$((FAILS+1)); }

# --- T25 (HIMMEL-828 Part B): a top-level add inside a source subtree (source dir
# mtime newer than the sentinel) auto-reseeds without --reseed — pre-828 this drift
# needed an explicit --reseed. Fixture: seed, age settings so only the subtree can be
# the trigger, set a fresh-ish sentinel, add a new command (bumping the source commands
# dir mtime past the sentinel), confirm a plain launch mirrors it into the lane copy.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands"
printf 'a' > "$FAKEHOME/.claude/commands/one.md"
t "seed before subtree drift" 0
touch -t 202001010000 "$FAKEHOME/.claude/settings.json" 2>/dev/null
touch -t 202006010000 "$FAKEHOME/.claude-glm/.seeded"
printf 'b' > "$FAKEHOME/.claude/commands/two.md"   # new source command bumps the commands dir mtime to now
t "source subtree drift auto-reseeds on plain launch" 0
[ -f "$FAKEHOME/.claude-glm/commands/two.md" ] || { echo "FAIL: new source command NOT mirrored (subtree drift not detected)"; FAILS=$((FAILS+1)); }

# --- T26 (HIMMEL-828/819, codex-adv [high]): DELETION MIRRORING — a deleted SOURCE
# subtree is removed from the lane on a plain launch (a removed command/hook must not
# linger steering the cloud lane), symmetric with settings/manifest deletion mirroring,
# AND it does NOT churn forever (the seeder clears the dest, so the predicate stops
# firing). Fixture: seed with a commands subtree, delete the SOURCE; launch 2 mirrors
# the removal; launch 3 is stable (a lane tamper survives = no reseed).
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands"
printf 'a' > "$FAKEHOME/.claude/commands/keep.md"
t "seed before source-subtree deletion" 0
rm -rf "$FAKEHOME/.claude/commands"   # SOURCE subtree deleted
t "source-deleted subtree triggers a mirror reseed" 0
[ ! -d "$FAKEHOME/.claude-glm/commands" ] || { echo "FAIL: stale lane subtree survived source deletion"; FAILS=$((FAILS+1)); }
printf '{"local":"tamper-stable"}' > "$FAKEHOME/.claude-glm/settings.json"
touch -t 202001010000 "$FAKEHOME/.claude/settings.json" 2>/dev/null
touch "$FAKEHOME/.claude-glm/.seeded"
t "no further churn after deletion mirrored" 0
grep -q "tamper-stable" "$FAKEHOME/.claude-glm/settings.json" || { echo "FAIL: churns after deletion mirrored (tamper lost)"; FAILS=$((FAILS+1)); }

# --- T27 (HIMMEL-828/819, codex-adv [high]): LEAF-FILE deletion mirroring — a deleted
# source CLAUDE.md (which literally steers the lane) is removed from the lane on a plain
# launch, not just subtrees/manifests. Every allowlisted leaf now mirrors deletion.
setup; KEY="zai-test-123"
printf 'steer' > "$FAKEHOME/.claude/CLAUDE.md"
t "seed before CLAUDE.md deletion" 0
[ -f "$FAKEHOME/.claude-glm/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not seeded"; FAILS=$((FAILS+1)); }
rm -f "$FAKEHOME/.claude/CLAUDE.md"   # SOURCE deleted
t "deleted source CLAUDE.md triggers a mirror reseed" 0
[ ! -f "$FAKEHOME/.claude-glm/CLAUDE.md" ] || { echo "FAIL: stale CLAUDE.md survived source deletion"; FAILS=$((FAILS+1)); }

# --- T28 (HIMMEL-830): a FRESH held seed lock makes a launch that needs seeding
# time out with exit 4, a message naming the lock path, and the held lock LEFT
# intact (we must not delete a fresh holder's lock on timeout). Lock is a SIBLING
# of the config dir. TIMEOUT=1 keeps the deterministic wait ~1s.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude-glm.seed-lock"        # fresh-mtime held lock, held by nobody
export CLAUDE_LANE_SEED_LOCK_TIMEOUT=1
t "held fresh seed lock times out (exit 4)" 4
unset CLAUDE_LANE_SEED_LOCK_TIMEOUT
grep -qF ".claude-glm.seed-lock" "$WORK/out.txt" || { echo "FAIL: timeout message does not name the lock path"; FAILS=$((FAILS+1)); }
[ -d "$FAKEHOME/.claude-glm.seed-lock" ] || { echo "FAIL: fresh held lock removed on timeout"; FAILS=$((FAILS+1)); }

# --- T29 (HIMMEL-830): a STALE held lock (mtime far in the past) is stolen, the
# seed proceeds, the launch exits 0, and the lock is released (no residue).
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude-glm.seed-lock"
touch -t 202001010000 "$FAKEHOME/.claude-glm.seed-lock"   # older than the 120s default stale window
t "stale seed lock is stolen and seed proceeds" 0
[ -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: seed did not complete after stealing stale lock"; FAILS=$((FAILS+1)); }
[ ! -d "$FAKEHOME/.claude-glm.seed-lock" ] || { echo "FAIL: stale lock not released after seed"; FAILS=$((FAILS+1)); }

# --- T30 (HIMMEL-830): the double-checked recheck UNDER the lock skips a redundant
# reseed when a concurrent winner already seeded while we waited. Deterministic by
# construction (no timing reliance): a background holder writes the sentinel THEN
# releases the lock, so by the moment our launcher can acquire, the recheck condition
# is already FALSE. A dest-only canary that a reseed's rm -rf would drop must SURVIVE.
setup; KEY="zai-test-123"
mkdir -p "$FAKEHOME/.claude/commands"
printf 'real' > "$FAKEHOME/.claude/commands/real.md"
t "seed before recheck-skip simulation" 0
printf 'canary' > "$FAKEHOME/.claude-glm/commands/canary.md"   # dest-only; a reseed would drop it
rm -f "$FAKEHOME/.claude-glm/.seeded"                          # make the OUTER pre-check fire (sentinel missing)
find "$FAKEHOME/.claude" -exec touch -t 202001010000 {} + 2>/dev/null   # age ALL sources so a fresh sentinel reads not-stale
mkdir -p "$FAKEHOME/.claude-glm.seed-lock"                     # a "winner" is holding the lock
# The winner's sentinel must look like a REAL seed's — i.e. stamped with the
# current sanitizer generation — otherwise the loser's recheck reads a generation
# mismatch and reseeds (dropping the canary). Derive it from the launcher so the
# simulation can't drift from SEED_VERSION.
seed_ver=$(sed -n 's/^SEED_VERSION="\(.*\)"$/\1/p' "$LAUNCHER")
[ -n "$seed_ver" ] || { echo "FAIL: could not derive SEED_VERSION from $LAUNCHER"; FAILS=$((FAILS+1)); }
( sleep 1; printf '%s\n' "$seed_ver" > "$FAKEHOME/.claude-glm/.seeded"; rmdir "$FAKEHOME/.claude-glm.seed-lock" ) &   # winner finishes its seed then releases
winpid=$!
t "recheck under lock skips redundant reseed" 0
wait "$winpid" 2>/dev/null
[ -f "$FAKEHOME/.claude-glm/commands/canary.md" ] || { echo "FAIL: recheck did not skip -- canary dropped by a redundant reseed"; FAILS=$((FAILS+1)); }
[ ! -d "$FAKEHOME/.claude-glm.seed-lock" ] || { echo "FAIL: lock residue after recheck-skip launch"; FAILS=$((FAILS+1)); }

# --- T31 (HIMMEL-830, best-effort concurrency smoke): two simultaneous first-launch
# seeders of the same lane both exit 0, leave a consistent config (sentinel present),
# and leave no lock residue. The lock serializes them; the loser's recheck skips.
setup; KEY="zai-test-123"
( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" ZAI_API_KEY="$KEY" CLAUDE_GLM_DOTENV_ROOT="$WORK" \
    bash "$LAUNCHER" >"$WORK/out-a.txt" 2>&1 ) &
cpid=$!
( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" ZAI_API_KEY="$KEY" CLAUDE_GLM_DOTENV_ROOT="$WORK" \
    bash "$LAUNCHER" >"$WORK/out-b.txt" 2>&1 )
brc=$?
wait "$cpid"; arc=$?
[ "$arc" -eq 0 ] || { echo "FAIL: concurrent launch A exit $arc"; cat "$WORK/out-a.txt"; FAILS=$((FAILS+1)); }
[ "$brc" -eq 0 ] || { echo "FAIL: concurrent launch B exit $brc"; cat "$WORK/out-b.txt"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-glm/.seeded" ] || { echo "FAIL: concurrent seed left no sentinel"; FAILS=$((FAILS+1)); }
[ ! -d "$FAKEHOME/.claude-glm.seed-lock" ] || { echo "FAIL: concurrent launch left lock residue"; FAILS=$((FAILS+1)); }

# --- T32 (HIMMEL-830 CR r1): a lock that cannot be released (a file appeared inside
# it while the seeder held it) is NON-FATAL -- the launch still exits 0 and a WARNING
# names the lock; the non-empty lock is LEFT for the stale steal to self-heal (its
# contents are evidence, never vaporized). Honest construction: a slow node shim (the
# sanitize step) keeps the seeder holding the lock ~1s while a background subshell
# plants an intruder file the moment the lock dir appears.
setup; KEY="zai-test-123"
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
# slow "sanitize": argv is -e <script> <src> <dest>; plain copy is fine here (this
# test asserts lock-release behaviour, not sanitization).
sleep 1
cp "$3" "$4"
NODESHIM
chmod +x "$BIN/node"
( while [ ! -d "$FAKEHOME/.claude-glm.seed-lock" ]; do sleep 0.05; done
  touch "$FAKEHOME/.claude-glm.seed-lock/intruder" ) &
plpid=$!
t "release failure is non-fatal (exit 0)" 0
wait "$plpid" 2>/dev/null
grep -q "WARNING - failed to release seed lock" "$WORK/out.txt" || { echo "FAIL: no release-failure warning emitted"; FAILS=$((FAILS+1)); }
[ -d "$FAKEHOME/.claude-glm.seed-lock" ] || { echo "FAIL: non-empty lock unexpectedly removed on release"; FAILS=$((FAILS+1)); }

echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
