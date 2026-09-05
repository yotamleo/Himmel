#!/usr/bin/env bash
# uninstall.sh — offboard the himmel operator surface (HIMMEL-227).
# Symmetric teardown of what setup.sh + install-plugins.sh onboard:
#
#   [1/7] stop the telegram bun bridge      (bun supervisor.ts --kill)
#   [2/7] remove telegram pairing + bridge state
#         (channel dir incl. access.json + bot-token .env; bridge root)
#   [3/7] remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge
#         logon task on Windows)
#   [4/7] uninstall Claude plugins + marketplaces
#         (machine-setup/uninstall-plugins.sh — user-scope, affects all repos)
#   [5/7] uninstall git hooks (pre-commit/pre-push/commit-msg)
#   [6/7] unwire ~/.claude/settings.json (statusLine, env.HIMMEL_REPO,
#         env.LUNA_VAULT_PATH, env.HANDOVER_DIR, the UNIVERSAL hooks — what
#         setup.sh/adopt wired)
#   [7/7] remove the himmelctl cache + state dir ~/.claude/himmel
#         (install-profile.json, state.json — HIMMEL-2459)
#
# Removes ONLY (HIMMEL-2505 — the fixed target set, no discovery/globbing):
#   $HOME/.claude/channels/telegram (or $TELEGRAM_CHANNEL_DIR)
#   $HOME/.claude/handover/bridge   (or $BRIDGE_ROOT)
#   $HOME/.claude/himmel            (or $HIMMELCTL_CACHE_DIR)
# An override pointing INSIDE a protected location (e.g. $HOME/.ssh,
# $HOME/Documents) is refused unless it names exactly one of these three.
#
# Destructive. Fail-closed: without --yes an interactive run prompts; a
# non-interactive run aborts (rc=2). --dry-run prints every action without
# executing anything. A WET run (no --dry-run) additionally refuses to run
# at all against what looks like a live operator $HOME unless
# HIMMEL_UNINSTALL_REAL_HOME=1 is set (rc=3) — see Env below (HIMMEL-2505,
# after the 2026-09-03 incident where a mutation-test run swept the
# operator's real ~/.claude, ~/.ssh, ~/.gitconfig, ~/.codex, ~/.local).
#
# Usage:
#   bash scripts/uninstall.sh [--dry-run] [--yes]
#        [--keep-telegram-state] [--skip-plugins] [--skip-tasks] [--skip-hooks]
#        [--skip-settings]
#
# Flags:
#   --dry-run              Print actions instead of running them.
#   --yes                  Skip the confirmation prompt.
#   --keep-telegram-state  Keep the channel dir (token + access.json) and
#                          bridge state; still stops the bridge process.
#   --skip-plugins         Keep Claude plugins + marketplaces installed.
#   --skip-tasks           Keep HIMMEL-Resume-* / HimmelTelegramBridge jobs.
#   --skip-hooks           Keep the repo's pre-commit git hooks.
#   --skip-settings        Keep the user-scope ~/.claude/settings.json wiring
#                          (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, hooks).
#   --source-only          Test seam (HIMMEL-2503): define the functions, then
#                          stop before any action — `. uninstall.sh --source-only`.
#
# Env overrides (tests):
#   TELEGRAM_CHANNEL_DIR — default $HOME/.claude/channels/telegram
#   BRIDGE_ROOT          — default $HOME/.claude/handover/bridge
#                          (same var the bridge's bus.ts honors)
#   HIMMEL_USER_SETTINGS — default $HOME/.claude/settings.json (the [6/7] target)
#   HIMMELCTL_CACHE_DIR  — default $HOME/.claude/himmel (the [7/7] target;
#                          same var himmelctl itself honors)
#   HIMMEL_UNINSTALL_REAL_HOME — must be "1" for a WET (non-dry-run) run to
#                          proceed when $HOME carries a live-operator marker
#                          (HIMMEL-2505); set by the operator's own shell, or
#                          by the wizard's confirmed teardown spawn
#                          (scripts/himmelctl/bin.js), or by the VM harness.
#
# Exit codes: 0 = done (per-step problems are WARNs); 2 = aborted
# (no confirmation), bad flag, or INCOMPLETE — a step that had to run could
# not, e.g. its tool was unresolvable (HIMMEL-2458), or a removal was refused/
# failed and halted later steps (HIMMEL-2505); 3 = a wet run was refused
# because $HOME looks like a live operator profile (HIMMEL-2505).
# "Uninstall complete." is printed only on 0.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
YES=0
KEEP_TELEGRAM_STATE=0
SKIP_PLUGINS=0
SKIP_TASKS=0
SKIP_HOOKS=0
SKIP_SETTINGS=0
SOURCE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --yes)                 YES=1 ;;
    --keep-telegram-state) KEEP_TELEGRAM_STATE=1 ;;
    --skip-plugins)        SKIP_PLUGINS=1 ;;
    --skip-tasks)          SKIP_TASKS=1 ;;
    --skip-hooks)          SKIP_HOOKS=1 ;;
    --skip-settings)       SKIP_SETTINGS=1 ;;
    --source-only)         SOURCE_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# strip_trailing_slash <path> — HIMMEL-2505 gap A.3: a trailing slash makes
# `cd`/`rm -rf` follow a symlinked directory instead of the removal sites
# treating it as the link itself — strip it right after each removal-target
# var is assigned, below. Never reduces "/" itself.
strip_trailing_slash() {
  local _v="$1"
  while [ "$_v" != "/" ] && [ "${_v%/}" != "$_v" ]; do
    _v="${_v%/}"
  done
  printf '%s\n' "$_v"
}

CHANNEL_DIR="${TELEGRAM_CHANNEL_DIR:-$HOME/.claude/channels/telegram}"
CHANNEL_DIR="$(strip_trailing_slash "$CHANNEL_DIR")"
BRIDGE_ROOT="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
BRIDGE_ROOT="$(strip_trailing_slash "$BRIDGE_ROOT")"
# Test override (HIMMEL_USER_SETTINGS) so the [6/7] settings-unwire can target a
# temp file instead of the operator's real ~/.claude/settings.json.
USER_SETTINGS="${HIMMEL_USER_SETTINGS:-$HOME/.claude/settings.json}"
# Same override himmelctl reads (scripts/himmelctl/bin.js) — pointing one at a
# temp dir must point the other there too, or uninstall would delete the real
# cache during a test.
HIMMEL_CACHE_DIR="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}"
HIMMEL_CACHE_DIR="$(strip_trailing_slash "$HIMMEL_CACHE_DIR")"

