#!/usr/bin/env bash
# install-plugins — install all true-flagged Claude Code plugins listed in
# docs/setup/settings-template.json.
#
# Reads `enabledPlugins` (plugin@marketplace keys, installing only entries
# flagged `true` — HIMMEL-816) and `extraKnownMarketplaces` from the
# template, registers each marketplace
# via `claude plugin marketplace add`, sets `autoUpdate: true` on every
# template-flagged marketplace already registered in the scope's settings.json
# (the CLI has no auto-update flag, so this is patched straight into that file —
# HIMMEL-365), then installs each plugin via `claude plugin install
# <plugin>@<marketplace> --scope <scope>`.
#
# Both CLI calls are idempotent — re-running this script on a fully
# installed machine is a no-op.
#
# Usage:
#   bash install-plugins.sh [--dry-run] [--scope SCOPE] [--template PATH] [--himmel-path PATH]
#
# Flags:
#   --dry-run            Print commands instead of running them.
#   --scope SCOPE        Where to declare the marketplaces + plugins:
#                        user (default, ~/.claude — every project),
#                        project (this repo's .claude/settings.json,
#                        shared on clone), or local (this repo's gitignored
#                        .claude/settings.local.json). For project/local the
#                        target is the CURRENT directory — run from the repo
#                        you want the plugins scoped to.
#   --template PATH      Override default template path.
#   --himmel-path PATH   Override $HIMMEL_PATH used for <himmel-path>
#                        placeholder expansion (defaults to repo root
#                        inferred from script location).
#   --settings PATH      Override the scope-resolved settings.json target
#                        (used by the marketplace autoUpdate patch and the
#                        force-enable step below; a hermetic-test seam,
#                        mirrors reconcile-enabled-plugins.sh's own flag).
set -euo pipefail

# ── Resolve script + repo paths ─────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
DRY_RUN=0
SCOPE="user"
TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"
HIMMEL_PATH="$REPO_ROOT"
SETTINGS=""

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --scope)         SCOPE="$2"; shift 2 ;;
    --template)      TEMPLATE="$2"; shift 2 ;;
    --himmel-path)   HIMMEL_PATH="$2"; shift 2 ;;
    --settings)      SETTINGS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── Validate scope ───────────────────────────────────────────────────────────
case "$SCOPE" in
  user|project|local) ;;
  *) echo "ERROR: invalid --scope: $SCOPE (expected user|project|local)" >&2; exit 2 ;;
