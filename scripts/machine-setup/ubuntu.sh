#!/usr/bin/env bash
set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
LUNA_REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --luna-remote) LUNA_REMOTE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$LUNA_REMOTE" ]]; then
  echo "ERROR: --luna-remote <url> required" >&2
  exit 1
fi

# ── Paths ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC2034
HIMMEL_PATH="$HOME/github/himmel"
STATUSLINE_PATH="$HOME/github/claude-statusline"
LUNA_VAULT_PATH="$HOME/Documents/luna"
CLAUDE_DIR="$HOME/.claude"

# ── PATH hoist ──────────────────────────────────────────────────────────────
# uv, the native Claude Code installer, and the npm-global redirect (step 11)
# all drop binaries into ~/.local/bin. Prepend once here so every step picks
# them up — avoids the per-step re-export duplication.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# ── Progress ────────────────────────────────────────────────────────────────
TOTAL_STEPS=20
STEP=0
FAILURES=()

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "══════════════════════════════════════════════"
  echo "[$STEP/$TOTAL_STEPS] $1"
  echo "══════════════════════════════════════════════"
}

fail_nonfatal() {
  echo "  WARNING: $1 failed — continuing"
  FAILURES+=("Step $STEP: $1")
}

# Validated settings.json write (HIMMEL-264 CR). The naive
# `printf … | jq > .new && mv` chain clobbers settings.json with an
# empty/garbage file when the upstream jq transform produced nothing
# (e.g. a filter error with set -e suspended inside a step block) —
# while the step still reports success. Refuse empty content, pretty-
# print to .new, re-validate .new, and only then mv into place.
# Returns non-zero (original file untouched) on any failure.
write_settings_json() { # $1 = JSON string, $2 = target path
  local content="$1" target="$2"
  if [[ -z "$content" ]]; then
    echo "  ERROR: refusing to write empty content to $target (upstream jq produced no output)" >&2
    return 1
  fi
  if ! printf '%s\n' "$content" | jq --indent 2 . > "${target}.new" \
     || ! jq -e . "${target}.new" >/dev/null 2>&1; then
    echo "  ERROR: generated content for $target is not valid JSON — leaving the original untouched" >&2
    rm -f "${target}.new"
    return 1
  fi
  mv "${target}.new" "$target"
}

# ── Fatal steps (1–6): set -e active ────────────────────────────────────────
step "Update package manager"
sudo apt update
sudo apt upgrade -y

step "Install core tools: git, Python, jq, curl, shellcheck, gitleaks"
# The shellcheck and gitleaks binaries are referenced by .pre-commit-config.yaml.
# pre-commit downloads its own copies inside the hook framework, but local
# direct invocation (manual lint runs, smoke tests) needs them on PATH.
sudo apt install -y git python3 python3-pip jq curl shellcheck gitleaks

step "Install nvm + Node from .nvmrc"
NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
NODE_VERSION="$(cat "$REPO_ROOT/.nvmrc")"
nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

ACTUAL_MAJOR="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"
_nv="${NODE_VERSION#v}"
EXPECT_MAJOR="${_nv%%.*}"
if [ "$ACTUAL_MAJOR" != "$EXPECT_MAJOR" ]; then
  echo "ERROR: node major $ACTUAL_MAJOR != expected $EXPECT_MAJOR from .nvmrc"
  exit 1
fi
echo "Node $(node --version) active (.nvmrc=$NODE_VERSION)"

step "Install uv + uvx"
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version

step "Install Claude Code CLI (native installer — no npm dependency)"
curl -fsSL https://claude.ai/install.sh | bash
claude --version