# Steps that HAD to run and could not. Non-empty ⇒ rc=2 and no completion
# claim (HIMMEL-2458).
STEPS_INCOMPLETE=()

# HIMMEL-2505: set the moment [2/7] or [7/7] refuses or fails to remove a
# target. Every LATER step that removes or unwires ([4/7]-[7/7]) checks this
# FIRST and skips instead of running — a partial teardown is safer left in
# place than guessed past.
HALTED=0

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# canonicalize_target <path> — echo a canonical absolute path for comparison
# purposes only (HIMMEL-2505's protected_path). Bash 3.2-safe (no `realpath`).
# An EXISTING path resolves the same way suspicious_rm_path always has: `cd …
# && pwd -P` on a dir, or the same on its parent with the basename re-appended
# for a file/symlink (so a dangling symlink, where `-e` is false, is still
# treated as present rather than walked past). A path that does NOT exist yet
# walks UP to the nearest EXISTING ancestor, canonicalizes THAT, and
# re-appends every missing path segment in order — so
# "$HOME/.claude/himmel" (not yet created) still canonicalizes to
# ".../.claude/himmel", not to its existing parent "$HOME/.claude" alone.
# Returns 1 (echoing nothing) when no ancestor at all can be resolved.
canonicalize_target() {
  local _t="$1" _tail="" _cur _resolved _base
  [ -n "$_t" ] || return 1
  _cur="$_t"
  while [ "$_cur" != "/" ] && [ ! -e "$_cur" ] && [ ! -L "$_cur" ]; do
    _base=$(basename -- "$_cur")
    if [ -z "$_tail" ]; then _tail="$_base"; else _tail="$_base/$_tail"; fi
    _cur=$(dirname -- "$_cur")
  done
  if [ -d "$_cur" ]; then
    _resolved=$(cd -- "$_cur" 2>/dev/null && pwd -P) || return 1
  else
    _base=$(basename -- "$_cur")
    _resolved=$(cd -- "$(dirname -- "$_cur")" 2>/dev/null && pwd -P) || return 1
    _resolved="$_resolved/$_base"
  fi
  if [ -n "$_tail" ]; then
    printf '%s/%s\n' "$_resolved" "$_tail"
  else
    printf '%s\n' "$_resolved"
  fi
}

# normalize_lexical <path> — HIMMEL-2505 (revised): pure STRING
# normalization, NO filesystem access at all: collapse repeated "/", drop
# "/./" segments, resolve ".." segments lexically by popping the previous
# segment (never touches disk to confirm what it popped), and strip a
# trailing "/". $HOME itself is never resolved by this — callers compare its
# output against literal "$HOME/<suffix>" strings, $HOME used exactly as
# given. Says nothing about symlinks on disk; that's the separate
# target_has_symlinked_component_below_home check, paired with this one in
# protected_path below. Returns 1 (echoing nothing) only on an empty input.
normalize_lexical() {
  local _t="$1" _rest _seg _abs=0
  [ -n "$_t" ] || return 1
  case "$_t" in
    /*) _abs=1 ;;
  esac
  local _stack=()
  _rest="$_t"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      */*) _seg="${_rest%%/*}"; _rest="${_rest#*/}" ;;
      *)   _seg="$_rest"; _rest="" ;;
    esac
    case "$_seg" in
      ""|".") continue ;;
      "..")
        if [ "${#_stack[@]}" -gt 0 ]; then
          unset "_stack[$((${#_stack[@]} - 1))]"
        fi
        ;;
      *) _stack+=("$_seg") ;;
    esac
  done
  local _out="" _s
  for _s in "${_stack[@]}"; do
    if [ -z "$_out" ]; then _out="$_s"; else _out="$_out/$_s"; fi
  done
  if [ "$_abs" -eq 1 ]; then
    printf '/%s\n' "$_out"
  else
    printf '%s\n' "$_out"
  fi
}

# target_has_symlinked_component_below_home <as-spelled path> — HIMMEL-2505
# (revised a third time, gap A's gap's gap): the filesystem half of the
# allowed-target exemption, paired with normalize_lexical above. The caller
# passes the ORIGINAL, un-collapsed target — NOT normalize_lexical's output
# — because collapsing ".." lexically before this walk is exactly what let a
# target dodge it: "$HOME/.claude/link/../himmel" lexically collapses to
# "$HOME/.claude/himmel" (an allowed suffix) while the REAL removal follows
# the ORIGINAL spelling, resolving "link" to wherever it points FIRST and
# applying ".." relative to THAT. This walk inspects the as-spelled
# components in order (after collapsing only "//" and "/./" noise — NEVER
# ".." — so cosmetic slash/dot variation can't fool the "$HOME/" prefix test
# below): "" and "." are skipped, ".." pops the running path lexically,
# anything else is appended and tested — so a symlinked component is always
# tested BEFORE a later ".." can pop it out of the walk. Returns success
# (0 = true = blocked) the moment an EXISTING component — the leaf included
# — is itself a symlink; a component that does not exist yet is skipped, not
# treated as a block, since nothing not-yet-created could have redirected
# the walk. protected_path only ever calls this once the LEXICAL form has
# already matched an allowed suffix, so "can't confirm this reaches $HOME
# safely" must mean BLOCKED, not "no symlink found" — two cases the walk
# used to hand back as 1 (safe) and now refuses (0) instead: the as-spelled
# target not literally starting with "$HOME/" at all (e.g.
# "$TMP/link/../home/.claude/himmel" where "link" is a SIBLING symlink
# outside $HOME — never even reaches $HOME as spelled, so the real removal
# follows "link", not $HOME), and a ".." that would pop the running path
# ABOVE $HOME (popping back down to exactly $HOME stays fine — nothing
# above $HOME is ever in scope for this exemption).
target_has_symlinked_component_below_home() {
  local _t="$1" _rel _cur _seg _rest _norm="" _abs=0
  case "$_t" in /*) _abs=1 ;; esac
  _rest="$_t"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      */*) _seg="${_rest%%/*}"; _rest="${_rest#*/}" ;;
      *)   _seg="$_rest"; _rest="" ;;
    esac
    case "$_seg" in
      ""|".") continue ;;
      *) if [ -z "$_norm" ]; then _norm="$_seg"; else _norm="$_norm/$_seg"; fi ;;
    esac
  done
  [ "$_abs" -eq 1 ] && _norm="/$_norm"
  case "$_norm" in
    "$HOME"/*) _rel="${_norm#"$HOME"/}" ;;
    *) return 0 ;;
  esac
  _cur="$HOME"
  while [ -n "$_rel" ]; do
    case "$_rel" in
      */*) _seg="${_rel%%/*}"; _rel="${_rel#*/}" ;;
      *)   _seg="$_rel"; _rel="" ;;
    esac
    case "$_seg" in
      ""|".") continue ;;
      "..")
        # A ".." while AT $HOME would pop ABOVE it — refuse; popping DOWN to
        # exactly $HOME (from one level below) stays fine.
        [ "$_cur" = "$HOME" ] && return 0
        _cur="${_cur%/*}"
        ;;
      *)
        _cur="$_cur/$_seg"
        [ -L "$_cur" ] && return 0
        ;;
    esac
  done
  return 1
}

