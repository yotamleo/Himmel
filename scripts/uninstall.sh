#!/usr/bin/env bash
# uninstall.sh — offboard the himmel operator surface (HIMMEL-227).
# Symmetric teardown of what setup.sh + install-plugins.sh onboard:
#
#   [1/8] stop the telegram bun bridge      (bun supervisor.ts --kill)
#   [2/8] remove telegram pairing + bridge state
#         (channel dir incl. access.json + bot-token .env; bridge root)
#   [3/8] remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge
#         logon task on Windows)
#   [4/8] uninstall installed Claude plugins at their own scope
#         (machine-setup/uninstall-plugins.sh --plugins-only; the install
#         profile supplies only the fallback scope — HIMMEL-2694)
#   [5/8] uninstall git hooks (pre-commit/pre-push/commit-msg)
#   [6/8] unwire user + current-project settings.json (statusLine, env.HIMMEL_REPO,
#         env.LUNA_VAULT_PATH, env.HANDOVER_DIR, the UNIVERSAL hooks — what
#         setup.sh/adopt wired; himmel's own project settings are kept)
#   [7/8] remove Claude marketplaces (only when no installed plugins remain)
#   [8/8] remove the himmelctl cache + state dir ~/.claude/himmel
#         (install-profile.json, state.json — HIMMEL-2459)
#
# Two removal choices, never conflated (HIMMEL-3058):
#   default          himmel's OWN code — plugins, git hooks, settings.json
#                    wiring, scheduled jobs, marketplaces, the himmelctl cache.
#                    Operator STATE (telegram pairing + bridge state) is KEPT.
#   --purge-state    additionally removes that operator state.
# Every surface either choice touches is listed in the path manifest
# scripts/install/uninstall-manifest.tsv, which THIS script reads (targets,
# code-vs-state class, printed footprint) — see HIMMEL_UNINSTALL_MANIFEST.
#
# Removes ONLY (HIMMEL-2505 — the fixed target set, no discovery/globbing):
#   $HOME/.claude/channels/telegram (or $TELEGRAM_CHANNEL_DIR)   [state]
#   $HOME/.claude/handover/bridge   (or $BRIDGE_ROOT)            [state]
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
#        [--purge-state] [--keep-backups] [--skip-plugins] [--skip-tasks]
#        [--skip-hooks] [--skip-settings]
#
# Provenance ledger (HIMMEL-3332 S6): when scripts/lib/provenance.sh recorded
# what install/adopt actually wrote (docs/internals/install-provenance.md),
# [4/8], [6/8] and [7/8] use it to tell a pre-existing plugin/marketplace/
# statusLine/env.HANDOVER_DIR/hud-config/adopter-script from one himmel itself
# put there — the former is kept or restored from its recorded backup, never
# blindly removed. With no readable ledger for this $HOME those six rows are
# kept with a hand command instead (the conservative pre-S6 behaviour).
#
# Flags:
#   --dry-run              Print actions instead of running them.
#   --yes                  Skip the confirmation prompt.
#   --purge-state          ALSO remove operator state: the telegram channel dir
#                          (bot token + access.json) and the bridge state.
#                          Without it that state is kept (the conservative
#                          default); the bridge process is stopped either way.
#                          Also removes the provenance ledger + its backups,
#                          last.
#   --keep-backups         Keep provenance-backups/ after a clean, ledger-
#                          driven run instead of pruning it (backups are kept
#                          on a halt regardless). Under --purge-state, spares
#                          provenance-backups/ from that removal too — the
#                          ledger file itself is still removed.
#   --keep-telegram-state  Accepted for compatibility; state is already kept by
#                          default. Contradicts --purge-state (rc=2).
#   --skip-plugins         Keep Claude plugins + marketplaces installed.
#   --skip-tasks           Keep HIMMEL-Resume-* / HimmelTelegramBridge jobs.
#   --skip-hooks           Keep the repo's pre-commit git hooks.
#   --skip-settings        Keep user- and current-project settings.json wiring
#                          (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, hooks).
#   --source-only          Test seam (HIMMEL-2503): define the functions, then
#                          stop before any action — `. uninstall.sh --source-only`.
#
# Env overrides (tests):
#   HIMMEL_UNINSTALL_MANIFEST — default scripts/install/uninstall-manifest.tsv
#                          (next to this script); the fixture-manifest seam.
#   TELEGRAM_CHANNEL_DIR — default $HOME/.claude/channels/telegram
#   BRIDGE_ROOT          — default $HOME/.claude/handover/bridge
#                          (same var the bridge's bus.ts honors)
#   HIMMEL_USER_SETTINGS — default $HOME/.claude/settings.json (the [6/8] target)
#   HIMMELCTL_CACHE_DIR  — default $HOME/.claude/himmel (the [8/8] target;
#                          same var himmelctl itself honors)
#   HIMMEL_UNINSTALL_REPO_ROOT — fixture repo for scripts (HIMMEL-2754;
#                          default is this script's repo), and also for
#                          HOOKS_REPO_ROOT below (the [5/8] git-hooks target)
#                          when set — same fixture-repo seam. When unset,
#                          HOOKS_REPO_ROOT instead defaults to $PWD
#                          (HIMMEL-2849) — a REAL project-scope run never
#                          sets this var, so [5/8] targets $PWD — the
#                          repo adopt.sh actually installed hooks into, not
#                          necessarily the checkout providing this script.
#   HIMMEL_UNINSTALL_REAL_HOME — must be "1" for a WET (non-dry-run) run to
#                          proceed when $HOME carries a live-operator marker
#                          (HIMMEL-2505); set by the operator's own shell, or
#                          by the wizard's confirmed teardown spawn
#                          (scripts/himmelctl/bin.js), or by the VM harness.
#
# Exit codes: 0 = done (absent items are notes); 2 = aborted
# (no confirmation), bad flag, or INCOMPLETE — a step that had to run could
# not, e.g. its tool was unresolvable (HIMMEL-2458), or a removal was refused/
# failed; ANY failed step halts later steps (HIMMEL-2754); 3 = a wet run was refused
# because $HOME looks like a live operator profile (HIMMEL-2505).
# "Uninstall complete." is printed only on 0.
set -uo pipefail

# WHY (HIMMEL-2754): a fixture can test hook detection without inspecting or
# changing the checkout's real hooks, like the settings/cache overrides below.
REPO_ROOT="${HIMMEL_UNINSTALL_REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# HIMMEL-2849: [5/8]'s git-hooks target must be the repo adopt.sh actually
# wrote hooks into — the invocation CWD, same target [6/8]'s project-settings
# unwire already keys off ($PWD, project_is_himmel_checkout below) — never
# REPO_ROOT, which points at the checkout providing THIS script's own sibling
# scripts and is only the same repo by coincidence (a dev self-hosted
# uninstall, or --scope user run from inside the checkout). himmelctl/bin.js
# never sets HIMMEL_UNINSTALL_REPO_ROOT for a real run, so this defaults to
# $PWD there; an explicit override (the HIMMEL-2754 fixture seam) still wins,
# unchanged, for every existing hook-detection test.
HOOKS_REPO_ROOT="${HIMMEL_UNINSTALL_REPO_ROOT:-$PWD}"

DRY_RUN=0
YES=0
KEEP_TELEGRAM_STATE=0
PURGE_STATE=0
KEEP_BACKUPS=0
SKIP_PLUGINS=0
SKIP_TASKS=0
SKIP_HOOKS=0
SKIP_SETTINGS=0
SOURCE_ONLY=0
# HIMMEL-3332 S6: the ledger-load block below needs the argv this script was
# actually invoked with (prov_read_session_begin records it for audit) — the
# flag-parsing loop consumes "$@", so it must be snapshotted before that loop.
_ORIG_ARGV=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --yes)                 YES=1 ;;
    --keep-telegram-state) KEEP_TELEGRAM_STATE=1 ;;
    --purge-state)         PURGE_STATE=1 ;;
    --keep-backups)        KEEP_BACKUPS=1 ;;
    --skip-plugins)       SKIP_PLUGINS=1 ;;
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
if [ "$PURGE_STATE" -eq 1 ] && [ "$KEEP_TELEGRAM_STATE" -eq 1 ]; then
  echo "ERROR: --purge-state and --keep-telegram-state contradict each other — pick one." >&2
  exit 2
fi
# HIMMEL-3415: an unset or empty $HOME is refused outright, dry-run included —
# every {HOME} target would otherwise print (or remove) as a root-relative path.
if [ -z "${HOME:-}" ]; then
  echo "ERROR: refusing to run — real-home check (HOME-unset): \$HOME is unset or empty" >&2
  exit 3
fi

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

# squash_leading_slashes <path> — collapse a leading run of `/` to one.
squash_leading_slashes() {
  local _v="$1"
  while [ "${_v#//}" != "$_v" ]; do
    _v="${_v#/}"
  done
  printf '%s\n' "$_v"
}

# --- Path manifest (HIMMEL-3058) ---------------------------------------------
# scripts/install/uninstall-manifest.tsv is the ONE list of every surface this
# script acts on. It is READ here — removal targets, the code-vs-state class
# behind --purge-state, the printed footprint and the post-run read-back all
# come from it — so a surface cannot be touched without being listed.
# Fail-closed: an unreadable/malformed manifest is a refusal, never a fallback
# to a re-derived list (a re-derived list is how paths get missed).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${HIMMEL_UNINSTALL_MANIFEST:-$SCRIPT_DIR/install/uninstall-manifest.tsv}"
M_ID=(); M_CLASS=(); M_KIND=(); M_ENV=(); M_PATH=(); M_STEP=(); M_WHAT=()
load_manifest() {
  local _id _class _surface _kind _env _path _step _what _record _extra _want _wk _wp _ws _haspath
  [ -r "$MANIFEST_FILE" ] || { echo "ERROR: uninstall manifest unreadable: $MANIFEST_FILE" >&2; return 1; }
  while IFS=$'\t' read -r _id _class _surface _kind _env _path _step _what _record _extra; do
    case "$_id" in ''|'#'*) continue ;; esac
    if [ -z "$_what" ] || [ -n "$_extra" ]; then
      echo "ERROR: malformed row '$_id' in $MANIFEST_FILE (need 8 or 9 tab-separated columns)" >&2
      return 1
    fi
    case "$_class" in
      code|state|keep) ;;
      *) echo "ERROR: row '$_id' has class '$_class' (want code|state|keep) in $MANIFEST_FILE" >&2; return 1 ;;
    esac
    case "$_kind" in
      dir|settings|githooks|process|jobs|plugins|marketplaces|file) ;;
      *) echo "ERROR: row '$_id' has kind '$_kind' in $MANIFEST_FILE" >&2; return 1 ;;
    esac
    case "$_step" in
      [1-8]|-) ;;
      *) echo "ERROR: row '$_id' has step '$_step' (want 1-8 or -) in $MANIFEST_FILE" >&2; return 1 ;;
    esac
    case "$_env" in
      -) ;;
      *[!A-Za-z0-9_]*|[0-9]*|'') echo "ERROR: row '$_id' has env '$_env' (want a shell variable name or -) in $MANIFEST_FILE" >&2; return 1 ;;
    esac
    # Structural contract of the rows this script reads by id: kind, step and
    # whether it carries a path. Each field valid on its own is not enough — a
    # cache row of path '-' and step '-' would target the literal '-'.
    case "$_id" in
      bridge-process)   _want="process - 1" ;;
      telegram-channel) _want="dir path 2" ;;
      telegram-bridge)  _want="dir path 2" ;;
      scheduled-jobs)   _want="jobs - 3" ;;
      plugins)          _want="plugins - 4" ;;
      git-hooks)        _want="githooks path 5" ;;
      git-hook-backups) _want="githooks path 5" ;;
      user-settings)    _want="settings path 6" ;;
      project-settings) _want="settings path 6" ;;
      user-claude-md)   _want="file path 6" ;;
      user-agents-md)   _want="file path 6" ;;
      hud-config)       _want="file path 6" ;;
      marketplaces)     _want="marketplaces - 7" ;;
      himmelctl-cache)  _want="dir path 8" ;;
      *)                _want="" ;;
    esac
    if [ -n "$_want" ]; then
      read -r _wk _wp _ws <<< "$_want"
      _haspath=path; [ "$_path" = "-" ] && _haspath=-
      if [ "$_kind" != "$_wk" ] || [ "$_haspath" != "$_wp" ] || [ "$_step" != "$_ws" ]; then
        echo "ERROR: row '$_id' violates its contract (want kind=$_wk path=$_wp step=$_ws; got kind=$_kind path=$_haspath step=$_step) in $MANIFEST_FILE" >&2
        return 1
      fi
    fi
    case " ${M_ID[*]:-} " in
      *" $_id "*) echo "ERROR: duplicate manifest id '$_id' in $MANIFEST_FILE" >&2; return 1 ;;
    esac
    M_ID+=("$_id"); M_CLASS+=("$_class"); M_KIND+=("$_kind"); M_ENV+=("$_env")
    M_PATH+=("$_path"); M_STEP+=("$_step"); M_WHAT+=("$_what")
  done < "$MANIFEST_FILE"
  [ "${#M_ID[@]}" -gt 0 ] || { echo "ERROR: uninstall manifest has no rows: $MANIFEST_FILE" >&2; return 1; }
}

# m_index <id> — echo the row index; rc=1 (and an error) when the id is absent.
m_index() {
  local _i
  for _i in "${!M_ID[@]}"; do
    if [ "${M_ID[$_i]}" = "$1" ]; then printf '%s\n' "$_i"; return 0; fi
  done
  echo "ERROR: manifest $MANIFEST_FILE has no row '$1'" >&2
  return 1
}

# m_path <row-index> — the row's target: its override env var when set, else
# the default template with {HOME} {PWD} {REPO_ROOT} {HOOKS_REPO_ROOT} expanded.
m_path() {
  local _i="$1" _var="${M_ENV[$1]}" _p _t
  if [ "$_var" != "-" ] && [ -n "${!_var:-}" ]; then
    printf '%s\n' "${!_var}"
    return 0
  fi
  _p="${M_PATH[$_i]}"
  if [ "$_p" = "-" ]; then printf '%s\n' "-"; return 0; fi
  _t='{HOME}';            _p="${_p//"$_t"/$HOME}"
  _t='{PWD}';             _p="${_p//"$_t"/$PWD}"
  _t='{REPO_ROOT}';       _p="${_p//"$_t"/$REPO_ROOT}"
  _t='{HOOKS_REPO_ROOT}'; _p="${_p//"$_t"/$HOOKS_REPO_ROOT}"
  printf '%s\n' "$_p"
}

load_manifest || exit 2
_ix_channel=$(m_index telegram-channel) || exit 2
_ix_bridge=$(m_index telegram-bridge) || exit 2
_ix_settings=$(m_index user-settings) || exit 2
_ix_cache=$(m_index himmelctl-cache) || exit 2
_ix_pset=$(m_index project-settings) || exit 2
_ix_bproc=$(m_index bridge-process) || exit 2
_ix_jobs=$(m_index scheduled-jobs) || exit 2
_ix_plug=$(m_index plugins) || exit 2
_ix_ghooks=$(m_index git-hooks) || exit 2
_ix_hbak=$(m_index git-hook-backups) || exit 2
_ix_mkt=$(m_index marketplaces) || exit 2
_ix_ucm=$(m_index user-claude-md) || exit 2
_ix_uam=$(m_index user-agents-md) || exit 2
_ix_hud=$(m_index hud-config) || exit 2

CHANNEL_DIR="$(strip_trailing_slash "$(m_path "$_ix_channel")")"
BRIDGE_ROOT="$(strip_trailing_slash "$(m_path "$_ix_bridge")")"
# Test override (HIMMEL_USER_SETTINGS, the manifest row's env column) so the
# [6/8] settings-unwire can target a temp file instead of the operator's real
# ~/.claude/settings.json.
USER_SETTINGS="$(m_path "$_ix_settings")"
# Same override himmelctl reads (scripts/himmelctl/bin.js) — pointing one at a
# temp dir must point the other there too, or uninstall would delete the real
# cache during a test.
HIMMEL_CACHE_DIR="$(strip_trailing_slash "$(m_path "$_ix_cache")")"

# Operator state (manifest class=state) is removed only on --purge-state; the
# legacy --keep-telegram-state can only ever keep more, and contradicts the
# purge flag above.
state_removed() { [ "$PURGE_STATE" -eq 1 ] && [ "$KEEP_TELEGRAM_STATE" -eq 0 ]; }

# class_removes <row-index> — does this run delete the row's target? The
# manifest CLASS decides (code: yes; state: only when state_removed; keep:
# never), so the printed footprint and the deletion cannot disagree.
class_removes() {
  case "${M_CLASS[$1]}" in
    code)  return 0 ;;
    state) state_removed ;;
    *)     return 1 ;;
  esac
}

# step_skipped <step> — is the manifest step turned off by a --skip-* flag?
step_skipped() {
  case "$1" in
    3)   [ "$SKIP_TASKS" -eq 1 ] ;;
    4|7) [ "$SKIP_PLUGINS" -eq 1 ] ;;
    5)   [ "$SKIP_HOOKS" -eq 1 ] ;;
    6)   [ "$SKIP_SETTINGS" -eq 1 ] ;;
    *)   return 1 ;;
  esac
}