step "Install RTK"
# Use the unversioned `rtk_amd64.deb` alias rather than `rtk_${VER}_amd64.deb`.
# The release also publishes `rtk_${VER}-1_amd64.deb` (note the `-1` debian
# revision) but no `rtk_${VER}_amd64.deb` — the old derivation 404'd silently.
# The alias survives both version and revision bumps.
RTK_TAG=$(curl -s https://api.github.com/repos/rtk-ai/rtk/releases/latest | jq -r .tag_name)
RTK_DEB="rtk_amd64.deb"
curl -fL "https://github.com/rtk-ai/rtk/releases/download/${RTK_TAG}/${RTK_DEB}" \
  -o "/tmp/${RTK_DEB}"
sudo apt install -y "/tmp/${RTK_DEB}"
rtk init -g
rtk --version

step "Clone himmel + run repo setup"
mkdir -p "$(dirname "$HIMMEL_PATH")"
git clone https://github.com/yotamleo/Himmel.git "$HIMMEL_PATH"
cd "$HIMMEL_PATH"

# HIMMEL-105: gate the clone for core.hooksPath misconfiguration BEFORE
# running pre-commit install. If the operator's machine inherited a bad
# core.hooksPath from a sibling repo (or copied .gitconfig), pre-commit
# install would silently install hooks into a dir git is ignoring, and
# every gate (no-push-to-main, npm-audit, code-review-before-push,
# platforms-tested, hookspath-misconfig itself) would be bypassed.
bash scripts/hooks/check-hookspath.sh

bash scripts/setup.sh
cd -

step "Build scripts/jira/dist + scripts/himmel-run/dist"
( cd "$HIMMEL_PATH/scripts/jira" && npm ci && npm run build )
( cd "$HIMMEL_PATH/scripts/himmel-run" && npm ci && npm run build )

step "Link himmel-run bin to ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$HIMMEL_PATH/scripts/himmel-run/bin/himmel-run" "$HOME/.local/bin/himmel-run"

# ── Non-fatal steps (7–12): try/catch ───────────────────────────────────────
# Non-fatal from here — failures logged but don't abort
set +e

step "Clone claude-statusline"
{
  mkdir -p "$(dirname "$STATUSLINE_PATH")"
  git clone https://github.com/yotamleo/claude-statusline.git "$STATUSLINE_PATH"
} || fail_nonfatal "clone statusline"

step "Copy Claude config"
{
  mkdir -p "$CLAUDE_DIR"
  cp "$HIMMEL_PATH/docs/setup/global-claude-md.md" "$CLAUDE_DIR/CLAUDE.md"
  cp "$HIMMEL_PATH/docs/setup/rtk-md.md" "$CLAUDE_DIR/RTK.md"
} || fail_nonfatal "copy Claude config"

step "Install obsidian-second-brain skill"
{
  mkdir -p "$CLAUDE_DIR/plugins"
  git clone https://github.com/eugeniughelbur/obsidian-second-brain.git \
    "$CLAUDE_DIR/plugins/obsidian-second-brain"
  cd "$CLAUDE_DIR/plugins/obsidian-second-brain"
  bash install.sh
  cd -
} || fail_nonfatal "obsidian-second-brain plugin"

step "Rewrite git@github.com SSH URLs to HTTPS (public-repo clone fix)"
{
  # Some marketplaces (e.g. claude-obsidian) declare plugin sources with
  # `git@github.com:` URLs. Public repos clone fine over HTTPS — only the
  # URL form requires an SSH key. Rewrite globally so `claude plugin
  # install` succeeds without configuring a GitHub deploy key.
  if ! git config --global --get-all url."https://github.com/".insteadOf 2>/dev/null \
       | grep -qx "git@github.com:"; then
    git config --global --add url."https://github.com/".insteadOf "git@github.com:"
    echo "  added: git insteadOf rule"
  else
    echo "  already configured"
  fi
} || fail_nonfatal "git insteadOf"

step "Install Claude plugins from manifest"
{
  # Scope choice: user = ~/.claude (every project); project = this repo's
  # .claude/settings.json (shared on clone). The third scope `local` is
  # reachable only via install-plugins.sh --scope local, not this prompt.
  # `|| true` so a non-interactive run (no TTY / EOF) falls through to the
  # default instead of aborting.
  read -r -p "Install plugins at [u]ser scope (all projects) or [p]roject scope (this repo only)? [default: user]: " PLUGIN_SCOPE_CHOICE || true
  case "${PLUGIN_SCOPE_CHOICE:-u}" in
    [Pp]*) PLUGIN_SCOPE="project" ;;
    *)     PLUGIN_SCOPE="user" ;;
  esac
  echo "  → installing at $PLUGIN_SCOPE scope"
  bash "$HIMMEL_PATH/scripts/machine-setup/install-plugins.sh" \
    --scope "$PLUGIN_SCOPE" --himmel-path "$HIMMEL_PATH"
} || fail_nonfatal "install plugins from manifest"