# protected_path <target> — HIMMEL-2505 (revised again after gap A's own
# gap): a FIXED allowlist-independent hard refusal, distinct from (and
# checked before) suspicious_rm_path's root/$HOME-alias checks below. A
# target is exempted from the protected-set checks below only when its
# pure-lexical spelling (normalize_lexical — no filesystem access) is
# EXACTLY $HOME/<suffix> for one of the three documented removal targets AND
# no path component between $HOME and the leaf (leaf included) is, on disk,
# a symlink (target_has_symlinked_component_below_home) — so neither a
# symlinked ancestor (HIMMEL-2505 gap A: e.g. $HOME/.claude/channels ->
# $HOME/Documents routing the documented telegram target into real user
# data) nor a symlinked leaf can ever satisfy the exemption; anything else
# falls through to the equality/ancestor/descendant checks below. Those
# checks run TWICE — once against the leaf-RESOLVED $_t_resolved (which
# catches $HOME/. and $HOME/../<user>, and a target that resolves INTO a
# protected destination through a symlink), and once against the pure-
# LEXICAL $_t_lexical compared to each protected path's own literal
# "$HOME/..." string (which catches the opposite direction: a non-exempt
# override like "$HOME/.claude/link/data", with "$HOME/.claude/link" a
# symlink OUT of $HOME, resolves to somewhere that matches no protected
# path at all even though, AS SPELLED, it is a strict descendant of
# protected $HOME/.claude and the real removal follows the link —
# HIMMEL-2505 gap 2's own gap). Either form hitting is a refusal. An
# unresolvable target is refused, not assumed safe.
# The symlink walk is handed the ORIGINAL $_target, NOT $_t_lexical: the
# lexical identity check above may use the collapsed form to decide
# WHETHER the suffix matches, but the filesystem walk must see ".."
# spellings as-is or a "link/.." segment can collapse into an allowed
# suffix lexically while the real `rm -rf` — which the kernel resolves
# left-to-right on the ORIGINAL spelling — follows the live symlink FIRST
# and applies ".." relative to wherever it points (HIMMEL-2505 gap A's own
# gap, caught post-merge).
protected_path() {
  local _target="$1" _t_resolved _t_lexical _p _p_resolved _prefix _p_prefix
  local _lex_prefix _p_lex_prefix
  local _allowed=0 _suffix
  _t_resolved=$(canonicalize_target "$_target") || return 0
  [ -n "$_t_resolved" ] || return 0
  # The protected-set equality/ancestor/descendant checks further down run
  # on BOTH the leaf-RESOLVED $_t_resolved (catches $HOME/. and
  # $HOME/../<user>, and a target that resolves INTO a protected destination
  # through a symlink) AND the pure-LEXICAL $_t_lexical (catches the
  # opposite: a target that resolves OUT of a protected location through an
  # ancestor symlink but is, as spelled, still a descendant of it — see
  # header comment). The exemption above also compares the lexical form.
  _t_lexical=$(normalize_lexical "$_target") || _t_lexical=""
  local _protected_paths=(
    "/" "$HOME" "$HOME/.claude" "$HOME/.claude.json" "$HOME/.claude/.credentials.json"
    "$HOME/.claude/settings.json" "$HOME/.claude/plugins" "$HOME/.claude/projects"
    "$HOME/.codex" "$HOME/.ssh" "$HOME/.gitconfig" "$HOME/.config" "$HOME/.local"
    "$HOME/.cache" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc" "$HOME/Documents"
    "/etc" "/usr" "/bin" "/var" "/opt"
  )
  # The three documented removal targets are descendants of protected
  # $HOME/.claude by design and must stay allowed no matter what the
  # descendant check below would otherwise do to them — but only when BOTH
  # conditions in the header comment hold (lexical identity AND no symlinked
  # component). Neither check alone is enough (HIMMEL-2505 gap A).
  local _allowed_suffixes=(
    ".claude/himmel" ".claude/channels/telegram" ".claude/handover/bridge"
  )
  if [ -n "$_t_lexical" ]; then
    for _suffix in "${_allowed_suffixes[@]}"; do
      if [ "$_t_lexical" = "$HOME/$_suffix" ]; then
        _allowed=1
        break
      fi
    done
  fi
  if [ "$_allowed" -eq 1 ]; then
    # A symlinked component below $HOME is refused OUTRIGHT (rc=0), never
    # handed down to the resolved-path checks below: those only know
    # PROTECTED destinations, so an ancestor symlink into an unprotected
    # place (~/.claude/channels -> /tmp/x) would pass them and the recursive
    # removal would follow the link into whatever it points at.
    target_has_symlinked_component_below_home "$_target" && return 0
    return 1
  fi
  _prefix="$_t_resolved/"
  [ -n "$_t_lexical" ] && _lex_prefix="$_t_lexical/"
  for _p in "${_protected_paths[@]}"; do
    _p_resolved=$(canonicalize_target "$_p") || _p_resolved="$_p"
    if [ "$_t_resolved" = "$_p_resolved" ]; then
      return 0
    fi
    # Literal (non-glob) prefix test: quoting the pattern inside a parameter
    # expansion disables its special-character meaning, so a path containing
    # a glob metacharacter can't misfire this check.
    if [ "${_p_resolved#"$_prefix"}" != "$_p_resolved" ]; then
      return 0
    fi
    # Gap 2: the target is a strict DESCENDANT of this protected path —
    # already exempted above if it's one of the three documented targets.
    _p_prefix="$_p_resolved/"
    if [ "${_t_resolved#"$_p_prefix"}" != "$_t_resolved" ]; then
      return 0
    fi
    # Gap 2's own gap: the SAME three checks again, but against the pure-
    # LEXICAL spelling on both sides — $_p is already a literal "$HOME/..."
    # (or root-anchored) string, no resolution needed. Catches a target
    # whose AS-SPELLED path is equal/ancestor/descendant of a protected path
    # even though an ancestor symlink resolves it somewhere else entirely.
    if [ -n "$_t_lexical" ]; then
      if [ "$_t_lexical" = "$_p" ]; then
        return 0
      fi
      if [ "${_p#"$_lex_prefix"}" != "$_p" ]; then
        return 0
      fi
      _p_lex_prefix="$_p/"
      if [ "${_t_lexical#"$_p_lex_prefix"}" != "$_t_lexical" ]; then
        return 0
      fi
    fi
  done
  return 1
}