esac

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ -f "$TEMPLATE" ]] || { echo "ERROR: template missing: $TEMPLATE" >&2; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
command -v claude  >/dev/null || { echo "ERROR: claude CLI required on PATH" >&2; exit 1; }

# ── Helper: run-or-print ────────────────────────────────────────────────────
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# ── Helper: run a `claude` CLI step with LOUD, classified diagnostics ─────────
# Replaces the old muted `|| echo "(non-zero — transient failure)"`: on a
# non-zero step, surface WHICH step failed and the CLI's own output, instead of
# a one-line shrug that hid the cause. Classification is ADVISORY ONLY — it never
# changes pass/fail. The end presence-verify is authoritative, so an unmatched
# failure falls through (never aborts the loop, never false-fatals an idempotent
# re-run). A benign "already installed/registered" match stays a quiet line.
run_step() {
  if [[ $DRY_RUN -eq 1 ]]; then echo "DRY: $*"; return 0; fi
  # `|| rc=$?` (not `; rc=$?`): under `set -e` a bare `out=$(failing_cmd)` aborts
  # the script at the assignment before we can classify — the `||` absorbs it.
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  [[ $rc -eq 0 ]] && return 0
  if printf '%s' "$out" | grep -qiE 'already (installed|registered|exists)'; then
    echo "    (already present, skipping): $*"
  else
    echo "    !! step FAILED (exit $rc): $*" >&2
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  fi
  return 0   # advisory; presence-verify below is the authoritative gate
}

# ── Expand <himmel-path> in template ─────────────────────────────────────────
EXPANDED=$(sed "s|<himmel-path>|$HIMMEL_PATH|g" "$TEMPLATE")

# ── Register marketplaces ───────────────────────────────────────────────────
echo "──── Registering marketplaces ────"
echo "$EXPANDED" | jq -r '
  .extraKnownMarketplaces
  | to_entries[]
  | .value.source
  | if .source == "github"    then .repo
    elif .source == "directory" then .path
    elif .source == "url"       then .url
    else "UNKNOWN:" + (.|tostring)
    end
' | tr -d '\r' | while read -r SRC; do
  [[ -z "$SRC" || "$SRC" == UNKNOWN:* ]] && { echo "  skip: $SRC"; continue; }
  echo "  marketplace add: $SRC"
  run_step claude plugin marketplace add "$SRC" --scope "$SCOPE"
done

# ── Enable marketplace auto-update (HIMMEL-365) ──────────────────────────────
# `claude plugin marketplace add` writes each settings.json extraKnownMarketplaces
# entry WITHOUT autoUpdate, so a fresh install leaves every marketplace's
# auto-update OFF (only a manual /plugin UI toggle ever turned it on, and that
# never propagated to new machines). The CLI exposes no auto-update flag, so set
# the canonical field — extraKnownMarketplaces.<name>.autoUpdate, which the
# runtime known_marketplaces.json mirrors — directly in the scope's settings
# file, for every template entry flagged autoUpdate:true. Patch only entries that
# already exist there, so a marketplace-name vs template-key mismatch can't
# create an orphan entry.
case "$SCOPE" in
  # HIMMEL-2353: honor CLAUDE_CONFIG_DIR like the sibling reconcile-enabled-plugins.sh:81
  # idiom — a hermetic-test seam, not a per-call-site flag (a bare $HOME/.claude
  # here is what let a test suite reach the operator's real settings.json).
  user)    SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
  project) SETTINGS_FILE="$PWD/.claude/settings.json" ;;
  local)   SETTINGS_FILE="$PWD/.claude/settings.local.json" ;;
esac
[[ -n "$SETTINGS" ]] && SETTINGS_FILE="$SETTINGS"

