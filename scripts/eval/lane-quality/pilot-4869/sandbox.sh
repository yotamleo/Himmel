#!/usr/bin/env bash
# scripts/eval/lane-quality/pilot-4869/sandbox.sh - the bubblewrap jail a
# pilot row runs in. A third-party model must never reach the vaults, PHI, the
# operator's memory, the bank state, a real handover root or a host service,
# so the row sees an empty /home, /tmp, /run and /var/log with only these put
# back:
#   read-write  the row's worktree and its git admin dir, a per-row git object
#               dir (the shared object store is read-only behind it), the row
#               doc dir, the row's OWN lane config dir mounted at the lane's
#               config path, and the row's transcript dir as its projects/;
#   read-only   a clean export of the repo's tracked files (never the primary
#               checkout: its untracked MCP profiles, local settings and logs
#               stay out), the row's run dir, the ~/.claude items the lane
#               mirror seeds from (user settings with every plugin and MCP
#               server removed), the lane's egress config, and the toolchain
#               on PATH under $HOME.
# The network is a fresh namespace with only loopback. A launch adds ONE
# tunnel: a socat on the host forwards a unix socket to the lane's endpoint
# (api.deepseek.com:443, or the local cliproxy for claudex) and a socat inside
# listens on that port on 127.0.0.1; /etc/hosts maps the API host there. TLS
# stays end to end. Host loopback services (qmd, the obsidian APIs, docker)
# are unreachable. The lane key is read OUTSIDE the jail and passed in the
# environment, so no dotenv file is visible. /run/lq-pilot-jail exists only in
# the jail; the row's worktree settings refuse every prompt and tool without it.
#
# Usage:
#   sandbox.sh argv <row-env>              print the launch argv, one word per line
#   sandbox.sh run <row-env> <cmd...>      run <cmd> in the row's jail, no network (probes)
#   sandbox.sh check <row-env> <cmd...>    run <cmd> in the acceptor jail: any lane, no lane
#                                          config, no key, no network, the eval kit read-only
#   sandbox.sh launch <row-env> <args...>  run the lane launcher in the jail with its tunnel
# The row's <row>.sandbox wrapper (written by `pilot.sh prepare`) calls
# `launch`; headed-arm-leg.sh reaches it through HEADED_ARM_LEG_<LANE>_BIN.
# Test seam: PILOT_SANDBOX_TUNNEL_TARGET replaces the host side of the tunnel.
set -u
die() { echo "pilot-sandbox: $*" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

mode="${1:-}"; envf="${2:-}"
{ [ -n "$mode" ] && [ -r "$envf" ]; } || die "usage: sandbox.sh argv|run|check|launch <row-env> [args...]"
shift 2
# shellcheck source=/dev/null
. "$envf"
KEY=""; LAUNCHER=""; CONF=""; EGRESS=()
case "${LANE:-}" in
  deepseek) LAUNCHER="$REPO/scripts/claude-deepseek"; CONF="$HOME/.claude-deepseek"; KEY=DEEPSEEK_API_KEY
            EGRESS=("$HOME/.config/claude-glm")
            TUN_HOST=api.deepseek.com; TUN_PORT=443; TUN_TARGET=api.deepseek.com:443 ;;
  claudex)  LAUNCHER="$REPO/scripts/claude-codex"; CONF="$HOME/.claude-codex"; KEY=CLIPROXY_API_KEY
            EGRESS=("$HOME/.config/claude-codex" "$HOME/.config/claude-glm")
            hp="${CODEX_PROXY_BASE_URL:-http://127.0.0.1:8317}"; hp="${hp#*://}"; hp="${hp%%/*}"
            case "$hp" in 127.0.0.1:[0-9]*|localhost:[0-9]*) ;; *) die "claudex proxy '$hp' is not a local host:port" ;; esac
            TUN_HOST=""; TUN_PORT="${hp##*:}"; TUN_TARGET="127.0.0.1:$TUN_PORT" ;;
  native)   [ "$mode" = check ] || die "a native row runs unsandboxed; only its acceptor runs in the jail (check)" ;;
  *) die "unknown lane '${LANE:-}'" ;;