# Obviously wrong rm -rf target (empty / root / $HOME itself)? rc=0 = yes.
# Checked by the caller (with `continue`, mirroring the ps1 sibling) so a
# refusal is never conflated with an rm FAILURE — the residue WARN must not
# tell the operator to manually remove $HOME.
#
# CANONICALIZE BEFORE COMPARING: the literal match below passes `$HOME/.` and
# `$HOME/../<user>`, both of which resolve TO $HOME and would take the
# operator's home directory with them. `cd … && pwd -P` is the bash 3.2-safe
# canonicalizer (no `realpath` on macOS). Only an EXISTING directory can be
# resolved that way — which is exactly the case that matters, since the callers
# only remove paths that exist.
suspicious_rm_path() {
  local _resolved _home_resolved
  # HIMMEL-2505: protected_path is the hard-refuse allowlist check; every
  # caller of suspicious_rm_path inherits it by running it first here.
  protected_path "$1" && return 0
  case "$1" in
    ""|"/"|"$HOME"|"$HOME/") return 0 ;;
    # A Windows drive root, checked on the RAW argument before any `cd`. The
    # post-canonicalization arm below only fires on a shell where
    # `cd -- "C:/"` actually succeeds and resolves to `/c` (Git Bash/MSYS,
    # verified on this box) — a shell that canonicalizes a drive root some
    # OTHER way would fall through it undetected. Checking the literal
    # spelling first makes the refusal independent of canonicalization
    # behaviour, which is the whole point of a destructive-removal guard.
    # Exact drive-root spellings only (`C:`, `C:/`, `C:\`) — a real subpath
    # like `C:/Users/x` is not a root and must still reach the checks below.
    [A-Za-z]:|[A-Za-z]:/|[A-Za-z]:\\) return 0 ;;
  esac
  if [ -d "$1" ]; then
    _resolved=$(cd -- "$1" 2>/dev/null && pwd -P) || _resolved=""
    _home_resolved=$(cd -- "$HOME" 2>/dev/null && pwd -P) || _home_resolved=""
    # An unresolvable target is not proof it is safe — refuse it.
    [ -n "$_resolved" ] || return 0
    # Refuse anything that IS a filesystem root: `/`, a UNC share root
    # (`//server/share` — long and not $HOME, so only an explicit shape check
    # catches it), and a Windows drive root. MSYS/Git Bash canonicalizes
    # `C:/` (and `D:/`, …) to a bare one-letter top-level path — `/c`, `/d` —
    # not `/`, so the `/` arm above cannot see it; a caller that passes
    # HIMMELCTL_CACHE_DIR=C:/ would otherwise sail past every check here and
    # `rm -rf` the whole drive, the exact class this guard exists to stop.
    # Match the letter class (`/[A-Za-z]`, with or without a trailing slash),
    # not just one specific letter. Refusing a genuine one-letter top-level
    # directory on native Linux (`/c`, `/x`, …) as a side effect is a
    # deliberate fail-closed trade in a destructive-removal guard, not a
    # false positive worth tolerating.
    case "$_resolved" in
      "/") return 0 ;;
      //*/*/*) : ;;                 # deeper than a share root — fine
      //*/*)  return 0 ;;           # exactly //server/share
      /[A-Za-z]|/[A-Za-z]/) return 0 ;;   # exactly /c or /c/ — a drive root
    esac
    if [ -n "$_home_resolved" ] && [ "$_resolved" = "$_home_resolved" ]; then
      return 0
    fi
  fi
  return 1
}

# Where setup.sh / machine-setup put the tools this script drives. A stock
# Ubuntu account has TWO PATH layers — ~/.profile owns ~/.local/bin and applies
# to a login shell, ~/.bashrc owns ~/.bun/bin and early-returns for
# non-interactive shells — so `command -v` alone is blind under
# `ssh host 'cmd'`, cron, CI, or an agent, and steps 4+5 then skipped silently
# while the run still claimed success (HIMMEL-2458; same class as
# HIMMEL-2439's resolve_bun in check-lockfile-integrity.sh).
#
# tool_candidates <name> — echo every place we look, one per line, in order.
# Also printed verbatim when the tool is NOT found, so "where did it look?" is
# answerable from the failure message alone.
tool_candidates() {
  local name="$1"
  command -v "$name" 2>/dev/null || true
  if [ -n "${HOME:-}" ]; then
    printf '%s\n' \
      "$HOME/.local/bin/$name" \
      "$HOME/.bun/bin/$name" \
      "$HOME/.npm-global/bin/$name" \
      "$HOME/.claude/local/$name" \
      "$HOME/.local/share/pipx/venvs/pre-commit/bin/$name"
  fi
  [ -n "${BUN_INSTALL:-}" ] && printf '%s\n' "$BUN_INSTALL/bin/$name"
  return 0
}

# resolve_tool <name> — echo an ABSOLUTE path to the tool, rc=0; rc=1 if absent.
resolve_tool() {
  local name="$1" cand
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -x "$cand" ] || continue
    # `command -v` builds its answer from the matching PATH entry, so a
    # RELATIVE entry yields a relative path — and both call sites run the tool
    # after `cd "$REPO_ROOT"`, where it would resolve against the wrong
    # directory. Normalize before returning (no `realpath`: macOS bash 3.2).
    local _abs
    _abs=$(cd "$(dirname "$cand")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$cand")")
    [ -n "$_abs" ] || continue
    printf '%s\n' "$_abs"
    return 0
  done <<EOF