echo "──── Enabling marketplace auto-update ($SETTINGS_FILE) ────"
# tr -d '\r': jq emits CRLF on Windows; a trailing \r would corrupt the name key.
AUTO_NAMES=$(echo "$EXPANDED" | jq -r '
  .extraKnownMarketplaces // {}
  | to_entries[]
  | select(.value.autoUpdate == true)
  | .key
' | tr -d '\r')
while IFS= read -r NAME; do
  [[ -z "$NAME" ]] && continue
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: set autoUpdate=true for '$NAME' in $SETTINGS_FILE"
    continue
  fi
  [[ -f "$SETTINGS_FILE" ]] || { echo "  skip: $NAME (no $SETTINGS_FILE)"; continue; }
  if ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "  skip: $SETTINGS_FILE not valid JSON — refusing to patch" >&2
    continue
  fi
  if [[ "$(jq --arg n "$NAME" '(.extraKnownMarketplaces // {}) | has($n)' "$SETTINGS_FILE")" != "true" ]]; then
    echo "  skip: '$NAME' not registered in $SETTINGS_FILE"
    continue
  fi
  # if/else (not `&& mv`): a bare `jq … && mv` is a standalone statement, so a
  # jq failure trips `set -e` and aborts the whole script mid-run — skipping the
  # install + verify steps for a merely-cosmetic patch. Tolerate it like the
  # `marketplace add` / `install` steps do, and clean up the temp on failure.
  #
  # HIMMEL-2324: mktemp, not a predictable "$SETTINGS_FILE.autoupdate.tmp" — a
  # fixed name lets anyone with write access to this directory pre-plant a
  # symlink there before we get here, so the jq redirect (or the mv) writes
  # through it. mktemp creates the file itself (O_EXCL, unpredictable suffix,
  # same directory so the mv stays atomic) — there's nothing to plant onto. A
  # `-L` exists-check would still be TOCTOU-racy between check and write.
  # Seed it as a perms-preserving copy of $SETTINGS_FILE first: mktemp creates
  # at mode 0600, and this site previously had no seed (it always created a
  # brand-new file via redirect) — without the seed the mv would narrow
  # settings.json's mode to 0600.
  AUTOUPDATE_TMP="$(mktemp "$SETTINGS_FILE.autoupdate.XXXXXX")" || {
    echo "  skip: $NAME (mktemp failed — $SETTINGS_FILE left unchanged)" >&2
    continue
  }
  cp -p "$SETTINGS_FILE" "$AUTOUPDATE_TMP" 2>/dev/null || cp "$SETTINGS_FILE" "$AUTOUPDATE_TMP" || {
    # CR round 3 (codex-2, sibling site): if BOTH cp attempts fail, this bare
    # statement's failure trips `set -e` and exits the script — leaving the
    # already-mktemp'd $AUTOUPDATE_TMP orphaned. Clean it up; tolerant/skip
    # (not exit), matching this site's own jq-failure branch below — a
    # cosmetic patch must not abort the installer under set -e.
    rm -f "$AUTOUPDATE_TMP"
    echo "  skip: $NAME (cp failed — $SETTINGS_FILE left unchanged)" >&2
    continue
  }
  if jq --arg n "$NAME" '.extraKnownMarketplaces[$n].autoUpdate = true' \
       "$SETTINGS_FILE" > "$AUTOUPDATE_TMP"; then
    mv "$AUTOUPDATE_TMP" "$SETTINGS_FILE"
    echo "  autoUpdate=true: $NAME"
  else
    rm -f "$AUTOUPDATE_TMP"
    echo "  skip: $NAME (jq patch failed — $SETTINGS_FILE left unchanged)" >&2
  fi
done <<< "$AUTO_NAMES"

# ── Install plugins ─────────────────────────────────────────────────────────
echo "──── Installing plugins ($SCOPE scope) ────"
# tr -d '\r': jq emits CRLF on Windows; a trailing \r would corrupt both the
# install spec and the later presence comparison (INSTALLED_SPECS is \r-free).
# select(.value == true): only install template entries flagged true — a
# false-flagged entry (the HIMMEL-816 lean profile) must NOT be installed,
# or the lean template silently re-creates the pre-lean maximal set on every
# fresh machine (HIMMEL-816 follow-up gap).
SPECS=$(echo "$EXPANDED" | jq -r '.enabledPlugins | to_entries[] | select(.value == true) | .key' | tr -d '\r')
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  echo "  install: $SPEC"
  run_step claude plugin install "$SPEC" --scope "$SCOPE"
done <<< "$SPECS"

# ── Verify (post-install presence check, HIMMEL-361) ─────────────────────────
# `claude plugin install` can legitimately exit non-zero on an already-installed
# plugin, so install exit codes can't tell a real failure from an idempotent
# no-op — which is exactly how a failed handover@himmel install used to look
# identical to "already installed". Verify by PRESENCE instead: list the
# installed plugins and confirm every enabledPlugins spec is there. Skipped
# under --dry-run (nothing was installed).
if [[ $DRY_RUN -eq 1 ]]; then
  echo "──── Done (dry-run; verify skipped) ────"
  exit 0
fi

echo "──── Verifying installed plugins ────"
# Fail closed: a verify step that cannot run has confirmed NOTHING, so it must
# not report success — that silent pass is the exact bug HIMMEL-361 kills. The
# pre-flight already proved `claude` is on PATH, so a `list` failure here is a
# real anomaly. Capture stderr (2>&1) so the operator sees WHY it failed.
if ! INSTALLED=$(claude plugin list 2>&1); then
  echo "ERROR: 'claude plugin list' failed — cannot verify plugin installs:" >&2
  # shellcheck disable=SC2001
  # Per-line indent — parameter expansion doesn't replicate sed's per-line anchor cleanly.
  echo "$INSTALLED" | sed 's/^/    /' >&2
  exit 1
fi
# Pull the bare <plugin>@<marketplace> tokens out of the list output (grep -oE);
# the exact whole-line compare happens below via `grep -qxF`, which is what
# avoids substring/prefix false-positives.
INSTALLED_SPECS=$(echo "$INSTALLED" | grep -oE '[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' || true)

MISSING=()
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  grep -qxF "$SPEC" <<< "$INSTALLED_SPECS" || MISSING+=("$SPEC")
done <<< "$SPECS"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: ${#MISSING[@]} plugin(s) not present after install:" >&2
  for SPEC in "${MISSING[@]}"; do
    echo "    $SPEC — retry: claude plugin install $SPEC --scope $SCOPE" >&2
  done
  exit 1
fi

echo "  All $(grep -c . <<< "$SPECS") enabled plugins present."

# ── Force-enable drifted template-true plugins (HIMMEL-2292) ─────────────────
# Presence in `claude plugin list` (verified above) is NOT the same as ENABLED
# in settings.json — a plugin can be fully installed while
# enabledPlugins["<spec>"] is still `false` (a stale manual /plugin toggle, an
# older template, a machine that predates a template flip — the overlord8
# himmel-ops@himmel:false state that left block-glm-external-writes.sh inert
# despite being correctly wired via the plugin's own hooks.json). Unlike the
# lean-floor reconcile below, this step is ALWAYS ON, no HIMMEL_RECONCILE_
# PLUGINS gate: it only ever flips a template-`true` spec's live value from
# `false`/absent to `true` and never touches a spec the template doesn't flag
# `true` — additive-only, so there's nothing here for that opt-in to protect
# against. Skipped for settings.local.json (the protected per-machine
# override input — mirrors reconcile-enabled-plugins.sh's own basename guard)
# and when the target file doesn't exist yet (a fresh machine has nothing to
# patch; the installs above already created it correctly).
SETTINGS_FILE_BASENAME_LC="$(basename "$SETTINGS_FILE" | tr '[:upper:]' '[:lower:]')"
if [[ -f "$SETTINGS_FILE" && "$SETTINGS_FILE_BASENAME_LC" != "settings.local.json" ]]; then
  if jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
    TRUE_SPECS_JSON=$(echo "$EXPANDED" | jq -c '[.enabledPlugins | to_entries[] | select(.value == true) | .key]')
    DRIFTED=$(jq -r --argjson trueSpecs "$TRUE_SPECS_JSON" '
      (.enabledPlugins // {}) as $live | $trueSpecs[] | select(($live[.] // false) != true)
    ' "$SETTINGS_FILE")
    if [[ -n "$DRIFTED" ]]; then
      echo "──── Force-enabling drifted plugins (installed but disabled) ────"
      while IFS= read -r SPEC; do [[ -n "$SPEC" ]] && echo "  enable: $SPEC"; done <<< "$DRIFTED"
      # CR fix (codex-1, panel round 3): seed the temp file as a perms-preserving
      # COPY of $SETTINGS_FILE first (cp -p — mirrors reconcile-enabled-plugins.sh's
      # own pattern), THEN let jq's `>` redirect truncate-write that ALREADY-
      # EXISTING file in place — redirecting into an existing path preserves its
      # inode/permission bits, unlike creating a brand-new file, which takes the
      # process umask and can widen a restrictive settings.json (e.g. 0600) to
      # world-readable on the final mv. cp -p is best-effort; a filesystem
      # without perm bits (Windows) falls back to plain cp, harmless there.
      #
      # HIMMEL-2324: mktemp, not the predictable "$SETTINGS_FILE.enable.tmp" —
      # a fixed name lets anyone with write access to this directory pre-plant
      # a symlink there before we get here, so the jq redirect (or the mv)
      # writes through it. mktemp creates the file itself (O_EXCL, unpredictable
      # suffix, same directory so the mv stays atomic) — there's nothing to
      # plant onto. A `-L` exists-check would still be TOCTOU-racy between
      # check and write.
      if ! ENABLE_TMP="$(mktemp "$SETTINGS_FILE.enable.XXXXXX")"; then
        echo "  ERROR: mktemp failed — $SETTINGS_FILE left unchanged" >&2
        exit 1
      fi
      cp -p "$SETTINGS_FILE" "$ENABLE_TMP" 2>/dev/null || cp "$SETTINGS_FILE" "$ENABLE_TMP" || {
        # CR round 3 (codex-2, sibling site): if BOTH cp attempts fail, this
        # bare statement's failure trips `set -e` and exits the script —
        # leaving the already-mktemp'd $ENABLE_TMP orphaned. Clean it up;
        # loud AND non-zero (not tolerant), matching this site's own
        # jq-failure branch below — this step is the HIMMEL-2292 repair
        # mechanism itself, so a swallowed failure must not report success.
        rm -f "$ENABLE_TMP"
        echo "  ERROR: force-enable cp failed — $SETTINGS_FILE left unchanged" >&2
        exit 1
      }
      if jq --argjson trueSpecs "$TRUE_SPECS_JSON" \
           '.enabledPlugins = ((.enabledPlugins // {}) + ($trueSpecs | map({(.): true}) | add))' \
           "$SETTINGS_FILE" > "$ENABLE_TMP"; then
        mv "$ENABLE_TMP" "$SETTINGS_FILE"
      else
        rm -f "$ENABLE_TMP"
        # Loud AND non-zero (unlike the autoUpdate patch above, which is
        # cosmetic): this step is the repair mechanism the whole ticket
        # exists for (HIMMEL-2292) — a swallowed failure here would let the
        # installer report success while a required plugin like himmel-ops
        # stays silently disabled, exactly the failure mode being fixed.
        echo "  ERROR: force-enable jq patch failed — $SETTINGS_FILE left unchanged" >&2
        exit 1
      fi
    fi
  else
    # Loud AND non-zero — same reasoning as the failed-patch branch above:
    # a malformed settings.json means force-enable silently never ran, and
    # a required plugin (e.g. himmel-ops) can stay disabled with the
    # installer still reporting success.
    echo "  ERROR: $SETTINGS_FILE is not valid JSON — refusing to force-enable" >&2
    exit 1
  fi
fi

# ── Reconcile enabledPlugins to the lean floor (HIMMEL-1032) ─────────────────
# Install is additive (it only installs `true` entries), so a FRESH machine is
# already lean — the extras were never installed. The subtractive reconcile only
# matters on a RE-RUN over a machine with pre-existing drift, where it would
# DISABLE plugins the user may have enabled. That must be OPT-IN, identical to
# himmel-update (HIMMEL_RECONCILE_PLUGINS) — never disable a user's plugins on a
# plain re-install. Best-effort: a reconcile hiccup must not fail the install.
RECONCILE="$SCRIPT_DIR/reconcile-enabled-plugins.sh"
case "${HIMMEL_RECONCILE_PLUGINS:-}" in
  1|all|true|yes)
    if [[ -f "$RECONCILE" ]]; then
      echo "──── Reconciling enabledPlugins to lean floor (HIMMEL_RECONCILE_PLUGINS) ────"
      bash "$RECONCILE" --settings "$SETTINGS_FILE" --template "$TEMPLATE" \
        || echo "  warn: plugin-set reconcile failed (non-fatal)." >&2
    else
      # Opted in but the reconciler is missing — enforcement is silently a no-op
      # otherwise, so say so loudly.
      echo "  warn: HIMMEL_RECONCILE_PLUGINS is set but reconcile-enabled-plugins.sh not found ($RECONCILE) — lean floor NOT enforced." >&2
    fi ;;
  *)
    echo "  (install is additive-only; set HIMMEL_RECONCILE_PLUGINS=1 to also disable drifted plugins down to the lean floor)" ;;
esac
echo "──── Done ────"
