#!/usr/bin/env bash
# Hermetic marketplace-source guard (HIMMEL-2837): every plugin id that
# install-plugins.sh actually INSTALLS on a fresh machine (HIMMEL-2863) —
# enabledPlugins entries with value === true (the ALWAYS tier) UNION every
# onDemandPlugins key (the ON-DEMAND tier: installed but left disabled, e.g.
# codex@openai-codex) — except the claude-plugins-official marketplace
# (Anthropic's own, exempt), must
# resolve to a marketplace whose extraKnownMarketplaces source is "url"
# (explicit HTTPS git clone) or "directory" (a local vendored path — e.g.
# himmel's own marketplace) — never "github" (owner/repo shorthand, which
# clones over SSH and fails host-key verification on a fresh guest with no
# github.com in ~/.ssh/known_hosts and no SSH key: HIMMEL-549, HIMMEL-2836).
# This is exactly the class of regression HIMMEL-2733 introduced by adding
# plannotator-effective-html@effective-html — a github-shorthand marketplace
# source — to the ALWAYS-installed tier. HIMMEL-2837 fixed that instance by
# vendoring the plugin as plannotator-effective-html@himmel, a url-sourced
# per-plugin pin inside the himmel marketplace; this guard stops the class
# from recurring for any future plugin.
#
# A "directory" top-level source (himmel's own vendored marketplace) is not
# exempt either: its OWN marketplace/.claude-plugin/marketplace.json is
# opened and the same hermetic predicate (directory/url-https pass,
# github/ssh/anything-else fail) is applied to every plugin entry there,
# transitively — a plugin entry that is itself a "directory" source recurses
# into ITS marketplace.json up to DEPTH_CAP levels, with a per-branch
# ancestor set so a self-referential directory fails loud instead of looping
# (HIMMEL-2846).
#
# Fail-closed on detected drift; skips (exit 0) only when jq is unavailable
# or the template is MISSING (fresh clone / CI without it — a legitimate
# skip). An input that EXISTS but is unreadable is not a skip: it would
# otherwise read as empty and report a false PASS, so that case fails closed
# (exit 1) with a named diagnostic. Input path is env-overridable for testing.
#
# Exit codes:
#   0  all enabledPlugins entries (and, for directory-sourced marketplaces,
#      every nested plugin entry up to DEPTH_CAP) resolve to a hermetic
#      (url-https or directory) source; or jq/the template is legitimately
#      absent (skip).
#   1  a top-level or nested plugin source is non-hermetic (github/ssh/
#      non-https url/unregistered), a directory-sourced marketplace.json is
#      missing/unreadable/unparsable, the depth cap is exceeded, or a
#      self-referential directory source is detected. Also: the template
#      exists but is unreadable; a plugins[] entry that is not a JSON
#      object; or the per-plugin jq extraction itself failing for any
#      reason — all fail closed, never read as an empty/passing result.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure jq + POSIX shell; no .ps1 twin needed.
set -euo pipefail

TEMPLATE_JSON="${HIMMEL_SETTINGS_TEMPLATE:-docs/setup/settings-template.json}"
DEPTH_CAP=3

command -v jq >/dev/null 2>&1 || { echo "marketplace-source-hermetic: jq not on PATH — skipping"; exit 0; }

[ -f "$TEMPLATE_JSON" ] || { echo "marketplace-source-hermetic: $TEMPLATE_JSON missing — skipping"; exit 0; }
if [ ! -r "$TEMPLATE_JSON" ]; then
  echo "ERR marketplace-source-hermetic: $TEMPLATE_JSON exists but is unreadable — refusing to skip (fail-closed)." >&2
  exit 1
fi

# <himmel-path> in a "directory" source's path is a placeholder the
# installer expands to the target repo root (scripts/machine-setup/
# install-plugins.sh). Here there is no install target — default to the
# repo root implied by the template's own location (docs/setup/<file> is
# always two levels under the repo root), env-overridable for tests whose
# fixture templates live elsewhere.
if [ -z "${HIMMEL_PATH_ROOT:-}" ]; then
  tmpl_dir="$(dirname -- "$TEMPLATE_JSON")"
  HIMMEL_PATH_ROOT="$(cd -- "$tmpl_dir/../.." 2>/dev/null && pwd || printf '%s' "$tmpl_dir/../..")"
fi

