#!/usr/bin/env bash
# Hermetic tests for scripts/claude-routed. bash 3.2-safe.
# Twin of test-claude-glm.sh — the routed launcher is a copy-and-edit of claude-glm
# where ONLY the backend block differs (loopback OmniRoute router + OmniRoute client
# key). The mock-claude + t() harness is reused verbatim from the WS1 suite.
# shellcheck disable=SC2015  # && || pattern is intentional for ternary-like behavior
set -u
FAILS=0
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/claude-routed"

t() { # t <name> <expected-exit> — runs launcher in the prepared sandbox
  local name="$1" want="$2"; shift 2
  ( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" OMNIROUTE_API_KEY="${KEY-}" \
      CLAUDE_ROUTED_DOTENV_ROOT="$WORK" OMNIROUTE_PORT="${PORT-}" \
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
  PORT=""   # default: launcher falls back to its documented default port 20128
  mkdir -p "$FAKEHOME/.claude"
  printf '{"model":"claude-fable-5[1m]","env":{"ANTHROPIC_MODEL":"x","HIMMEL_INITIATIVE":"1"}}' \
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

# --- T2: key set -> exit 0 and all eight env vars reach the child.
# Backend block differs from claude-glm: loopback router base URL (default port
# 20128) + auth from OMNIROUTE_API_KEY + config dir ~/.claude-routed. Tier aliases
# stay the GLM values (the router config defines these aliases).
setup; KEY="omni-test-123"
t "launch with key" 0
for pair in \
  "ANTHROPIC_BASE_URL=http://127.0.0.1:20128" \
  "ANTHROPIC_AUTH_TOKEN=omni-test-123" \
  "ANTHROPIC_MODEL=glm-5.2[1m]" \
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7" \
  "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2[1m]" \
  "ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]" \
  "CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000" \
  "CLAUDE_CONFIG_DIR=$FAKEHOME/.claude-routed"; do
  grep -qF "$pair" "$WORK/child-env.txt" || { echo "FAIL: child env missing $pair"; FAILS=$((FAILS+1)); }
done

# --- T2b: OMNIROUTE_PORT override -> child sees the overridden loopback port
setup; KEY="omni-test-123"; PORT="9999"
t "port override launches" 0
# Loopback host is FIXED (127.0.0.1) — only the port is the env seam.
grep -qF "ANTHROPIC_BASE_URL=http://127.0.0.1:9999" "$WORK/child-env.txt" || { echo "FAIL: OMNIROUTE_PORT override did not reach child"; FAILS=$((FAILS+1)); }

# --- T3: key never echoed to stdout/stderr
setup; KEY="omni-test-123"
t "no key echo" 0
grep -q "omni-test-123" "$WORK/out.txt" && { echo "FAIL: key echoed"; FAILS=$((FAILS+1)); }

# --- T3b: key resolvable from a repo .env ONLY (the load_dotenv path)
# gitleaks flags key-shaped assignments even with dummy values; the
# `# gitleaks:allow` markers are required.
setup; KEY=""
printf 'OMNIROUTE_API_KEY=from-dotenv-456\n' > "$WORK/.env"  # gitleaks:allow
t "key from .env launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=from-dotenv-456" "$WORK/child-env.txt" || { echo "FAIL: .env key did not reach child"; FAILS=$((FAILS+1)); }  # gitleaks:allow

# --- T4: first launch seeds config dir; credentials NEVER copied
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.claude/commands" "$FAKEHOME/.claude/plugins/marketplaces"
printf 'x' > "$FAKEHOME/.claude/CLAUDE.md"
printf '{}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
t "seed on first launch" 0
[ -f "$FAKEHOME/.claude-routed/plugins/claude-hud/config.json" ] || { echo "FAIL: claude-hud config not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-routed/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-routed/plugins/installed_plugins.json" ] || { echo "FAIL: plugin registry not seeded"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-routed/.credentials.json" ] || { echo "FAIL: credentials copied"; FAILS=$((FAILS+1)); }

# --- T5: seeded settings.json sanitized (no model key, no env.ANTHROPIC_*)
node -e "
const s=require(process.argv[1]+'/.claude-routed/settings.json');
if('model' in s) { console.error('model key survived'); process.exit(1); }
for (const k of Object.keys(s.env||{})) if (k.startsWith('ANTHROPIC_')) { console.error('env.'+k+' survived'); process.exit(1); }
if ((s.env||{}).HIMMEL_INITIATIVE!=='1') { console.error('non-ANTHROPIC env entry lost'); process.exit(1); }
" "$FAKEHOME" || { echo "FAIL: settings sanitization"; FAILS=$((FAILS+1)); }

# --- T6: no key material anywhere under the seeded dir
grep -R "omni-test-123" "$FAKEHOME/.claude-routed" >/dev/null 2>&1 && { echo "FAIL: key leaked into config dir"; FAILS=$((FAILS+1)); }

# --- T7: --reseed refreshes seeded files, never resurrects denied files
printf 'updated' > "$FAKEHOME/.claude/CLAUDE.md"
printf 'secret' > "$FAKEHOME/.claude/history.jsonl"
t "reseed" 0 --reseed
grep -q updated "$FAKEHOME/.claude-routed/CLAUDE.md" || { echo "FAIL: reseed did not refresh"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-routed/history.jsonl" ] || { echo "FAIL: denied file seeded"; FAILS=$((FAILS+1)); }

# --- T8: .salus marker -> refuse exit 3, --force does NOT override (guard survives
# the variant — the mandated red path)
setup; KEY="omni-test-123"; touch "$WORK/.salus"
t "salus refuses" 3
t "salus refuses despite --force" 3 --force

# --- T9: denylisted cwd -> refuse without --force, proceed with it. Guard config
# is DELIBERATELY read from ~/.config/claude-glm (shared source of truth), NOT a
# per-lane ~/.config/claude-routed — a claude-glm denylist hit must refuse routed too.
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "shared claude-glm denylist refuses routed" 3
t "denylist + --force proceeds" 0 --force

# --- T10: PHI root file (shared claude-glm config) -> absolute refuse even with --force
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-root refuses despite --force" 3 --force

# --- T10b: config roots are normalized (trailing slash + CRLF) before matching
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s/\n' "$(dirname "$WORK")" > "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-root trailing-slash still refuses descendant despite --force" 3 --force

setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\r\n' "$WORK" > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "denylist CRLF line still refuses" 3

# --- T11: clean cwd proceeds silently
setup; KEY="omni-test-123"
t "clean proceeds" 0

# --- T12: launch output contains an off-peak annotation line (routed lane is
# GLM-behind-the-router — the advisory still applies)
setup; KEY="omni-test-123"
t "annotation present" 0
grep -q "GLM peak window" "$WORK/out.txt" || { echo "FAIL: no off-peak annotation"; FAILS=$((FAILS+1)); }

# --- T13: claude flags pass through verbatim; leading --reseed is consumed
setup; KEY="omni-test-123"
t "passthrough launch" 0 --reseed -p hello -d
grep -qF -- "-p hello -d" "$WORK/claude-argv.txt" || { echo "FAIL: claude flags not passed verbatim"; FAILS=$((FAILS+1)); }
grep -qF -- "--reseed" "$WORK/claude-argv.txt" && { echo "FAIL: --reseed leaked to claude argv"; FAILS=$((FAILS+1)); }

# --- T14: launcher propagates claude's exit code (exec by construction; test it)
setup; KEY="omni-test-123"
t "exit code propagates from claude" 7 --mock-exit-7

# --- T15 (C1): phi-roots file WITHOUT a trailing newline still blocks the final line
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s' "$WORK" > "$FAKEHOME/.config/claude-glm/phi-roots"   # NO trailing newline
t "phi-root no-trailing-newline still refuses" 3

# --- T16 (C2): seeding is transactional — a sanitize failure exits 4, launches
# nothing, writes no sentinel; the NEXT launch (node restored) self-heals.
setup; KEY="omni-test-123"
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
exit 1
NODESHIM
chmod +x "$BIN/node"
t "sanitize failure exits 4" 4
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched despite failed seed"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-routed/.seeded" ] || { echo "FAIL: sentinel written despite failed seed"; FAILS=$((FAILS+1)); }
rm -f "$BIN/node"
t "second launch self-heals after node restored" 0
[ -f "$FAKEHOME/.claude-routed/settings.json" ] || { echo "FAIL: settings.json not seeded on self-heal"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-routed/.seeded" ] || { echo "FAIL: sentinel not written on self-heal"; FAILS=$((FAILS+1)); }

# --- T17 (guard I7): phi-roots that is a DIRECTORY (not a readable file) fails
# CLOSED with exit 3, never silently allows egress.
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm/phi-roots"
t "phi-roots as directory fails closed" 3

# --- T18 (I8): a quoted .env value has its surrounding quotes stripped in the
# launcher before reaching the child (bash otherwise sends literal quotes).
setup; KEY=""
printf 'OMNIROUTE_API_KEY="quoted-val-789"\n' > "$WORK/.env"  # gitleaks:allow
t "quoted .env key launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=quoted-val-789" "$WORK/child-env.txt" || { echo "FAIL: surrounding quotes not stripped from key"; FAILS=$((FAILS+1)); }  # gitleaks:allow

# --- T19: a FAILED --reseed clears the stale sentinel, so a later plain launch
# re-seeds (and fails again while node is broken) instead of proceeding with the
# stale tree; node restored -> plain launch self-heals.
setup; KEY="omni-test-123"
t "initial seed ok" 0                                   # sentinel written
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
exit 1
NODESHIM
chmod +x "$BIN/node"
t "reseed with broken node exits 4" 4 --reseed
[ ! -f "$FAKEHOME/.claude-routed/.seeded" ] || { echo "FAIL: stale sentinel survived failed reseed"; FAILS=$((FAILS+1)); }
rm -f "$WORK/child-env.txt"
t "plain launch after failed reseed still exits 4" 4    # NOT 0 with a stale sentinel
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched with a stale-sentinel tree"; FAILS=$((FAILS+1)); }
rm -f "$BIN/node"
t "plain launch self-heals after node restored" 0
[ -f "$FAKEHOME/.claude-routed/.seeded" ] || { echo "FAIL: sentinel not written on self-heal"; FAILS=$((FAILS+1)); }

# --- T20: a blank CRLF-only line in a guard config must NOT over-refuse every workspace.
setup; KEY="omni-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '/some/unrelated/root\r\n\r\n' > "$FAKEHOME/.config/claude-glm/egress-denylist"
t "blank CRLF guard line does not over-refuse clean cwd" 0

echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