$(tool_candidates "$name")
EOF
  return 1
}

# report_unresolved <step-label> <tool>: record the gap and say where we looked.
report_unresolved() {
  local step="$1" tool="$2"
  echo "  ERROR: \`$tool\` not found — this step did NOT run." >&2
  echo "  looked in: $(tool_candidates "$tool" | tr '\n' ' ')" >&2
  echo "  Re-run from a login shell (bash -l), or put $tool on PATH." >&2
  STEPS_INCOMPLETE+=("$step: \`$tool\` not found")
}

# HIMMEL-2503: `. scripts/uninstall.sh --source-only` loads everything above —
# the suspicious_rm_path guard in particular — and stops HERE, before the
# banner, the prompt and every step. It exists so a suite can assert the
# guard's return codes in isolation (scripts/test-uninstall-guard.sh) instead
# of proving it through the destructive caller; never mutation-test the guard
# by reverting it in-tree and running test-uninstall.sh, whose wet rows rely
# on it as their only protection.
if [ "$SOURCE_ONLY" -eq 1 ]; then
  # shellcheck disable=SC2317  # the exit is reached only when --source-only is EXECUTED rather than sourced
  return 0 2>/dev/null || exit 0
fi

# --- Wet-run fence (HIMMEL-2505) ---------------------------------------------
# 2026-09-03: a mutation-test run executed this script (no --dry-run) against
# the operator's REAL $HOME and swept ~/.claude, ~/.ssh, ~/.gitconfig,
# ~/.codex, ~/.local. --dry-run is never fenced — nothing is removed under it.
# A WET run is refused, before the banner/prompt/any step, when $HOME carries
# a live-operator marker, unless the caller set HIMMEL_UNINSTALL_REAL_HOME=1
# (the operator's own shell, the himmelctl wizard's confirmed spawn, or the
# VM harness — never a test suite, which must set its own fixture $HOME).
# Markers checked: $HOME/.claude/.credentials.json, $HOME/.claude.json,
# $HOME/.codex (an existing dir OR file counts — a Codex-only profile with no
# other marker must still fence), $HOME/.ssh/id_*, $HOME/.gitconfig.
if [ "$DRY_RUN" -eq 0 ] && [ "${HIMMEL_UNINSTALL_REAL_HOME:-0}" != "1" ]; then
  _live_marker=""
  for _m in "$HOME/.claude/.credentials.json" "$HOME/.claude.json" "$HOME/.codex"; do
    [ -e "$_m" ] && { _live_marker="$_m"; break; }
  done
  if [ -z "$_live_marker" ]; then
    for _m in "$HOME"/.ssh/id_*; do
      [ -e "$_m" ] || continue
      _live_marker="$_m"
      break
    done
  fi
  if [ -z "$_live_marker" ] && [ -e "$HOME/.gitconfig" ]; then
    _live_marker="$HOME/.gitconfig"
  fi
  if [ -n "$_live_marker" ]; then
    echo "ERROR: refusing a wet uninstall — found $_live_marker" >&2
    echo "  This \$HOME ($HOME) looks like a live operator profile, not a test" >&2
    echo "  fixture. A wet uninstall here is refused by default (HIMMEL-2505," >&2
    echo "  after the 2026-09-03 incident where a test run swept a real HOME)." >&2
    echo "" >&2
    echo "  If this really IS the machine to offboard, re-run from your OWN" >&2
    echo "  shell with: HIMMEL_UNINSTALL_REAL_HOME=1 bash scripts/uninstall.sh ..." >&2
    echo "  Otherwise, pass --dry-run to preview without touching anything." >&2
    exit 3
  fi
fi

echo "==> himmel uninstall (offboard)"
echo ""
echo "This will:"
echo "  1. stop the telegram bun bridge (if running)"
if [ "$KEEP_TELEGRAM_STATE" -eq 0 ]; then
  echo "  2. REMOVE telegram pairing + bridge state:"
  echo "       $CHANNEL_DIR   (bot-token .env + access.json)"
  echo "       $BRIDGE_ROOT   (sessions, inbox/outbox, supervisor state)"
else
  echo "  2. keep telegram state (--keep-telegram-state)"
fi
if [ "$SKIP_TASKS" -eq 0 ]; then
  echo "  3. remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge logon task)"
else
  echo "  3. keep scheduled jobs (--skip-tasks)"
fi
if [ "$SKIP_PLUGINS" -eq 0 ]; then
  echo "  4. uninstall Claude plugins + marketplaces from settings-template"
  echo "     (USER-SCOPE: affects every repo on this machine)"
else
  echo "  4. keep Claude plugins (--skip-plugins)"
fi
if [ "$SKIP_HOOKS" -eq 0 ]; then
  echo "  5. uninstall this repo's git hooks (pre-commit/pre-push/commit-msg)"
else
  echo "  5. keep git hooks (--skip-hooks)"
fi
if [ "$SKIP_SETTINGS" -eq 0 ]; then
  echo "  6. unwire ~/.claude/settings.json (statusLine, HIMMEL_REPO,"
  echo "     LUNA_VAULT_PATH, HANDOVER_DIR, UNIVERSAL hooks — non-himmel keys untouched)"
else
  echo "  6. keep ~/.claude/settings.json wiring (--skip-settings)"
fi
echo "  7. REMOVE the himmelctl cache + state: $HIMMEL_CACHE_DIR"
echo "     (install-profile.json, state.json — a re-install would otherwise"
echo "     start from the previous install's profile)"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run — nothing will be executed)"
elif [ "$YES" -ne 1 ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    printf "Proceed? [y/N] "
    read -r _ans
    case "$_ans" in
      [yY]|[yY][eE][sS]) : ;;
      *) echo "Aborted."; exit 2 ;;
    esac
  else
    echo "ERROR: non-interactive run without --yes — aborting (fail-closed)." >&2
    echo "  Re-run with --yes to confirm, or --dry-run to preview." >&2
    exit 2
  fi
fi
echo ""