# Resolve a (possibly relative, possibly <himmel-path>-prefixed) directory
# path against $1=base. Prints the resolved path; does not require the
# directory to exist (a missing target is reported by the caller).
resolve_dir_path() {
  local base="$1" p="$2"
  case "$p" in
    "<himmel-path>"*) p="${HIMMEL_PATH_ROOT}${p#<himmel-path>}" ;;
  esac
  case "$p" in
    # A leading POSIX / is absolute everywhere; a drive-letter prefix
    # (C:/... or C:\...) is absolute on the explicitly supported Git Bash
    # platform (HIMMEL-2846 panel round 2) — without this branch it would
    # be treated as relative and wrongly prefixed with $base.
    /*|[A-Za-z]:[/\\]*) : ;;
    *) p="$base/$p" ;;
  esac
  (cd -- "$p" 2>/dev/null && pwd) || printf '%s' "$p"
}

bad=""

# Applies the hermetic predicate to every plugin entry in the
# marketplace.json under directory $1, transitively. $2=depth (1 = the
# top-level directory-sourced marketplace itself), $3=label for diagnostics,
# $4=space-separated ancestor directories (cycle guard).
check_marketplace_dir() {
  local dir="$1" depth="$2" label="$3" ancestors="$4" mpjson mp_extract mp_err jq_rc
  case " $ancestors " in
    *" $dir "*)
      bad="$bad  $label (self-referential directory-sourced marketplace at \"$dir\")
"
      return
      ;;
  esac
  if [ "$depth" -gt "$DEPTH_CAP" ]; then
    bad="$bad  $label (nested directory-sourced marketplace exceeds depth cap $DEPTH_CAP at \"$dir\")
"
    return
  fi

  mpjson="$dir/.claude-plugin/marketplace.json"
  if [ ! -e "$mpjson" ]; then
    bad="$bad  $label (marketplace.json missing at \"$mpjson\")
"
    return
  fi
  if [ ! -r "$mpjson" ]; then
    bad="$bad  $label (marketplace.json at \"$mpjson\" exists but is unreadable)
"
    return
  fi
  if ! jq -e '.plugins | type == "array"' "$mpjson" >/dev/null 2>&1; then
    bad="$bad  $label (marketplace.json at \"$mpjson\" is unparsable or missing a .plugins array)
"
    return
  fi

  # NUL-delimited (never @tsv): @tsv backslash-escapes ("\" -> "\\") and a
  # plain `read -r` does not un-escape it, so a nested Windows path using
  # backslash separators would reach resolve_dir_path doubled (HIMMEL-2855).
  # Extracted to a temp file first (not straight into process substitution)
  # so jq's own exit status is checked: a `while read < <(cmd)` loop never
  # sees cmd's exit code, so a jq error mid-stream (e.g. a non-object
  # plugins[] entry, or an entry whose .source is neither an object nor a
  # string) used to leave $bad untouched and PASS a malformed marketplace
  # (HIMMEL-2858).
  mp_extract="$(mktemp)" || { bad="$bad  $label (mktemp failed while extracting marketplace.json plugins)
"; return; }
  mp_err="$(mktemp)" || { rm -f "$mp_extract"; bad="$bad  $label (mktemp failed while extracting marketplace.json plugins)
"; return; }
  jq_rc=0
  jq -j '
    .plugins[]
    | if type != "object" then
        "<non-object plugins[] entry>", "\u0000", "NON-OBJECT", "\u0000", "plugins[] entry is not an object", "\u0000"
      else
        (.name as $n
        | (if (.source | type) == "string" then "STRING" else (.source.source // "MISSING") end) as $t
        | (if (.source | type) == "string" then .source else (.source.url // .source.path // "MISSING") end) as $d
        | if ((($n | tostring) + ($t | tostring) + ($d | tostring)) | test("\u0000")) then
            ($n | gsub("\u0000"; "\ufffd")), "\u0000", "NUL-REJECTED", "\u0000", "embedded NUL byte in plugin name/source", "\u0000"
          else
            $n, "\u0000", $t, "\u0000", $d, "\u0000"
          end)
      end
  ' "$mpjson" >"$mp_extract" 2>"$mp_err" || jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    bad="$bad  $label (marketplace.json extraction failed (jq rc=$jq_rc): $(head -n1 -- "$mp_err" 2>/dev/null))
"
    rm -f "$mp_extract" "$mp_err"
    return
  fi
  rm -f "$mp_err"

  while IFS= read -r -d '' pname && IFS= read -r -d '' ptype && IFS= read -r -d '' pdetail; do
    [ -z "$pname" ] && continue
    case "$ptype" in
      NON-OBJECT)
        bad="$bad  $label > $pname ($pdetail)
"
        ;;
      STRING)
        # Absolute/traversal checks run against a backslash-normalized copy
        # so a mixed-separator path (e.g. "plugins/..\../outside") can't slip
        # through by matching neither the all-slash nor all-backslash pattern
        # alternatives (HIMMEL-2858, panel round 1).
        pdetail_norm=${pdetail//\\//}
        case "$pdetail" in
          *://*)
            bad="$bad  $label > $pname (source: STRING, but value is a URL, not a relative path: $pdetail)
"
            ;;
          *@*:*)
            bad="$bad  $label > $pname (source: STRING, but value is an scp-style SSH spec, not a relative path: $pdetail)
"
            ;;
          *)
            case "$pdetail_norm" in
              /*|[A-Za-z]:/*)
                bad="$bad  $label > $pname (source: STRING, but value is an absolute path, not a relative path: $pdetail)
"
                ;;
              ..|../*|*/../*|*/..)
                bad="$bad  $label > $pname (source: STRING, but value escapes the marketplace tree via a \"..\" path segment, not a relative path: $pdetail)
