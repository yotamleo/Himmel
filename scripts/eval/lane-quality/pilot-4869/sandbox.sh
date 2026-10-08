#!/usr/bin/env bash
# scripts/eval/lane-quality/pilot-4869/sandbox.sh - the bubblewrap jail a
# deepseek or claudex pilot row runs in. A third-party model must never reach
# the vaults, PHI, the operator's memory, the bank state or a real handover
# root, so the row sees an empty /home, /tmp and /run/user with only these put
# back:
#   read-write  the row's worktree (+ its git admin dir), the row doc dir, the
#               lane config dir (its projects/ replaced by the row's own
#               transcript dir) - nothing else is writable;
#   read-only   the repo (its dotenv file masked, handovers/ emptied), the
#               row's run dir (launch settings and preface), the ~/.claude
#               items the lane mirror seeds from, the lane's egress config,
#               and the toolchain on PATH under $HOME.
# The network stays on (the lane talks to its API). The lane's API key is read
# OUTSIDE the jail and passed in the environment, so no dotenv file is visible.
#
# Usage:
#   sandbox.sh argv <row-env>             print the bwrap argv, one word per line
#   sandbox.sh run <row-env> <cmd...>     run <cmd> in the row's jail (probes)
#   sandbox.sh launch <row-env> <args...> run the lane launcher in the jail
# The row's <row>.sandbox wrapper (written by `pilot.sh prepare`) calls
# `launch`; headed-arm-leg.sh reaches it through HEADED_ARM_LEG_<LANE>_BIN.
set -u
die() { echo "pilot-sandbox: $*" >&2; exit 1; }

mode="${1:-}"; envf="${2:-}"
{ [ -n "$mode" ] && [ -r "$envf" ]; } || die "usage: sandbox.sh argv|run|launch <row-env> [args...]"
shift 2
# shellcheck source=/dev/null
. "$envf"
case "${LANE:-}" in
  deepseek) LAUNCHER="$REPO/scripts/claude-deepseek"; CONF="$HOME/.claude-deepseek"; KEY=DEEPSEEK_API_KEY
            EGRESS=("$HOME/.config/claude-glm") ;;
  claudex)  LAUNCHER="$REPO/scripts/claude-codex"; CONF="$HOME/.claude-codex"; KEY=CLIPROXY_API_KEY
            EGRESS=("$HOME/.config/claude-codex" "$HOME/.config/claude-glm") ;;
  *) die "lane '${LANE:-}' runs unsandboxed; only deepseek and claudex rows have a jail" ;;
esac
for v in REPO WT DOC RUN TX; do [ -n "${!v:-}" ] || die "$envf has no $v"; done

# Never put back a path that is, or sits under, one of these.
HIDDEN="(/Documents/(luna|salus)(/|$)|/\.claude/projects(/|$)|/\.himmel(/|$)|/handovers(/|$))"

A=(--die-with-parent --unshare-all --share-net --ro-bind / / --dev /dev --proc /proc)
for d in /home /tmp /var/tmp /run/user /mnt /media "$HOME"; do
  [ -d "$d" ] && A+=(--tmpfs "$d")