step "Clone Luna vault + install pre-commit hooks"
{
  mkdir -p "$(dirname "$LUNA_VAULT_PATH")"

  # Migrate legacy double-nested layout: $LUNA_VAULT_PATH/luna/.git but no
  # $LUNA_VAULT_PATH/.git. Previous versions of this script cloned to
  # $HOME/Documents/luna/luna which left Obsidian opening the empty wrapper
  # $HOME/Documents/luna/ instead of the real vault. Move repo contents up.
  if [[ -d "$LUNA_VAULT_PATH/luna/.git" && ! -d "$LUNA_VAULT_PATH/.git" ]]; then
    echo "  migrating double-nested luna/luna → luna"
    # Backup the outer wrapper config (workspace.json etc.) before merge.
    if [[ -d "$LUNA_VAULT_PATH/.obsidian" ]]; then
      mv "$LUNA_VAULT_PATH/.obsidian" "$LUNA_VAULT_PATH/.obsidian.wrapper-backup.$(date +%s)"
    fi
    # Move inner contents (including dotfiles) up one level.
    shopt -s dotglob nullglob
    mv "$LUNA_VAULT_PATH/luna/"* "$LUNA_VAULT_PATH/"
    shopt -u dotglob nullglob
    rmdir "$LUNA_VAULT_PATH/luna"
  fi

  if [[ -d "$LUNA_VAULT_PATH/.git" ]]; then
    echo "  luna vault already present — skipping clone"
  else
    git clone "$LUNA_REMOTE" "$LUNA_VAULT_PATH"
  fi

  cd "$LUNA_VAULT_PATH"
  uv tool install pre-commit
  pre-commit install
  pre-commit install --hook-type pre-push
  cd -
} || fail_nonfatal "Luna vault setup"