# --- [1/7] stop the bridge -------------------------------------------------
# Uses the documented cross-platform lever (supervisor.pid under the bridge
# root; see docs/internals/telegram-bridge.md). BRIDGE_ROOT is passed through
# so a non-default root kills the matching bridge, not another one.
# bridge_maybe_running gates step 2: removing state while a supervisor may
# still be live would be recreated by it (and on Windows, locked files make
# the removal fail partway).
bridge_maybe_running=0
echo "[1/7] Stopping telegram bridge..."
if [ ! -f "$BRIDGE_ROOT/supervisor.pid" ]; then
  echo "  no supervisor.pid under $BRIDGE_ROOT — bridge not running, skipping."
elif ! command -v bun >/dev/null 2>&1; then
  echo "  WARN: supervisor.pid exists but bun is not on PATH — cannot stop the bridge." >&2
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win"* ]] \
      || command -v pwsh >/dev/null 2>&1; then
    echo "  Stop it manually: pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly (inspect), then kill." >&2
  else
    echo "  Find the supervisor pid in $BRIDGE_ROOT/supervisor.pid and kill it manually." >&2
  fi
  bridge_maybe_running=1
else
  run env BRIDGE_ROOT="$BRIDGE_ROOT" bun --cwd "$REPO_ROOT/scripts/telegram" supervisor.ts --kill
  _rc=$?
  # --kill rc: 0 = killed/already gone, 1 = pidfile absent (not running),
  # 2 = pidfile unreadable/corrupt OR a signal failed (e.g. EPERM) → bridge
  # MAY still be running (supervisor keeps the pidfile in that case).
  if [ "$DRY_RUN" -eq 0 ] && [ "$_rc" -ge 2 ]; then
    echo "  WARN: supervisor --kill rc=$_rc — bridge may still be running; check manually." >&2
    bridge_maybe_running=1
  fi
fi
echo ""

# --- [2/7] remove telegram pairing + bridge state ----------------------------
echo "[2/7] Removing telegram pairing + bridge state..."
if [ "$KEEP_TELEGRAM_STATE" -eq 1 ]; then
  echo "  kept (--keep-telegram-state)."
elif [ "$bridge_maybe_running" -eq 1 ]; then
  echo "  SKIPPED: step 1 could not stop the bridge — a running supervisor would" >&2
  echo "  recreate (or hold locks on) state under $BRIDGE_ROOT. Kill the bridge" >&2
  echo "  manually, then re-run uninstall." >&2
else
  for _dir in "$CHANNEL_DIR" "$BRIDGE_ROOT"; do
    if [ "$HALTED" -eq 1 ]; then
      echo "  skipped: $_dir (halted after a failed removal)"
      STEPS_INCOMPLETE+=("[2/7] telegram pairing + bridge state: $_dir skipped — halted")
      continue
    fi
    if suspicious_rm_path "$_dir"; then
      echo "  WARN: refusing to remove suspicious path: '$_dir'" >&2
      HALTED=1
      STEPS_INCOMPLETE+=("[2/7] telegram pairing + bridge state: refused a suspicious path ('$_dir')")
      continue
    fi
    if [ -L "$_dir" ]; then
      # HIMMEL-2505 gap A.3: the target is a symlink — unlink the link
      # itself, never `rm -rf` through it into whatever it points at.
      if run rm -f -- "$_dir"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          echo "  removed symlink (link only): $_dir"
        fi
      else
        echo "  WARN: failed to remove $_dir — residue remains; remove it manually." >&2
        HALTED=1
        STEPS_INCOMPLETE+=("[2/7] telegram pairing + bridge state: $_dir could not be removed")
      fi
    elif [ -d "$_dir" ]; then
      if run rm -rf -- "$_dir"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          echo "  removed: $_dir"
        fi
      else
        echo "  WARN: failed to remove $_dir — residue remains; remove it manually." >&2
        HALTED=1
        STEPS_INCOMPLETE+=("[2/7] telegram pairing + bridge state: $_dir could not be removed")
      fi
    else
      echo "  absent, skipping: $_dir"
    fi
  done
  echo "  NOTE: deleting the local token does NOT revoke it — if decommissioning"
  echo "  the bot, revoke the token via @BotFather too."
fi
echo ""

# --- [3/7] remove scheduled jobs ---------------------------------------------
# Mirrors scripts/handover/arm-resume.sh job discovery: schtasks task names
# on Windows; at-job body marker / crontab line marker on Linux/macOS.
echo "[3/7] Removing scheduled jobs (HIMMEL-Resume-*, HimmelTelegramBridge)..."
if [ "$SKIP_TASKS" -eq 1 ]; then
  echo "  kept (--skip-tasks)."
elif [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after a failed removal)"
  STEPS_INCOMPLETE+=("[3/7] scheduled jobs: skipped — halted after a failed removal")
elif command -v schtasks >/dev/null 2>&1; then
  # MSYS_NO_PATHCONV=1 per call (HIMMEL-125): gitbash otherwise mangles
  # /query-style flags into Windows paths before schtasks sees them.
  # Capture the /query rc separately (setup.sh qmd-list precedent): piping
  # straight through grep would mask an enumeration failure as "no tasks".
  _query_out=$(MSYS_NO_PATHCONV=1 schtasks /query /fo CSV /nh 2>&1)
  _query_rc=$?
  if [ "$_query_rc" -ne 0 ]; then
    echo "  WARN: schtasks /query failed (rc=$_query_rc) — cannot enumerate;" >&2
    echo "  HIMMEL-Resume-* / HimmelTelegramBridge tasks may remain." >&2
  else
    # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from schtasks's path-prefixed task names
    _tasks=$(printf '%s\n' "$_query_out" \
      | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
      | tr -d '"\\' | sort -u || true)
    if MSYS_NO_PATHCONV=1 schtasks /query /tn "HimmelTelegramBridge" >/dev/null 2>&1; then
      _tasks=$(printf '%s\nHimmelTelegramBridge' "$_tasks")
    fi
    _found=0
    while IFS= read -r _task; do
      [ -z "$_task" ] && continue
      _found=1
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: schtasks /delete /tn $_task /f"
      elif MSYS_NO_PATHCONV=1 schtasks /delete /tn "$_task" /f >/dev/null 2>&1; then
        echo "  deleted scheduled task: $_task"
      else
        echo "  WARN: failed to delete scheduled task: $_task" >&2
      fi
    done <<EOF