esac
for v in REPO WT DOC RUN TX ROWCONF EXPORT GITOBJ GITDIR; do [ -n "${!v:-}" ] || die "$envf has no $v"; done
[ -d "$EXPORT/.git" ] || die "no repo export at $EXPORT (pilot.sh prepare makes it)"

# Never put back a path that is, or sits under, one of these.
HIDDEN="(/Documents/(luna|salus)(/|$)|/\.claude/projects(/|$)|/\.himmel(/|$)|/handovers(/|$))"

# A mount point under $REPO must exist in the read-only export; make it there.
mnt() { # $1 jail path, $2 dir|file
  case "$1" in
    "$REPO"/*)
      local p="$EXPORT${1#"$REPO"}"
      if [ "$2" = dir ]; then mkdir -p "$p"; else mkdir -p "$(dirname "$p")" && { [ -e "$p" ] || : >"$p"; }; fi \
        || die "cannot make the mount point $p" ;;
  esac
}

A=(--die-with-parent --unshare-all --ro-bind / / --dev /dev --proc /proc)
# /var/lib holds core dumps (process env tokens), /var/spool the crontabs.
for d in /home /tmp /var/tmp /run /var/log /var/lib /var/spool /var/cache /mnt /media "$HOME"; do
  [ -d "$d" ] && A+=(--tmpfs "$d")
done
A+=(--ro-bind /dev/null /run/lq-pilot-jail)
# Toolchain under $HOME: every PATH entry there, plus the claude install.
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}" "$HOME/.local/share/claude"; do
  case "$d" in "$HOME"/*) ;; *) continue ;; esac
  printf '%s\n' "$d" | grep -qE "$HIDDEN" && continue
  case "$d" in "$REPO"|"$REPO"/*) continue ;; esac
  A+=(--ro-bind-try "$d" "$d")
done
# The repo: tracked files only, from the export. Its .git is a stub so the
# launcher's rev-parse works; the shared objects, refs and packed-refs come
# back read-only, and new objects land in the row's own object dir.
A+=(--ro-bind "$EXPORT" "$REPO")
# The lane writes the row object dir, so the host never writes into it (a
# symlink planted there would take the write out of the jail): the alternates
# file comes from the run dir, read-only, bound over the lane's copy.
{ [ -d "$GITOBJ" ] && [ ! -L "$GITOBJ" ]; } || die "row object dir $GITOBJ is missing or a symlink (pilot.sh prepare makes it)"
for p in "$GITOBJ/info" "$GITOBJ/info/alternates"; do [ ! -L "$p" ] || die "$p is a symlink"; done
[ ! -e "$GITOBJ/info" ] || [ -d "$GITOBJ/info" ] || die "$GITOBJ/info is not a dir"
printf '%s\n' "$REPO/.git/host-objects" >"$RUN/alternates" || die "cannot write $RUN/alternates"
mnt "$REPO/.git/host-objects" dir
A+=(--ro-bind "$REPO/.git/objects" "$REPO/.git/host-objects" --bind "$GITOBJ" "$REPO/.git/objects")
A+=(--ro-bind "$RUN/alternates" "$REPO/.git/objects/info/alternates")
A+=(--ro-bind "$REPO/.git/refs" "$REPO/.git/refs")
if [ -f "$REPO/.git/packed-refs" ]; then mnt "$REPO/.git/packed-refs" file; A+=(--ro-bind "$REPO/.git/packed-refs" "$REPO/.git/packed-refs"); fi
# The row's git dir is the one prepare recorded (its own shared clone's), never
# what the worktree's .git file (which the lane can rewrite) says now: a
# repointed .git or an added commondir would otherwise bind the primary .git.
case "$GITDIR" in */..|*/../*|"$REPO"|"$REPO"/*) die "git dir $GITDIR is not the row's own" ;; /*) ;; *) die "git dir $GITDIR is not absolute" ;; esac
{ [ -d "$GITDIR" ] && [ ! -L "$GITDIR" ]; } || die "git dir $GITDIR is missing or a symlink"
[ "$(cat "$WT/.git" 2>/dev/null)" = "gitdir: $GITDIR" ] || die "$WT/.git no longer points at $GITDIR"
{ [ ! -e "$GITDIR/commondir" ] && [ ! -L "$GITDIR/commondir" ]; } || die "$GITDIR has a commondir"
mnt "$WT" dir
A+=(--bind "$WT" "$WT" --bind "$GITDIR" "$GITDIR")
# The row lives outside the checkout (clean-garden scans .claude/worktrees),
# but the lane launcher only serves a cwd under the checkout: the jail shows
# the row there too, and a launch starts in it.
JWT="$REPO/.claude/worktrees/${WT##*/}"
mnt "$JWT" dir
A+=(--bind "$WT" "$JWT")