done
# Toolchain under $HOME: every PATH entry there, plus the claude install.
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}" "$HOME/.local/share/claude"; do
  case "$d" in "$HOME"/*) ;; *) continue ;; esac
  printf '%s\n' "$d" | grep -qE "$HIDDEN" && continue
  case "$d" in "$REPO"|"$REPO"/*) continue ;; esac
  A+=(--ro-bind-try "$d" "$d")
done
# What the lane mirror seeds the lane config from (scripts/lane-mirror-seed.sh).
for s in settings.json CLAUDE.md RTK.md claude-hud.json commands skills hooks agents plugins; do
  A+=(--ro-bind-try "$HOME/.claude/$s" "$HOME/.claude/$s")
done
for d in "${EGRESS[@]}"; do A+=(--ro-bind-try "$d" "$d"); done
A+=(--ro-bind "$REPO" "$REPO")
[ -e "$REPO/.env" ] && A+=(--ro-bind /dev/null "$REPO/.env")
[ -d "$REPO/handovers" ] && A+=(--tmpfs "$REPO/handovers")
# Nothing to crib from: the eval kits (acceptors, references, expected
# outputs), the bench fixtures and every other worktree (the row's own is
# bound back below). ponytail: the shared object store under $REPO/.git stays
# readable (the row's worktree needs it), so `git show <ref>:scripts/eval/...`
# still reaches the kit; the transcript's `peeked` flag DEFERs such a row.
for d in scripts/eval scripts/lanes/bench/fixtures .claude/worktrees; do
  [ -d "$REPO/$d" ] && A+=(--tmpfs "$REPO/$d")
done
gitdir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || die "$WT is not a git worktree"
A+=(--bind "$WT" "$WT" --bind "$gitdir" "$gitdir")
A+=(--bind "$(dirname "$DOC")" "$(dirname "$DOC")" --ro-bind "$RUN" "$RUN")
A+=(--bind "$CONF" "$CONF" --bind "$TX" "$CONF/projects")
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
# reach the jail, minus anything credential-shaped except the lane key itself.
# Names go in the argv, never values (bwrap unsets them from its own env).
KEEP='^(PATH|HOME|USER|LOGNAME|SHELL|TERM|COLORTERM|LANG|LANGUAGE|LC_[A-Z]+|TZ|NO_COLOR|FORCE_COLOR|(HIMMEL|LEG|HANDOVER|CLAUDE|ANTHROPIC|CODEX|DEEPSEEK|HEADED_ARM_LEG|LUNA_VAULT)[A-Z0-9_]*)$'
SECRET='TOKEN|SECRET|PASSW|CREDENTIAL|COOKIE|API_KEY|AUTH'
while IFS= read -r v; do
  [ "$v" = "$KEY" ] && continue
  if ! printf '%s\n' "$v" | grep -qE "$KEEP" || printf '%s\n' "$v" | grep -qE "$SECRET"; then
    A+=(--unsetenv "$v")
  fi
done < <(compgen -e)

# The jail must not put back anything it exists to hide.
i=0
while [ "$i" -lt "${#A[@]}" ]; do
  case "${A[$i]}" in
    --bind|--ro-bind|--ro-bind-try)
      w="${A[$((i + 1))]}" # the source decides what the jail can read
      if [ "$w" != /dev/null ]; then
        printf '%s\n' "$w" | grep -qE "/Documents/(luna|salus)(/|$)|/\.claude/projects(/|$)|/\.himmel/state(/|$)" && die "refusing a bind of a hidden path: $w"
        for r in "${roots[@]}"; do
          case "$r" in /*) case "$w" in "$r"|"$r"/*) die "refusing a bind of a guarded root: $w" ;; esac ;; esac
        done
      fi
      i=$((i + 3)) ;;
    *) i=$((i + 1)) ;;
  esac
done

case "$mode" in
  argv) printf '%s\n' bwrap "${A[@]}" ;;
  run) [ $# -gt 0 ] || die "run needs a command"; exec bwrap "${A[@]}" --chdir "$WT" -- "$@" ;;
  launch)
    mkdir -p "$CONF" "$TX" || die "cannot create $CONF or $TX"
    if [ -z "${!KEY:-}" ]; then
      # shellcheck source=/dev/null
      . "$REPO/scripts/lib/load-dotenv.sh"
      load_dotenv --root "$(_load_dotenv_primary_for "$REPO")" "$KEY"
      val="${!KEY:-}"; val="${val#[\"\']}"; val="${val%[\"\']}"
      [ -n "$val" ] || die "$KEY is not set and the primary dotenv file has none"
      export "$KEY=$val"
    fi
    exec bwrap "${A[@]}" --chdir "$PWD" -- "$LAUNCHER" "$@" ;;
  *) die "unknown mode '$mode'" ;;
esac