# WHY (HIMMEL-2694): `claude plugin list --json` is the primary source for
# each installed plugin's scope. The profile supplies only the child's
# fallback --scope when enumeration is unavailable, and the marketplace-only
# phase's scope. Missing/unreadable profiles or jq fall back to "user".
PLUGIN_SCOPE="user"
_profile_file="$HIMMEL_CACHE_DIR/install-profile.json"
if [ -f "$_profile_file" ] && command -v jq >/dev/null 2>&1; then
  _recorded_scope="$(jq -r '.scope // empty' "$_profile_file" 2>/dev/null || true)"
  case "$_recorded_scope" in
    user|project|local) PLUGIN_SCOPE="$_recorded_scope" ;;
  esac
fi

# Steps that HAD to run and could not. Non-empty ⇒ rc=2 and no completion
# claim (HIMMEL-2458).
STEPS_INCOMPLETE=()

# WHY (HIMMEL-2754): ANY failed step halts every later destructive step.
# Keep the first cause distinct from the later steps skipped because of it.
HALTED=0
HALTED_AT=""

# fail_step <label> — record a step that HAD to run and could not, and HALT the
# rest of the sequence (HIMMEL-2754). Every destructive step below checks
# $HALTED first. The FIRST failure is what $HALTED_AT names; later entries are
# consequences of it.
fail_step() {
  STEPS_INCOMPLETE+=("$1")
  if [ "$HALTED" -eq 0 ]; then HALTED=1; HALTED_AT="$1"; fi
}

# note_step <text> — something that did not need to run. Never halts, never
# affects the exit code.
note_step() { echo "  note: $1"; }

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
  # `pwd -P` keeps a leading `//` (POSIX leaves it implementation-defined;
  # Linux treats it as `/`): collapse it so every comparison sees one spelling.
  _resolved=$(squash_leading_slashes "$_resolved")
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
  for _s in ${_stack[@]+"${_stack[@]}"}; do
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
  # The documented removal targets are descendants of protected $HOME (or
  # $HOME/.claude) by design and must stay allowed no matter what the
  # descendant check below would otherwise do to them — but only when BOTH
  # conditions in the header comment hold (lexical identity AND no symlinked
  # component). Neither check alone is enough (HIMMEL-2505 gap A).
  # ponytail (HIMMEL-3332 S6): ".himmel" is provenance.sh's own documented
  # default (`${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance.jsonl`) —
  # this exemption covers only that bare default location. An operator who
  # points HIMMEL_PROVENANCE_DIR somewhere else still hits the "$HOME is
  # protected, therefore its descendants are protected" refusal at [8/8]'s
  # --purge-state step; that's the same fail-closed trade the other three
  # exemptions accept, not a new gap this slice introduces.
  local _allowed_suffixes=(
    ".claude/himmel" ".claude/channels/telegram" ".claude/handover/bridge"
    ".himmel"
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
    # after `cd "$HOOKS_REPO_ROOT"`, where it would resolve against the wrong
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

# rerun_command [skip-flag] — the exact command that re-runs this uninstall,
# runnable as printed (HIMMEL-3250). It bypasses himmelctl on purpose:
# `himmelctl uninstall` forwards only --dry-run/--yes/--purge-state, so a
# --skip-* remedy is not reachable through it. HIMMEL_UNINSTALL_REAL_HOME=1 is
# what himmelctl's own spawn sets past the wet-run fence below; the absolute
# script path works from any cwd.
rerun_command() {
  local cmd
  cmd="HIMMEL_UNINSTALL_REAL_HOME=1 bash $(printf '%q' "$SCRIPT_DIR/uninstall.sh") --yes"
  # Mirror EVERY mode flag the run was given (all but --yes, always printed, and
  # --source-only, a test seam): a rerun that dropped one would remove what the
  # operator chose to keep, or turn a dry run into a wet teardown. The remedy
  # flag is added once.
  [ "$DRY_RUN" -eq 1 ] && cmd="$cmd --dry-run"
  [ "$PURGE_STATE" -eq 1 ] && cmd="$cmd --purge-state"
  [ "$KEEP_TELEGRAM_STATE" -eq 1 ] && cmd="$cmd --keep-telegram-state"
  [ "$SKIP_PLUGINS" -eq 1 ] && cmd="$cmd --skip-plugins"
  [ "$SKIP_TASKS" -eq 1 ] && cmd="$cmd --skip-tasks"
  [ "$SKIP_HOOKS" -eq 1 ] && cmd="$cmd --skip-hooks"
  [ "$SKIP_SETTINGS" -eq 1 ] && cmd="$cmd --skip-settings"
  if [ -n "${1:-}" ]; then
    case " $cmd " in *" $1 "*) ;; *) cmd="$cmd $1" ;; esac
  fi
  printf '%s\n' "$cmd"
}

# report_unresolved <step-label> <tool> <skip-flag>: record the gap and say where
# we looked. The skip flag is remembered for the footer's runnable advice.
HALT_SKIP_FLAG=""
report_unresolved() {
  local step="$1" tool="$2"
  echo "  ERROR: \`$tool\` not found — this step did NOT run." >&2
  echo "  looked in: $(tool_candidates "$tool" | tr '\n' ' ')" >&2
  [ "$tool" = pre-commit ] && [ -n "${FRAMEWORK_HOOK_TRIGGER:-}" ] && echo "  triggered by: $FRAMEWORK_HOOK_TRIGGER (looks like a pre-commit framework hook)" >&2
  echo "  Put $tool on PATH and re-run, or skip this step (command below)." >&2
  [ -z "$HALT_SKIP_FLAG" ] && HALT_SKIP_FLAG="${3:-}"
  fail_step "$step: \`$tool\` not found"
}

# HIMMEL-3253: pre_commit/commands/install_uninstall.py's is_our_script() —
# CURRENT_HASH then PRIOR_HASHES. `pre-commit install` writes exactly one of
# these into every hook it owns, and `pre-commit uninstall` removes a hook only
# when the file carries one; match all six, since an adopter on an older
# pre-commit is exactly who this path exists for.
FRAMEWORK_HOOK_HASHES='138fd403232d2ddd5efb44317e38bf03 4d9958c90bc262f47553e2c073f14cfe d8ee923c46731b42cd95cc869add4062 49fd668cb42069aa1b6048464be5d395 79f09a650522a87b0da915d0d983b2de e358c9dae00eac5d06b38dfdb1e33a8c'