if [ "$mode" = check ]; then
  # The acceptor jail: the kit it runs, read-only, and nothing of the lane.
  for d in "$HERE/.." "$HERE/../../../lanes/bench/fixtures/T4"; do
    d="$(cd "$d" && pwd)" || die "no kit dir $d"
    mnt "$d" dir; A+=(--ro-bind "$d" "$d")
  done
else
  # User settings with every plugin and MCP server removed (qmd, obsidian, ...).
  if [ -f "$HOME/.claude/settings.json" ]; then
    # HIMMEL-5077: claudex's classifier runs client-side on the codex model and over-reads
    # the rm -rf deny rule. The row's own test scripts get a jail-only PreToolUse hook
    # (lq-allow-hook.sh; a permissions.allow glob's `*` would cross `/` and `..`) and
    # own-file rewrites an autoMode.allow line. The deny list stays.
    if [ "$LANE" = claudex ]; then
      cp "$HERE/lq-allow-hook.sh" "$RUN/lq-allow-hook.sh" || die "cannot copy the allow hook"
    fi
    jq --arg lane "$LANE" --arg wt "$WT" --arg jwt "$JWT" --arg hook "$RUN/lq-allow-hook.sh" \
      'del(.enabledPlugins, .mcpServers, .enabledMcpjsonServers, .enableAllProjectMcpServers)
       | if $lane == "claudex" then
           .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \([$hook, $jwt, $wt] | map(@sh) | join(" "))"}]}])
           | .autoMode.allow = ((.autoMode.allow // ["$defaults"]) + ["Editing or rewriting files inside the task'"'"'s own working directory (\($jwt)/lq-work) is routine work, not destruction: lq-work is a disposable eval copy"])
         else . end' \
      "$HOME/.claude/settings.json" >"$RUN/user-settings.json" || die "cannot filter the user settings"
    A+=(--ro-bind "$RUN/user-settings.json" "$HOME/.claude/settings.json")
  fi
  # What the lane mirror seeds the lane config from (scripts/lane-mirror-seed.sh)
  # and nothing else: plugins/data and the plugin caches stay out.
  for s in CLAUDE.md RTK.md claude-hud.json commands skills hooks agents \
           plugins/installed_plugins.json plugins/known_marketplaces.json plugins/marketplaces plugins/claude-hud/config.json; do
    A+=(--ro-bind-try "$HOME/.claude/$s" "$HOME/.claude/$s")
  done
  for d in "${EGRESS[@]}"; do A+=(--ro-bind-try "$d" "$d"); done
  A+=(--bind "$(dirname "$DOC")" "$(dirname "$DOC")" --ro-bind "$RUN" "$RUN")
  A+=(--bind "$ROWCONF" "$CONF" --bind "$TX" "$CONF/projects")
  { printf '127.0.0.1 localhost\n::1 localhost\n'; if [ -n "$TUN_HOST" ]; then printf '127.0.0.1 %s\n' "$TUN_HOST"; fi; } >"$RUN/hosts" \
    || die "cannot write $RUN/hosts"
  A+=(--ro-bind "$RUN/hosts" /etc/hosts)
fi
# Every guarded root gets an EMPTY placeholder: the launcher's egress check
# resolves each one (realpath) and fails closed when it is missing, and an
# empty mount also hides a guarded root that sits outside the trees above.
roots=("$HOME/Documents/luna" "$HOME/Documents/salus" "${LUNA_VAULT:-}" "${LUNA_VAULT_PATH:-}")
for d in "${EGRESS[@]}"; do
  for f in "$d/phi-roots" "$d/egress-denylist"; do
    [ -f "$f" ] && while IFS= read -r r; do roots+=("$r"); done <"$f"
  done
done
for r in "${roots[@]}"; do
  case "$r" in /*) ;; *) continue ;; esac
  if [ -d "$r" ]; then A+=(--tmpfs "$r"); elif [ -e "$r" ]; then A+=(--ro-bind /dev/null "$r"); fi
done

# The environment: only the terminal basics and the harness and lane families
# reach the jail, minus anything credential-shaped except the lane key itself
# (and not even that in the acceptor jail). Names go in the argv, never values.
KEEP='^(PATH|HOME|USER|LOGNAME|SHELL|TERM|COLORTERM|LANG|LANGUAGE|LC_[A-Z]+|TZ|NO_COLOR|FORCE_COLOR|(HIMMEL|LEG|HANDOVER|CLAUDE|ANTHROPIC|CODEX|DEEPSEEK|HEADED_ARM_LEG|LUNA_VAULT)[A-Z0-9_]*)$'
SECRET='TOKEN|SECRET|PASSW|CREDENTIAL|COOKIE|API_KEY|AUTH'
while IFS= read -r v; do
  [ "$mode" != check ] && [ "$v" = "$KEY" ] && continue
  if ! printf '%s\n' "$v" | grep -qE "$KEEP" || printf '%s\n' "$v" | grep -qE "$SECRET"; then
    A+=(--unsetenv "$v")
  fi
done < <(compgen -e)

# HIMMEL-5183: the row must not rewrite its own permission policy. ROWCONF stays
# writable (the launcher writes its mirror and runtime state there), but the seeded
# settings.json and the hooks dir it references come back read-only. The launcher seeds
# them OUTSIDE the lane: a first jail with the same mounts (so the seed fingerprint
# matches the lane's view) runs `<launcher> --seed-only` with a dummy key and exits; the
# lane's own launch then finds a current seed and writes neither file. The seed runs in
# the jail, never on the host, so a symlink a row planted cannot take a host write out;
# a planted symlink is refused before the seed and again before the bind.
if [ "$mode" != check ]; then
  for p in settings.json hooks; do [ ! -L "$ROWCONF/$p" ] || die "$ROWCONF/$p is a symlink"; done
  if [ "$mode" != argv ]; then
    mkdir -p "$ROWCONF" "$TX" || die "cannot create $ROWCONF or $TX"
    env "$KEY=seed-only" bwrap "${A[@]}" --chdir "$JWT" -- "$LAUNCHER" --seed-only >/dev/null \
      || die "the lane config seed failed (launcher --seed-only)"
    for p in settings.json hooks; do [ ! -L "$ROWCONF/$p" ] || die "$ROWCONF/$p is a symlink"; done
    # A launcher that seeded no policy still gets one bound: the row cannot create its own.
    [ -f "$ROWCONF/settings.json" ] || { printf '{}\n' >"$RUN/empty-settings.json" || die "cannot write $RUN/empty-settings.json"; }
    [ -d "$ROWCONF/hooks" ] || mkdir -p "$RUN/empty-hooks" || die "cannot create $RUN/empty-hooks"
  fi
  if [ "$mode" != argv ] && [ ! -f "$ROWCONF/settings.json" ]; then s_src="$RUN/empty-settings.json"; else s_src="$ROWCONF/settings.json"; fi
  if [ "$mode" != argv ] && [ ! -d "$ROWCONF/hooks" ]; then h_src="$RUN/empty-hooks"; else h_src="$ROWCONF/hooks"; fi
  A+=(--ro-bind "$s_src" "$CONF/settings.json" --ro-bind "$h_src" "$CONF/hooks")
fi

# The jail must not put back anything it exists to hide.
i=0
while [ "$i" -lt "${#A[@]}" ]; do
  case "${A[$i]}" in
    --bind|--ro-bind|--ro-bind-try)
      w="${A[$((i + 1))]}" # the source decides what the jail can read
      if [ "$w" != /dev/null ]; then
        printf '%s\n' "$w" | grep -qE "/Documents/(luna|salus)(/|$)|/\.claude/projects(/|$)|/\.himmel/state(/|$)" && die "refusing a bind of a hidden path: $w"
        [ "$w" = "$REPO" ] && die "refusing a bind of the primary checkout: $w"
        for r in "${roots[@]}"; do
          case "$r" in /*) case "$w" in "$r"|"$r"/*) die "refusing a bind of a guarded root: $w" ;; esac ;; esac
        done
      fi
      i=$((i + 3)) ;;
    *) i=$((i + 1)) ;;
  esac
done

# The launch: a user+net namespace whose loopback carries the tunnel's inner
# end (it may bind a low port there), then bwrap with every capability dropped.
# A unix socket path is capped at 108 bytes, so a launch puts the socket in a
# short private dir of its own (the inner end connects before bwrap hides /tmp).
sock="$RUN/tunnel.sock"; sockdir=""
if [ "$mode" = launch ]; then
  sockdir="$(mktemp -d /tmp/lq-tun.XXXXXX)" || die "cannot create the tunnel dir"
  sock="$sockdir/s"; trap 'rm -rf "$sockdir"' EXIT
fi
# shellcheck disable=SC2016 # expanded by the inner shell, from its own arguments
INNER='ip link set lo up || exit 1
setpriv --pdeathsig KILL socat TCP-LISTEN:"$1",bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:"$2" &
want="$(printf ":%04X 00000000:0000 0A" "$1")"; n=0
until grep -q "$want" /proc/net/tcp; do n=$((n + 1)); [ "$n" -lt 50 ] || exit 1; sleep 0.1; done
shift 2; exec setpriv --ambient-caps -all --inh-caps -all "$@"'
L=(unshare --user --map-current-user --net --keep-caps bash -c "$INNER" tunnel "${TUN_PORT:-}" "$sock" bwrap "${A[@]}" --share-net)

case "$mode" in
  argv) printf '%s\n' "${L[@]}" ;;
  run|check) [ $# -gt 0 ] || die "$mode needs a command"; exec bwrap "${A[@]}" --chdir "$WT" -- "$@" ;;
  launch)
    mkdir -p "$ROWCONF" "$TX" || die "cannot create $ROWCONF or $TX"
    # The jailed claude runs at $JWT with $ROWCONF as its lane config, so the folder-trust
    # flag (HIMMEL-5068) must be seeded there, under that exact key; non-fatal like the caller's.
    LEG_PRETRUST_CONFIG="$ROWCONF/.claude.json" LEG_PRETRUST_KEY="$JWT" \
      bash "$REPO/scripts/handover/console-kit/leg-pretrust.sh" "$LANE" "$WT" \
      || echo "pilot-sandbox: warning: could not pre-trust $JWT in $ROWCONF" >&2
    if [ -z "${!KEY:-}" ]; then
      # shellcheck source=/dev/null
      . "$REPO/scripts/lib/load-dotenv.sh"
      load_dotenv --root "$(_load_dotenv_primary_for "$REPO")" "$KEY"
      val="${!KEY:-}"; val="${val#[\"\']}"; val="${val%[\"\']}"
      [ -n "$val" ] || die "$KEY is not set and the primary dotenv file has none"
      export "$KEY=$val"
    fi
    socat UNIX-LISTEN:"$sock",fork,mode=600 TCP:"${PILOT_SANDBOX_TUNNEL_TARGET:-$TUN_TARGET}" & spid=$!
    trap 'kill "$spid" 2>/dev/null; rm -rf "$sockdir"' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    n=0; until [ -S "$sock" ]; do n=$((n + 1)); [ "$n" -lt 50 ] || die "the tunnel socket never appeared"; sleep 0.1; done
    case "$PWD" in "$WT"|"$WT"/*) cwd="$JWT${PWD#"$WT"}" ;; *) cwd="$PWD" ;; esac
    "${L[@]}" --chdir "$cwd" -- "$LAUNCHER" "$@"
    exit $? ;;
  *) die "unknown mode '$mode'" ;;
esac