step "Install qmd CLI + register himmel/luna collections"
{
  # Project rule: qmd installs via bun, not npm. The qmd Claude plugin ships
  # a path stub that breaks plain `qmd` on Windows; scripts/lib/qmd-bin.sh
  # picks the working invoker. --ignore-scripts skips the better-sqlite3
  # native build (prebuilt binary works).
  # shellcheck source=../lib/qmd-bin.sh
  # shellcheck disable=SC1091
  . "$HIMMEL_PATH/scripts/lib/qmd-bin.sh"

  # Neutralize the broken qmd plugin-cache stub at source so plain `qmd`
  # works inside Claude's Bash tool too (HIMMEL-163 — Linux plugin installs
  # share the same stub layout). No-op when the plugin is absent, already
  # patched, or upstream has shipped a fixed stub.
  bash "$HIMMEL_PATH/scripts/lib/fix-qmd-stub.sh" || echo "  WARNING: fix-qmd-stub failed — continuing." >&2

  # Track step-wide success. Plain `false` does NOT propagate through this
  # `{} || fail_nonfatal` group because the trailing commands (unset, the
  # for-loop's last echo) overwrite $? to 0. End the group with an explicit
  # `[ "$_qmd_step_ok" -eq 1 ]` so failure cascades to fail_nonfatal.
  _qmd_step_ok=1

  if ! has_qmd; then
    if command -v bun >/dev/null 2>&1; then
      # Capture rc *before* the `if`: `if ! cmd; then $?` is 0, not cmd's rc.
      bun add -g @tobilu/qmd@latest --ignore-scripts
      _bun_rc=$?
      if [ "$_bun_rc" -ne 0 ]; then
        echo "  ERROR: bun add -g @tobilu/qmd failed (rc=$_bun_rc)." >&2
        echo "  Check network / registry; skipping collection registration." >&2
        _qmd_step_ok=0
      fi
    else
      echo "  bun not on PATH — cannot install qmd. Install bun first: https://bun.sh" >&2
      _qmd_step_ok=0
    fi
  fi

  # Skip --version + register loop when install failed. Running them would
  # produce confusing "rc=127" warnings on top of the real install failure.
  if [ "$_qmd_step_ok" -eq 1 ]; then
    qmd_cmd --version
    _qmd_version_rc=$?
    if [ "$_qmd_version_rc" -ne 0 ]; then
      echo "  WARNING: qmd_cmd --version failed (rc=$_qmd_version_rc) — qmd install may be broken." >&2
      _qmd_step_ok=0
    fi
  fi

  if [ "$_qmd_step_ok" -eq 1 ]; then
    for entry in "himmel:$HIMMEL_PATH" "luna:$LUNA_VAULT_PATH"; do
      NAME="${entry%%:*}"
      PATH_VAL="${entry#*:}"
      if [[ ! -d "$PATH_VAL" ]]; then
        echo "  Skip '$NAME': $PATH_VAL not present"
        continue
      fi
      _qmd_list_out=$(qmd_cmd collection list 2>&1)
      _qmd_list_rc=$?
      if [ "$_qmd_list_rc" -ne 0 ]; then
        echo "  WARNING: qmd collection list failed (rc=$_qmd_list_rc) — skipping '$NAME' registration." >&2
        # shellcheck disable=SC2001
        echo "$_qmd_list_out" | sed 's/^/    /' >&2
        _qmd_step_ok=0
        continue
      fi
      if echo "$_qmd_list_out" | grep -q "^${NAME}\b"; then
        echo "  Collection '$NAME' already registered — skipping"
      else
        qmd_cmd collection add "$PATH_VAL" --name "$NAME"
        _qmd_add_rc=$?
        if [ "$_qmd_add_rc" -ne 0 ]; then
          echo "  WARNING: qmd collection add '$NAME' failed (rc=$_qmd_add_rc) — vault may be unindexed." >&2
          _qmd_step_ok=0
        fi
      fi
    done
  fi

  # Compute final rc. The bare test is the group's last command, so its
  # rc determines whether `|| fail_nonfatal` fires.
  _qmd_step_final=$_qmd_step_ok
  unset _qmd_list_out _qmd_list_rc _bun_rc _qmd_version_rc _qmd_add_rc _qmd_step_ok
  [ "$_qmd_step_final" -eq 1 ]
} || fail_nonfatal "qmd setup"