$_tasks
EOF
    [ "$_found" -eq 0 ] && echo "  no matching scheduled tasks found."
  fi
else
  _found=0
  _query_failed=0
  if command -v atq >/dev/null 2>&1; then
    # Capture the atq rc separately — `atq || true` would mask an
    # enumeration failure as "no jobs" (same precedent as above).
    _atq_out=$(atq 2>&1)
    _atq_rc=$?
    if [ "$_atq_rc" -ne 0 ]; then
      _query_failed=1
      echo "  WARN: atq failed (rc=$_atq_rc) — cannot enumerate at jobs; they may remain." >&2
    else
      while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _job_id=$(printf '%s' "$_line" | awk '{print $1}')
        [ -z "$_job_id" ] && continue
        if at -c "$_job_id" 2>/dev/null | grep -q 'HIMMEL-Resume-'; then
          _found=1
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY: atrm $_job_id"
          elif atrm "$_job_id" 2>/dev/null; then
            echo "  removed at job: $_job_id"
          else
            echo "  WARN: failed to remove at job: $_job_id" >&2
          fi
        fi
      done <<EOF
$_atq_out
EOF
    fi
  fi
  if command -v crontab >/dev/null 2>&1; then
    # Snapshot `crontab -l` output + rc FIRST (pipeline-cadence cron_read
    # precedent): piping `crontab -l 2>/dev/null` straight into grep would mask
    # a read failure as "no match", and feeding the rewrite below from a failed
    # (empty) listing would install an EMPTY crontab — wiping every unrelated
    # job. Fail-closed classifier: only rc=1 with empty stderr or the standard
    # "no crontab for <user>" message is trusted as "no crontab installed";
    # anything else WARNs and skips the rewrite.
    _cron_err=$(mktemp)
    _cron_out=$(LC_ALL=C crontab -l 2>"$_cron_err")
    _cron_rc=$?
    if [ "$_cron_rc" -eq 0 ]; then
      case "$_cron_out" in
        *HIMMEL-Resume-*)
          _found=1
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY: crontab — strip lines containing HIMMEL-Resume-"
          # `|| true` inside the group: grep -v exits 1 when every line matched
          # (legit: only HIMMEL lines existed → install an empty crontab); with
          # pipefail that rc would otherwise mask a successful rewrite as failed.
          elif { printf '%s\n' "$_cron_out" | grep -vF 'HIMMEL-Resume-' || true; } | crontab -; then
            echo "  stripped HIMMEL-Resume-* lines from crontab"
          else
            echo "  WARN: failed to rewrite crontab — HIMMEL-Resume-* lines may remain." >&2
          fi
          ;;
      esac
    elif [ "$_cron_rc" -eq 1 ] && { [ ! -s "$_cron_err" ] || grep -qi 'no crontab' "$_cron_err"; }; then
      : # no crontab installed — genuinely nothing to do
    else
      _query_failed=1
      echo "  WARN: crontab -l failed (rc=$_cron_rc) — cannot enumerate cron jobs;" >&2
      echo "  HIMMEL-Resume-* lines may remain." >&2
    fi
    rm -f "$_cron_err"
  fi
  [ "$_found" -eq 0 ] && [ "$_query_failed" -eq 0 ] && echo "  no matching scheduled jobs found."
fi
echo ""