# repo_has_framework_hooks — rc 0 iff this repo actually carries hooks that
# `pre-commit uninstall` would have to remove (HIMMEL-2754): a set
# core.hooksPath, or a non-.sample file in the resolved hooks directory that
# carries one of the framework's own identity hashes (HIMMEL-3253, below) —
# the framework's is_our_script() test, so an adopter's own hook that merely
# mentions pre-commit is not one (`pre-commit uninstall` could never remove it).
# HIMMEL-2841: a file carrying $NATIVE_GATE_MARKER is a HIMMEL-2771
# native gate, never a framework hook — checked and skipped before the hash
# test. rc 1 = definitely none, including a missing directory resolved
# by git; rc 2 = missing directory whose location could not be resolved
# because git was absent or rev-parse failed, or an existing hook file that
# could not be read (including a grep error), or a hooks directory that exists but cannot be read or searched.
# When it returns 1 and pre-commit is absent, [5/8] has nothing to
# do — a note, not a halt (a plain adopter install without uv/pipx never
# places framework hooks at all; see HIMMEL-2771).
repo_has_framework_hooks() {
  local hooks_path f grep_rc hooks_dir="" resolved_hooks_dir hooks_resolved=0 hooks_unreadable=0 h
  local -a hash_args=()
  for h in $FRAMEWORK_HOOK_HASHES; do hash_args+=(-e "$h"); done
  if command -v git >/dev/null 2>&1; then
    hooks_path="$(git -C "$HOOKS_REPO_ROOT" config --get core.hooksPath 2>/dev/null)" || hooks_path=""
    if [ -n "$hooks_path" ]; then FRAMEWORK_HOOK_TRIGGER="core.hooksPath=$hooks_path"; return 0; fi
    if resolved_hooks_dir="$(git -C "$HOOKS_REPO_ROOT" rev-parse --git-path hooks 2>/dev/null)"; then
      hooks_resolved=1
      hooks_dir="$resolved_hooks_dir"
      # WHY (HIMMEL-2754): Git for Windows returns drive-letter absolute paths.
      # Prefixing one produces a nonexistent directory that the resolved-path
      # branch below would misreport as "definitely none".
      case "$hooks_dir" in
        ""|/*|[A-Za-z]:[/\\]*) ;;
        *) hooks_dir="$HOOKS_REPO_ROOT/$hooks_dir" ;;
      esac
    fi
  fi
  [ -n "$hooks_dir" ] || hooks_dir="$HOOKS_REPO_ROOT/.git/hooks"
  if [ ! -d "$hooks_dir" ]; then
    if [ "$hooks_resolved" -eq 1 ]; then return 1; fi
    return 2
  fi
  # WHY (HIMMEL-2754): a directory we cannot enumerate is unresolved, not empty —
  # the glob below would silently expand to nothing and report "definitely none".
  if [ ! -r "$hooks_dir" ] || [ ! -x "$hooks_dir" ]; then
    return 2
  fi
  for f in "$hooks_dir"/*; do
    case "$f" in *.sample) continue ;; esac
    # HIMMEL-3248: `<hook>.himmel-backup` is the ADOPTER's own hook, displaced by
    # adopt.sh's install_native_hooks — never one the framework installed, and
    # marker-free, so its text (often naming pre-commit) must not read as one.
    # [5/8] restores it (restore_hook_backups); it is not this scan's business.
    case "$f" in *.himmel-backup) continue ;; esac
    if [ ! -f "$f" ]; then continue; fi
    if [ ! -r "$f" ]; then hooks_unreadable=1; continue; fi
    # HIMMEL-2841: a native gate (HIMMEL-2771) is never a framework hook —
    # check for it FIRST so it can never be misidentified as one.
    grep -qF "$NATIVE_GATE_MARKER" "$f" 2>/dev/null && continue
    grep_rc=0
    grep -qF "${hash_args[@]}" "$f" || grep_rc=$?
    case "$grep_rc" in
      0) FRAMEWORK_HOOK_TRIGGER="$f"; return 0 ;;
      1) continue ;;
      *) hooks_unreadable=1 ;;
    esac
  done
  [ "$hooks_unreadable" -eq 1 ] && return 2
  return 1
}

# HIMMEL-2839: adopt.sh's install_native_hooks (HIMMEL-2771) places these
# hooks directly, outside the pre-commit framework, when pre-commit cannot be
# bootstrapped — `pre-commit uninstall` never recognizes them. This marker is
# the exact literal adopt.sh writes as the first line of each such hook; it
# must stay byte-identical to adopt.sh's copy so this step finds exactly what
# adopt.sh placed, nothing more.
NATIVE_GATE_MARKER='# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.'

# resolve_native_hooks_dir — echo the hooks directory adopt.sh's
# install_native_hooks would have written into for $HOOKS_REPO_ROOT: a single
# `git rev-parse --git-path hooks`, which already honors core.hooksPath and
# worktrees (verified: it returns a configured core.hooksPath verbatim), with
# the same Windows-drive-letter-safe HOOKS_REPO_ROOT prefixing repo_has_framework_hooks
# uses. Falls back to $HOOKS_REPO_ROOT/.git/hooks when git is absent or rev-parse
# fails — the same best-effort guess repo_has_framework_hooks falls back to,
# and still worth scanning: it is the plain non-worktree default either way.
resolve_native_hooks_dir() {
  local resolved hooks_dir=""
  if command -v git >/dev/null 2>&1 && resolved="$(git -C "$HOOKS_REPO_ROOT" rev-parse --git-path hooks 2>/dev/null)"; then
    hooks_dir="$resolved"
    case "$hooks_dir" in
      ""|/*|[A-Za-z]:[/\\]*) ;;
      *) hooks_dir="$HOOKS_REPO_ROOT/$hooks_dir" ;;
    esac
  fi
  [ -n "$hooks_dir" ] || hooks_dir="$HOOKS_REPO_ROOT/.git/hooks"
  printf '%s\n' "$hooks_dir"
}

# remove_native_gate_hooks — remove every hook file in the resolved hooks dir
# whose text carries $NATIVE_GATE_MARKER, and ONLY those: a `.sample`, an
# adopter's own unrelated hook, or a pre-commit-framework-generated hook (none
# of which carry the marker) is never touched. Prints "removed native gate:
# <path>" per file removed ("DRY: would remove native gate: <path>" under
# --dry-run, nothing removed), or "no native gates found" when none match.
# The step's own read-back (HIMMEL-2839: a report of success with the hooks
# still present is exactly the bug this closes) re-scans after removal and
# fails if any marker-bearing file survives — never trusts `rm`'s rc alone.
# rc 0 = clean (including "none found" and --dry-run); rc 1 = a matched file
# could not be removed, one still carries the marker after the pass, or a
# hook file / the hooks directory itself could not be read or scanned to
# check (HIMMEL-2839 CR round 1/2: a grep read-error is not a nonmatch —
# treating it as one let an unreadable, or otherwise unscannable, marker-
# bearing hook survive both the removal loop and the verification re-scan
# while the function still reported rc 0. Round 2: the `-r` precheck alone
# does not cover a grep call that itself errors — e.g. a TOCTOU race after
# the precheck — so both scans also discriminate grep's own exit status
# (0 = matched, 1 = no match, anything else = a scan error) the same way
# repo_has_framework_hooks already does for its own grep calls.)
remove_native_gate_hooks() {
  local hooks_dir f found=0 rc=0 grep_rc payload_dir hooks_path_configured
  hooks_dir="$(resolve_native_hooks_dir)"
  if [ -d "$hooks_dir" ]; then
    if [ ! -r "$hooks_dir" ] || [ ! -x "$hooks_dir" ]; then
      echo "  ERROR: could not read hooks directory to scan for native gates: $hooks_dir" >&2
      rc=1
    else
      for f in "$hooks_dir"/*; do
        case "$f" in *.sample) continue ;; esac
        [ -f "$f" ] || continue
        if [ ! -r "$f" ]; then
          echo "  ERROR: could not read hook file to check for native gate marker: $f" >&2
          rc=1
          continue
        fi
        grep_rc=0
        grep -qF "$NATIVE_GATE_MARKER" "$f" || grep_rc=$?
        case "$grep_rc" in
          0) ;;
          1) continue ;;
          *)
            echo "  ERROR: could not scan hook file for native gate marker: $f" >&2
            rc=1
            continue
            ;;
        esac
        found=1
        if [ "$DRY_RUN" -eq 1 ]; then
          echo "  DRY: would remove native gate: $f"
        elif rm -f "$f"; then
          echo "  removed native gate: $f"
        else
          echo "  ERROR: could not remove native gate hook $f" >&2
          rc=1
        fi
      done
      # HIMMEL-2843: adopt.sh's install_native_hooks also drops a shared
      # fallback copy of scripts/hooks at <hooks_dir>/himmel-payload for the
      # dispatchers above to source — but ONLY when core.hooksPath is unset
      # (adopt.sh's own hooks_path_configured gate: when core.hooksPath IS
      # configured, adopt.sh sets payload_dir="" and never writes there,
      # since a configured hooksPath can point at a directory shared with
      # other repos/tools). Removal must mirror that exact gate: with
      # core.hooksPath configured, a same-named himmel-payload under it was
      # never ours to begin with, and deleting it risks destroying something
      # unrelated (CodeRabbit #2288, scripts/uninstall.sh:723).
      hooks_path_configured=0
      if command -v git >/dev/null 2>&1 && git -C "$HOOKS_REPO_ROOT" config --get core.hooksPath >/dev/null 2>&1; then
        hooks_path_configured=1
      fi
      if [ "$hooks_path_configured" -eq 0 ]; then
        payload_dir="$hooks_dir/himmel-payload"
        if [ -L "$payload_dir" ]; then
          echo "  ERROR: himmel-payload is a symlink, refusing to remove: $payload_dir" >&2
          rc=1
        elif [ -d "$payload_dir" ]; then
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "  DRY: would remove native payload: $payload_dir"
          elif rm -rf -- "$payload_dir"; then
            echo "  removed native payload: $payload_dir"
          else
            echo "  ERROR: could not remove native payload: $payload_dir" >&2
            rc=1
          fi
        fi
      fi
    fi
  fi
  if [ "$found" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "  no native gates found"
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ -d "$hooks_dir" ] && [ -r "$hooks_dir" ] && [ -x "$hooks_dir" ]; then
    for f in "$hooks_dir"/*; do
      case "$f" in *.sample) continue ;; esac
      [ -f "$f" ] || continue
      if [ ! -r "$f" ]; then
        echo "  ERROR: could not read hook file during verification: $f" >&2
        rc=1
        continue
      fi
      grep_rc=0
      grep -qF "$NATIVE_GATE_MARKER" "$f" || grep_rc=$?
      case "$grep_rc" in
        0)
          echo "  ERROR: native gate hook still present after removal: $f" >&2
          rc=1
          ;;
        1) ;;
        *)
          echo "  ERROR: could not verify hook file is free of native gate marker: $f" >&2
          rc=1
          ;;
      esac
    done
  fi
  return "$rc"
}

# restore_hook_backups — give the adopter back the hook adopt.sh's
# install_native_hooks displaced to <hook>.himmel-backup (HIMMEL-3249). Only the
# three names adopt.sh ever backs up are considered, and a backup is only ever
# MOVED to its own name, never deleted or copied over anything: when <hook>
# exists and is not a himmel gate (no $NATIVE_GATE_MARKER, or a symlink) the
# backup stays where it is and the row says so — the adopter loses nothing
# either way. A target that still carries the marker is restored over: under
# --dry-run the gate has not been removed yet, and in a wet run it is already
# gone, so the two runs report the same row. Prints "restored: <hook> (from
# <backup>)" / "DRY: would restore: …" / "kept (not restored): …" per backup.
# rc 0 = every backup restored or deliberately kept; rc 1 = a move failed or a
# target could not be read to classify it.
restore_hook_backups() {
  local hooks_dir hook backup target grep_rc rc=0
  hooks_dir="$(resolve_native_hooks_dir)"
  [ -d "$hooks_dir" ] || return 0
  for hook in commit-msg pre-commit pre-push; do
    backup="$hooks_dir/$hook.himmel-backup"
    target="$hooks_dir/$hook"
    { [ -e "$backup" ] || [ -L "$backup" ]; } || continue
    if [ -L "$target" ]; then
      echo "  kept (not restored): $target exists and is not a himmel gate — your hook stays at $backup"
      continue
    fi
    if [ -e "$target" ]; then
      grep_rc=0
      grep -qF "$NATIVE_GATE_MARKER" "$target" 2>/dev/null || grep_rc=$?
      case "$grep_rc" in
        0) ;;
        1)
          echo "  kept (not restored): $target exists and is not a himmel gate — your hook stays at $backup"
          continue
          ;;
        *)
          echo "  ERROR: could not read $target to tell whether it is a himmel gate — leaving $backup in place" >&2
          rc=1
          continue
          ;;
      esac
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  DRY: would restore: $target (from $hook.himmel-backup)"
    elif mv -f -- "$backup" "$target"; then
      echo "  restored: $target (from $hook.himmel-backup)"
    else
      echo "  ERROR: could not restore $backup to $target" >&2
      rc=1
    fi
  done
  return "$rc"
}

# --- Runtime real-home refusal (HIMMEL-3415) ---------------------------------
# The wet-run fence below is lifted by HIMMEL_UNINSTALL_REAL_HOME=1, and the
# static caller guard (scripts/test-uninstall-real-home-callers.sh) only reads
# how callers SPELL $HOME. A $HOME that claims to be scratch but RESOLVES into
# the real home — `ln -s ~ "$td/home"`, a scratch $HOME whose .claude links to
# the real one, an override target like HIMMELCTL_CACHE_DIR aimed into the
# real ~/.claude — passes both. This check resolves the real home WITHOUT
# $HOME and refuses such a run before any step.
#
# A $HOME spelled exactly as a protected home (trailing slashes trimmed, no
# other normalisation) is a DECLARED real-home run — the operator's own shell,
# himmelctl's confirmed spawn (scripts/himmelctl/bin.js), the VM harness — and
# passes through to the fence unchanged. Any other spelling that resolves
# there (`$R/.`, `/home//me`, a symlink) is refused.
#
# ponytail: a $HOME that IS literally the real home — reset by systemd-run
# --user, sudo -u, ssh or su, or a literal HOME=/home/<me> — is
# indistinguishable here from the operator's own run; the static caller guard
# stays the only control for that shape. A same-uid process can also fake the
# lookup itself (a PATH-shadowed `id`, getent or dscl, or an LD_PRELOAD'd
# getpwnam) and so name a different "real" home. On win32 himmelctl always
# spawns uninstall.ps1 (bin.js deriveUninstallCommand), so this script runs
# there only by hand under Git-Bash — the MSYS USERPROFILE source below.

# real_home_resolve — the invoking user's passwd home, never read from $HOME:
# bash's own `~<user>` expansion (getpwnam, no external binary), then
# `getent passwd <uid>`, then macOS `dscl`. The name from `id -un` is
# charset-checked BEFORE the single eval, so it can never inject; an unknown
# user leaves `~name` unexpanded, which counts as unresolved. rc=1 (nothing
# printed) when no source yields an absolute path.
real_home_resolve() {
  local _u _uid _h=""
  _u=$(id -un 2>/dev/null) || _u=""
  case "$_u" in ''|-*|*[!A-Za-z0-9._-]*) _u="" ;; esac
  if [ -n "$_u" ]; then
    # An all-digit name never reaches the eval: `~N` expands from the
    # directory stack (`~0` is $PWD), not from the passwd database.
    case "$_u" in *[!0-9]*) eval "_h=~$_u" ;; esac
    case "$_h" in /*) ;; *) _h="" ;; esac
  fi
  if [ -z "$_h" ] && command -v getent >/dev/null 2>&1; then
    _uid=$(id -u 2>/dev/null) || _uid=""
    case "$_uid" in ''|*[!0-9]*) ;; *) _h=$(getent passwd "$_uid" 2>/dev/null | cut -d: -f6) ;; esac
    case "$_h" in /*) ;; *) _h="" ;; esac
  fi
  if [ -z "$_h" ] && [ -n "$_u" ] && command -v dscl >/dev/null 2>&1; then
    _h=$(dscl . -read "/Users/$_u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: *//p')
    case "$_h" in /*) ;; *) _h="" ;; esac
  fi
  [ -n "$_h" ] || return 1
  printf '%s\n' "$_h"
}

# real_home_protected_homes — every home a fence-lifted run must not resolve
# into, one per line. Each source only ADDS: the passwd home (required; rc=1
# when unresolved), the MSYS USERPROFILE (Git-Bash, whose getpwnam home is
# /home/<user> while $HOME is /c/Users/<user>), and the test seam
# HIMMEL_UNINSTALL_TEST_REAL_HOME, which fixtures point at a FAKE real home.
# The seam can never replace or drop the passwd home; set to "/" it protects
# the root, so a HOME resolving to "/" or an override target outside $HOME is
# refused and nothing else changes.
real_home_protected_homes() {
  local _h
  _h=$(real_home_resolve) || return 1
  strip_trailing_slash "$_h"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        _h=$(cygpath -u "$USERPROFILE" 2>/dev/null) && [ -n "$_h" ] && strip_trailing_slash "$_h"
      fi
      ;;
  esac
  if [ -n "${HIMMEL_UNINSTALL_TEST_REAL_HOME:-}" ]; then
    strip_trailing_slash "$HIMMEL_UNINSTALL_TEST_REAL_HOME"
  fi
  return 0
}

# real_home_phys <path> — the physical path: a symlinked leaf is followed
# (files too — `rm`/`jq >` act on the link's target), then
# canonicalize_target resolves the rest. rc=1 when nothing resolves.
real_home_phys() {
  local _p="$1" _l _n=0
  while [ -L "$_p" ] && [ "$_n" -lt 40 ]; do
    _l=$(readlink -- "$_p") || return 1
    case "$_l" in /*) _p="$_l" ;; *) _p="$(dirname -- "$_p")/$_l" ;; esac
    _n=$((_n + 1))
  done
  canonicalize_target "$_p"
}

# real_home_under <path> <root> — true when path is root or below it. Both
# sides lose a leading `//` first: an unresolved fallback is compared raw.
real_home_under() {
  local _p _q
  _p=$(squash_leading_slashes "$1")
  _q=$(squash_leading_slashes "$2")
  [ "$_q" = "/" ] && return 0
  case "$_p" in "$_q"|"$_q"/*) return 0 ;; esac
  return 1
}

# real_home_target_ok <label> <target> <physical $HOME> <roots> — rc=1 (one
# stderr line, check c) when the target resolves into one of the
# newline-separated roots outside $HOME, or anywhere in a root that $HOME is
# an ancestor of.
real_home_target_ok() {
  local _tp _root
  _tp=$(real_home_phys "$2") || _tp="$2"
  while IFS= read -r _root; do
    if real_home_under "$_tp" "$_root" && { ! real_home_under "$_tp" "$3" || real_home_under "$_root" "$3"; }; then
      echo "ERROR: refusing a wet uninstall — real-home check (c): $1 target $2 resolves to $_tp, inside the real home's $_root" >&2
      return 1
    fi
  done <<< "$4"
  return 0
}

# real_home_check — rc=0 when this run may proceed; otherwise ONE stderr line
# naming the check that fired and the two physical paths, and rc=1:
#   unresolved  the passwd home could not be resolved (fail-closed)
#   a           physical $HOME is a protected home, or $HOME is a symlink
#               (physical != lexical) into a protected root
#   b           physical $HOME/.claude is at or under a protected home's
#               physical .claude (followed when it is symlinked out of the home)
#   c           a removal target resolves into a protected root but outside
#               $HOME — or anywhere in it when $HOME is an ancestor of that
#               root. Targets: every non-keep manifest row with a path (its
#               override env, {HOME}, {PWD}, {HOOKS_REPO_ROOT} or an absolute
#               path), the hooks dir after core.hooksPath resolution, and
#               HIMMELCTL_SYSTEMD_USER_UNIT_DIR. The roots are the physical
#               home plus the physical location of each top-level entry the
#               {HOME} rows live under (.claude, .himmel)
# ponytail: a LEXICAL $HOME under the real home (e.g. ~/tmp/scratch, spelled
# with no symlink) is a scratch dir by design and passes; only a HOME that
# resolves somewhere other than where it is spelled is judged by where it
# lands. That relies on one canonical spelling of every compared path, which
# is why a leading `//` is collapsed (canonicalize_target, real_home_under):
# `//R` would otherwise compare unequal to `/R` and skip every check. The
# lexical pass-through itself still needs the EXACT passwd spelling, so
# `HOME=//R` is refused, not passed. Session launchers that reset HOME, and step [3/8]'s crontab and
# `systemctl --user` (which act on the invoking user whatever HOME is), are
# outside this check.
real_home_check() {
  local _homes _r _rp _rc _hp _cp _i _t _home _c _comps _roots _root
  if ! _homes=$(real_home_protected_homes); then
    echo "ERROR: refusing a wet uninstall — real-home check (unresolved): cannot resolve this user's passwd home independently of \$HOME ($HOME)" >&2
    return 1
  fi
  _home=$(strip_trailing_slash "$HOME")
  _hp=$(real_home_phys "$HOME") || _hp=$(squash_leading_slashes "$HOME")
  _cp=$(real_home_phys "$HOME/.claude") || _cp=$(squash_leading_slashes "$HOME/.claude")
  # The top-level entries the {HOME} manifest rows live under (.claude,
  # .himmel, ...): a real home may symlink any of them OUT of itself (a
  # dotfiles layout), so each is protected at its PHYSICAL location too.
  _comps=""
  for _i in "${!M_ID[@]}"; do
    case "${M_PATH[$_i]}" in '{HOME}/'*) ;; *) continue ;; esac
    _c="${M_PATH[$_i]#'{HOME}/'}"
    _c="${_c%%/*}"
    case "
$_comps
" in *"
$_c
"*) ;; *) _comps="$_comps
$_c" ;; esac
  done
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    [ "$_home" = "$_r" ] && continue
    _rp=$(real_home_phys "$_r") || _rp=$(squash_leading_slashes "$_r")
    if [ "$_rp" = "/" ]; then _rc="/.claude"; else _rc="$_rp/.claude"; fi
    _t=$(real_home_phys "$_rc") && _rc="$_t"
    _roots="$_rp"
    while IFS= read -r _c; do
      [ -n "$_c" ] || continue
      if [ "$_rp" = "/" ]; then _t="/$_c"; else _t="$_rp/$_c"; fi
      _t=$(real_home_phys "$_t") || continue
      _roots="$_roots
$_t"
    done <<< "$_comps"
    if [ "$_hp" = "$_rp" ]; then
      echo "ERROR: refusing a wet uninstall — real-home check (a): \$HOME resolves to $_hp, the real home $_rp" >&2
      return 1
    fi
    if [ "$_hp" != "$_home" ]; then
      while IFS= read -r _root; do
        if real_home_under "$_hp" "$_root"; then
          echo "ERROR: refusing a wet uninstall — real-home check (a): \$HOME $_home resolves to $_hp, inside the real home's $_root" >&2
          return 1
        fi
      done <<< "$_roots"
    fi
    if real_home_under "$_cp" "$_rc"; then
      echo "ERROR: refusing a wet uninstall — real-home check (b): \$HOME/.claude resolves to $_cp, under the real $_rc" >&2
      return 1
    fi
    for _i in "${!M_ID[@]}"; do
      [ "${M_CLASS[$_i]}" = keep ] && continue
      _t=$(m_path "$_i")
      [ "$_t" = "-" ] && continue
      real_home_target_ok "${M_ID[$_i]}" "$_t" "$_hp" "$_roots" || return 1
    done
    real_home_target_ok "git hooks dir" "$(resolve_native_hooks_dir)" "$_hp" "$_roots" || return 1
    if [ -n "${HIMMELCTL_SYSTEMD_USER_UNIT_DIR:-}" ]; then
      real_home_target_ok HIMMELCTL_SYSTEMD_USER_UNIT_DIR "$HIMMELCTL_SYSTEMD_USER_UNIT_DIR" "$_hp" "$_roots" || return 1
    fi
  done <<< "$_homes"
  return 0
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

# HIMMEL-3415: the runtime real-home refusal (functions above the
# --source-only stop), for every wet run — fence lifted or not.
if [ "$DRY_RUN" -eq 0 ] && ! real_home_check; then
  exit 3
fi

# --- Provenance ledger load (HIMMEL-3332 S6) ---------------------------------
# HIMMEL-3058: source THIS script's own lib dir, never $REPO_ROOT (a
# HIMMEL_UNINSTALL_REPO_ROOT fixture can point at a different checkout).
# Read-only, safe under --dry-run and before the confirm prompt; runs before
# the plan printout below so the preview reflects what the ledger decided.
LEDGER_OK=0
# codex-9 fix: ledger_apply_unit (shared by the settings/hud-config/
# adopter-scripts loops below) reads-then-appends this on every restore/keep
# verdict. unwire_settings() resets it before ITS loop, but --skip-settings
# skips unwire_settings entirely -- leaving it unset for the hud-config/
# adopter-scripts loops under `set -uo pipefail` (line 111). Initialize it
# globally, once, so no loop order or skip combination hits an unbound var.
_LEDGER_PROTECTED=""
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=lib/provenance-read.sh
  . "$SCRIPT_DIR/lib/provenance-read.sh"
  prov_read_load
  # HIMMEL-3332 S6 fix: this trap must NOT rm -f "$_scope_map" -- $_scope_map
  # is not yet assigned here (it is set well below) and, on a real (non-dry)
  # run, it is later pointed at the PERSISTENT $HIMMEL_CACHE_DIR/uninstall-scope-map
  # file, which HIMMEL-2754 deliberately leaves in place across a halt so a
  # retry can recover the original removal scopes. An EXIT trap that always
  # rm -f's whatever "$_scope_map" currently holds would delete that
  # persistent handoff on every exit (including a halt), silently breaking
  # HIMMEL-2754's retry contract. Only the later, ephemeral-only scope-map
  # branches (mktemp'd for --dry-run or an unusable cache dir) re-install a
  # trap that also cleans up "$_scope_map" -- correctly, since by then it
  # really is a throwaway tempfile.
  trap 'prov_read_cleanup; rm -f "${_ledger_owned:-}"' EXIT
  _prov_ledger_path="$(prov_ledger_path 2>/dev/null || true)"
  case "$PROV_READ_STATE" in
    ok)
      LEDGER_OK=1
      echo "provenance: ledger $_prov_ledger_path — $PROV_READ_ROWS rows ($PROV_READ_BAD_ROWS skipped)"
      if [ "$PROV_READ_PARTIAL" -eq 1 ]; then
        echo "provenance: the last install did not finish (no install-end); proceeding"
      fi
      ;;
    *)
      echo "provenance: no ledger at $_prov_ledger_path; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept"
      case "$PROV_READ_STATE" in
        unparsable|foreign) echo "  ($PROV_READ_REASON)" ;;
      esac
      ;;
  esac
else
  # ponytail: provenance-read.sh is jq-only by design (see its header) — with
  # no jq on PATH the ledger cannot be read at all, so this run falls back to
  # the same no-ledger keep path as a missing ledger rather than failing the
  # whole uninstall over an optional dependency.
  _prov_ledger_path="${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance.jsonl"
  echo "provenance: no ledger at $_prov_ledger_path; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept"
  echo "  (jq is not installed; the ledger cannot be read)"
fi

echo "==> himmel uninstall (offboard)"
echo ""
echo "This will:"
if class_removes "$_ix_bproc"; then
  echo "  1. stop the telegram bun bridge (if running)"
else
  echo "  1. keep the telegram bun bridge running (manifest class ${M_CLASS[$_ix_bproc]})"
fi
if [ "$LEDGER_OK" -eq 1 ] && class_removes "$_ix_bproc"; then
  echo "     and disable + remove the telegram-bridge systemd unit the ledger recorded (linger only if it was not already on)"
fi
# Step 2 acts per row: the plan says REMOVE/keep for each row from the same
# class_removes the step and the footprint read (a hand-edited manifest can
# keep one row while --purge-state removes the other).
if class_removes "$_ix_channel" && class_removes "$_ix_bridge"; then
  echo "  2. REMOVE telegram pairing + bridge state (--purge-state):"
  echo "       $CHANNEL_DIR   (bot-token .env + access.json)"
  echo "       $BRIDGE_ROOT   (sessions, inbox/outbox, supervisor state)"
elif class_removes "$_ix_channel" || class_removes "$_ix_bridge"; then
  echo "  2. telegram pairing + bridge state, per manifest class:"
  if class_removes "$_ix_channel"; then echo "       REMOVE $CHANNEL_DIR"
  else echo "       keep   $CHANNEL_DIR (manifest class ${M_CLASS[$_ix_channel]})"; fi
  if class_removes "$_ix_bridge"; then echo "       REMOVE $BRIDGE_ROOT"
  else echo "       keep   $BRIDGE_ROOT (manifest class ${M_CLASS[$_ix_bridge]})"; fi
elif [ "$KEEP_TELEGRAM_STATE" -eq 1 ]; then
  echo "  2. keep telegram state (--keep-telegram-state)"
elif state_removed; then
  echo "  2. keep telegram pairing + bridge state (manifest class keep):"
  echo "       $CHANNEL_DIR"
  echo "       $BRIDGE_ROOT"
elif [ "${M_CLASS[$_ix_channel]}" = state ] && [ "${M_CLASS[$_ix_bridge]}" = state ]; then
  echo "  2. KEEP telegram pairing + bridge state (pass --purge-state to remove it):"
  echo "       $CHANNEL_DIR"
  echo "       $BRIDGE_ROOT"
else
  # A row re-classed keep is never removed, --purge-state or not: say so per
  # row instead of offering --purge-state as the way to remove it.
  echo "  2. keep telegram pairing + bridge state, per manifest class:"
  for _ix2 in "$_ix_channel:$CHANNEL_DIR" "$_ix_bridge:$BRIDGE_ROOT"; do
    if [ "${M_CLASS[${_ix2%%:*}]}" = state ]; then
      echo "       keep   ${_ix2#*:} (manifest class state; --purge-state removes it)"
    else
      echo "       keep   ${_ix2#*:} (manifest class ${M_CLASS[${_ix2%%:*}]})"
    fi
  done
fi
if [ "$SKIP_TASKS" -eq 1 ]; then
  echo "  3. keep scheduled jobs (--skip-tasks)"
elif ! class_removes "$_ix_jobs"; then
  echo "  3. keep scheduled jobs (manifest class ${M_CLASS[$_ix_jobs]})"
else
  echo "  3. remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge logon task)"
  if [ "$LEDGER_OK" -eq 1 ]; then
    echo "     and the cron/at jobs the ledger recorded a cadence arm adding (exact recorded names only)"
  fi
fi
if [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  4. keep Claude plugins (--skip-plugins)"
elif ! class_removes "$_ix_plug"; then
  echo "  4. keep Claude plugins (manifest class ${M_CLASS[$_ix_plug]})"
else
  echo "  4. uninstall installed Claude plugins from himmel-owned marketplaces"
  echo "     (project/local: current project only; USER-SCOPE: affects every repo on this machine; fallback scope: $PLUGIN_SCOPE)"
fi
if [ "$SKIP_HOOKS" -eq 1 ]; then
  echo "  5. keep git hooks (--skip-hooks)"
elif ! class_removes "$_ix_ghooks"; then
  echo "  5. keep git hooks (manifest class ${M_CLASS[$_ix_ghooks]})"
else
  echo "  5. uninstall this repo's git hooks (pre-commit/pre-push/commit-msg)"
  if class_removes "$_ix_hbak"; then
    echo "     and restore any of your own hooks himmel displaced (<hook>.himmel-backup -> <hook>)"
  else
    echo "     keep displaced hook backups (manifest class ${M_CLASS[$_ix_hbak]})"
  fi
fi
if [ "$SKIP_SETTINGS" -eq 1 ]; then
  echo "  6. keep user- and current-project settings.json wiring, the working-principles blocks and the hud config (--skip-settings)"
else
  if class_removes "$_ix_settings"; then
    echo "  6. unwire ~/.claude/settings.json (statusLine, HIMMEL_REPO,"
    echo "     LUNA_VAULT_PATH, HANDOVER_DIR, UNIVERSAL hooks — non-himmel keys untouched)"
  else
    echo "  6. keep ~/.claude/settings.json (manifest class ${M_CLASS[$_ix_settings]})"
  fi
  if class_removes "$_ix_pset"; then
    echo "     and current-project settings: $PWD/.claude/settings.json (himmel's own checkout excluded)"
    if [ "$LEDGER_OK" -eq 1 ]; then
      echo "     and every other project's settings the ledger recorded (himmel's own checkout excluded)"
    fi
  else
    echo "     keep current-project settings (manifest class ${M_CLASS[$_ix_pset]})"
  fi
  for _ix2 in "$_ix_ucm" "$_ix_uam"; do
    if class_removes "$_ix2"; then
      echo "     and strip himmel's working-principles block from $(m_path "$_ix2") (your own text untouched)"
    else
      echo "     keep $(m_path "$_ix2") (manifest class ${M_CLASS[$_ix2]})"
    fi
  done
  if class_removes "$_ix_hud"; then
    echo "     and remove himmel's claude-hud config: $(m_path "$_ix_hud")"
  else
    echo "     keep the claude-hud config (manifest class ${M_CLASS[$_ix_hud]})"
  fi
fi
if [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  7. keep Claude marketplaces (--skip-plugins)"
elif ! class_removes "$_ix_mkt"; then
  echo "  7. keep Claude marketplaces (manifest class ${M_CLASS[$_ix_mkt]})"
else
  echo "  7. remove Claude marketplaces with no remaining installed plugins"
fi
if class_removes "$_ix_cache"; then
  echo "  8. REMOVE the himmelctl cache + state: $HIMMEL_CACHE_DIR"
  echo "     (install-profile.json, state.json — a re-install would otherwise"
  echo "     start from the previous install's profile)"
else
  echo "  8. keep the himmelctl cache + state (manifest class ${M_CLASS[$_ix_cache]}): $HIMMEL_CACHE_DIR"
fi
if [ "$LEDGER_OK" -eq 1 ] && [ "$PURGE_STATE" -eq 1 ]; then
  echo "  9. (--purge-state) also REMOVE the provenance ledger + its backups: $(prov_dir 2>/dev/null || true)"
fi
echo ""

# Footprint — every manifest row with its disposition, so the operator sees the
# code-vs-state split and what is never touched before confirming. REMOVE =
# himmel code (default), KEEP = operator state without --purge-state, SKIP =
# switched off by a --skip-* flag, NEVER = not uninstall's to touch.
echo "Footprint (scripts/install/uninstall-manifest.tsv):"
for _mi in "${!M_ID[@]}"; do
  case "${M_CLASS[$_mi]}" in
    keep) _disp="NEVER " ;;
    *)
      if step_skipped "${M_STEP[$_mi]}"; then _disp="SKIP  "
      elif class_removes "$_mi"; then
        _disp="REMOVE"
        [ "${M_ID[$_mi]}" = "git-hook-backups" ] && _disp="RESTORE"
        case "${M_ID[$_mi]}" in user-claude-md|user-agents-md) _disp="STRIP " ;; esac
      else _disp="KEEP  "; fi ;;
  esac
  _mp=$(m_path "$_mi")
  [ "$_mp" = "-" ] && _mp="(${M_ID[$_mi]})"
  echo "  $_disp  $_mp — ${M_WHAT[$_mi]}"
done
if ! state_removed; then
  echo "  (operator state is KEPT by default; --purge-state also removes the KEEP rows tagged state)"
fi
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

# HIMMEL-3332 S6: begin the uninstall session AFTER a declined run has
# already exited above (a decline writes nothing). No-op when the ledger
# did not load (prov_read_session_begin checks PROV_READ_STATE itself).
if [ "$LEDGER_OK" -eq 1 ]; then
  # bash 3.2: "${arr[@]}" on an EMPTY array errors under `set -u` — the
  # "${arr[@]+...}" guard is this script's existing idiom for that (see
  # _plug_args below).
  if [ "$DRY_RUN" -eq 1 ]; then
    prov_read_session_begin dry ${_ORIG_ARGV[@]+"${_ORIG_ARGV[@]}"}
  else
    prov_read_session_begin wet ${_ORIG_ARGV[@]+"${_ORIG_ARGV[@]}"}
  fi
fi

# ledger_report_preexisted_units <plugin|marketplace> — for every fold unit of
# this register kind with ours=false, print "kept (was already yours)" and
# write its outcome row. Shared by [4/8] and [7/8] (HIMMEL-3332 S6).
ledger_report_preexisted_units() {
  local _kind="$1" _units _unit_json _unit
  _units=$(prov_read_units --kind "$_kind")
  while IFS= read -r _unit_json; do
    [ -z "$_unit_json" ] && continue
    [ "$(printf '%s' "$_unit_json" | jq -r '.ours')" = "false" ] || continue
    _unit=$(printf '%s' "$_unit_json" | jq -r '.unit')
    echo "  kept (was already yours): $_unit"
    prov_read_outcome kept "$_unit_json" preexisted
  done <<EOF
$_units
EOF
}

# ledger_apply_unit <unit-json> [step-label] — the ledger-driven per-unit action shared by
# [6/8]'s settings/adopter-scripts/hud-config passes (HIMMEL-3332 S6; S8 also
# calls it from [1/8] for the bridge unit file, passing its own step label):
# computes prov_read_verdict, then removes/restores/keeps and writes the
# outcome row. rc 1 means the unit is PROTECTED (kept or restored — the
# caller must mask it out of any read-back and skip the matching today's
# helper); rc 0 means removed, skipped, heuristic, or an already-reported
# failure. Appends every PROTECTED unit's pointer/path to the global
# _LEDGER_PROTECTED (newline-separated; the caller resets it before its loop).
ledger_apply_unit() {
  local u="$1" _step="${2:-[6/8]}" verdict action reason unit backup _ans _apply_args
  verdict=$(prov_read_verdict "$u") || { fail_step "$_step ledger verdict: could not read current state for a unit"; return 0; }
  action="${verdict%% *}"; reason="${verdict#* }"
  unit=$(printf '%s' "$u" | jq -r '.unit // .path // "?"')
  _apply_args=()
  [ "$DRY_RUN" -eq 1 ] && _apply_args=(--dry-run)
  case "$action" in
    skip|heuristic)
      # Not uninstall's ledger call — class-state (untouched by uninstall) or
      # an ungoverned unit the caller's own default logic decides instead.
      return 0 ;;
    remove)
      backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
      if prov_read_apply "$u" remove ${_apply_args[@]+"${_apply_args[@]}"}; then
        [ "$DRY_RUN" -eq 0 ] && echo "  removed $unit"
        prov_read_outcome removed "$u" "$reason" "$backup"
      else
        echo "  WARN: could not remove $unit" >&2
        fail_step "$_step ledger remove: $unit"
        prov_read_outcome failed "$u" "step-failed" "$backup"
      fi
      return 0 ;;
    restore)
      backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
      if prov_read_apply "$u" restore ${_apply_args[@]+"${_apply_args[@]}"}; then
        [ "$DRY_RUN" -eq 0 ] && echo "  restored $unit (from $backup)"
        prov_read_outcome restored "$u" "$reason" "$backup"
      else
        echo "  WARN: could not restore $unit" >&2
        fail_step "$_step ledger restore: $unit"
        prov_read_outcome failed "$u" "step-failed" "$backup"
      fi
      _LEDGER_PROTECTED="$_LEDGER_PROTECTED
$unit"
      return 1 ;;
    *)
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: would keep $unit ($reason)"
      else
        echo "  kept $unit ($reason)"
        # ponytail: the [k]eep/[r]estore-or-[d]elete override for a
        # user-modified unit only ever offers itself on a real TTY with no
        # --yes — a scripted/CI/--yes run always takes the safe default
        # (keep) rather than prompting into a pipe.
        if [ "$reason" = "user-modified" ] && [ "$YES" -ne 1 ] && [ -t 0 ] && [ -t 1 ]; then
          backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
          if [ -n "$backup" ] && [ -r "$backup" ]; then
            printf "  %s changed since install -- [k]eep / [r]estore himmel's backup? [k] " "$unit"
            read -r _ans
            case "$_ans" in
              [rR]*)
                if prov_read_apply "$u" restore; then
                  echo "  restored $unit (from $backup)"
                  prov_read_outcome restored "$u" "user-modified" "$backup"
                else
                  echo "  WARN: could not restore $unit" >&2
                  fail_step "$_step ledger restore: $unit"
                  prov_read_outcome failed "$u" "step-failed" "$backup"
                fi
                _LEDGER_PROTECTED="$_LEDGER_PROTECTED
$unit"
                return 1 ;;
            esac
          else
            printf "  %s changed since install -- [k]eep / [d]elete anyway? [k] " "$unit"
            read -r _ans
            case "$_ans" in
              [dD]*)
                if prov_read_apply "$u" remove; then
                  echo "  removed $unit"
                  prov_read_outcome removed "$u" "user-modified" "$backup"
                else
                  echo "  WARN: could not remove $unit" >&2
                  fail_step "$_step ledger remove: $unit"
                  prov_read_outcome failed "$u" "step-failed" "$backup"
                fi
                return 0 ;;
            esac
          fi
        fi
      fi
      prov_read_outcome kept "$u" "$reason"
      _LEDGER_PROTECTED="$_LEDGER_PROTECTED
$unit"
      return 1 ;;
  esac
}

# ledger_job_markers <cron|at> — HIMMEL-3332 S8: the markers of `job register`
# rows himmel brought (ours=true) for this scheduler, one per line. Only a
# HIMMEL-... token is accepted: a tampered row naming a bare word must never
# turn into a line filter over the operator's crontab.
ledger_job_markers() {
  [ "$LEDGER_OK" -eq 1 ] || return 0
  prov_read_units --kind job \
    | jq -r --arg s "$1" 'select(.ours == true and (.fields.scheduler // "") == $s) | .unit // empty' \
    | grep -E '^HIMMEL-[A-Za-z0-9._-]+$' || true
}

# job_line_marker <line> <markers> — prints the recorded marker a crontab line
# (or an at-job body line) ends with as ` # <marker>`, rc 0; rc 1 when none.
# EXACT trailing match: a lookalike (`# HIMMEL-Qmd-Reindex-extra`) is not it.
job_line_marker() {
  local _l="$1" _m
  _l="${_l%"${_l##*[![:space:]]}"}"
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    case "$_l" in
      *" # $_m"|"# $_m") printf '%s\n' "$_m"; return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# cron_strip_recorded <markers> — stdin filter for the [3/8] rewrite: drops the
# legacy HIMMEL-Resume- lines and lines ending in a recorded marker, keeps the rest.
cron_strip_recorded() {
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in *HIMMEL-Resume-*) continue ;; esac
    job_line_marker "$_line" "$1" >/dev/null && continue
    printf '%s\n' "$_line"
  done
  return 0
}

# ledger_job_outcome <marker> <removed|kept|failed> <reason> — outcome row for one job unit.
ledger_job_outcome() {
  local _uj
  _uj=$(prov_read_units --kind job | jq -c --arg m "$1" 'select(.unit == $m)' | head -n 1)
  [ -n "$_uj" ] && prov_read_outcome "$2" "$_uj" "$3"
  return 0
}

# ledger_teardown_bridge_unit — HIMMEL-3332 S8 [1/8]: the telegram-bridge
# systemd user unit bridge-persistence.js installed. Runs BEFORE the supervisor
# kill so systemd cannot restart a bridge we just stopped. Ownership comes from
# the recorded `file` row at the unit path (the `register unit` row carries no
# `preexisted`, so its own fold verdict is meaningless); only linger_preexisted
# is read from the register row. remove -> `systemctl --user disable --now`,
# then the unit file goes, then daemon-reload; restore (the operator had their
# own unit) -> the file comes back, nothing is disabled; keep (user-modified,
# no backup) -> nothing is touched and the interactive [d]elete/[r]estore
# override is never offered (it would swap the file under a live unit, and the
# disable -> reload sequence only runs for a removal this function drives).
# `disable-linger` runs only when this uninstall removed or restored the unit
# AND linger_preexisted is literally false — null (unknown) and true both leave
# linger alone.
ledger_teardown_bridge_unit() {
  local _upath _uj _verdict _act _regj _linger _steps_before
  _upath="${HIMMELCTL_SYSTEMD_USER_UNIT_DIR:-$HOME/.config/systemd/user}/telegram-bridge.service"
  _uj=$(prov_read_units --path "$_upath" --kind file | head -n 1)
  [ -n "$_uj" ] || return 0
  _verdict=$(prov_read_verdict "$_uj") || { fail_step "[1/8] telegram bridge unit: could not read current state of $_upath"; return 0; }
  _act="${_verdict%% *}"
  case "$_act" in
    remove|restore) ;;
    skip|heuristic) return 0 ;;
    *)
      YES=1 ledger_apply_unit "$_uj" "[1/8]" || true   # YES=1: report kept, never prompt
      if [ "${_verdict#* }" = "user-modified" ] && [ -e "$_upath" ] && [ "$DRY_RUN" -ne 1 ]; then
        echo "  hand step: systemctl --user disable --now telegram-bridge.service, then remove $_upath"
      fi
      return 0 ;;
  esac
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "  kept $_upath (systemctl not on PATH — cannot disable the unit; disable and remove it by hand)"
    prov_read_outcome kept "$_uj" "no-systemctl"
    return 0
  fi
  if [ "$_act" = "remove" ]; then
    # ponytail: only the unit himmel itself installed is disabled. A restored
    # operator unit keeps whatever enablement it has — bridge-persistence.js
    # does not record the pre-install enablement, so there is nothing to put back.
    if ! run systemctl --user disable --now telegram-bridge.service; then
      echo "  WARN: systemctl --user disable --now telegram-bridge.service failed — unit file kept." >&2
      fail_step "[1/8] telegram bridge unit: could not disable telegram-bridge.service"
      prov_read_outcome failed "$_uj" "step-failed"
      return 0
    fi
  fi
  _steps_before=${#STEPS_INCOMPLETE[@]}
  ledger_apply_unit "$_uj" "[1/8]" || true   # rc 1 = a restore, still a done unit
  [ "${#STEPS_INCOMPLETE[@]}" -gt "$_steps_before" ] && return 0
  if ! run systemctl --user daemon-reload; then
    echo "  WARN: systemd user manager reload failed — run it by hand." >&2
    fail_step "[1/8] telegram bridge unit: could not do the systemd user manager reload after removing the unit file"
  fi
  _regj=$(prov_read_units --kind unit | jq -c 'select(.unit == "telegram-bridge.service")' | head -n 1)
  [ -n "$_regj" ] || return 0
  _linger=$(printf '%s' "$_regj" | jq -r '.fields.linger_preexisted | if . == null then "null" else tostring end')
  if [ "$_linger" = "false" ]; then
    if command -v loginctl >/dev/null 2>&1; then
      if run loginctl disable-linger "${USER:-$(id -un)}"; then
        prov_read_outcome removed "$_regj" "linger-not-preexisting"
      else
        echo "  WARN: loginctl disable-linger failed — run it by hand." >&2
        fail_step "[1/8] telegram bridge unit: could not disable linger"
        prov_read_outcome failed "$_regj" "step-failed"
      fi
    else
      echo "  kept linger (loginctl not on PATH)"
      prov_read_outcome kept "$_regj" "no-loginctl"
    fi
  else
    echo "  kept linger (linger_preexisted=$_linger)"
    prov_read_outcome kept "$_regj" "linger-preexisted"
  fi
}

# --- [1/8] stop the bridge -------------------------------------------------
# Uses the documented cross-platform lever (supervisor.pid under the bridge
# root; see docs/internals/telegram-bridge.md). BRIDGE_ROOT is passed through
# so a non-default root kills the matching bridge, not another one.
# WHY (HIMMEL-2754): halt if the bridge may still be live — removing state
# would recreate it (and on Windows, locked files make removal fail partway).
echo "[1/8] Stopping telegram bridge..."
# HIMMEL-3332 S8: the systemd unit goes first — see ledger_teardown_bridge_unit.
if [ "$LEDGER_OK" -eq 1 ] && class_removes "$_ix_bproc"; then
  ledger_teardown_bridge_unit
fi
if ! class_removes "$_ix_bproc"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_bproc]}): bridge left running."
  # A bridge that stays running must not have its state deleted under it: the
  # supervisor would recreate it (HIMMEL-2754) — refuse rather than half-remove.
  if [ -f "$BRIDGE_ROOT/supervisor.pid" ] \
      && { class_removes "$_ix_channel" || class_removes "$_ix_bridge"; }; then
    echo "  ERROR: the bridge is kept running (manifest class ${M_CLASS[$_ix_bproc]}) but its state would be removed:" >&2
    echo "    supervisor.pid exists under $BRIDGE_ROOT; step 2 would delete the state it is using." >&2
    echo "    Drop --purge-state, or stop the bridge first." >&2
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  (dry-run) a wet run would halt here."
    else
      fail_step "[1/8] telegram bridge: kept running but its state would be removed"
    fi
  fi
elif [ ! -f "$BRIDGE_ROOT/supervisor.pid" ]; then
  echo "  no supervisor.pid under $BRIDGE_ROOT — bridge not running, skipping."
elif ! command -v bun >/dev/null 2>&1; then
  echo "  WARN: supervisor.pid exists but bun is not on PATH — cannot stop the bridge." >&2
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win"* ]] \
      || command -v pwsh >/dev/null 2>&1; then
    echo "  Stop it manually: pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly (inspect), then kill." >&2
  else
    echo "  Find the supervisor pid in $BRIDGE_ROOT/supervisor.pid and kill it manually." >&2
  fi
  fail_step "[1/8] telegram bridge: could not stop the supervisor"
else
  run env BRIDGE_ROOT="$BRIDGE_ROOT" bun --cwd "$REPO_ROOT/scripts/telegram" supervisor.ts --kill
  _rc=$?
  # --kill rc: 0 = killed/already gone, 1 = pidfile absent (not running),
  # 2 = pidfile unreadable/corrupt OR a signal failed (e.g. EPERM) → bridge
  # MAY still be running (supervisor keeps the pidfile in that case).
  if [ "$DRY_RUN" -eq 0 ] && [ "$_rc" -ge 2 ]; then
    echo "  WARN: supervisor --kill rc=$_rc — bridge may still be running; check manually." >&2
    fail_step "[1/8] telegram bridge: could not stop the supervisor"
  fi
fi
echo ""

# --- [2/8] remove telegram pairing + bridge state ----------------------------
echo "[2/8] Removing telegram pairing + bridge state..."
if [ "$HALTED" -eq 1 ]; then
  echo "  SKIPPED: step 1 could not stop the bridge — halted after an earlier failure"
  STEPS_INCOMPLETE+=("[2/8] telegram pairing + bridge state: skipped — halted after an earlier failure")
elif ! class_removes "$_ix_channel" && ! class_removes "$_ix_bridge"; then
  if [ "$KEEP_TELEGRAM_STATE" -eq 1 ]; then
    echo "  kept (--keep-telegram-state)."
  elif state_removed; then
    echo "  kept (manifest class keep): $CHANNEL_DIR, $BRIDGE_ROOT"
  else
    echo "  kept (operator state; pass --purge-state to remove): $CHANNEL_DIR, $BRIDGE_ROOT"
  fi
else
  for _ix_dir in "$_ix_channel" "$_ix_bridge"; do
    if [ "$_ix_dir" = "$_ix_channel" ]; then _dir="$CHANNEL_DIR"; else _dir="$BRIDGE_ROOT"; fi
    if [ "$HALTED" -eq 1 ]; then
      echo "  skipped: $_dir (halted after an earlier failure)"
      STEPS_INCOMPLETE+=("[2/8] telegram pairing + bridge state: $_dir skipped — halted after an earlier failure")
      continue
    fi
    if ! class_removes "$_ix_dir"; then
      echo "  kept (manifest class ${M_CLASS[$_ix_dir]}): $_dir"
      continue
    fi
    if suspicious_rm_path "$_dir"; then
      echo "  WARN: refusing to remove suspicious path: '$_dir'" >&2
      fail_step "[2/8] telegram pairing + bridge state: refused a suspicious path ('$_dir')"
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
        fail_step "[2/8] telegram pairing + bridge state: $_dir could not be removed"
      fi
    elif [ -d "$_dir" ]; then
      if run rm -rf -- "$_dir"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          echo "  removed: $_dir"
        fi
      else
        echo "  WARN: failed to remove $_dir — residue remains; remove it manually." >&2
        fail_step "[2/8] telegram pairing + bridge state: $_dir could not be removed"
      fi
    else
      echo "  absent, skipping: $_dir"
    fi
  done
  echo "  NOTE: deleting the local token does NOT revoke it — if decommissioning"
  echo "  the bot, revoke the token via @BotFather too."
fi
echo ""

# --- [3/8] remove scheduled jobs ---------------------------------------------
# Mirrors scripts/handover/arm-resume.sh job discovery: schtasks task names
# on Windows; at-job body marker / crontab line marker on Linux/macOS.
echo "[3/8] Removing scheduled jobs (HIMMEL-Resume-*, HimmelTelegramBridge)..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[3/8] scheduled jobs: skipped — halted after an earlier failure")
elif [ "$SKIP_TASKS" -eq 1 ]; then
  echo "  kept (--skip-tasks)."
elif ! class_removes "$_ix_jobs"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_jobs]})."
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
    fail_step "[3/8] scheduled jobs: could not enumerate schtasks"
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
        fail_step "[3/8] scheduled jobs: could not delete $_task"
      fi
    done <<EOF
$_tasks
EOF
    [ "$_found" -eq 0 ] && echo "  no matching scheduled tasks found."
  fi
else
  _found=0
  _query_failed=0
  # HIMMEL-3332 S8: the routines a cadence arm recorded, plus the report of the
  # job rows that were already the operator's (kept, never removed).
  _rec_cron=$(ledger_job_markers cron)
  _rec_at=$(ledger_job_markers at)
  [ "$LEDGER_OK" -eq 1 ] && ledger_report_preexisted_units job
  if command -v atq >/dev/null 2>&1; then
    # Capture the atq rc separately — `atq || true` would mask an
    # enumeration failure as "no jobs" (same precedent as above).
    _atq_out=$(atq 2>&1)
    _atq_rc=$?
    if [ "$_atq_rc" -ne 0 ]; then
      _query_failed=1
      echo "  WARN: atq failed (rc=$_atq_rc) — cannot enumerate at jobs; they may remain." >&2
      fail_step "[3/8] scheduled jobs: could not enumerate at jobs"
    else
      while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _job_id=$(printf '%s' "$_line" | awk '{print $1}')
        [ -z "$_job_id" ] && continue
        _at_body=$(at -c "$_job_id" 2>/dev/null)
        _at_marker=""
        case "$_at_body" in
          *HIMMEL-Resume-*) _at_marker="HIMMEL-Resume-" ;;
          *)
            if [ -n "$_rec_at" ]; then
              while IFS= read -r _l; do
                _at_marker=$(job_line_marker "$_l" "$_rec_at") && break
                _at_marker=""
              done <<EOF
$_at_body
EOF
            fi ;;
        esac
        if [ -n "$_at_marker" ]; then
          _found=1
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY: atrm $_job_id"
            ledger_job_outcome "$_at_marker" removed ours
          elif atrm "$_job_id" 2>/dev/null; then
            echo "  removed at job: $_job_id ($_at_marker)"
            ledger_job_outcome "$_at_marker" removed ours
          else
            echo "  WARN: failed to remove at job: $_job_id" >&2
            fail_step "[3/8] scheduled jobs: could not remove at job $_job_id"
            ledger_job_outcome "$_at_marker" failed step-failed
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
      # HIMMEL-3332 S8: also drop the lines the ledger says a cadence arm added.
      # Only the recorded markers, matched EXACTLY as the trailing ` # <marker>`.
      _cron_hit=""
      while IFS= read -r _m; do
        [ -n "$_m" ] || continue
        while IFS= read -r _l; do
          if job_line_marker "$_l" "$_m" >/dev/null; then _cron_hit="$_cron_hit$_m"$'\n'; break; fi
        done <<EOF
$_cron_out
EOF
      done <<EOF
$_rec_cron
EOF
      _cron_do=0
      case "$_cron_out" in *HIMMEL-Resume-*) _cron_do=1 ;; esac
      [ -n "$_cron_hit" ] && _cron_do=1
      if [ "$_cron_do" -eq 1 ]; then
        _found=1
        if [ "$DRY_RUN" -eq 1 ]; then
          echo "DRY: crontab — strip lines containing HIMMEL-Resume- and the recorded jobs below"
          while IFS= read -r _m; do
            [ -n "$_m" ] || continue
            echo "DRY: crontab — remove recorded cron job: $_m"
            ledger_job_outcome "$_m" removed ours
          done <<EOF
$_cron_hit
EOF
        # cron_strip_recorded always returns 0: a crontab whose every line is a
        # himmel line legitimately becomes an empty one, and a filter that ended
        # rc 1 would otherwise mask that successful rewrite as failed.
        elif printf '%s\n' "$_cron_out" | cron_strip_recorded "$_rec_cron" | crontab -; then
          case "$_cron_out" in *HIMMEL-Resume-*) echo "  stripped HIMMEL-Resume-* lines from crontab" ;; esac
          while IFS= read -r _m; do
            [ -n "$_m" ] || continue
            echo "  removed cron job: $_m"
            ledger_job_outcome "$_m" removed ours
          done <<EOF
$_cron_hit
EOF
        else
          echo "  WARN: failed to rewrite crontab — HIMMEL-Resume-* and recorded lines may remain." >&2
          fail_step "[3/8] scheduled jobs: could not rewrite crontab"
          while IFS= read -r _m; do
            [ -n "$_m" ] || continue
            ledger_job_outcome "$_m" failed step-failed
          done <<EOF
$_cron_hit
EOF
        fi
      fi
    elif [ "$_cron_rc" -eq 1 ] && { [ ! -s "$_cron_err" ] || grep -qi 'no crontab' "$_cron_err"; }; then
      : # no crontab installed — genuinely nothing to do
    else
      _query_failed=1
      echo "  WARN: crontab -l failed (rc=$_cron_rc) — cannot enumerate cron jobs;" >&2
      echo "  HIMMEL-Resume-* lines may remain." >&2
      fail_step "[3/8] scheduled jobs: could not enumerate crontab"
    fi
    rm -f "$_cron_err"
  fi
  [ "$_found" -eq 0 ] && [ "$_query_failed" -eq 0 ] && echo "  no matching scheduled jobs found."
fi
echo ""

# WHY (HIMMEL-2754): wet-run removal scopes deliberately outlive a halted
# teardown so a retry can remove marketplaces at their original scopes.
# Successful teardown removes the handoff with the cache in the last step.
_scope_map=""
# HIMMEL-3332 S6: --ledger-owned handoff for uninstall-plugins.sh — a TSV of
# the plugin/marketplace register units the fold says himmel itself installed
# (prov_read_owned). Only built when the ledger loaded; [4/8]/[7/8] pass it
# through so a pre-existing plugin/marketplace is told apart from himmel's own.
_ledger_owned=""
if [ "$LEDGER_OK" -eq 1 ] && [ "$HALTED" -eq 0 ] && [ "$SKIP_PLUGINS" -eq 0 ] &&
   { class_removes "$_ix_plug" || class_removes "$_ix_mkt"; }; then
  if _ledger_owned=$(mktemp "${TMPDIR:-/tmp}/himmel-uninstall-ledger-owned.XXXXXX"); then
    # Same fix as the earlier ledger-load trap: never rm -f "$_scope_map" here
    # -- it is not assigned yet, and by the time it is (below), a real run
    # points it at the PERSISTENT cache-dir handoff that must survive a halt.
    trap 'prov_read_cleanup; rm -f "${_ledger_owned:-}"' EXIT
    prov_read_owned "$_ledger_owned"
  else
    _ledger_owned=""
    fail_step "[4/8] Claude plugins: could not create the ledger-owned handoff file"
  fi
fi
if [ "$HALTED" -eq 0 ] && [ "$SKIP_PLUGINS" -eq 0 ] && { class_removes "$_ix_plug" || class_removes "$_ix_mkt"; }; then
  if [ "$DRY_RUN" -eq 1 ]; then
    if _scope_map=$(mktemp "${TMPDIR:-/tmp}/himmel-uninstall-scope-map.XXXXXX"); then
      trap 'prov_read_cleanup; rm -f "${_scope_map:-}" "${_ledger_owned:-}"' EXIT
      if [ -d "$HIMMEL_CACHE_DIR" ] && [ ! -L "$HIMMEL_CACHE_DIR" ] &&
         ! suspicious_rm_path "$HIMMEL_CACHE_DIR" &&
         [ -f "$HIMMEL_CACHE_DIR/uninstall-scope-map" ] &&
         [ ! -L "$HIMMEL_CACHE_DIR/uninstall-scope-map" ] &&
         [ -r "$HIMMEL_CACHE_DIR/uninstall-scope-map" ]; then
        # WHY (HIMMEL-2754): a failed read empties the handoff; make the fallback preview explicit.
        cat "$HIMMEL_CACHE_DIR/uninstall-scope-map" > "$_scope_map" 2>/dev/null || {
          : > "$_scope_map"
          echo "WARN: could not read $HIMMEL_CACHE_DIR/uninstall-scope-map; preview will show marketplace removals at the fallback scope rather than the recorded scopes." >&2
        }
      fi
    else
      _scope_map=""
      fail_step "[4/8] Claude plugins: could not create the scope-map handoff file"
    fi
  else
    _scope_map="$HIMMEL_CACHE_DIR/uninstall-scope-map"
    if [ -L "$HIMMEL_CACHE_DIR" ] || suspicious_rm_path "$HIMMEL_CACHE_DIR" || [ -L "$_scope_map" ] ||
       { [ -e "$HIMMEL_CACHE_DIR" ] && [ ! -d "$HIMMEL_CACHE_DIR" ]; }; then
      echo "WARN: using ephemeral scope-map handoff; removal scopes will not survive a halt because the cache path is not a usable directory for the handoff." >&2
      if _scope_map=$(mktemp "${TMPDIR:-/tmp}/himmel-uninstall-scope-map.XXXXXX"); then
        trap 'prov_read_cleanup; rm -f "${_scope_map:-}" "${_ledger_owned:-}"' EXIT
      else
        _scope_map=""
        fail_step "[4/8] Claude plugins: could not create the scope-map handoff file"
      fi
    elif mkdir -p "$HIMMEL_CACHE_DIR" && : >> "$_scope_map"; then
      :
    else
      _scope_map=""
      fail_step "[4/8] Claude plugins: could not create the scope-map handoff file"
    fi
  fi
fi

# ledger_owned_hand_command <kind: plugins|marketplaces> — the single hand
# command both [4/8] and [7/8] point at when there is no ledger to decide
# ownership (HIMMEL-3332 S6, spec §4/§8 case 3).
ledger_owned_hand_command() {
  printf '    remove by hand: bash %q --scope %q\n' \
    "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" "$PLUGIN_SCOPE"
}

# --- [4/8] uninstall plugins ------------------------------------------------
echo "[4/8] Uninstalling Claude plugins..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[4/8] Claude plugins: skipped — halted after an earlier failure")
elif [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  kept (--skip-plugins)."
elif ! class_removes "$_ix_plug"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_plug]})."
elif ! _claude_bin=$(resolve_tool claude); then
  report_unresolved "[4/8] Claude plugins" claude --skip-plugins
elif [ "$LEDGER_OK" -ne 1 ]; then
  # ponytail (HIMMEL-3332 S6, spec §4): with no ledger to tell a pre-existing
  # plugin apart from himmel's own template plugins, this run keeps ALL of
  # them rather than risk removing one the operator installed themselves.
  echo "  kept (no ledger): himmel's template plugins"
  ledger_owned_hand_command
  if [ "$DRY_RUN" -ne 1 ] && [ "$YES" -ne 1 ] && [ -t 0 ] && [ -t 1 ]; then
    printf "  remove himmel's template plugins anyway? [y/N] "
    read -r _ans
    case "$_ans" in
      [yY]|[yY][eE][sS])
        echo "  using: $_claude_bin (fallback scope: $PLUGIN_SCOPE)"
        _plug_args=(--plugins-only --scope "$PLUGIN_SCOPE" --scope-map "$_scope_map")
        if ! PATH="$(dirname "$_claude_bin"):$PATH" \
            bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
          echo "  WARN: uninstall-plugins.sh reported failures — re-run it directly to inspect." >&2
          fail_step "[4/8] Claude plugins: uninstall-plugins.sh reported failures"
        fi
        ;;
      *) : ;;
    esac
  fi
else
  echo "  using: $_claude_bin (fallback scope: $PLUGIN_SCOPE)"
  ledger_report_preexisted_units plugin
  _plug_ours_units=$(prov_read_units --kind plugin | { while IFS= read -r _u; do
    [ -n "$_u" ] || continue
    [ "$(printf '%s' "$_u" | jq -r '.ours')" = "true" ] && printf '%s\n' "$_u"
  done; })
  _plug_args=(--plugins-only --scope "$PLUGIN_SCOPE" --scope-map "$_scope_map" --ledger-owned "$_ledger_owned")
  [ "$DRY_RUN" -eq 1 ] && _plug_args+=(--dry-run)
  # uninstall-plugins.sh does its own `command -v claude` and hard-exits when
  # it fails, so the resolved directory has to be on the CHILD's PATH — passing
  # the path alone would leave the child just as blind as this script was.
  if PATH="$(dirname "$_claude_bin"):$PATH" \
      bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
    _plug_outcome="removed"; _plug_reason="ours"
  else
    echo "  WARN: uninstall-plugins.sh reported failures — re-run it directly to inspect." >&2
    fail_step "[4/8] Claude plugins: uninstall-plugins.sh reported failures"
    _plug_outcome="failed"; _plug_reason="step-failed"
  fi
  # ponytail: the step's rc is the finest grain uninstall-plugins.sh reports —
  # a partial failure (one plugin removed, another blocked) still marks every
  # himmel-owned unit "failed" here rather than tracking per-plugin results.
  if [ -n "$_plug_ours_units" ]; then
    while IFS= read -r _u; do
      [ -z "$_u" ] && continue
      prov_read_outcome "$_plug_outcome" "$_u" "$_plug_reason"
    done <<EOF
$_plug_ours_units
EOF
  fi
fi
echo ""

# --- [5/8] uninstall git hooks -------------------------------------------------
# Mirror of setup-hooks.sh / setup.sh step 2.
echo "[5/8] Uninstalling git hooks (this repo)..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[5/8] git hooks: skipped — halted after an earlier failure")
elif [ "$SKIP_HOOKS" -eq 1 ]; then
  echo "  kept (--skip-hooks)."
elif ! class_removes "$_ix_ghooks"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_ghooks]})."
elif command -v git >/dev/null 2>&1 && ! _hooks_git_probe=$(LC_ALL=C git -C "$HOOKS_REPO_ROOT" rev-parse --is-inside-work-tree 2>&1); then
  # HIMMEL-2854: a `--scope user` offboard run from a plain (non-git) $PWD has
  # no repo-local hooks to remove — the native-gate scan and every
  # `pre-commit uninstall` call below assume a git work tree and otherwise
  # fail_step (and HALT every later step) for a directory that was never a
  # git repo to begin with. But `rev-parse` also fails non-zero for a repo
  # git refuses to trust (safe.directory dubious-ownership) or one whose
  # metadata it could not read — those ARE git work trees that may still
  # carry installed hooks. git's "not a git repository" wording is identical
  # whether `.git` is genuinely absent or present-but-broken (e.g. a missing
  # HEAD), so string-matching that text cannot tell them apart (codex-1,
  # round 3) — check for a `.git` entry instead. A single check at
  # HOOKS_REPO_ROOT is not enough either (codex-1, round 4): HOOKS_REPO_ROOT
  # can itself be a SUBDIRECTORY of the real repo root (dubious-ownership
  # rejects rev-parse the same way from a subdirectory), where `.git` lives
  # only at the ancestor. Walk up, mirroring git's own repo-discovery search,
  # so only a confirmed absence of `.git` anywhere in the ancestor chain
  # takes the clean skip.
  #
  # HIMMEL-2859 (codex-1 round 6): a relative HOOKS_REPO_ROOT reaches
  # dirname's textual fixed point (".") without ever visiting the real
  # absolute ancestors above $PWD — resolve to an absolute physical path
  # first; an unresolvable start (dir missing, or inaccessible) is never a
  # clean skip.
  # codex-1 (panel round 1): a relative HOOKS_REPO_ROOT is subject to CDPATH
  # lookup, which can make `cd` print its resolved destination to stdout and
  # contaminate the captured path — clear it for this cd only (not a special
  # builtin, so the assignment does not persist past the command).
  if _hooks_probe_dir="$(CDPATH='' cd -- "$HOOKS_REPO_ROOT" 2>/dev/null && pwd -P)" && [ -n "$_hooks_probe_dir" ]; then
    # HIMMEL-2857 (codex-1 round 5): `[ -e ]` can't tell "confirmed absent"
    # apart from "inspection failed" — a permission-denied ancestor (stat
    # fails) or a dangling `.git` symlink (target absent) both read as
    # absence and could walk past a real repo. Classify each level: (a)
    # `.git` present → found; (b) `.git` a dangling symlink → found but
    # unresolvable; (c) the directory itself unreadable/unsearchable →
    # unresolvable. Only a chain where every level is inspectable and `.git`
    # is confirmed absent may continue to the next ancestor.
    _hooks_found_git=0
    _hooks_unresolved_reason=""
    while :; do
      if [ -e "$_hooks_probe_dir/.git" ]; then
        _hooks_found_git=1
        break
      elif [ -L "$_hooks_probe_dir/.git" ]; then
        _hooks_found_git=1
        _hooks_unresolved_reason=" (a dangling .git symlink at $_hooks_probe_dir/.git)"
        break
      elif ! [ -r "$_hooks_probe_dir" ] || ! [ -x "$_hooks_probe_dir" ]; then
        _hooks_found_git=1
        _hooks_unresolved_reason=" (an inaccessible ancestor directory: $_hooks_probe_dir)"
        break
      fi
      _hooks_probe_parent="$(dirname "$_hooks_probe_dir")"
      # Stop at any root spelling: "/", ".", and Git-for-Windows "C:/" —
      # dirname never reaches "/" for a drive-letter root (it settles at a
      # fixed point instead), so a bare `!= "/"` check spins forever (CodeRabbit).
      [ "$_hooks_probe_parent" != "$_hooks_probe_dir" ] || break
      _hooks_probe_dir="$_hooks_probe_parent"
    done
  else
    _hooks_found_git=1
    _hooks_unresolved_reason=" (HOOKS_REPO_ROOT could not be resolved to an absolute path: $HOOKS_REPO_ROOT)"
  fi
  if [ "$_hooks_found_git" -eq 0 ]; then
    echo "  skipped: $HOOKS_REPO_ROOT is not a git work tree — no repo-local hooks to remove (run from the adopted project to remove its hooks)"
  else
    echo "  ERROR: could not confirm whether $HOOKS_REPO_ROOT is a git work tree — installed hooks cannot be ruled out.$_hooks_unresolved_reason" >&2
    echo "  git said: $_hooks_git_probe" >&2
    fail_step "[5/8] git hooks: hooks-repo git status unresolved"
  fi
else
  # HIMMEL-2839: native gates (HIMMEL-2771) live outside the pre-commit
  # framework — remove them independent of whether pre-commit resolves below.
  if ! remove_native_gate_hooks; then
    fail_step "[5/8] git hooks: native gate hook(s) survived removal"
  fi
  if ! _precommit_bin=$(resolve_tool pre-commit); then
    repo_has_framework_hooks; _rc=$?
    if [ "$_rc" -eq 0 ]; then
      report_unresolved "[5/8] git hooks" pre-commit --skip-hooks
    elif [ "$_rc" -eq 2 ]; then
      echo "  ERROR: cannot determine whether this repo carries framework hooks — the hooks directory did not resolve." >&2
      echo "  Put git on PATH and re-run." >&2
      fail_step "[5/8] git hooks: hook location unresolved — installed framework hooks cannot be ruled out"
    else
      note_step "\`pre-commit\` not found and this repo carries no framework hooks — nothing to uninstall"
    fi
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
      if ! (cd "$HOOKS_REPO_ROOT" && run "$_precommit_bin" uninstall ${_cmd_args[@]+"${_cmd_args[@]}"}); then
        echo "  WARN: pre-commit uninstall $_label failed." >&2
        fail_step "[5/8] git hooks: pre-commit uninstall $_label failed"
      fi
    done
  fi
  # HIMMEL-3249: hand the adopter's displaced hooks back. Runs LAST and only when
  # nothing above failed — a restored hook is marker-free, so restoring before
  # the framework check above would let it trip that check within this same run.
  if [ "$HALTED" -eq 0 ]; then
    if ! class_removes "$_ix_hbak"; then
      echo "  kept displaced hook backups (manifest class ${M_CLASS[$_ix_hbak]})."
    elif ! restore_hook_backups; then
      fail_step "[5/8] git hooks: could not restore your displaced hook(s) (<hook>.himmel-backup left in place)"
    fi
  fi
fi
echo ""

# --- [6/8] unwire user/project settings.json (HIMMEL-460, HIMMEL-2776) -------
# Symmetric inverse of setup.sh [9/10] + adopt: remove the
# statusLine, env.HIMMEL_REPO, env.LUNA_VAULT_PATH, env.HANDOVER_DIR
# (HIMMEL-839), and the UNIVERSAL hooks that himmel wired into
# ~/.claude/settings.json. Each helper removes ONLY its own key/stanza
# (refuses invalid JSON, preserves every non-himmel key: rtk guard, the
# operator's own hooks, MCP config). --dry-run flows through to each.
echo "[6/8] Unwiring ~/.claude/settings.json (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, HANDOVER_DIR, hooks)..."
# One sanctioned unwire sequence for both scopes; retain the user-scope order.
#
# HIMMEL-3058: the patterns the read-back matches are read from THIS script's
# own sibling libs (never from $REPO_ROOT, which a fixture or a stub can
# replace), each in a subshell — those libs set `set -euo pipefail` when
# sourced. The read-back re-reads the settings file with jq; it never trusts a
# helper's return code, because a helper that exits 0 without removing anything
# is the failure this guards against.
HIMMEL_HOOK_PAT="$( . "$SCRIPT_DIR/lib/unwire-pretooluse-hooks.sh" >/dev/null 2>&1; printf '%s|%s' "${_UNWIRE_PRE_PAT:-}" "${_UNWIRE_SS_PAT:-}" )"
[ "$HIMMEL_HOOK_PAT" = "|" ] && HIMMEL_HOOK_PAT=""
HIMMEL_SL_PAT="$( . "$SCRIPT_DIR/lib/unwire-statusline.sh" >/dev/null 2>&1; printf '%s' "${_UNWIRE_SL_PAT:-}" )"

# himmel_wiring_lines <settings> [mask_hooks mask_sl mask_repo mask_vault
# mask_hd] — one "<what>" line per himmel wiring currently in the file: each
# himmel hook command, the himmel statusLine and each of the three himmel env
# keys (env.CLAUDE_HUD_ALLOW_EXTRA_CMD is not listed: the statusline helper
# never removes it; only the ledger's /env/CLAUDE_HUD_ALLOW_EXTRA_CMD unit does,
# so with no ledger it stays beside the kept statusLine). Not suppressing: a jq failure is a
# non-zero rc, so the read-back cannot mistake "could not read" for "clean".
# The five mask_* flags (HIMMEL-3332 S6, all default 0 = unmasked when
# omitted) exclude a category the ledger explicitly kept or restored — a
# PROTECTED unit must never read back as "STILL WIRED", it is wired on
# purpose.
himmel_wiring_lines() {
  local settings="$1" mask_hooks="${2:-0}" mask_sl="${3:-0}" mask_repo="${4:-0}" mask_vault="${5:-0}" mask_hd="${6:-0}"
  # HIMMEL-3332 S6 fix: jq's --argjson hands these in as JSON NUMBERS (0/1),
  # and jq truthiness treats 0 as truthy (only `false`/`null` are falsy) — so
  # a `($mX|not)` test was always false regardless of the mask value, which
  # silently excluded EVERY hook/statusLine/env row from both the dry-run
  # preview (D1/S1: hook command lines never appeared) and, far more
  # seriously, the post-removal read-back verification, which could then
  # never report "STILL WIRED" no matter what a broken helper left behind
  # (R1/R2: a no-op unwire falsely completed instead of halting). Compare the
  # mask against 0 numerically instead of relying on jq boolean coercion.
  jq -r --arg pat "$HIMMEL_HOOK_PAT" --arg sl "$HIMMEL_SL_PAT" \
      --argjson mhooks "$mask_hooks" --argjson msl "$mask_sl" \
      --argjson mrepo "$mask_repo" --argjson mvault "$mask_vault" --argjson mhd "$mask_hd" '
    ((.hooks // {}) | to_entries[] | .key as $ev | (.value // [])[]? | (.hooks // [])[]?
      | (.command // "") | select(($mhooks==0) and test($pat)) | "hook \($ev): \(.)"),
    ((.statusLine.command? // "") | select(($msl==0) and test($sl)) | "statusLine: \(.)"),
    ((.env // {}) | to_entries[]
      | select(.key | IN("HIMMEL_REPO","LUNA_VAULT_PATH","HANDOVER_DIR"))
      | select(
          (.key=="HIMMEL_REPO" and ($mrepo==0)) or
          (.key=="LUNA_VAULT_PATH" and ($mvault==0)) or
          (.key=="HANDOVER_DIR" and ($mhd==0)))
      | "env.\(.key)=\(.value)")
  ' "$settings"
}

unwire_settings() {
  local settings="$1" helper _line _left _units _u _seen_sl=0 _seen_hd=0 _kept_as
  local _mask_hooks=0 _mask_sl=0 _mask_repo=0 _mask_vault=0 _mask_hd=0
  _LEDGER_PROTECTED=""
  if [ "$LEDGER_OK" -eq 1 ]; then
    # Ledger-driven per-unit pass (HIMMEL-3332 S6): every json-key/json-elem
    # fold unit recorded at THIS settings path gets its own verdict —
    # removed, restored from its recorded backup, or kept (already-absent,
    # preexisted, user-modified since install, or no backup to restore
    # from). A key/unit the ledger never recorded (predates per-key
    # recording) is untouched here — the mask flags below only ever protect
    # a key the ledger EXPLICITLY kept or restored, so today's helper loop
    # further down still runs for anything the ledger stayed silent on.
    _units="$(prov_read_units --path "$settings" --kind json-key)
$(prov_read_units --path "$settings" --kind json-elem)"
    while IFS= read -r _u; do
      [ "$HALTED" -eq 0 ] || break
      [ -n "$_u" ] || continue
      # F3 (parent review): the /env container unit's recorded post sha goes
      # stale the moment a second /env/KEY is added, so it would always read
      # user-modified here — skip it with no print/outcome row;
      # prov_read_drop_env_if_ours (below, after the helper loop) drops the
      # now-empty container once its /env/<KEY> units are handled.
      case "$(printf '%s' "$_u" | jq -r '.unit // ""')" in
        /env) continue ;;
        # R2-codex4: track whether the ledger recorded a unit AT ALL for
        # these two rows -- distinct from whether ledger_apply_unit ended up
        # protecting it (below), so a governed-but-e.g.-removed row still
        # counts as "seen" and does not fall into the not-in-ledger branch.
        /statusLine)          _seen_sl=1 ;;
        /env/HANDOVER_DIR)    _seen_hd=1 ;;
      esac
      ledger_apply_unit "$_u"
    done <<EOF
$_units
EOF
    case "$_LEDGER_PROTECTED" in *$'\n''/statusLine'*)          _mask_sl=1 ;; esac
    case "$_LEDGER_PROTECTED" in *$'\n''/env/HIMMEL_REPO'*)     _mask_repo=1 ;; esac
    case "$_LEDGER_PROTECTED" in *$'\n''/env/LUNA_VAULT_PATH'*) _mask_vault=1 ;; esac
    case "$_LEDGER_PROTECTED" in *$'\n''/env/HANDOVER_DIR'*)    _mask_hd=1 ;; esac
    case "$_LEDGER_PROTECTED" in *$'\n''/hooks/'*)              _mask_hooks=1 ;; esac
    # HIMMEL-3332 S6 fix: no early return here for DRY_RUN. ledger_apply_unit
    # above already printed its own per-unit DRY line for anything the
    # ledger DID track, but a key/unit the ledger never recorded (predates
    # per-key recording) is untouched by it -- the shared preview block
    # below (same one the no-ledger branch uses) is what falls through to
    # preview those, mirroring the WET helper loop further down, which
    # already unconditionally re-runs every non-masked helper regardless of
    # whether the ledger already handled it. Without this fall-through, a
    # --dry-run under a ledger silently under-reported HIMMEL_REPO /
    # LUNA_VAULT_PATH / hook removals the wet run still performs (caught by
    # U22: 5 rows expected, only the hooks line was printed).
  fi
  # ponytail (HIMMEL-3332 S6, spec §4 six rows): a pre-existing statusLine or
  # env.HANDOVER_DIR cannot be told from himmel's own without a ledger unit
  # recording it — both are kept and reported with a hand command instead of
  # letting today's unwire-*.sh helpers remove them blindly. R2-codex4: a
  # LOADED ledger that stayed silent about one of these two rows (predates
  # per-key recording) must be treated exactly the same way — "kept (no
  # ledger)" would be misleading with a real ledger present, so that case
  # reads "kept (not in ledger)" instead; the hand command is identical.
  if [ "$LEDGER_OK" -ne 1 ] || [ "$_seen_sl" -eq 0 ]; then
    _kept_as="no ledger"; [ "$LEDGER_OK" -eq 1 ] && _kept_as="not in ledger"
    if [ -n "$HIMMEL_SL_PAT" ] && jq -e --arg sl "$HIMMEL_SL_PAT" \
        '((.statusLine.command? // "") | test($sl))' "$settings" >/dev/null 2>&1; then
      if [ "$DRY_RUN" -eq 1 ]; then echo "DRY: would keep ($_kept_as) statusLine  [$settings]"
      else echo "  kept ($_kept_as): statusLine  [$settings] — remove by hand: bash $REPO_ROOT/scripts/lib/unwire-statusline.sh $settings"
      fi
      _mask_sl=1
    fi
  fi
  if [ "$LEDGER_OK" -ne 1 ] || [ "$_seen_hd" -eq 0 ]; then
    _kept_as="no ledger"; [ "$LEDGER_OK" -eq 1 ] && _kept_as="not in ledger"
    if jq -e '((.env.HANDOVER_DIR? // "") | length) > 0' "$settings" >/dev/null 2>&1; then
      if [ "$DRY_RUN" -eq 1 ]; then echo "DRY: would keep ($_kept_as) env.HANDOVER_DIR  [$settings]"
      else echo "  kept ($_kept_as): env.HANDOVER_DIR  [$settings] — remove by hand: bash $REPO_ROOT/scripts/lib/unwire-handover-dir.sh $settings"
      fi
      _mask_hd=1
    fi
  fi
  # HIMMEL-3332 S6 R2-codex5: a halt mid per-unit ledger loop must stop HERE
  # -- neither the DRY preview nor the unconditional legacy-helper loop below
  # may run afterward (they would strip a unit the halted pass never got to
  # verdict, or re-strip one it already restored).
  [ "$HALTED" -eq 0 ] || return 0
  # Print exactly what is about to change (dry-run: what WOULD change) or, on
  # a wet run, narrate it -- masking out anything either branch above already
  # protected. HIMMEL-3332 S6 fix: shared by the ledger and no-ledger paths,
  # since a key/unit neither branch masked still needs this preview whether
  # the ledger stayed silent on it (predates per-key recording) or there is
  # no ledger at all -- mirroring the WET helper loop below, which already
  # unconditionally re-runs every non-masked helper regardless of LEDGER_OK.
  # Preview only: an unreadable file is reported by the helpers / the read-back.
  if [ -n "$HIMMEL_HOOK_PAT" ] && [ -n "$HIMMEL_SL_PAT" ]; then
    # HIMMEL-3332 S6 R2-codex8: pass every COMPUTED mask (not a literal 0 for
    # mask_hooks/mask_repo/mask_vault) -- the DRY preview must never announce
    # removal of a unit the ledger pass above already kept/restored.
    { himmel_wiring_lines "$settings" "$_mask_hooks" "$_mask_sl" "$_mask_repo" "$_mask_vault" "$_mask_hd" 2>/dev/null || true; } | while IFS= read -r _line; do
      if [ "$DRY_RUN" -eq 1 ]; then echo "DRY: would remove $_line  [$settings]"
      else echo "  removing $_line  [$settings]"; fi
    done
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    # One row per still-unmasked helper (the hooks helper prints its own
    # DRY row), so a preview never shows fewer removals than the real run.
    # HIMMEL-3332 S6 fix: statusLine/HANDOVER_DIR need this same unconditional
    # row too -- the pre-S6 baseline always printed all four (regardless of
    # whether the key was actually present, since the helpers are idempotent
    # no-ops), and the no-ledger branch's "kept (no ledger)" checks above only
    # fire when the value IS present, leaving an absent-and-unmasked case with
    # no preview line at all otherwise (caught by U22: 3 rows instead of 5).
    [ "$_mask_sl" -eq 0 ]    && echo "DRY: unwire statusLine (himmel) from $settings"
    [ "$_mask_repo" -eq 0 ]  && echo "DRY: unwire env.HIMMEL_REPO from $settings"
    [ "$_mask_vault" -eq 0 ] && echo "DRY: unwire env.LUNA_VAULT_PATH from $settings"
    [ "$_mask_hd" -eq 0 ]    && echo "DRY: unwire env.HANDOVER_DIR from $settings"
    if [ "$_mask_hooks" -eq 0 ] && ! bash "$REPO_ROOT/scripts/lib/unwire-pretooluse-hooks.sh" "$settings" 1; then
      fail_step "[6/8] settings unwire: unwire-pretooluse-hooks dry-run failed"
    fi
    return
  fi
  for helper in unwire-statusline unwire-himmel-repo unwire-luna-vault unwire-handover-dir unwire-pretooluse-hooks; do
    case "$helper" in
      unwire-statusline)   [ "$_mask_sl" -eq 1 ]    && continue ;;
      unwire-himmel-repo)  [ "$_mask_repo" -eq 1 ]  && continue ;;
      unwire-luna-vault)   [ "$_mask_vault" -eq 1 ] && continue ;;
      unwire-handover-dir) [ "$_mask_hd" -eq 1 ]    && continue ;;
      unwire-pretooluse-hooks)
        # ponytail: any PROTECTED hook chain at this path skips the WHOLE
        # helper rather than surgically re-running it for only the
        # ungoverned entries — an ungoverned himmel hook could survive
        # alongside a kept/restored one at the same event.
        [ "$_mask_hooks" -eq 1 ] && continue ;;
    esac
    if ! bash "$REPO_ROOT/scripts/lib/$helper.sh" "$settings"; then
      echo "  WARN: $helper reported a problem; setup-state may remain." >&2
      fail_step "[6/8] settings unwire: $helper failed"
    fi
  done
  [ "$HALTED" -eq 0 ] || return 0
  if [ "$LEDGER_OK" -eq 1 ] && ! prov_read_drop_env_if_ours "$settings"; then
    echo "  WARN: could not drop the now-empty /env from $settings" >&2
    fail_step "[6/8] ledger: could not drop the now-empty /env from $settings"
  fi
  # Positive read-back: the file itself, not the helpers' exit codes. A
  # PROTECTED key/hook is masked out here too — it is meant to still be
  # wired, so it must never read back as "STILL WIRED".
  if [ -z "$HIMMEL_HOOK_PAT" ] || [ -z "$HIMMEL_SL_PAT" ]; then
    echo "  ERROR: cannot verify $settings — hook/statusLine patterns unavailable" >&2
    fail_step "[6/8] read-back: cannot verify $settings (hook/statusLine patterns unavailable)"
  elif ! _left="$(himmel_wiring_lines "$settings" "$_mask_hooks" "$_mask_sl" "$_mask_repo" "$_mask_vault" "$_mask_hd")"; then
    echo "  ERROR: could not read $settings back" >&2
    fail_step "[6/8] read-back: could not read $settings back"
  elif [ -n "$_left" ]; then
    printf '%s\n' "$_left" | while IFS= read -r _line; do echo "  STILL WIRED: $_line  [$settings]" >&2; done
    fail_step "[6/8] read-back: himmel hook/statusLine/env still wired in $settings"
  else
    echo "  verified: no himmel wiring left in $settings"
  fi
}

# Same project target as install-plugins.sh/adopt.sh: invocation CWD, not the
# clone providing the helpers. Match checkUninstallCompleteness's identity
# guard: direct inode equality, then git-common-dir for linked worktrees.
# rc 2 means identity is unresolved, never permission to edit repo source.
project_is_himmel_checkout() {
  local dir="${1:-$PWD}" source_root project_common source_common
  source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || return 2
  [ "$dir" -ef "$source_root" ] && return 0
  [ -e "$dir/.git" ] || return 1
  project_common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 2
  source_common=$(git -C "$source_root" rev-parse --git-common-dir 2>/dev/null) || return 2
  case "$project_common" in /*|[A-Za-z]:[/\\]*) ;; *) project_common="$dir/$project_common" ;; esac
  case "$source_common" in /*|[A-Za-z]:[/\\]*) ;; *) source_common="$source_root/$source_common" ;; esac
  [ "$project_common" -ef "$source_common" ]
}

# unwire_recorded_projects — HIMMEL-3332 S8 [6/8]: every OTHER project the
# ledger recorded himmel wiring into (a project-scope settings row whose path
# is not $PWD's), unwired through the same unwire_settings pass and behind the
# same guards as the $PWD block: himmel's own checkout is kept, an unresolved
# identity or a symlinked `.claude`/settings.json is refused, a target that is
# already gone is only reported. The list comes from the ledger alone — no
# directory is ever discovered by scanning the disk.
unwire_recorded_projects() {
  local _targets _t _dir _id _dir_real
  _targets=$(prov_read_units --row project-settings \
    | jq -r 'select(.scope == "project" and (.kind == "json-key" or .kind == "json-elem")) | .path // empty' \
    | grep '/\.claude/settings\.json$' | sort -u || true)
  while IFS= read -r _t; do
    [ "$HALTED" -eq 0 ] || return 0
    [ -n "$_t" ] || continue
    _dir="${_t%/.claude/settings.json}"
    [ "$_dir" -ef "$PWD" ] && continue   # $PWD's own settings are the block above's job
    if [ ! -e "$_t" ] && [ ! -L "$_t" ]; then
      echo "  project settings: recorded target already gone: $_t"
      continue
    fi
    # a recorded dir replaced after recording with a symlink (itself or an
    # ancestor component) must not silently redirect unwire_settings into an
    # unrelated directory: resolve it and require the string to match what
    # was recorded (no bare `realpath` — this file targets bash 3.2/macOS).
    _dir_real=$(cd -P -- "$_dir" 2>/dev/null && pwd) || _dir_real=""
    _id=0
    project_is_himmel_checkout "$_dir" || _id=$?
    if [ "$_id" -eq 0 ]; then
      echo "  project settings: kept $_t (himmel's own checkout)"
    elif [ "$_id" -eq 2 ]; then
      echo "  project settings: cannot resolve checkout identity of $_dir — refusing to unwire" >&2
      fail_step "[6/8] project settings: checkout identity unresolved for $_dir"
    elif [ -L "$_dir/.claude" ] || [ -L "$_t" ] || [ ! -f "$_t" ] || [ "$_dir_real" != "$_dir" ]; then
      echo "  project settings: refusing non-regular or symlinked target $_t" >&2
      fail_step "[6/8] project settings: unsafe target $_t"
    else
      unwire_settings "$_t"
      if [ "$HALTED" -eq 1 ]; then
        echo "  project settings: unwire failed $_t" >&2
      elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: project settings: would unwire $_t"
      else
        echo "  project settings: unwired $_t"
      fi
    fi
  done <<EOF
$_targets
EOF
}

# unwire_user_files — the user-scope files install writes beside settings.json
# (HIMMEL-3251): the working-principles block in ~/.claude/CLAUDE.md and
# ~/.codex/AGENTS.md, and the claude-hud config. One helper call per manifest
# row, each row's class deciding whether it acts; the helpers come from THIS
# script's own lib dir (see the HIMMEL-3058 note above) and the read-back
# re-reads the files rather than trusting a helper's rc. --dry-run flows through.
# The rule-file read-back is the helper's own `--probe` (HIMMEL-3333): it must
# agree with the strip about what a marker IS -- a whole line outside a fenced
# code block -- or a file that merely quotes the block would read as still wired.
# HIMMEL-3332 S6 R2-codex4: HIMMEL_HUD_PAT (the pattern used to verify a
# post-strip hud config was really himmel's) is no longer read anywhere --
# the pattern-matched strip below it used to guard is gone, replaced by the
# ledger-or-kept fallback -- so the computation is dropped as an orphan of
# that fix rather than left unused.
unwire_user_files() {
  local _ix _p _dry=0 _probe_rc _hud_units _hu _fc_args _block_unit _fc
  [ "$DRY_RUN" -eq 1 ] && _dry=1
  for _ix in "$_ix_ucm" "$_ix_uam" "$_ix_hud"; do
    # A failure on one file halts the step: never edit the next file after it.
    [ "$HALTED" -eq 0 ] || return 0
    _p="$(m_path "$_ix")"
    if ! class_removes "$_ix"; then
      echo "  kept (manifest class ${M_CLASS[$_ix]}): $_p"
      continue
    fi
    if [ "$_ix" = "$_ix_hud" ]; then
      if [ "$LEDGER_OK" -ne 1 ]; then
        # ponytail (HIMMEL-3332 S6, spec §4 six rows): no ledger to tell a
        # pre-existing claude-hud config from himmel's own — kept, with a
        # hand command, instead of the unconditional strip below.
        echo "  kept (no ledger): $_p — remove by hand: bash $SCRIPT_DIR/lib/unwire-hud-config.sh $_p"
        continue
      fi
      _hud_units="$(prov_read_units --path "$_p" --kind file)"
      if [ -n "$_hud_units" ]; then
        while IFS= read -r _hu; do
          [ "$HALTED" -eq 0 ] || break
          [ -n "$_hu" ] || continue
          ledger_apply_unit "$_hu"
        done <<EOF
$_hud_units
EOF
      # R2-codex4: the ledger loaded but never recorded THIS hud-config path
      # (predates per-file recording) -- treat it exactly like the no-ledger
      # branch above (kept with a hand command), not an unconditional strip;
      # "kept (no ledger)" would be misleading with a real ledger present.
      else
        echo "  kept (not in ledger): $_p — remove by hand: bash $SCRIPT_DIR/lib/unwire-hud-config.sh $_p"
      fi
    else
      _fc_args=()
      if [ "$LEDGER_OK" -eq 1 ]; then
        # HIMMEL-3332 S6: pass the ledger's recorded file_created straight
        # through, overriding the helper's own blank-line guess (see its
        # header). No governed block unit recorded for this path (predates
        # per-file recording) -> _fc_args stays empty, same as before S6.
        _block_unit="$(prov_read_units --path "$_p" --kind block | head -n1)"
        if [ -n "$_block_unit" ] && [ "$(printf '%s' "$_block_unit" | jq -r '.governed')" = "true" ]; then
          # codex-8 fix: `// empty` coalesces an explicit `false` the same
          # as an absent field, dropping a recorded file_created=false into
          # the no-args (helper-guesses) case instead of --file-created no.
          _fc="$(printf '%s' "$_block_unit" | jq -r 'if .fields.file_created == null then empty else (.fields.file_created | tostring) end')"
          case "$_fc" in
            true|yes) _fc_args=(--file-created yes) ;;
            false|no) _fc_args=(--file-created no) ;;
          esac
        fi
      fi
      if ! bash "$SCRIPT_DIR/lib/unwire-user-claude-md.sh" ${_fc_args[@]+"${_fc_args[@]}"} "$_p" "$_dry"; then
        fail_step "[6/8] user rule file: could not strip himmel's block from $_p"
      elif [ "$_dry" -eq 0 ] && [ -f "$_p" ]; then
        # 0 = clean; 3 = a marker is still there; anything else = the probe
        # itself failed, which is NOT a verified-clean file (HIMMEL-3333).
        _probe_rc=0
        bash "$SCRIPT_DIR/lib/unwire-user-claude-md.sh" --probe "$_p" >/dev/null 2>&1 || _probe_rc=$?
        if [ "$_probe_rc" -eq 3 ]; then
          echo "  STILL WIRED: himmel working-principles block  [$_p]" >&2
          fail_step "[6/8] read-back: himmel working-principles block still in $_p"
        elif [ "$_probe_rc" -ne 0 ]; then
          echo "  UNVERIFIED: could not re-read $_p after the strip (probe rc $_probe_rc)" >&2
          fail_step "[6/8] read-back: could not verify $_p (probe rc $_probe_rc)"
        fi
      fi
    fi
  done
}

_user_settings="$USER_SETTINGS"
_project_settings="$(m_path "$_ix_pset")"
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[6/8] settings unwire: skipped — halted after an earlier failure")
elif [ "$SKIP_SETTINGS" -eq 1 ]; then
  echo "  kept (--skip-settings)."
else
  if ! class_removes "$_ix_settings"; then
    echo "  kept (manifest class ${M_CLASS[$_ix_settings]}): $_user_settings"
  elif [ -f "$_user_settings" ]; then
    unwire_settings "$_user_settings"
  else
    echo "  no $_user_settings — nothing to unwire."
  fi
  [ "$HALTED" -eq 1 ] || unwire_user_files
  if [ "$HALTED" -eq 1 ]; then
    echo "  project settings: skipped (halted after an earlier failure)"
  elif ! class_removes "$_ix_pset"; then
    echo "  project settings: kept (manifest class ${M_CLASS[$_ix_pset]}): $_project_settings"
  elif [ ! -e "$_project_settings" ] && [ ! -L "$_project_settings" ]; then
    echo "  project settings: none found"
  else
    _project_identity=0
    project_is_himmel_checkout || _project_identity=$?
    if [ "$_project_identity" -eq 0 ]; then
      echo "  project settings: kept $_project_settings (himmel's own checkout)"
    elif [ "$_project_identity" -eq 2 ]; then
      echo "  project settings: cannot resolve checkout identity — refusing to unwire" >&2
      fail_step "[6/8] project settings: checkout identity unresolved"
    elif [ -L "$PWD/.claude" ] || [ -L "$_project_settings" ] || [ ! -f "$_project_settings" ]; then
      echo "  project settings: refusing non-regular or symlinked target $_project_settings" >&2
      fail_step "[6/8] project settings: unsafe target"
    else
      unwire_settings "$_project_settings"
      if [ "$HALTED" -eq 1 ]; then
        echo "  project settings: unwire failed $_project_settings" >&2
      elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: project settings: would unwire $_project_settings"
      else
        echo "  project settings: unwired $_project_settings"
      fi
    fi
  fi
  # HIMMEL-3332 S8: the other projects the ledger recorded, same guards.
  if [ "$HALTED" -eq 0 ] && [ "$LEDGER_OK" -eq 1 ] && class_removes "$_ix_pset"; then
    unwire_recorded_projects
  fi
fi
# adopter-scripts (HIMMEL-3332 S6): a project-scope script install replaced,
# ledger-restorable — new with S6 (the manifest's `adopter-scripts` row was
# class=keep/step='-' before, listed for completeness only, never acted on).
# Runs independently of --skip-settings: a different surface ({PWD}/scripts
# files, not settings.json), gated only on HALTED like every other sub-step.
if [ "$HALTED" -eq 0 ] && [ "$LEDGER_OK" -eq 1 ]; then
  _adopter_units="$(prov_read_units --row adopter-scripts)"
  # codex-2 fix: an adopter-scripts row is written once per adopted project,
  # not scoped to any one of them — without this filter a ledger recording
  # several adopted projects would act on every one of them from whichever
  # project uninstall.sh happens to run in. Restrict to units whose recorded
  # .path (physically resolved the same way _prov_abs_path recorded it) lies
  # under the CURRENT project root; a unit outside it is silently left alone.
  _adopter_proj_root="$(canon_path_native "$PWD" 2>/dev/null)" || _adopter_proj_root="$PWD"
  while IFS= read -r _au; do
    [ "$HALTED" -eq 0 ] || break
    [ -n "$_au" ] || continue
    _adopter_path="$(printf '%s' "$_au" | jq -r '.path // ""')"
    case "$_adopter_path" in
      "$_adopter_proj_root"/*) ;;
      *) continue ;;
    esac
    ledger_apply_unit "$_au"
  done <<EOF
$_adopter_units
EOF
fi
# ponytail (HIMMEL-3332 S6, spec §4 six rows): with no ledger, a replaced
# adopter script cannot be told apart from the operator's own edit — nothing
# under {PWD}/scripts is touched, and no candidate files can even be
# enumerated without the ledger, so this prints no per-run line; the
# manifest's own `adopter-scripts` row already states the policy in the
# footprint printed before the run.
echo ""

# --- [7/8] remove marketplaces ----------------------------------------------
echo "[7/8] Removing Claude marketplaces..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[7/8] Claude marketplaces: skipped — halted after an earlier failure")
elif [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  kept (--skip-plugins)."
elif ! class_removes "$_ix_mkt"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_mkt]})."
elif ! _claude_bin=$(resolve_tool claude); then
  report_unresolved "[7/8] Claude marketplaces" claude --skip-plugins
elif [ "$LEDGER_OK" -ne 1 ]; then
  # ponytail (HIMMEL-3332 S6, spec §4/§8 case 3): same no-ledger fallback as
  # [4/8]; the hand command there removes marketplaces too, so it is only
  # printed once, at step 4, rather than repeated here.
  echo "  kept (no ledger): himmel's template marketplaces"
  echo "    (remove by hand: see step 4's command above — it removes marketplaces too)"
  if [ "$DRY_RUN" -ne 1 ] && [ "$YES" -ne 1 ] && [ -t 0 ] && [ -t 1 ]; then
    printf "  remove himmel's template marketplaces anyway? [y/N] "
    read -r _ans
    case "$_ans" in
      [yY]|[yY][eE][sS])
        echo "  using: $_claude_bin (fallback scope: $PLUGIN_SCOPE)"
        _plug_args=(--marketplaces-only --scope "$PLUGIN_SCOPE" --scope-map "$_scope_map")
        if ! PATH="$(dirname "$_claude_bin"):$PATH" \
            bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
          echo "  WARN: uninstall-plugins.sh reported failures or blocked removals — re-run it directly to inspect." >&2
          fail_step "[7/8] Claude marketplaces: uninstall-plugins.sh reported failures or blocked removals"
        fi
        ;;
      *) : ;;
    esac
  fi
else
  echo "  using: $_claude_bin (fallback scope: $PLUGIN_SCOPE)"
  ledger_report_preexisted_units marketplace
  _mkt_ours_units=$(prov_read_units --kind marketplace | { while IFS= read -r _u; do
    [ -n "$_u" ] || continue
    [ "$(printf '%s' "$_u" | jq -r '.ours')" = "true" ] && printf '%s\n' "$_u"
  done; })
  _plug_args=(--marketplaces-only --scope "$PLUGIN_SCOPE" --scope-map "$_scope_map" --ledger-owned "$_ledger_owned")
  [ "$DRY_RUN" -eq 1 ] && _plug_args+=(--dry-run)
  # uninstall-plugins.sh does its own `command -v claude` and hard-exits when
  # it fails, so the resolved directory has to be on the CHILD's PATH — passing
  # the path alone would leave the child just as blind as this script was.
  # ponytail: same coarse rc-based outcome as [4/8] — a marketplace kept
  # installed by uninstall-plugins.sh's own remaining-plugin check still
  # reads "removed" here rather than "kept" per-marketplace.
  if PATH="$(dirname "$_claude_bin"):$PATH" \
      bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
    _mkt_outcome="removed"; _mkt_reason="ours"
  else
    echo "  WARN: uninstall-plugins.sh reported failures or blocked removals — re-run it directly to inspect." >&2
    fail_step "[7/8] Claude marketplaces: uninstall-plugins.sh reported failures or blocked removals"
    _mkt_outcome="failed"; _mkt_reason="step-failed"
  fi
  if [ -n "$_mkt_ours_units" ]; then
    while IFS= read -r _u; do
      [ -z "$_u" ] && continue
      prov_read_outcome "$_mkt_outcome" "$_u" "$_mkt_reason"
    done <<EOF
$_mkt_ours_units
EOF
  fi
fi
echo ""

# --- [8/8] remove the himmelctl cache + state (HIMMEL-2459) ------------------
# install-profile.json + state.json survived a COMPLETE uninstall, so a
# re-install started against the PREVIOUS install's profile and state ledger.
# WHY (HIMMEL-2754): keep the cache LAST — install-profile.json records the
# install and must outlive every step that may need a retry.
# Honours HIMMELCTL_CACHE_DIR, the same override himmelctl itself reads.
echo "[8/8] Removing himmelctl cache + state ($HIMMEL_CACHE_DIR)..."
if [ "$HALTED" -eq 1 ]; then
  echo "  skipped (halted after an earlier failure)"
  STEPS_INCOMPLETE+=("[8/8] himmelctl cache: skipped — halted after an earlier failure")
elif ! class_removes "$_ix_cache"; then
  echo "  kept (manifest class ${M_CLASS[$_ix_cache]}): $HIMMEL_CACHE_DIR"
elif suspicious_rm_path "$HIMMEL_CACHE_DIR"; then
  # A refusal is not a teardown: the cache is still there. Unlike step [2/8],
  # where the guard protects an OPTIONAL removal, this step is required, so a
  # refusal is an incomplete step and must not end in "Uninstall complete."
  echo "  ERROR: refusing to remove suspicious path: '$HIMMEL_CACHE_DIR'" >&2
  fail_step "[8/8] himmelctl cache: refused a suspicious HIMMELCTL_CACHE_DIR ('$HIMMEL_CACHE_DIR')"
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
    fail_step "[8/8] himmelctl cache: $HIMMEL_CACHE_DIR could not be removed"
  fi
else
  # Name the known state files before removing, so --dry-run is auditable. The
  # last four are the session-start update check's (check-update-available.sh,
  # HIMMEL-3260): it keeps its throttle stamp, first-attempt stamp and release
  # cache in this same dir so they survive a reboot — and go with it here.
  for _cache_file in install-profile.json state.json \
    himmel-update-check-last himmel-update-check-first himmel-latest-release himmel-latest-release.fail; do
    [ -f "$HIMMEL_CACHE_DIR/$_cache_file" ] && echo "  contains: $HIMMEL_CACHE_DIR/$_cache_file"
  done
  # HIMMEL-3270: headed-arm-leg.sh appends one launch record per leg launch to
  # launch-logs/<session>.log here (the cost cohort's source). One line naming
  # the dir + a count, not one line per leg: a long-lived machine has hundreds.
  if [ -d "$HIMMEL_CACHE_DIR/launch-logs" ]; then
    _launch_n=0
    for _launch_rec in "$HIMMEL_CACHE_DIR"/launch-logs/*.log; do
      [ -f "$_launch_rec" ] && _launch_n=$((_launch_n + 1))
    done
    echo "  contains: $HIMMEL_CACHE_DIR/launch-logs/ ($_launch_n launch record(s), *.log)"
  fi
  if run rm -rf -- "$HIMMEL_CACHE_DIR"; then
    [ "$DRY_RUN" -eq 0 ] && echo "  removed: $HIMMEL_CACHE_DIR"
  else
    # A failed removal is residue that survives the uninstall — the exact
    # thing HIMMEL-2458 says must not end in "Uninstall complete." at rc=0.
    echo "  ERROR: failed to remove $HIMMEL_CACHE_DIR — residue remains; remove it manually." >&2
    fail_step "[8/8] himmelctl cache: $HIMMEL_CACHE_DIR could not be removed"
  fi
fi
echo ""

# HIMMEL-3332 S8: `tool register` rows are docs-only — himmel records the tool
# it installed but uninstall never removes one. One line each in the final
# "NOT touched" report, one kept outcome each in the ledger session.
_kept_tools=""
if [ "$LEDGER_OK" -eq 1 ]; then
  _tool_units=$(prov_read_units --kind tool)
  while IFS= read -r _u; do
    [ -n "$_u" ] || continue
    _kept_tools="$_kept_tools  - $(printf '%s' "$_u" | jq -r '.unit // .path // "?"') — tool himmel installed (documented; uninstall never removes a tool)"$'\n'
    prov_read_outcome kept "$_u" class-keep
  done <<EOF
$_tool_units
EOF
fi

# HIMMEL-3332 S6: close the ledger session. On a halt, keep everything —
# backups and (with --purge-state) the ledger itself — so a retry has the
# recorded pre-state to work from; only a clean end may purge.
if [ "$LEDGER_OK" -eq 1 ]; then
  if [ "$HALTED" -eq 1 ]; then
    prov_read_session_end halted
  else
    prov_read_session_end ok
    if [ "$PURGE_STATE" -eq 1 ]; then
      _prov_base_dir="$(prov_dir 2>/dev/null || true)"
      if [ -z "$_prov_base_dir" ] || suspicious_rm_path "$_prov_base_dir"; then
        echo "WARN: refusing to purge the provenance ledger — suspicious path: '$_prov_base_dir'" >&2
        fail_step "[8/8] provenance ledger: refused a suspicious ledger directory ('$_prov_base_dir')"
      else
        _prov_backups_dir="$_prov_base_dir/provenance-backups"
        _prov_ledger_file="$_prov_base_dir/provenance.jsonl"
        # HIMMEL-3332 S6 R2-codex6: --keep-backups spares provenance-backups/
        # under --purge-state too -- the ledger file itself is still removed
        # unconditionally, only the backups directory is protected.
        if [ "$KEEP_BACKUPS" -ne 1 ]; then
          # HIMMEL-2505 gap A.3: a symlinked backups dir is unlinked, never
          # `rm -rf`'d through into whatever it points at.
          if [ -L "$_prov_backups_dir" ]; then
            run rm -f -- "$_prov_backups_dir"
          else
            run rm -rf -- "$_prov_backups_dir"
          fi
        fi
        run rm -f -- "$_prov_ledger_file"
      fi
    elif [ "$KEEP_BACKUPS" -ne 1 ]; then
      # codex-1 fix: a dry run must not delete real backup files -- only say
      # what a wet run would do.
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: would prune provenance-backups/"
      else
        prov_read_prune_backups
      fi
    fi
  fi
fi

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
    if [ -n "$HALTED_AT" ]; then
      echo "Halted at: $HALTED_AT"
      echo "No later step ran — the machine is unchanged past that point."
      echo ""
    fi
    echo "Nothing was removed by those steps."
    if [ -n "$HALT_SKIP_FLAG" ]; then
      echo "To accept that gap deliberately and finish the rest, run (from the"
      echo "adopted project directory; \`himmelctl uninstall\` does not forward --skip-* flags):"
      echo "    $(rerun_command "$HALT_SKIP_FLAG")"
      echo "Or fix the cause first and re-run:"
    else
      echo "Fix the cause and re-run:"
    fi
    echo "    $(rerun_command)"
    echo "ANY failed step halts every later one (HIMMEL-2754). Re-running"
    echo "is safe and repairs a half-torn-down machine:"
    echo "it re-adds any marketplace its still-installed plugins need."
  } >&2
  exit 2
fi

if [ "$DRY_RUN" -eq 0 ]; then
  # Footprint read-back (HIMMEL-3058): every manifest directory this run was
  # meant to remove is checked absent on disk — the file system, not the rc.
  for _mi in "${!M_ID[@]}"; do
    [ "${M_KIND[$_mi]}" = "dir" ] || continue
    class_removes "$_mi" || continue
    step_skipped "${M_STEP[$_mi]}" && continue
    _mp="$(strip_trailing_slash "$(m_path "$_mi")")"
    if [ -e "$_mp" ] || [ -L "$_mp" ]; then
      echo "  ERROR: $_mp is still present after uninstall" >&2
      STEPS_INCOMPLETE+=("read-back: ${M_ID[$_mi]} $_mp still present")
    else
      echo "  verified: absent $_mp"
    fi
  done
  if [ "${#STEPS_INCOMPLETE[@]}" -gt 0 ]; then
    echo "Uninstall INCOMPLETE — read-back found residue:" >&2
    for _step in "${STEPS_INCOMPLETE[@]}"; do echo "  - $_step" >&2; done
    exit 2
  fi
fi

echo "Uninstall complete."
echo ""
echo "NOT touched (by design):"
for _mi in "${!M_ID[@]}"; do
  case "${M_CLASS[$_mi]}" in
    keep)
      _mp=$(m_path "$_mi")
      [ "$_mp" = "-" ] && _mp="(${M_ID[$_mi]})"
      echo "  - $_mp — ${M_WHAT[$_mi]}" ;;
    state) state_removed || echo "  - $(m_path "$_mi") — ${M_WHAT[$_mi]} (operator state; --purge-state removes it)" ;;
  esac
done
if [ -n "$_kept_tools" ]; then printf '%s' "$_kept_tools"; fi