step "Patch ~/.claude/settings.json"
{
  SETTINGS="$CLAUDE_DIR/settings.json"
  TEMPLATE="$HIMMEL_PATH/docs/setup/settings-template.json"
  STATUSLINE_CMD="bash \"$STATUSLINE_PATH/bin/statusline.sh\""

  # Strip SessionEnd from template — the next step ("Configure end-session-wiki
  # SessionEnd hook") owns that key end-to-end and prompts the user. Writing
  # placeholder commands here would leave dangling `<himmel-path>` strings
  # if the user skips that step.
  #
  # HIMMEL-105: guard against silent regression — if a future template
  # refactor removes or reshapes .hooks.SessionStart[0].hooks, the jq
  # patch below would produce a wrong shape and the caveman-activate
  # SessionStart entry would vanish without any error surfacing. Assert
  # the expected pre-patch shape first; abort loudly on mismatch.
  # Using `false` propagates failure out of the `{ ... } || fail_nonfatal`
  # chain rather than relying on `set -e` (suspended inside the block).
  if ! jq -e '.hooks.SessionStart[0].hooks | type == "array"' "$TEMPLATE" >/dev/null 2>&1; then
    echo "  ERROR: settings-template.json missing .hooks.SessionStart[0].hooks — refusing to patch (would clobber existing entries)" >&2
    false
  else
    # HIMMEL-105: append the bash check-hookspath SessionStart entry. Only the
    # bash sibling is registered on Linux — the pwsh sibling would fail with
    # "pwsh: command not found" every session start on machines without
    # PowerShell installed (Ubuntu's default), logging a confusing warning.
    # The Windows path adds the pwsh entry via win11.ps1; the cross-platform
    # template carries neither so each setup script can register the right one.
    PATCH=$(jq \
      --arg sl "$STATUSLINE_CMD" \
      --arg lv "$LUNA_VAULT_PATH" \
      --arg hp "$HIMMEL_PATH" \
      '. + {
        statusLine: { type: "command", command: $sl },
        mcpServers: {
          "obsidian-vault": { command: "uvx", args: ["mcp-obsidian", $lv] }
        },
        extraKnownMarketplaces: (.extraKnownMarketplaces + {
          "himmel": { source: { source: "directory", path: ($hp + "/marketplace") } }
        }),
        hooks: ((.hooks | del(.SessionEnd))
          | .SessionStart[0].hooks += [{
              type: "command",
              command: ("bash \"" + $hp + "/scripts/hooks/check-hookspath.sh\""),
              shell: "bash",
              timeout: 10
            }])
      }
      # HIMMEL-264: resolve <himmel-path> placeholders the template carries
      # (the PreToolUse rtk-hook-guard entry) so a freshly written
      # settings.json never holds a dangling <himmel-path>. Scope note:
      # ONLY <himmel-path> — the caveman <node-path>/<claude-dir>
      # placeholders are not resolved on Ubuntu (caveman hook wiring is
      # Windows-only, via win11.ps1).
      | walk(if type == "string" then gsub("<himmel-path>"; $hp) else . end)' \
      "$TEMPLATE")

    # HIMMEL-264 CR: walk() needs jq >= 1.6 — on jq 1.5 the filter errors,
    # PATCH comes back empty, and the writes below would clobber
    # settings.json with literal `null` (merge path) or a blank file
    # (fresh path) while reporting success. Mirror the HIMMEL-105
    # shape-assert above: validate PATCH before either write.
    if [[ -z "$PATCH" ]] || ! printf '%s\n' "$PATCH" | jq -e . >/dev/null 2>&1; then
      echo "  ERROR: template patch produced empty/invalid JSON (walk() requires jq >= 1.6) — refusing to write" >&2
      false
    elif [[ -f "$SETTINGS" ]]; then
      # Deep-merge: existing settings win on key conflict (idempotent re-runs)
      MERGED=$(printf '%s\n' "$PATCH" | jq -s '.[0] * .[1]' - "$SETTINGS")
      write_settings_json "$MERGED" "$SETTINGS"
    else
      write_settings_json "$PATCH" "$SETTINGS"
    fi
  fi
} || fail_nonfatal "patch settings.json"

step "Configure end-session-wiki SessionEnd hook"
{
  SETTINGS="$CLAUDE_DIR/settings.json"
  SH_HOOK="$HIMMEL_PATH/scripts/hooks/end-session-wiki.sh"

  if [[ ! -f "$SH_HOOK" ]]; then
    echo "  ERROR: hook script not found: $SH_HOOK"
    fail_nonfatal "register SessionEnd hook"
  elif [[ ! -f "$SETTINGS" ]]; then
    echo "  ERROR: settings.json missing — previous step did not run"
    fail_nonfatal "register SessionEnd hook"
  else
    # jq is installed by step 2 (core tools). Sanity-check anyway.
    if ! command -v jq >/dev/null 2>&1; then
      echo "  jq missing — installing"
      sudo apt install -y jq
    fi

    read -r -p "Register SessionEnd hook for end-session-wiki? [Y]es/[n]o [default: Y]: " HOOK_CHOICE
    HOOK_CHOICE="${HOOK_CHOICE:-Y}"

    if [[ "$HOOK_CHOICE" =~ ^[Nn] ]]; then
      echo "  Skipped SessionEnd registration. Re-run this script or edit $SETTINGS manually."
    else
      EXISTING_SE=$(jq -r '.hooks.SessionEnd // empty' "$SETTINGS")
      ACTION="overwrite"
      if [[ -n "$EXISTING_SE" ]]; then
        read -r -p "SessionEnd already configured. [O]verwrite / [A]ppend / [S]kip [default: skip]: " EXIST_CHOICE
        EXIST_CHOICE="${EXIST_CHOICE:-S}"
        case "$EXIST_CHOICE" in
          [Oo]*) ACTION="overwrite" ;;
          [Aa]*) ACTION="append" ;;
          *)     ACTION="skip" ;;
        esac
      fi

      if [[ "$ACTION" == "skip" ]]; then
        echo "  Skipped: existing SessionEnd preserved as-is."
      else
        TS=$(date +"%Y%m%d-%H%M%S")
        BACKUP="${SETTINGS}.bak.${TS}"
        cp "$SETTINGS" "$BACKUP"
        echo "  Backed up: $BACKUP"

        NEW_ENTRY=$(jq -n --arg cmd "bash \"$SH_HOOK\"" \
          '{hooks: [{type: "command", command: $cmd, shell: "bash", timeout: 30}]}')

        if [[ "$ACTION" == "append" ]]; then
          UPDATED=$(jq --argjson e "$NEW_ENTRY" '.hooks.SessionEnd += [$e]' "$SETTINGS")
        else
          UPDATED=$(jq --argjson e "$NEW_ENTRY" '.hooks.SessionEnd = [$e]' "$SETTINGS")
        fi

        write_settings_json "$UPDATED" "$SETTINGS" \
          && echo "  Registered SessionEnd: bash. Hook script at: $SH_HOOK"
      fi
    fi
  fi
} || fail_nonfatal "register SessionEnd hook"

