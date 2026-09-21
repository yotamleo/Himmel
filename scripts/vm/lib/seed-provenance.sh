#!/usr/bin/env bash
# seed-provenance.sh — pre-seed a guest HOME with a user's own Claude/himmel-
# adjacent state before a himmel install (HIMMEL-3332 S9b, spec §11 step 2).
# Runs ON the guest, from scripts/vm/provenance-roundtrip.sh. Every file is
# written directly (never through the claude CLI: the guest is not signed in,
# and the CLI creates state of its own on first run).
#
# Writes, next to itself (the harness's /tmp/rt-work):
#   seeded.list   every seeded path, absolute, one per line (the byte-identity set)
#   state.list    the telegram + bridge state seeded for the --purge-state
#                 variant (three files, their two directories): a plain uninstall
#                 must keep them and --purge-state must remove them, so they are
#                 NOT in seeded.list (whose paths must always survive)
#   seed-state/   facts the checks compare against later: the crontab text,
#                 mine.service's enabled state, and pristine copies of the
#                 seeded JSON files
#
# RT_PROFILE=all (the harness's --profile all) also seeds executable stubs
# ~/.local/bin/qmd and ~/.local/bin/graphify. They exist only so the qmd and
# graphmap cadence arms find an absolute executable (`command -v`) and install
# can arm its crontab lines; they are the USER's own pre-existing files, listed
# in seeded.list, so uninstall must leave them alone and nothing counts them as
# himmel's.
#
# ponytail: a stub is not a real qmd or graphify. It proves the arm and the
# disarm of the cadence crontab lines, never that a cadence RUN works: no
# cadence fires in the guest, and installing the real tools (the qmd fork build
# and 2.1 GB of models, HIMMEL-2531) is not reproducible from this repo.
#
# Refuses (rc 2, writing nothing) unless HIMMEL_RT_GUEST=1, when any target
# already exists (~/.bashrc excepted: the seed lines are PREPENDED to the
# image's own, ahead of its interactive-shell guard, so a login shell reads
# them), or when the user already has a crontab.
# shellcheck disable=SC2016 # jq programs and literal shell lines are single-quoted on purpose.
set -u
export LC_ALL=C

[ "${HIMMEL_RT_GUEST:-}" = 1 ] || { echo "seed-provenance.sh: refusing: guest-only (set HIMMEL_RT_GUEST=1 on the guest)" >&2; exit 2; }

H="$HOME"
PROFILE="${RT_PROFILE:-core}"
OUT="$(cd "$(dirname "$0")" && pwd)"
TARGETS=(
    .claude/CLAUDE.md .claude.json .claude/settings.json
    .claude/plugins/marketplaces/claude-plugins-official .claude/plugins/marketplaces/my-market
    .claude/plugins/cache/claude-plugins-official/context7 .claude/plugins/cache/my-market/my-tool
    .claude/skills/my-skill .claude/plugins/claude-hud/config.json
    proj .local/bin/mytool .config/systemd/user/mine.service
    .config/claude-glm/phi-roots .himmel/config.json
    .npm/_cacache/seed .cache/node-gyp/seed .bun/install/cache/seed
    .claude/channels/telegram/.env .claude/channels/telegram/access.json .claude/handover/bridge/state.json
)
[ "$PROFILE" != all ] || TARGETS+=(.local/bin/qmd .local/bin/graphify)
hit=0
for t in "${TARGETS[@]}"; do
    if [ -e "$H/$t" ] || [ -L "$H/$t" ]; then echo "seed-provenance.sh: refusing: $H/$t already exists" >&2; hit=1; fi
done
[ "$hit" = 0 ] || exit 2
if [ -n "$(crontab -l 2>/dev/null)" ]; then echo "seed-provenance.sh: refusing: the user already has a crontab" >&2; exit 2; fi
command -v jq >/dev/null 2>&1 || { echo "seed-provenance.sh: jq is required" >&2; exit 2; }

set -e
LIST="$OUT/seeded.list"
SLIST="$OUT/state.list"
STATE="$OUT/seed-state"
mkdir -p "$STATE"
: >"$LIST"
: >"$SLIST"
rec() { local p; for p in "$@"; do printf '%s\n' "$H/$p" >>"$LIST"; done; }
rec_state() { local p; for p in "$@"; do printf '%s\n' "$H/$p" >>"$SLIST"; done; }

# --- ~/.claude/CLAUDE.md: two headings; a fenced block quoting the working-
# principles BEGIN marker (the #1008 case — a literal inside a fence is not a block).
mkdir -p "$H/.claude"
cat >"$H/.claude/CLAUDE.md" <<'EOF'
# My global rules