# --- [4/7] uninstall plugins + marketplaces ----------------------------------
echo "[4/7] Uninstalling Claude plugins + marketplaces..."
if [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  kept (--skip-plugins)."
elif [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after a failed removal)"
  STEPS_INCOMPLETE+=("[4/7] Claude plugins + marketplaces: skipped — halted after a failed removal")
elif ! _claude_bin=$(resolve_tool claude); then
  report_unresolved "[4/7] Claude plugins + marketplaces" claude
else
  echo "  using: $_claude_bin"
  _plug_args=()
  [ "$DRY_RUN" -eq 1 ] && _plug_args+=(--dry-run)
  # uninstall-plugins.sh does its own `command -v claude` and hard-exits when
  # it fails, so the resolved directory has to be on the CHILD's PATH — passing
  # the path alone would leave the child just as blind as this script was.
  if ! PATH="$(dirname "$_claude_bin"):$PATH" \
      bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
    echo "  WARN: uninstall-plugins.sh reported failures — re-run it directly to inspect." >&2
    STEPS_INCOMPLETE+=("[4/7] Claude plugins + marketplaces: uninstall-plugins.sh reported failures")
  fi
fi
echo ""

# --- [5/7] uninstall git hooks -------------------------------------------------
# Mirror of setup-hooks.sh / setup.sh step 2.
echo "[5/7] Uninstalling git hooks (this repo)..."
if [ "$SKIP_HOOKS" -eq 1 ]; then
  echo "  kept (--skip-hooks)."
elif [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after a failed removal)"
  STEPS_INCOMPLETE+=("[5/7] git hooks: skipped — halted after a failed removal")
elif ! _precommit_bin=$(resolve_tool pre-commit); then
  report_unresolved "[5/7] git hooks" pre-commit
else
  echo "  using: $_precommit_bin"
  for _hook_type in "" "pre-push" "commit-msg"; do
    if [ -n "$_hook_type" ]; then
      _cmd_args=(--hook-type "$_hook_type")
      _label="--hook-type $_hook_type"
    else
      _cmd_args=()
      _label="pre-commit (default)"
    fi
    if ! (cd "$REPO_ROOT" && run "$_precommit_bin" uninstall ${_cmd_args[@]+"${_cmd_args[@]}"}); then
      echo "  WARN: pre-commit uninstall $_label failed." >&2
      STEPS_INCOMPLETE+=("[5/7] git hooks: pre-commit uninstall $_label failed")
    fi
  done
fi
echo ""

# --- [6/7] unwire user-scope settings.json (HIMMEL-460) ----------------------
# Symmetric inverse of setup.sh [9/10] + adopt --scope user: remove the
# statusLine, env.HIMMEL_REPO, env.LUNA_VAULT_PATH, env.HANDOVER_DIR
# (HIMMEL-839), and the UNIVERSAL hooks that himmel wired into
# ~/.claude/settings.json. Each helper removes ONLY its own key/stanza
# (refuses invalid JSON, preserves every non-himmel key: rtk guard, the
# operator's own hooks, MCP config). --dry-run flows through to each.
echo "[6/7] Unwiring ~/.claude/settings.json (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, HANDOVER_DIR, hooks)..."
_user_settings="$USER_SETTINGS"
if [ "$SKIP_SETTINGS" -eq 1 ]; then
  echo "  kept (--skip-settings)."
elif [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after a failed removal)"
  STEPS_INCOMPLETE+=("[6/7] settings unwire: skipped — halted after a failed removal")
elif [ ! -f "$_user_settings" ]; then
  echo "  no $_user_settings — nothing to unwire."
elif [ "$DRY_RUN" -eq 1 ]; then
  # The single-key unwire helpers have no dry-run flag, so gate at this level to
  # keep --dry-run a true no-op (SC6). unwire-pretooluse-hooks has its own flag.
  echo "DRY: unwire statusLine (himmel), env.HIMMEL_REPO, env.LUNA_VAULT_PATH, env.HANDOVER_DIR from $_user_settings"
  bash "$REPO_ROOT/scripts/lib/unwire-pretooluse-hooks.sh" "$_user_settings" 1 \
    || echo "  WARN: unwire-pretooluse-hooks dry-run reported a problem." >&2
else
  for _unwire in unwire-statusline unwire-himmel-repo unwire-luna-vault unwire-handover-dir; do
    if ! bash "$REPO_ROOT/scripts/lib/$_unwire.sh" "$_user_settings"; then
      echo "  WARN: $_unwire reported a problem; setup-state may remain." >&2
    fi
  done
  bash "$REPO_ROOT/scripts/lib/unwire-pretooluse-hooks.sh" "$_user_settings" \
    || echo "  WARN: unwire-pretooluse-hooks reported a problem." >&2
fi
echo ""

# --- [7/7] remove the himmelctl cache + state (HIMMEL-2459) ------------------
# install-profile.json + state.json survived a COMPLETE uninstall, so a
# re-install started against the PREVIOUS install's profile and state ledger.
# Honours HIMMELCTL_CACHE_DIR, the same override himmelctl itself reads.
echo "[7/7] Removing himmelctl cache + state ($HIMMEL_CACHE_DIR)..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after a failed removal)"
  STEPS_INCOMPLETE+=("[7/7] himmelctl cache: skipped — halted after a failed removal")
elif suspicious_rm_path "$HIMMEL_CACHE_DIR"; then
  # A refusal is not a teardown: the cache is still there. Unlike step [2/7],
  # where the guard protects an OPTIONAL removal, this step is required, so a
  # refusal is an incomplete step and must not end in "Uninstall complete."
  echo "  ERROR: refusing to remove suspicious path: '$HIMMEL_CACHE_DIR'" >&2
  HALTED=1
  STEPS_INCOMPLETE+=("[7/7] himmelctl cache: refused a suspicious HIMMELCTL_CACHE_DIR ('$HIMMEL_CACHE_DIR')")
# -e, not -d: a regular FILE at this path is residue too, and reporting it
# "absent" would leave it behind while claiming a complete uninstall. Also
# check -L: a DANGLING symlink makes -e false (it follows the link to a
# target that doesn't exist), which would report "absent" and leave the
# dead link itself behind as residue.
elif [ ! -e "$HIMMEL_CACHE_DIR" ] && [ ! -L "$HIMMEL_CACHE_DIR" ]; then
  echo "  absent, skipping: $HIMMEL_CACHE_DIR"
elif [ -L "$HIMMEL_CACHE_DIR" ]; then
  # HIMMEL-2505 gap A.3: the target is a symlink — unlink the link itself,
  # never `rm -rf` through it into whatever it points at.
  if run rm -f -- "$HIMMEL_CACHE_DIR"; then
    [ "$DRY_RUN" -eq 0 ] && echo "  removed symlink (link only): $HIMMEL_CACHE_DIR"
  else
    echo "  ERROR: failed to remove $HIMMEL_CACHE_DIR — residue remains; remove it manually." >&2
    HALTED=1
    STEPS_INCOMPLETE+=("[7/7] himmelctl cache: $HIMMEL_CACHE_DIR could not be removed")
  fi
else
  # Name the known state files before removing, so --dry-run is auditable.
  for _cache_file in install-profile.json state.json; do
    [ -f "$HIMMEL_CACHE_DIR/$_cache_file" ] && echo "  contains: $HIMMEL_CACHE_DIR/$_cache_file"
  done
  if run rm -rf -- "$HIMMEL_CACHE_DIR"; then
    [ "$DRY_RUN" -eq 0 ] && echo "  removed: $HIMMEL_CACHE_DIR"
  else
    # A failed removal is residue that survives the uninstall — the exact
    # thing HIMMEL-2458 says must not end in "Uninstall complete." at rc=0.
    echo "  ERROR: failed to remove $HIMMEL_CACHE_DIR — residue remains; remove it manually." >&2
    HALTED=1
    STEPS_INCOMPLETE+=("[7/7] himmelctl cache: $HIMMEL_CACHE_DIR could not be removed")
  fi
fi
echo ""

# A step that HAD to run and could not is not a completed uninstall. Saying so
# — and exiting non-zero — is the whole point of HIMMEL-2458: a caller reading
# the rc, or a human reading the last line, was previously told a full teardown
# happened when the two most consequential steps never ran.
if [ "${#STEPS_INCOMPLETE[@]}" -gt 0 ]; then
  {
    echo "Uninstall INCOMPLETE — ${#STEPS_INCOMPLETE[@]} step(s) did not run:"
    for _step in "${STEPS_INCOMPLETE[@]}"; do
      echo "  - $_step"
    done
    echo ""
    echo "Nothing was removed by those steps. Re-run from a login shell"
    echo "(bash -l -c 'bash scripts/uninstall.sh --yes'), or pass"
    echo "--skip-plugins / --skip-hooks to accept the gap deliberately."
    echo "A refused or failed removal halts every LATER step on purpose"
    echo "(HIMMEL-2505) — a partial teardown is safer left in place than"
    echo "guessed past."
  } >&2
  exit 2
fi

echo "Uninstall complete."
echo ""
echo "NOT touched (by design):"
echo "  - ~/.claude/settings.json non-himmel keys (MCP config, your own hooks, rtk guard)"
echo "  - the himmel clone itself, .env, and worktrees"
echo "  - ~/.claude/handover/registry.json + handover state outside the bridge root"