step "Register auto-arm-on-cap PreToolUse hook (HIMMEL-220)"
{
  # User-level registration so EVERY repo's sessions get cap protection
  # (the himmel checkout carries its own project-level wiring in
  # .claude/settings.json; this covers luna / yotam_docs / etc).
  # The hook resolves its lib + arm-resume relative to its own location,
  # so an absolute himmel path works from any cwd.
  SETTINGS="$CLAUDE_DIR/settings.json"
  ARM_HOOK="$HIMMEL_PATH/scripts/hooks/auto-arm-on-cap.sh"

  if [[ ! -f "$ARM_HOOK" ]]; then
    echo "  ERROR: hook script not found: $ARM_HOOK"
    fail_nonfatal "register auto-arm hook"
  elif [[ ! -f "$SETTINGS" ]]; then
    echo "  ERROR: settings.json missing — previous step did not run"
    fail_nonfatal "register auto-arm hook"
  elif jq -e '.hooks.PreToolUse // [] | map(.hooks // [] | map(.command) | join(" ")) | join(" ") | contains("auto-arm-on-cap.sh")' "$SETTINGS" >/dev/null 2>&1; then
    echo "  Already registered — skipping (idempotent)."
  else
    read -r -p "Register auto-arm-on-cap PreToolUse hook (auto-arms a resume at 90% usage)? [Y]es/[n]o [default: Y]: " ARM_CHOICE
    ARM_CHOICE="${ARM_CHOICE:-Y}"
    if [[ "$ARM_CHOICE" =~ ^[Nn] ]]; then
      echo "  Skipped auto-arm registration. Re-run this script or edit $SETTINGS manually."
    else
      TS=$(date +"%Y%m%d-%H%M%S")
      BACKUP="${SETTINGS}.bak.${TS}"
      cp "$SETTINGS" "$BACKUP"
      echo "  Backed up: $BACKUP"

      ARM_ENTRY=$(jq -n --arg cmd "bash \"$ARM_HOOK\"" \
        '{matcher: "*", hooks: [{type: "command", command: $cmd}]}')
      UPDATED=$(jq --argjson e "$ARM_ENTRY" '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [$e])' "$SETTINGS")
      if write_settings_json "$UPDATED" "$SETTINGS"; then
        echo "  Registered auto-arm-on-cap (PreToolUse, matcher *). Hook script at: $ARM_HOOK"
        echo "  Kill switch: AUTO_ARM_DISABLE=1 in the launching shell."
      else
        false
      fi
    fi
  fi
} || fail_nonfatal "register auto-arm hook"