Keep answers short. Prefer plain shell.

## Notes on markers

The himmel block starts with this line, quoted here, not a block:

```text
<!-- BEGIN HIMMEL:working-principles -->
```

Nothing after this is himmel's.
EOF
rec .claude/CLAUDE.md

# --- ~/.claude.json: unrelated keys + one trusted project elsewhere.
jq -n --arg other "$H/other-project" \
    '{numStartups: 3, userID: "seed-user", theme: "dark", projects: {($other): {hasTrustDialogAccepted: true, allowedTools: []}}}' \
    >"$H/.claude.json"
rec .claude.json

# --- ~/.claude/settings.json: foreign keys of every kind himmel's install touches.
jq -n --arg h "$H" '{
  mcpServers: {"my-mcp": {command: ($h + "/.local/bin/mytool"), args: ["mcp"]}},
  hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: ($h + "/.local/bin/mytool hook")}]}]},
  statusLine: {type: "command", command: ($h + "/.local/bin/mytool status")},
  env: {HANDOVER_DIR: ($h + "/my-handovers")},
  enabledPlugins: {"context7@claude-plugins-official": true, "my-tool@my-market": true},
  extraKnownMarketplaces: {
    "claude-plugins-official": {source: {source: "github", repo: "anthropics/claude-plugins-official"}},
    "my-market": {source: {source: "directory", path: ($h + "/.claude/plugins/marketplaces/my-market")}}
  }
}' >"$H/.claude/settings.json"
rec .claude/settings.json

# --- marketplace skeletons, plugin caches (one file each), one own skill.
for m in claude-plugins-official my-market; do
    mkdir -p "$H/.claude/plugins/marketplaces/$m/.claude-plugin"
    jq -n --arg m "$m" '{name: $m, owner: {name: "seed"}, plugins: []}' \
        >"$H/.claude/plugins/marketplaces/$m/.claude-plugin/marketplace.json"
    rec ".claude/plugins/marketplaces/$m/.claude-plugin/marketplace.json"
done
mkdir -p "$H/.claude/plugins/cache/claude-plugins-official/context7/1.0.0" "$H/.claude/plugins/cache/my-market/my-tool/0.1.0"
echo "context7 seed" >"$H/.claude/plugins/cache/claude-plugins-official/context7/1.0.0/README.md"
echo "my-tool seed" >"$H/.claude/plugins/cache/my-market/my-tool/0.1.0/README.md"
rec .claude/plugins/cache/claude-plugins-official/context7/1.0.0/README.md .claude/plugins/cache/my-market/my-tool/0.1.0/README.md
mkdir -p "$H/.claude/skills/my-skill"
printf -- '---\nname: my-skill\ndescription: the user own skill\n---\n\nDo the thing.\n' >"$H/.claude/skills/my-skill/SKILL.md"
rec .claude/skills/my-skill/SKILL.md

# --- a project with the user's own worktree.sh, a same-named hook script, a
# git pre-commit hook and project settings.
P="$H/proj"
mkdir -p "$P/scripts/hooks" "$P/.claude"
cat >"$P/scripts/worktree.sh" <<'EOF'
#!/usr/bin/env bash
# the user's own worktree helper
case "${1:-}" in --version) echo "USER-WORKTREE-v1" ;; *) echo "usage: worktree.sh --version" ;; esac
EOF
chmod 755 "$P/scripts/worktree.sh"
cat >"$P/scripts/hooks/check-commit-msg.sh" <<'EOF'
#!/usr/bin/env bash
# the user's own commit-msg check
exit 0
EOF
jq -n '{permissions: {allow: ["Bash(make test)"]}}' >"$P/.claude/settings.json"
echo "seed project" >"$P/README.md"
git -C "$P" init -q
git -C "$P" add -A
git -C "$P" -c user.name=seed -c user.email=seed@invalid commit -qm "seed"
printf '#!/bin/sh\necho USER-PRECOMMIT\nexit 0\n' >"$P/.git/hooks/pre-commit"
chmod 755 "$P/.git/hooks/pre-commit"
rec proj/scripts/worktree.sh proj/scripts/hooks/check-commit-msg.sh proj/.claude/settings.json proj/README.md proj/.git/hooks/pre-commit

# --- claude-hud config with the user's own custom line command.
mkdir -p "$H/.claude/plugins/claude-hud"
jq -n --arg h "$H" '{customLineCommand: ($h + "/.local/bin/mytool hud"), layout: "compact"}' >"$H/.claude/plugins/claude-hud/config.json"
rec .claude/plugins/claude-hud/config.json