"
                ;;
              *) ;; # relative path within this marketplace's own tree — hermetic
            esac
            ;;
        esac
        ;;
      directory)
        check_marketplace_dir "$(resolve_dir_path "$dir" "$pdetail")" "$((depth + 1))" "$label > $pname" "$ancestors $dir"
        ;;
      url)
        case "$pdetail" in
          https://*) ;;
          *)
            bad="$bad  $label > $pname (source: url, but url is not HTTPS: $pdetail)
"
            ;;
        esac
        ;;
      *)
        bad="$bad  $label > $pname (source: $ptype)
"
        ;;
    esac
  done < <(tr -d '\r' <"$mp_extract")
  rm -f "$mp_extract"
}

# The install set (install-plugins.sh:261-270, HIMMEL-2733) is
# enabledPlugins-true (the ALWAYS tier) UNION onDemandPlugins' keys (the
# ON-DEMAND tier — installed by install-plugins.sh but left disabled, e.g.
# codex@openai-codex, so it still needs a hermetic marketplace source). A
# `false` entry ABSENT from onDemandPlugins is genuinely never installed.
specs="$(jq -r '
  ((.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key),
  ((.onDemandPlugins // {}) | keys[])
' "$TEMPLATE_JSON" | sort -u | tr -d '\r')"
while IFS= read -r spec; do
  [ -z "$spec" ] && continue
  market="${spec##*@}"
  [ "$market" = "claude-plugins-official" ] && continue
  src_type="$(jq -r --arg m "$market" '(.extraKnownMarketplaces[$m].source.source // "MISSING")' "$TEMPLATE_JSON" | tr -d '\r')"
  case "$src_type" in
    directory)
      src_path="$(jq -r --arg m "$market" '(.extraKnownMarketplaces[$m].source.path // "MISSING")' "$TEMPLATE_JSON" | tr -d '\r')"
      check_marketplace_dir "$(resolve_dir_path "$HIMMEL_PATH_ROOT" "$src_path")" 1 "$spec" ""
      ;;
    url)
      src_url="$(jq -r --arg m "$market" '(.extraKnownMarketplaces[$m].source.url // "MISSING")' "$TEMPLATE_JSON" | tr -d '\r')"
      case "$src_url" in
        https://*) ;;
        *)
          bad="$bad  $spec (marketplace \"$market\" source: url, but url is not HTTPS: $src_url)
"
          ;;
      esac
      ;;
    *)
      bad="$bad  $spec (marketplace \"$market\" source: $src_type)
"
      ;;
  esac
done <<EOF
$specs
EOF

if [ -n "$bad" ]; then
  echo "ERR marketplace-source-hermetic: enabledPlugins entries whose marketplace does not resolve to a url/directory source:" >&2
  printf '%s' "$bad" >&2
  echo "    A \"github\" (owner/repo shorthand) source clones over SSH and fails host-key" >&2
  echo "    verification on a fresh guest with no known_hosts entry and no SSH key (HIMMEL-549," >&2
  echo "    HIMMEL-2836). Use an explicit HTTPS url source (see claude-obsidian / himmel's own" >&2
  echo "    marketplace in marketplace/.claude-plugin/marketplace.json), or a local directory source." >&2
  exit 1
fi

echo "marketplace-source-hermetic: all enabledPlugins entries resolve to a url or directory marketplace source"