step "Swap rtk hook for rtk-hook-guard wrapper (HIMMEL-241)"
{
  # `rtk init -g` registers bare `rtk hook claude`, which rewrites
  # `find …` to `rtk find …` — but `rtk find` rejects compound
  # predicates (-not/-exec/…), silently breaking every LUNA runbook
  # scan. rtk-hook-guard.sh delegates to rtk and passes compound finds
  # through unrewritten; everything else keeps the rtk rewrite.
  SETTINGS="$CLAUDE_DIR/settings.json"
  GUARD_HOOK="$HIMMEL_PATH/scripts/hooks/rtk-hook-guard.sh"

  # Any command starting with `rtk hook claude` (extra flags included)
  # counts as a bare entry. HIMMEL-264: swap ALL bare entries on every
  # run — even when a guard entry already exists (a re-run of
  # `rtk init -g` after a swap re-adds a raw entry the old
  # contains("rtk-hook-guard.sh") early-exit never replaced).
  # (POSIX classes — the regex reaches jq verbatim via --arg, no escaping)
  BARE_RTK_RE='^[[:space:]]*rtk[[:space:]]+hook[[:space:]]+claude([[:space:]]|$)'

  if [[ ! -f "$GUARD_HOOK" ]]; then
    echo "  ERROR: hook script not found: $GUARD_HOOK"
    fail_nonfatal "swap rtk hook for guard"
  elif [[ ! -f "$SETTINGS" ]]; then
    echo "  ERROR: settings.json missing — previous step did not run"
    fail_nonfatal "swap rtk hook for guard"
  elif ! jq -e '.hooks.PreToolUse' "$SETTINGS" >/dev/null 2>&1; then
    echo "  No hooks.PreToolUse in settings.json — skipping (did rtk init -g run?)."
  else
    BARE_COUNT=$(jq --arg re "$BARE_RTK_RE" \
      '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test($re))] | length' \
      "$SETTINGS")
    if [[ "$BARE_COUNT" -eq 0 ]]; then
      if jq -e '.hooks.PreToolUse // [] | map(.hooks // [] | map(.command) | join(" ")) | join(" ") | contains("rtk-hook-guard.sh")' "$SETTINGS" >/dev/null 2>&1; then
        echo "  Already swapped — skipping (idempotent)."
      else
        echo "  No 'rtk hook claude' entry found — skipping (did rtk init -g run?)."
      fi
    else
      TS=$(date +"%Y%m%d-%H%M%S")
      BACKUP="${SETTINGS}.bak.${TS}"
      cp "$SETTINGS" "$BACKUP"
      echo "  Backed up: $BACKUP"

      UPDATED=$(jq --arg cmd "bash \"$GUARD_HOOK\"" --arg re "$BARE_RTK_RE" \
        '(.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test($re))).command = $cmd' "$SETTINGS")
      write_settings_json "$UPDATED" "$SETTINGS" \
        && echo "  Swapped $BARE_COUNT 'rtk hook claude' entry(s) -> bash \"$GUARD_HOOK\""
    fi
  fi
} || fail_nonfatal "swap rtk hook for guard"

step "Install Obsidian + open vault"
{
  VER=$(curl -s https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | jq -r .tag_name)
  VER_NUM="${VER#v}"
  DEB_FILE="/tmp/obsidian_${VER_NUM}_amd64.deb"
  curl -L "https://github.com/obsidianmd/obsidian-releases/releases/download/${VER}/obsidian_${VER_NUM}_amd64.deb" \
    -o "$DEB_FILE"
  sudo apt install -y "$DEB_FILE"
  obsidian "obsidian://open?vault=luna" &
} || fail_nonfatal "Obsidian install"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "SETUP COMPLETE"
echo "════════════════════════════════════════"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "Non-fatal failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
echo ""
echo "MANUAL STEPS REMAINING:"
echo "  1. Fill JIRA_API_TOKEN in $HIMMEL_PATH/.env"
echo "  2. Configure Atlassian MCP token in $CLAUDE_DIR/settings.json"
echo "  3. (Optional) Run 'qmd embed' for semantic search over himmel + luna"
echo "  4. Verify: rtk --version | rtk gain | jira list | claude /obsidian-daily | qmd status"