# --- an own tool on PATH, and a .bashrc that puts it there and defines a function.
mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho "mytool $*"\n' >"$H/.local/bin/mytool"
chmod 755 "$H/.local/bin/mytool"
rec .local/bin/mytool
if [ "$PROFILE" = all ]; then
    for b in qmd graphify; do
        printf '#!/bin/sh\n# himmel round-trip stub: the user own %s (see seed-provenance.sh)\necho "%s stub 0.0.0"\n' "$b" "$b" >"$H/.local/bin/$b"
        chmod 755 "$H/.local/bin/$b"
        rec ".local/bin/$b"
    done
fi
rc_tail=""
[ ! -f "$H/.bashrc" ] || rc_tail=$(cat "$H/.bashrc")
{
    echo '# seed-provenance: the user own lines (before the interactive guard)'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo 'myfn() { echo "myfn ok"; }'
    printf '%s\n' "$rc_tail"
} >"$H/.bashrc"
rec .bashrc

# --- a user crontab line and a user systemd unit, enabled by its wants link.
echo '17 3 * * * /bin/true # seed-provenance user line' | crontab -
crontab -l >"$STATE/crontab.txt"
mkdir -p "$H/.config/systemd/user/default.target.wants"
printf '[Unit]\nDescription=the user own unit\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n\n[Install]\nWantedBy=default.target\n' \
    >"$H/.config/systemd/user/mine.service"
ln -s "$H/.config/systemd/user/mine.service" "$H/.config/systemd/user/default.target.wants/mine.service"
rec .config/systemd/user/mine.service .config/systemd/user/default.target.wants/mine.service
(systemctl --user is-enabled mine.service 2>/dev/null || true) >"$STATE/mine-enabled.txt"

# --- the rest of spec §11 step 2: claude-glm roots, a himmel config key, the 3330 caches.
mkdir -p "$H/.config/claude-glm" "$H/.himmel" "$H/.npm/_cacache" "$H/.cache/node-gyp" "$H/.bun/install/cache"
echo "$H/my-phi-root" >"$H/.config/claude-glm/phi-roots"
# ~/.himmel/config.json is schema-strict (every v1 field required, a foreign
# key refused — and a refused config fails the install), so the user's state
# is a full v1 document carrying one non-default choice of their own.
jq -n --arg h "$H" '{
  version: 1,
  luna: {
    vaultPath: ($h + "/Documents/luna"),
    cadence: {
      enabled: false,
      schedules: {fetchHealth: {time: "01:30"}, harvest: {time: "02:00"}, synthesize: {time: "03:00"}, health: {time: "04:00", day: "SUN"}},
      models: {harvest: "opus", synthesize: "sonnet", health: "haiku"}
    },
    phi: {declared: false}
  },
  bridge: {enabled: false, envPath: "~/.claude/channels/telegram/.env", whisper: {cli: null, model: "ggml-small.bin"}}
}' >"$H/.himmel/config.json"
echo seed >"$H/.npm/_cacache/seed"
echo seed >"$H/.cache/node-gyp/seed"
echo seed >"$H/.bun/install/cache/seed"
rec .config/claude-glm/phi-roots .himmel/config.json .npm/_cacache/seed .cache/node-gyp/seed .bun/install/cache/seed

# --- the telegram bridge's own state: the two locations `uninstall --purge-state`
# removes and a plain uninstall keeps. A core install creates neither, so
# without this seed the two variants could not differ.
mkdir -p "$H/.claude/channels/telegram" "$H/.claude/handover/bridge"
echo 'TELEGRAM_BOT_TOKEN=seeded-not-a-token' >"$H/.claude/channels/telegram/.env"
chmod 600 "$H/.claude/channels/telegram/.env"
jq -n '{allowFrom: ["seed-user"]}' >"$H/.claude/channels/telegram/access.json"
jq -n '{seeded: true, lastUpdateId: 0}' >"$H/.claude/handover/bridge/state.json"
rec_state .claude/channels/telegram .claude/channels/telegram/.env .claude/channels/telegram/access.json \
    .claude/handover/bridge .claude/handover/bridge/state.json

# Pristine copies of the JSON the semantic checks read back.
cp "$H/.claude/settings.json" "$STATE/settings.json"
cp "$H/.claude.json" "$STATE/claude.json"
cp "$H/.claude/plugins/claude-hud/config.json" "$STATE/hud-config.json"
cp "$P/.claude/settings.json" "$STATE/proj-settings.json"
sha256sum "$P/scripts/worktree.sh" | cut -d' ' -f1 >"$STATE/worktree.sha"

echo "seed-provenance.sh: seeded $(wc -l <"$LIST") paths under $H"
