#!/usr/bin/env bash
# refresh-graph-map.sh — incremental graphify refresh + curated-MOC publish for
# one corpus (HIMMEL-825). The schedulable core behind the interval refresh that
# bounds graph drift.
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. A full sync is ~$2 (measured 2026-07-09); `graphify --update` is
# INCREMENTAL (only changed files re-extracted) so a frequent (e.g. daily) run
# is cheap. This wraps the fence-safe refresh so a scheduler (or an operator)
# can call it per corpus.
#
# FENCE SAFETY: extraction never runs on a live vault — we operate on a
# scratchpad COPY carrying a `.graphify-corpus` marker (same discipline as the
# harvest tools + the egress matrix). The derived graph.json, full
# GRAPH_REPORT.md, and semantic cache artifacts land in the corpus's repo-local
# `graphify-out/` (the "latest in repo" substrate); only the curated MOC is
# published to the vault's
# 60-Maps/ (the tracked artifact that "moves" on update).
#
# Usage:
#   refresh-graph-map.sh --name luna --corpus-root <path> --backend deepseek \
#       --maps-dir <luna>/60-Maps --title "Graphify Luna Map" --slug graphify-luna-map \
#       [--corpus-tag luna] [--scratch <dir>] [--no-update]
#
# Exit: 0 ok; 1 usage/IO; 2 fence/graphify failure; 3 extraction skipped (bank
# at/over threshold — not a failure, graphify-out was left untouched).
#
# Freshness guard: this script REBUILDS the graph. To CHECK whether an existing
# graphify-out/ is still fresh (and not orphaned from its corpus) before querying
# it, run check-graph-freshness.sh --out <graphify-out> [--max-age-days N]
# (companion script, same dir). HIMMEL-621/824/825 family.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# HIMMEL-1776 (fence parity by extraction): file-readability and
# endpoint-host predicates shared with scripts/guardrails/graphify-fence.sh,
# the interactive path this scheduled script never runs under. ONE
# implementation instead of two hand-kept copies that can drift (HIMMEL-1748 /
# PR #1680 fixed exactly that drift once already).
# shellcheck source=../guardrails/phi-egress-lib.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/guardrails/phi-egress-lib.sh"

# BACKEND default = claude-cli (HIMMEL-1049): graphify distinguishes `claude`
# (Anthropic API — requires ANTHROPIC_API_KEY, pay-as-you-go) from `claude-cli`
# (routes through the locally-installed `claude` CLI). The claude-ONLY adopter
# story needs claude-cli, not claude.
# BILLING (HIMMEL-1748, measured 2026-08-11/12): subscription-authenticated
# headless-claude-ok: documentation of graphify's intentional subscription-authenticated CLI dispatch
# `claude -p` draws from the SAME 5-hour/weekly usage bank as the operator's
# interactive sessions — there is NO separate headless bucket for subscription
# auth. (The HIMMEL-128 "separate bucket" note that used to live in the dispatch
# comment below was wrong: a 48-chunk luna refresh exhausted the bank ~2.9h in
# and chunks 27-48 all failed.) Mitigation: the sonnet model pin below
# (GRAPHIFY_CLAUDE_CLI_MODEL, overridable), or an API backend (kimi/glm) for
# zero bank draw.
# BILLING CAVEAT (CodeRabbit): claude-cli authenticates via the operator's
# existing Pro/Max SUBSCRIPTION *only when no Anthropic API credential is in the
# environment* — a set ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN takes precedence
# in the `claude` CLI and switches the run back to pay-as-you-go. We deliberately
# do NOT strip those vars here (the operator may intend the API path); this is a
# default, not a billing guarantee.
NAME="" CORPUS_ROOT="" BACKEND="claude-cli" MAPS_DIR="" TITLE="" SLUG="" CORPUS_TAG=""
SCRATCH="" DO_UPDATE=1 CORPUS_CLASS="luna-personal" EFFECTIVE_PROVIDER=""
# HIMMEL-1704: OPTIONAL device:inode identity for --corpus-root / --maps-dir,
# as probed by the caller's OWN preflight (graph-refresh.sh) at validation
# time. A caller that does not pass one (e.g. a direct/manual invocation, or
# graphmap-cadence.sh, which has no vault preflight of its own) gets today's
# behaviour unchanged -- this is defense-in-depth ON TOP of the caller's
# validation, not a new requirement for every caller.
CORPUS_ID="" MAPS_ID="" MAPS_PARENT_ID=""
usage() { echo "usage: refresh-graph-map.sh --name N --corpus-root P --maps-dir D --title T --slug S [--backend B] [--corpus-tag T] [--corpus-class C] [--corpus-id DEV:INODE] [--maps-id DEV:INODE] [--maps-parent-id DEV:INODE] [--scratch DIR] [--no-update]" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --corpus-id) CORPUS_ID="${2:-}"; shift 2 ;;
    --maps-id) MAPS_ID="${2:-}"; shift 2 ;;
    # HIMMEL-1704 round 3 (codex-1): identity of MAPS_DIR's PARENT (the
    # vault), used ONLY when MAPS_ID is empty -- i.e. 60-Maps did not exist
    # at the caller's preflight (a legitimate first-ever publish). See the
    # publish site below for why this closes that residual.
    --maps-parent-id) MAPS_PARENT_ID="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    # HIMMEL-1415 CR follow-up rounds 2-4 (codex-1-r2, codex-adv-3,
    # CodeRabbit App): trim trailing slash(es) at parse time -- a raw
    # "--maps-dir /vault/60-Maps/" (or "//") propagated unmodified made the
    # HIMMEL-1415 exclusion patterns become "./60-Maps//graph/*", which
    # find's -path matcher never matches against the real
    # "./60-Maps/graph/..." path -- the exclusion silently no-ops and
    # derived pages leak back into the corpus. Looped, not a single `%/`, so
    # it closes MULTIPLE trailing slashes too (round-3 panel flagged the
    # single-trim as incomplete). Trimmed here (not just at the exclusion
    # site, matching CORPUS_ROOT_TRIMMED there) so every downstream use --
    # the exclusion AND the OUT_NOTE publish path below, which would
    # otherwise get the same double slash -- sees the same clean value.
    #
    # Guarded with `[ -n "${MAPS_DIR%/}" ]` (CodeRabbit App, round 4): a bare
    # `--maps-dir /` would otherwise be stripped to the EMPTY string (each
    # iteration removes the one slash, `%/` on "" is a no-op, loop exits with
    # nothing left) -- silently losing the maps dir entirely for every
    # downstream use, including the `[ -z "$MAPS_DIR" ]` usage-check at line
    # ~64, which would then wrongly reject a technically-valid (if absurd)
    # root maps-dir as a missing flag. The guard stops stripping once only
    # the bare "/" remains, so root is preserved as "/" instead of "".
    --maps-dir)
      MAPS_DIR="${2:-}"
      while [ -n "${MAPS_DIR%/}" ] && [ "${MAPS_DIR%/}" != "$MAPS_DIR" ]; do MAPS_DIR="${MAPS_DIR%/}"; done
      shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --corpus-tag) CORPUS_TAG="${2:-}"; shift 2 ;;
    --corpus-class) CORPUS_CLASS="${2:-}"; shift 2 ;;
    --scratch) SCRATCH="${2:-}"; shift 2 ;;
    --no-update) DO_UPDATE=0; shift ;;
    *) echo "refresh-graph-map: unknown flag: $1" >&2; usage ;;
  esac
done
if [ -z "$NAME" ] || [ -z "$CORPUS_ROOT" ] || [ -z "$MAPS_DIR" ] || [ -z "$TITLE" ] || [ -z "$SLUG" ]; then usage; fi
[ -d "$CORPUS_ROOT" ] || { echo "refresh-graph-map: corpus root not found: $CORPUS_ROOT" >&2; exit 1; }

# HIMMEL-1704 TOCTOU guard: probe $1's filesystem identity (device+inode,
# symlink-resolved via stat -L, same as graph-refresh.sh's own _fs_id) and
# compare it against an expected "dev:inode" string. Binds a check to the
# ACTUAL filesystem object rather than a pathname, which a parent-directory
# actor can retarget between when a caller validates a path and when this
# script actually reads/writes it. Called at the two points that actually
# consume CORPUS_ROOT/MAPS_DIR (the copy cd, and the publish write) -- not
# just once at the top -- so the re-check covers the window that matters.
_fs_id() {
    local p="$1" id
    id=$(stat -L -c '%d:%i' "$p" 2>/dev/null) || id=""
    case "$id" in *:*) printf '%s' "$id"; return 0 ;; esac
    id=$(stat -L -f '%d:%i' "$p" 2>/dev/null) || id=""
    case "$id" in *:*) printf '%s' "$id"; return 0 ;; esac
    return 1
}
# _verify_fs_id <label> <path> <expected-id> — no-op (return 0) when
# expected-id is empty (caller passed no --corpus-id/--maps-id, e.g. a
# manual invocation or graphmap-cadence.sh -- today's behaviour, unchanged).
# Fail CLOSED when an identity WAS pinned but can no longer be probed, or no
# longer matches: an unresolvable/changed identity is not permission to
# proceed with a safety control whose whole point is proving the object is
# unchanged.
_verify_fs_id() {
    local label="$1" path="$2" expected="$3" now
    [ -n "$expected" ] || return 0
    now="$(_fs_id "$path")" || {
        echo "refresh-graph-map: TOCTOU guard: could not probe $label identity via stat at use-time ($path) -- refusing (fail-closed, HIMMEL-1704)" >&2
        return 1
    }
    if [ "$now" != "$expected" ]; then
        echo "refresh-graph-map: TOCTOU guard: $label identity changed between preflight and use ($path expected $expected, now $now) -- refusing (HIMMEL-1704)" >&2
        return 1
    fi
    return 0
}

# Scheduled provider paths must verify the effective endpoint exactly rather
# than trusting a backend alias. Empty means the backend's trusted default;
# otherwise accept only HTTPS and return the exact lower-cased host after
# stripping path/query/fragment/userinfo/port. Malformed, plaintext, and
# backslash-bearing values return no host. Never echo the raw URL — it may
# carry userinfo/query credentials. _guard_endpoint_host (HIMMEL-1776,
# scripts/guardrails/phi-egress-lib.sh) is the shared implementation with
# graphify-fence.sh's _map_anthropic_endpoint/_map_kimi_endpoint — this is a
# thin wrapper so existing call sites in this file don't all need renaming.
_endpoint_host() {
  _guard_endpoint_host "$1"
}

_endpoint_host_allowed() {
  local host allowed
  [ -n "$1" ] || return 0
  host="$(_endpoint_host "$1")" || return 1
  shift
  for allowed in "$@"; do
    [ "$host" = "$allowed" ] && return 0
  done
  return 1
}

# GLM (Z.ai) alias (HIMMEL-1048). graphify has NO native `glm` backend — GLM is
# reached via graphify's `claude` backend pointed at Z.ai's Anthropic-compatible
# endpoint. The egress matrix + fence classify `--backend glm` as the zai-glm
# provider, so make `--backend glm` a single-flag process instead of hand-setting
# ANTHROPIC_* env each run: it remaps to `--backend claude` + ANTHROPIC_BASE_URL=<z.ai> +
# ANTHROPIC_MODEL=glm-5.2 + ANTHROPIC_API_KEY=<ZAI_API_KEY, loaded from .env, never
# printed>. A live ANTHROPIC_* env still wins (only fills gaps).
case "$BACKEND" in
  glm|zai-glm)
    BACKEND="claude"
    : "${ANTHROPIC_BASE_URL:=https://api.z.ai/api/anthropic}"
    _endpoint_host_allowed "$ANTHROPIC_BASE_URL" api.z.ai open.bigmodel.cn || {
      echo "refresh-graph-map: ANTHROPIC_BASE_URL is set to an unverified GLM endpoint (value not echoed); refusing scheduled egress (fail-closed). Use exact HTTPS host api.z.ai or open.bigmodel.cn." >&2
      exit 2
    }
    EFFECTIVE_PROVIDER="zai-glm"
    : "${ANTHROPIC_MODEL:=glm-5.2}"
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      # shellcheck source=../lib/load-dotenv.sh
      # shellcheck disable=SC1091
      if . "$(dirname "$0")/../lib/load-dotenv.sh" 2>/dev/null && load_dotenv ZAI_API_KEY 2>/dev/null && [ -n "${ZAI_API_KEY:-}" ]; then
        ANTHROPIC_API_KEY="$ZAI_API_KEY"
      else
        echo "refresh-graph-map: --backend glm needs ZAI_API_KEY (in the primary checkout's .env) or ANTHROPIC_API_KEY set." >&2
        exit 1
      fi
    fi
    export ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_API_KEY
    endpoint_host="$(_endpoint_host "$ANTHROPIC_BASE_URL")"
    echo "refresh-graph-map: --backend glm -> claude backend @ https://$endpoint_host (model $ANTHROPIC_MODEL)" >&2
    # DE-LISTED for private content (HIMMEL-2224, landing HIMMEL-1749's DROP):
    # every zai-glm VAULT/handover cell is now explicit deny, so the in-script
    # egress preflight below fails this remap closed on luna-personal,
    # luna-clippings and handover-state — no code change here is what enforces
    # that, the matrix is. The remap is KEPT rather than retired because
    # `himmel-code x * x *` is still `allow` (public code): `--backend glm` on a
    # himmel-code corpus remains a live, permitted path, and the de-listing is
    # deliberately not `hard`, so deleting the code would make the reversal
    # harder to undo than the matrix says it is. Kimi (`--backend kimi`,
    # moonshot, HIMMEL-1748) is the luna extraction lane now.
    ;;
  kimi|moonshot)
    # Kimi (Moonshot) — a NATIVE graphify backend (>=0.9.40; default model
    # kimi-k2.6, endpoint api.moonshot.ai), unlike the glm remap above which
    # rides the claude backend. Only the key needs wiring: load MOONSHOT_API_KEY
    # from the primary checkout's .env when absent (never printed). Egress:
    # moonshot is a ratified matrix provider (luna-personal / luna-clippings
    # extraction = allow+log, operator ratification 2026-08-12, HIMMEL-1748) —
    # the in-script preflight below evaluates the cell and appends the ledger
    # line the fence would have written (the fence never runs on scheduled
    # paths, HIMMEL-1084).
    BACKEND="kimi"
    _endpoint_host_allowed "${KIMI_BASE_URL:-}" api.moonshot.ai api.moonshot.cn || {
      echo "refresh-graph-map: KIMI_BASE_URL is set to an unverified endpoint (value not echoed); refusing scheduled egress (fail-closed). Use exact HTTPS api.moonshot.ai/api.moonshot.cn or unset it." >&2
      exit 2
    }
    EFFECTIVE_PROVIDER="moonshot"
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
      # shellcheck source=../lib/load-dotenv.sh
      # shellcheck disable=SC1091
      if . "$(dirname "$0")/../lib/load-dotenv.sh" 2>/dev/null && load_dotenv MOONSHOT_API_KEY 2>/dev/null && [ -n "${MOONSHOT_API_KEY:-}" ]; then
        :
      else
        echo "refresh-graph-map: --backend kimi needs MOONSHOT_API_KEY (in the primary checkout's .env) or set in the environment." >&2
        exit 1
      fi
    fi
    export MOONSHOT_API_KEY
    # Moonshot enforces strict per-org RPM caps; graphify's 429 retry machinery
    # (GRAPHIFY_MAX_RETRIES, honors Retry-After) exists for exactly this — give
    # the unattended cadence more headroom than graphify's default (6).
    # `-10` (unset-only): an operator override wins; graphify validates the value.
    GRAPHIFY_MAX_RETRIES="${GRAPHIFY_MAX_RETRIES-10}"
    export GRAPHIFY_MAX_RETRIES
    echo "refresh-graph-map: --backend kimi (Moonshot, native graphify backend)" >&2
    ;;
esac

# In-script egress preflight + ledger for the scheduled claude/claude-cli/glm/
# kimi paths (partial HIMMEL-1084). graphify-fence.sh owns matrix eval + the
# allow+log ledger on interactive paths, but it never runs on a scheduled
# invocation. Resolve claude/claude-cli by their EFFECTIVE ANTHROPIC_BASE_URL,
# then run the same matrix eval. Unknown/custom endpoints use the fence's
# anthropic-custom provider name and are hard-denied before matrix evaluation,
# so they cannot escape through a wildcard cell. Append the same ledger
# line for allow+log verdicts (same file, same JSONL shape), fail-closed: a deny/
# conditional verdict OR a failed ledger append aborts the run. Extraction path
# only: a --no-update republish makes no backend calls.
if [ "$DO_UPDATE" -eq 1 ]; then
  if [ -z "$EFFECTIVE_PROVIDER" ]; then
    case "$BACKEND" in
      claude|claude-cli)
        if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
          EFFECTIVE_PROVIDER="anthropic"
        else
          endpoint_host="$(_endpoint_host "$ANTHROPIC_BASE_URL")" || endpoint_host=""
          case "$endpoint_host" in
            api.anthropic.com) EFFECTIVE_PROVIDER="anthropic" ;;
            api.z.ai|open.bigmodel.cn) EFFECTIVE_PROVIDER="zai-glm" ;;
            *) EFFECTIVE_PROVIDER="anthropic-custom" ;;
          esac
        fi
        ;;
    esac
  fi
fi
if [ "$DO_UPDATE" -eq 1 ] && [ -z "$EFFECTIVE_PROVIDER" ]; then
  echo "refresh-graph-map: backend '$BACKEND' has no egress-matrix provider mapping — refusing scheduled extraction (fail-closed)" >&2
  exit 2
fi
if [ "$DO_UPDATE" -eq 1 ] && [ "$EFFECTIVE_PROVIDER" = "anthropic-custom" ]; then
  echo "refresh-graph-map: claude backend points at an unverified endpoint (ANTHROPIC_BASE_URL is set to an unrecognized/unsupported value — not echoed, it may carry credentials); refusing scheduled egress on every corpus (fail-closed)" >&2
  exit 2
fi
if [ -n "$EFFECTIVE_PROVIDER" ] && [ "$DO_UPDATE" -eq 1 ]; then
  _mx_json_escape() {
    local s="$1" i octal ctrl escaped
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    # POSIX paths may contain every C0 byte except NUL, which bash variables
    # cannot carry. Encode the representable range uniformly as \u00XX.
    for i in {1..31}; do
      printf -v octal '%03o' "$i"
      printf -v ctrl '%b' "\\0$octal"
      printf -v escaped '\\u%04x' "$i"
      s="${s//$ctrl/$escaped}"
    done
    printf '%s' "$s"
  }
  # PATH-DERIVED salus guard (CR codex-adv r4): --corpus-class is a caller
  # ASSERTION, and the fence (which classifies by path) never runs on the
  # scheduled path — so before honoring the asserted class, derive the one
  # classification that is a HARD deny from the corpus root itself, with the
  # same primitives the matrix's corpora section names: a `.salus` marker at
  # the root, or membership in ~/.config/claude-glm/phi-roots /
  # egress-denylist. A salus-derived root fails closed here REGARDLESS of the
  # asserted class or backend (the matrix salus row wildcard-denies every
  # non-local provider; the local-ollama conditional is out of scope for this
  # preflight, which only ever runs for network backends). Non-salus roots
  # proceed under the asserted class exactly as before — deriving
  # luna-personal vs himmel-code from a path needs vault-root config this
  # script does not own; salus is the class where a mislabel is catastrophic
  # and the only one that is path-derivable with fence parity.
  PHI_POLICY_UNREADABLE=""
  _corpus_is_salus_root() { # <root> -> 0 when the path classifies as salus
    local root="$1" canon cfg p d prev=""
    PHI_POLICY_UNREADABLE=""
    canon="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
    d="$canon"
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
      if [ -e "$d/.salus" ]; then return 0; fi
      prev="$d"
      d="${d%/*}"
    done
    for cfg in "$HOME/.config/claude-glm/phi-roots" "$HOME/.config/claude-glm/egress-denylist"; do
      [ -e "$cfg" ] || continue
      if ! _guard_file_readable "$cfg"; then
        PHI_POLICY_UNREADABLE="$cfg"
        return 1
      fi
      while IFS= read -r p || [ -n "$p" ]; do
        # trim before comparing (HIMMEL-1748 r4): a CRLF-saved config leaves a
        # trailing \r on every entry and a stray leading/trailing space does the
        # same — untrimmed, the prefix below never matches and a corpus that IS
        # under a declared PHI root classifies non-SALUS (fail-OPEN). An entry
        # that is empty after trimming must be skipped, not compared: "" would
        # prefix-match EVERY path. Bash 3.2-safe expansions only (T37).
        p="${p%$'\r'}"
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [ -n "$p" ] || continue
        case "$p" in \#*) continue ;; esac
        p="${p//\\//}"
        p="${p%/}"
        case "$canon/" in "$p"/*) return 0 ;; esac
      done < "$cfg"
    done
    return 1
  }
  if _corpus_is_salus_root "$CORPUS_ROOT"; then
    echo "refresh-graph-map: corpus root classifies as SALUS by path (marker/phi-roots/denylist) — refusing scheduled egress to $EFFECTIVE_PROVIDER regardless of the asserted --corpus-class '$CORPUS_CLASS' (PHI hard deny, fail-closed)" >&2
    exit 2
  fi
  if [ -n "$PHI_POLICY_UNREADABLE" ]; then
    echo "refresh-graph-map: a PHI root list under $HOME/.config/claude-glm exists but is not readable (fail-closed)" >&2
    exit 2
  fi
  MX_EVAL="$REPO_ROOT/scripts/guardrails/egress-matrix-eval.mjs"
  verdict_line="$(node "$MX_EVAL" "$CORPUS_CLASS" "$EFFECTIVE_PROVIDER" extraction)" \
    || { echo "refresh-graph-map: egress matrix eval failed (node/$MX_EVAL)" >&2; exit 2; }
  verdict="${verdict_line%%$'\t'*}"
  case "$verdict" in
    allow) : ;;
    allow+log)
      ledger="${GRAPHIFY_LEDGER:-$HOME/.claude/graphify-egress.jsonl}"
      mkdir -p "$(dirname "$ledger")" || { echo "refresh-graph-map: cannot create ledger dir for $ledger" >&2; exit 2; }
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # Ledger shape (HIMMEL-1787 CR follow-up): HIMMEL-1084's intent was
      # "the same file, same JSONL shape" as scripts/guardrails/
      # graphify-fence.sh's ledger_append would write for a fence-mediated
      # run (one shared audit trail regardless of entry path) -- checked
      # field-for-field against BOTH producers below, not assumed, and the
      # two do NOT currently fully agree (see the "purpose" gap this same
      # note flags), so this is a confirmed DIVERGENCE, not confirmed
      # parity. The field set here (ts, path, corpus, backend, provider,
      # verdict, purpose, tool) matches egress-matrix.json's OWN documented
      # allow+log contract ("the executing tool MUST append a ledger line
      # (JSONL: ts, corpus, provider, purpose, path, tool)") exactly,
      # including "purpose" -- which ledger_append() does NOT currently
      # emit (a gap against that same documented contract, in
      # scripts/guardrails/**, out of this ticket's file scope to fix).
      # Every OTHER shared field does agree (backend is a superset addition
      # both producers make); the
      # fence's conditional "declared"/"declared_backend_source" fields have
      # no equivalent here because a scheduled refresh-graph-map.sh run never
      # goes through the fence's `.graphify-corpus` marker declaration path
      # at all (HIMMEL-1084: "the fence never runs on scheduled paths") --
      # structurally not this producer's fields to add.
      printf '{"ts":"%s","path":"%s","corpus":"%s","backend":"%s","provider":"%s","verdict":"allow+log","purpose":"extraction","tool":"refresh-graph-map"}\n' \
        "$ts" "$(_mx_json_escape "$CORPUS_ROOT")" "$(_mx_json_escape "$CORPUS_CLASS")" "$(_mx_json_escape "$BACKEND")" "$EFFECTIVE_PROVIDER" >> "$ledger" \
        || { echo "refresh-graph-map: ledger append failed ($ledger) — allow+log without its ledger line is a deny" >&2; exit 2; }
      ;;
    *)
      echo "refresh-graph-map: egress matrix DENIES $CORPUS_CLASS x $EFFECTIVE_PROVIDER x extraction ($verdict_line)" >&2
      exit 2
      ;;
  esac
fi

GRAPHIFY_MAP="${GRAPHIFY_MAP_BIN:-graphify}"   # test hook: stub graphify
# graphify is only needed for the extraction path — --no-update publishes from
# an existing report and must not require it (CR: code-reviewer).

# Extraction/labeling concurrency knob (HIMMEL-1097 mitigation). --max-concurrency
# caps only how many requests are IN FLIGHT at once — it is not true rate-limiting
# (no pacing/backoff between sequential requests), so it reduces request pressure
# but cannot beat a hard per-key quota. The default 6 overshoots a rate-limited
# backend badly — `--backend glm` (Z.ai) 429s (rate_limit_error code 1302) on most
# chunks at 6. Lowering it (e.g. GRAPHIFY_MAX_CONCURRENCY=1) eases the pressure and
# is worth trying, but is NOT guaranteed to complete: an exhausted/hard request
# quota 429s even serialized (observed 2026-07-21 — chunk 1 failed at concurrency 1
# with ~33s spacing). Applies to BOTH the --update extraction and the cluster-only
# labeling pass (both make backend LLM calls against the same limit). Must be a
# positive integer; anything else (including an explicitly-empty value) fails loud.
# Band-aid — the durable fix (seed graphify's semantic cache so the regen is a
# small incremental, not a full 255-chunk extraction) is HIMMEL-1097.
# `-6` (unset-only default), NOT `:-6`: an explicitly-empty value stays empty and
# is caught by the validation below, rather than silently defaulting to 6.
# The default stays 6 (not glm-lowered): this script's DEFAULT backend is
# claude-cli (line 45), which is unaffected — lowering the default would 6x-slow
# every non-glm regen for no gain. glm callers pass the knob explicitly, and a
# lower value would not rescue glm anyway when the request quota is exhausted
# (it 429s even serialized, as above). Wiring a throttled default into the glm
# cadence is a separate concern, out of scope for this knob.
# claude-cli NOTE (HIMMEL-1748): graphify FORCE-SERIALIZES the claude-cli
# backend (llm.py: max_concurrency=1 unless GRAPHIFY_CLAUDE_CLI_PARALLEL=1 —
# headless-claude-ok: documents why graphify keeps its intentional CLI subprocesses serial
# parallel `claude -p` subprocesses conflict over session state), so this knob
# and the --max-concurrency flags below are a NO-OP for claude-cli; they govern
# the API backends only (claude, the glm remap, kimi, deepseek, ...).
GRAPHIFY_MAX_CONCURRENCY="${GRAPHIFY_MAX_CONCURRENCY-6}"
# Validate ONLY on the extraction path (DO_UPDATE=1): the knob feeds the
# --update + cluster-only graphify calls, which a --no-update publish-only run
# never makes — so an invalid value is irrelevant there and must not fail an
# unrelated republish (CR: codex-1).
if [ "$DO_UPDATE" -eq 1 ]; then
  case "$GRAPHIFY_MAX_CONCURRENCY" in
    ''|*[!0-9]*) echo "refresh-graph-map: GRAPHIFY_MAX_CONCURRENCY must be a positive integer (got '$GRAPHIFY_MAX_CONCURRENCY')" >&2; exit 1 ;;
  esac
  [ "$GRAPHIFY_MAX_CONCURRENCY" -ge 1 ] || { echo "refresh-graph-map: GRAPHIFY_MAX_CONCURRENCY must be >= 1 (got '$GRAPHIFY_MAX_CONCURRENCY')" >&2; exit 1; }
fi

# Per-chunk API timeout (HIMMEL-1645). graphify's DEFAULT API timeout is 300s, but
# claude-cli chunks run SERIAL (graphify's own clamp — see the concurrency note
# above) and a single serial chunk measures ~7 min wall on the luna corpus
# (2026-08-11/12, HIMMEL-1748), past the 300s default — observed live 2026-08-08,
# a 399-doc incremental (claude-cli) produced 13 chunks and >=5 died "timed out after 300.0
# seconds". graphify honors GRAPHIFY_API_TIMEOUT (seconds) as an override, so without
# this both manual runs AND the armed daily cadence ride the 300s default and re-pay
# every timed-out chunk on every fire. This raises the CEILING only (a timeout is a
# max-wait bound, not a duration — a fast chunk still returns as fast as ever) so a
# contending chunk that simply needs longer gets headroom; graphify still kills a
# genuinely wedged call at the bound, just a higher one (300s -> 900s = 3x, the
# observed worst case + margin). Backend-scoped (codex-adv-1): the contention is
# claude-cli ONLY — `claude` is graphify's Anthropic API backend (ANTHROPIC_API_KEY,
# pay-as-you-go HTTP, no local-CLI contention), and `--backend glm`/`zai-glm` remaps
# to `claude` (the Z.ai Anthropic-compatible API endpoint, above). So 900 ONLY for
# claude-cli (the sole backend with the observed failure); every other backend —
# including `claude` and the glm remap — stays at 300 = graphify's OWN default, so its
# behavior is unchanged (an API worker that needs longer takes its own caller-set
# GRAPHIFY_API_TIMEOUT; the default is not raised on its behalf). `-900`/`-300`
# (unset-only), NOT `:-900`/`:-300`: an explicitly-empty value stays empty and is caught
# by the validation below instead of silently becoming the default. Exported ONLY on
# the claude-cli branch (the one with a raised ceiling) so the env var (graphify's
# override channel) lets the cluster-only call below — which takes no --api-timeout
# flag — inherit the raised ceiling too; the 300 else-branch is graphify's own default
# (no export needed there — an unset env already means 300 to graphify). On the
# extraction path ONLY (DO_UPDATE=1): the timeout feeds the --update + cluster-only
# graphify calls a --no-update publish-only run never makes, so an invalid value is
# irrelevant there and must not fail an unrelated republish (same DO_UPDATE gating as
# GRAPHIFY_MAX_CONCURRENCY).
if [ "$DO_UPDATE" -eq 1 ]; then
  if [ "$BACKEND" = "claude-cli" ]; then
    GRAPHIFY_API_TIMEOUT="${GRAPHIFY_API_TIMEOUT-900}"
    export GRAPHIFY_API_TIMEOUT
    # Model pin (HIMMEL-1748). Unpinned, graphify's claude-cli chunks run on the
    # CLI's DEFAULT model — the operator's top tier — against the shared
    # subscription usage bank (header billing note). Sonnet is the quality-safe
    # default for graphify's structured-JSON extraction (haiku rejected:
    # unmeasured quality on nuanced vault notes). Exported so the cluster-only
    # labeling call inherits it too. `-sonnet` (unset-only): an operator
    # override wins, and an EXPLICITLY-EMPTY value is a deliberate opt-out back
    # to the CLI default (graphify passes no --model for an empty value).
    GRAPHIFY_CLAUDE_CLI_MODEL="${GRAPHIFY_CLAUDE_CLI_MODEL-sonnet}"
    export GRAPHIFY_CLAUDE_CLI_MODEL
    # Effort pin (HIMMEL-1748, same rationale as the model pin): an unpinned
    # spawn inherits the operator's interactive effort default — which may be
    # xhigh, pure burn for schema-constrained extraction. The CLI reads
    # CLAUDE_CODE_EFFORT_LEVEL from the environment (the documented env channel
    # for --effort; verified present in the installed claude binary 2026-08-12);
    # levels: low|medium|high|xhigh|max. Effort-vs-tier research (luna
    # 30-Resources/Concepts/"Effort-vs-Tier Tradeoff") found extraction is a
    # low-reasoning workload, so `low` is the default. `-low` (unset-only): an
    # operator override wins; an explicitly-empty value falls back to the CLI's
    # own default (the CLI ignores an empty/unknown value with a warning).
    CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL-low}"
    export CLAUDE_CODE_EFFORT_LEVEL
  else
    GRAPHIFY_API_TIMEOUT="${GRAPHIFY_API_TIMEOUT-300}"
  fi
  case "$GRAPHIFY_API_TIMEOUT" in
    ''|*[!0-9]*) echo "refresh-graph-map: GRAPHIFY_API_TIMEOUT must be a positive integer (got '$GRAPHIFY_API_TIMEOUT')" >&2; exit 1 ;;
  esac
  [ "$GRAPHIFY_API_TIMEOUT" -ge 1 ] || { echo "refresh-graph-map: GRAPHIFY_API_TIMEOUT must be >= 1 (got '$GRAPHIFY_API_TIMEOUT')" >&2; exit 1; }
fi

# Off-peak advisory (DeepSeek peak-valley UTC 1-4 + 6-10 = 2x). Advisory only —
# a scheduler should aim off-peak; we never hard-refuse (an operator may run ad hoc).
if [ "$BACKEND" = "deepseek" ]; then
  H=$(date -u +%H)
  case "$H" in 01|02|03|06|07|08|09) echo "refresh-graph-map: WARN inside DeepSeek peak window (2x); off-peak resumes 10:00 UTC. Advisory." >&2 ;; esac
fi

# HIMMEL-1960: graphify resolves its own out-dir name from GRAPHIFY_OUT
# (paths.py: `os.environ.get("GRAPHIFY_OUT", "graphify-out")`, read once at
# import; watch.py joins it as `out = watch_path / GRAPHIFY_OUT`), and
# ast-update.sh resolves it the same way so the hourly structural leg takes
# the promote lock on the directory actually being written. This script
# hardcoded "graphify-out", so under an override the two legs locked and wrote
# DIFFERENT directories: the serialization HIMMEL-1948 added would silently
# guard nothing, and the semantic leg would publish from the wrong path.
#
# Only the RELATIVE form is honourable here. ast-update.sh can accept an
# ABSOLUTE GRAPHIFY_OUT because it runs graphify against the live corpus in
# place; this script extracts into a scratch COPY and promotes. An absolute
# out dir would make graphify write outside $SCRATCH entirely — the extraction
# would land straight on the live path, the promote would find nothing to
# promote, and "extraction never touches the live corpus" would stop holding.
# Refuse it loudly rather than diverge quietly: a refusal is a cadence that
# does not run, a divergence is a cadence that corrupts.
# `${VAR-default}`, NOT `${VAR:-default}` (CR r5): Python's
# `os.environ.get("GRAPHIFY_OUT", "graphify-out")` substitutes the default only
# when the variable is ABSENT, and PRESERVES an exported empty string — which
# pathlib then joins away, so graphify would write the corpus root itself. `:-`
# would silently substitute "graphify-out" there and we would lock and promote a
# directory graphify is not writing: the exact divergence this block exists to
# remove. Keeping the empty value lets the name check below refuse it loudly.
GRAPHIFY_OUT_NAME="${GRAPHIFY_OUT-graphify-out}"
case "$GRAPHIFY_OUT_NAME" in
  /*|[A-Za-z]:[/\\]*)
    echo "refresh-graph-map: GRAPHIFY_OUT is an absolute path ('$GRAPHIFY_OUT_NAME'), which this script cannot honour -- it extracts into a scratch copy and promotes, and an absolute out dir bypasses both. Unset it, or set a plain relative directory NAME (ast-update.sh resolves the same value, so both legs stay serialized on one directory)." >&2
    exit 2 ;;
esac
# A plain single-segment name only: "." / ".." / a path with separators would
# resolve OUT_DIR onto the corpus root itself (or outside it), and this value
# is later fed to `rm -rf`-adjacent promote paths and a find -path exclusion.
if ! printf '%s' "$GRAPHIFY_OUT_NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  echo "refresh-graph-map: GRAPHIFY_OUT must be a single relative directory name matching [A-Za-z0-9][A-Za-z0-9._-]* (got '$GRAPHIFY_OUT_NAME')" >&2
  exit 2
fi
OUT_DIR="$CORPUS_ROOT/$GRAPHIFY_OUT_NAME"
# Refuse to adopt a directory that is not already a graphify out dir (CR r8/r9).
# Accepting any well-formed NAME widened what the promote can land on: with
# GRAPHIFY_OUT=docs, OUT_DIR becomes <corpus>/docs, and the promote block below
# recursively deletes "$OUT_DIR/cache", deletes "$OUT_DIR/manifest.json" and
# "$OUT_DIR/.graphify_root", then drops graph.json in. That is real data loss
# inside a SOURCE directory, from one mistyped environment variable.
#
# SCOPED TO THE OVERRIDE, deliberately. Two earlier versions tried to answer
# "does this directory belong to graphify?" from its contents and got it wrong
# in both directions: a wide marker list accepted a source tree that merely had
# a `cache/`, and a narrow one rejected legitimate out dirs that had not been
# promoted yet. The contents are the wrong question. The RISK is a mistyped
# GRAPHIFY_OUT; the conventional `graphify-out` under the corpus root is the
# out dir by definition and needs no proof, so the default path keeps exactly
# the behaviour it always had. Only an explicit override has to earn it — by
# being absent, empty, or carrying graphify's own namespaced control files
# (every promote writes `.graphify_root`, and an interrupted one leaves
# `.promote-stage.*`, so a real out dir always has one). Unmatched globs expand
# literally and fail `-e`, so the loop is safe with nullglob off.
# Gate on the resolved NAME, not on the variable merely being SET (CR r10):
# GRAPHIFY_OUT=graphify-out is the default spelled out loud and must behave
# exactly like leaving it unset, or a harmless explicit setting would start
# refusing a valid out dir that predates the marker convention.
# A SYMLINK at the override path escapes the corpus (CR r14): the name check
# above only proves the NAME is a single segment, and `-d` follows the link, so
# <corpus>/foo -> /somewhere/else would be adopted and the promote would then
# write into, and delete graph-named content from, a directory outside the
# corpus the operator named. `-L` is the only test that sees the link itself,
# and it runs before `-d` so a link to a directory cannot slip past.
if [ "$GRAPHIFY_OUT_NAME" != "graphify-out" ] && [ -L "$OUT_DIR" ]; then
  echo "refresh-graph-map: REFUSING to use $OUT_DIR as the graphify out dir -- GRAPHIFY_OUT is overridden to '$GRAPHIFY_OUT' and that path is a SYMLINK, which would place the promote outside the corpus root. Point it at a real directory under the corpus." >&2
  exit 2
fi
if [ "$GRAPHIFY_OUT_NAME" != "graphify-out" ] && [ -d "$OUT_DIR" ]; then
  _out_is_graphify=0
  # `.graphify_*` with the UNDERSCORE, not `.graphify*` (CR r11). Every out-dir
  # control file graphify writes is underscored -- .graphify_root,
  # .graphify_build.json, .graphify_semantic_marker, .graphify_analysis.json,
  # .graphify_labels.json, .graphify_promoted_version -- while the CORPUS-side
  # file this repo puts at a source root, `.graphify-corpus-ignore`
  # (HIMMEL-1903), is hyphenated. The looser glob accepted that as proof of
  # ownership, so a source tree carrying one could be adopted and have its
  # cache and manifest destroyed: the guard defeated by a file this very repo
  # tells operators to create.
  for _marker in "$OUT_DIR"/.graphify_* "$OUT_DIR"/.promote* \
                 "$OUT_DIR"/.cache.previous.*; do
    if [ -e "$_marker" ]; then _out_is_graphify=1; break; fi
  done
  # FAIL CLOSED when the directory cannot be listed (CR r14). `2>/dev/null`
  # turned an unreadable directory into an empty-looking one, i.e. into "safe
  # to adopt" -- a permissions problem silently granting the promote access to
  # contents nobody could see.
  if ! _out_listing=$(ls -A "$OUT_DIR" 2>/dev/null); then
    echo "refresh-graph-map: REFUSING to use $OUT_DIR as the graphify out dir -- it exists but could not be listed (permissions?), so its contents cannot be checked before a destructive promote." >&2
    exit 2
  fi
  if [ "$_out_is_graphify" -eq 0 ] && [ -n "$_out_listing" ]; then
    echo "refresh-graph-map: REFUSING to use $OUT_DIR as the graphify out dir -- GRAPHIFY_OUT is overridden to '$GRAPHIFY_OUT' and that is a non-empty directory carrying none of graphify's control files, so it is source content, not a graph output. Promoting into it would destroy $OUT_DIR/cache and $OUT_DIR/manifest.json." >&2
    exit 2
  fi
fi
REPORT="$OUT_DIR/GRAPH_REPORT.md"

# HIMMEL-910: exclusive per-out-dir promote lock. Two overlapping refreshes
# of the SAME out dir (a scheduler firing twice, an operator re-running
# while a prior run is still in flight, ...) had no inter-process
# serialization around the F2 transactional promote block below -- B
# overwriting a .tmp before A renames it (or B's cp landing between A's
# invalidate and A's own cp) could stamp A's graph with B's corpus snapshot,
# or leave the out dir with an artifact triple from two different runs.
# mkdir is atomic (no check-then-create TOCTOU, works on NTFS/Git-Bash
# without relying on O_EXCL) -- same primitive as
# scripts/handover/queue-lock.sh's queue lock (see its header for the full
# mkdir-atomicity rationale). Deliberately smaller here: this is a
# lean-invoke operator/scheduler tool, not the multi-writer armed-session
# coordination queue-lock.sh guards, so no session tokens, heartbeat, or
# arms-registry integration -- just a bounded-wait acquire with stale-by-age
# takeover (a loud stderr trail either way), released on ANY exit (success
# or failure) by the same EXIT trap that cleans up SCRATCH below.
# Residual (accepted, CR r1): a stale-but-ALIVE holder (machine-sleep
# mid-promote) that was taken over can still be INSIDE the promote block
# when it wakes and interleave with the successor -- inherent to fail-open
# stale takeover; the 600s stale floor vs a promote block measured in
# seconds gives the margin. Its RELEASE, however, is owner-tokened (below)
# so it never deletes the successor's lock.
PROMOTE_LOCK="$OUT_DIR/.promote.lock"
PROMOTE_LOCK_TIMEOUT_SECONDS="${GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS:-120}"
PROMOTE_LOCK_STALE_SECONDS="${GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS:-600}"
PROMOTE_LOCK_HELD=0
PROMOTE_LOCK_TOKEN=""
PROMOTE_STAGE=""
CACHE_BACKUP=""

# EXTRACTION_LOCK (HIMMEL-1653) -- a SECOND, WIDER lock covering the whole
# pull+copy+extraction+promote run, distinct from PROMOTE_LOCK above on
# purpose. PROMOTE_LOCK alone only serializes the transactional promote
# block and deliberately lets pull/copy/extraction overlap (see the "NOT
# under the promote lock" note near the pull step below) -- so two
# refreshes of the SAME corpus (a manual /graph-refresh next to the
# cadence runner, both invoking this same script) can run duplicate paid
# extraction concurrently, and worse, an OLDER corpus snapshot that
# finishes extraction later can still win the (correctly-ordered) promote
# and overwrite a NEWER graph, because the promote lock only orders
# promotes against each other, never against extraction START order.
# This lock closes that: acquired before pull/copy/extraction begins,
# released only at the very end (same EXIT trap as PROMOTE_LOCK), so a
# second invocation for the same OUT_DIR cannot enter extraction while one
# is already in flight -- it waits (bounded) or refuses.
#
# Its stale-takeover floor must be much LARGER than PROMOTE_LOCK's: the
# region it guards includes the extraction itself, which is the region the
# promote lock was explicitly kept OUT of specifically because that can
# outlast a short stale floor (see the same note below). A default in the
# hours, not seconds, means a genuinely still-running extraction is never
# mistaken for a crashed holder; a truly dead holder still self-heals, just
# slower. The acquire WAIT, by contrast, defaults short: this is an
# expensive step, so a second invocation should get a fast, clear refusal
# to retry later rather than block a session for the full extraction.
# Residual (accepted, same class as PROMOTE_LOCK's own -- CR follow-up,
# codex-2 @ HIMMEL-1653 paid panel): a fixed stale threshold with no
# heartbeat/lease renewal means a genuinely still-running extraction that
# legitimately outlasts EXTRACTION_LOCK_STALE_SECONDS (default 7200s = 2h)
# CAN be judged stale and taken over, letting two processes extract
# concurrently for the tail of that window -- the exact class of race this
# lock exists to close, just at a much longer timescale than promote's.
# Not fixed here: heartbeat/lease renewal is a real feature, not a bug fix,
# and the ticket's own text already scopes a full close of the
# stale-overwrite path to a separate "consider also" snapshot-freshness
# check at promote time, not this lock alone. Operators with corpora that
# legitimately run past 7200s should raise GRAPHIFY_EXTRACTION_LOCK_STALE_SECONDS.
EXTRACTION_LOCK="$OUT_DIR/.extraction.lock"
EXTRACTION_LOCK_TIMEOUT_SECONDS="${GRAPHIFY_EXTRACTION_LOCK_TIMEOUT_SECONDS:-10}"
EXTRACTION_LOCK_STALE_SECONDS="${GRAPHIFY_EXTRACTION_LOCK_STALE_SECONDS:-7200}"
# Validate BOTH as non-negative integers (CR follow-up, codex-4 @ HIMMEL-1653
# paid panel): a malformed override (non-numeric, or simply mistyped) makes
# every `[ "$x" -ge "$y" ]` comparison against it fail with a shell error
# rather than a true/false result -- under `if`, that failure reads as
# FALSE, so the acquire loop's own timeout/stale check can never fire and
# the bounded wait silently becomes unbounded. Fall back to the same
# defaults used above, matching this file's own established idiom for
# operator-supplied numeric env vars elsewhere (e.g. CRITIC_TIMEOUT_SECS).
case "$EXTRACTION_LOCK_TIMEOUT_SECONDS" in ''|*[!0-9]*) EXTRACTION_LOCK_TIMEOUT_SECONDS=10 ;; esac
case "$EXTRACTION_LOCK_STALE_SECONDS" in ''|*[!0-9]*) EXTRACTION_LOCK_STALE_SECONDS=7200 ;; esac
EXTRACTION_LOCK_HELD=0
EXTRACTION_LOCK_TOKEN=""

# _extraction_lock_release -- same owner-tokened protocol as
# _promote_lock_release (below): only removes the lock when it still holds
# OUR token, so a former holder that was taken over while paused (stale
# takeover) can never rm -rf a successor's lock on wake.
_extraction_lock_release() {
  local cur=""
  if [ "$EXTRACTION_LOCK_HELD" -eq 1 ]; then
    EXTRACTION_LOCK_HELD=0
    [ -d "$EXTRACTION_LOCK" ] || return 0
    cur=$(cat "$EXTRACTION_LOCK/owner" 2>/dev/null) || cur=""
    if [ "$cur" != "$EXTRACTION_LOCK_TOKEN" ]; then
      echo "refresh-graph-map: WARN extraction lock $EXTRACTION_LOCK was taken over by another refresh while we held it (owner token mismatch) -- not releasing the successor's lock" >&2
      return 0
    fi
    rm -rf "$EXTRACTION_LOCK" 2>/dev/null || true
  fi
}

# _extraction_lock_takeover <reason> -- single-winner takeover, same
# atomic-rename protocol as _promote_lock_takeover (below): exactly one
# contender's mv succeeds; the loser just loops back to the mkdir spin.
_extraction_lock_takeover() {
  local sideline="$EXTRACTION_LOCK.stale.$$.$RANDOM"
  if mv "$EXTRACTION_LOCK" "$sideline" 2>/dev/null; then
    echo "refresh-graph-map: WARN extraction lock $EXTRACTION_LOCK $1 -- taking over" >&2
    rm -rf "$sideline" 2>/dev/null || true
    return 0
  fi
  return 1
}

# _extraction_lock_acquire -- bounded mkdir spin (default 10s wait, 1s
# poll) with single-winner stale takeover (default 7200s). Same mkdir +
# owner-token + acquired-stamp protocol as _promote_lock_acquire (below).
# Returns 1 (never held) once the wait budget is exhausted -- the caller
# refuses to enter extraction rather than double-run it.
#
# Residual (accepted, SAME class already documented + shipped for
# PROMOTE_LOCK -- CR follow-up, codex-1 @ HIMMEL-1653 paid panel): the
# missing-stamp grace window (~5 polls) treats a holder that mkdir'd but
# has not yet written owner/acquired as crashed and takes over. A holder
# merely PAUSED (not crashed) in that narrow window -- between its own
# mkdir and its own writes -- can resume writing into what is now the
# successor's directory (the path still resolves, post-takeover, to
# whatever now occupies it). This is not new: it is the identical
# mkdir+stamp+grace-window algorithm PROMOTE_LOCK already ships with (same
# 5-poll grace, same rationale, same shared residual), applied here to a
# second lock. Not hardened further here -- doing so is a real
# lock-protocol redesign (e.g. writing owner+acquired atomically via a
# staged rename instead of two separate writes), out of proportion to this
# ticket, and would need the identical treatment on PROMOTE_LOCK to stay
# consistent.
#
# Same class, second round (codex-2/codex-3 @ the same panel): the
# `date -u +%s > "$EXTRACTION_LOCK/acquired" 2>/dev/null || true` write
# below can itself fail (disk full, permissions) and is swallowed -- a
# genuinely LIVE holder with no readable stamp reads identically to a
# crashed one, so it hits the SAME 5-poll grace-window takeover this
# comment already covers. Verified this is not a new gap either: promote
# lock's own acquired-write (below) has the identical `|| true` swallow.
_extraction_lock_acquire() {
  local waited=0 missing_polls=0 held_at now age token
  while :; do
    if mkdir "$EXTRACTION_LOCK" 2>/dev/null; then
      token="$$-$RANDOM"
      if ! printf '%s\n' "$token" > "$EXTRACTION_LOCK/owner" 2>/dev/null; then
        rm -rf "$EXTRACTION_LOCK" 2>/dev/null || true
        echo "refresh-graph-map: extraction lock acquired but its owner token could not be written ($EXTRACTION_LOCK/owner) -- released again, nothing acquired" >&2
        return 1
      fi
      date -u +%s > "$EXTRACTION_LOCK/acquired" 2>/dev/null || true
      EXTRACTION_LOCK_TOKEN="$token"
      EXTRACTION_LOCK_HELD=1
      return 0
    fi
    held_at=$(cat "$EXTRACTION_LOCK/acquired" 2>/dev/null) || held_at=""
    case "$held_at" in ''|*[!0-9]*) held_at="" ;; esac
    if [ -n "$held_at" ]; then
      missing_polls=0
      now=$(date -u +%s)
      age=$(( now - held_at ))
      if [ "$age" -ge "$EXTRACTION_LOCK_STALE_SECONDS" ]; then
        if _extraction_lock_takeover "is stale (age ${age}s >= ${EXTRACTION_LOCK_STALE_SECONDS}s)"; then
          continue
        fi
      fi
    else
      missing_polls=$((missing_polls + 1))
      if [ "$missing_polls" -ge 5 ]; then
        missing_polls=0
        if _extraction_lock_takeover "has no readable acquired stamp after a ~5s grace window (holder crashed between mkdir and stamp?)"; then
          continue
        fi
      fi
    fi
    if [ "$waited" -ge "$EXTRACTION_LOCK_TIMEOUT_SECONDS" ]; then
      echo "refresh-graph-map: extraction lock $EXTRACTION_LOCK held by another refresh-graph-map run -- another refresh is already extracting this corpus (out dir: $OUT_DIR); refusing to start a duplicate extraction. Wait for it to finish and retry, or override with GRAPHIFY_EXTRACTION_LOCK_TIMEOUT_SECONDS to wait longer." >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# _promote_stage_cleanup -- remove an incomplete same-filesystem staging dir.
# If a cache swap failed after sidelining the prior complete cache, restore it
# before releasing the promote lock. The freshness stamps remain invalidated,
# so even a later failure still fails closed rather than attesting mixed output.
_promote_stage_cleanup() {
  if [ -n "$CACHE_BACKUP" ] && { [ -e "$CACHE_BACKUP" ] || [ -L "$CACHE_BACKUP" ]; }; then
    if [ ! -e "$OUT_DIR/cache" ] && [ ! -L "$OUT_DIR/cache" ]; then
      mv "$CACHE_BACKUP" "$OUT_DIR/cache" 2>/dev/null || true
    else
      rm -rf "$CACHE_BACKUP" 2>/dev/null || true
    fi
  fi
  CACHE_BACKUP=""
  if [ -n "$PROMOTE_STAGE" ]; then
    rm -rf "$PROMOTE_STAGE" 2>/dev/null || true
    PROMOTE_STAGE=""
  fi
}

# _promote_lock_release -- owner-tokened (CR r1 [codex-1]): a former holder
# that was taken over while paused (stale takeover) must NOT, on wake,
# rm -rf the SUCCESSOR's lock -- so release compares the lock's owner file
# against OUR token and only removes on a match; on mismatch it WARNs
# loudly and walks away.
_promote_lock_release() {
  local cur=""
  if [ "$PROMOTE_LOCK_HELD" -eq 1 ]; then
    PROMOTE_LOCK_HELD=0
    [ -d "$PROMOTE_LOCK" ] || return 0
    cur=$(cat "$PROMOTE_LOCK/owner" 2>/dev/null) || cur=""
    if [ "$cur" != "$PROMOTE_LOCK_TOKEN" ]; then
      echo "refresh-graph-map: WARN promote lock $PROMOTE_LOCK was taken over by another refresh while we held it (owner token mismatch) -- not releasing the successor's lock" >&2
      return 0
    fi
    rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
  fi
}

# _promote_lock_takeover <reason> -- SINGLE-WINNER takeover (CR r1
# [codex-adv-1]): atomically SIDELINE the dead lock via a dir rename --
# exactly one contender's mv succeeds; the loser's mv fails and it just
# loops back to the mkdir spin. rm-then-continue was a race: two contenders
# judging the same stale stamp could have the second's rm -rf destroy the
# first's freshly-won lock. NOTE queue-lock.sh's header documents mv-to-
# graveyard as unreliable under concurrent rename on MSYS (spurious rc-0);
# here that is harmless -- mv only picks who prints the trail and reaps the
# sideline, while mkdir stays the sole acquire arbiter, so a spurious
# double-win degrades to a duplicate WARN, never a double-acquire.
_promote_lock_takeover() {
  local sideline="$PROMOTE_LOCK.stale.$$.$RANDOM"
  if mv "$PROMOTE_LOCK" "$sideline" 2>/dev/null; then
    echo "refresh-graph-map: WARN promote lock $PROMOTE_LOCK $1 -- taking over" >&2
    rm -rf "$sideline" 2>/dev/null || true
    return 0
  fi
  return 1
}

# _promote_lock_acquire -- bounded mkdir spin (default 120s, 1s poll) with
# single-winner stale takeover (default 600s, loud on stderr). The lock dir
# carries an "owner" token (release compares against it, above) and an
# "acquired" epoch-seconds file written by the winner right after mkdir,
# read back by a contender to judge staleness -- no filesystem-mtime probe
# needed (portable across NTFS/ext4 without a stat-flag dance). A lock
# whose stamp is missing/unparseable for ~5 consecutive polls (grace window
# covering a healthy winner's mkdir->stamp gap) is treated as a holder that
# crashed before stamping and reclaimed the same way (CR r1) -- otherwise
# such a lock would brick the out dir forever. Returns 1 (never held) once
# the wait budget is exhausted -- the caller exits non-zero rather than
# silently clobbering.
_promote_lock_acquire() {
  local waited=0 missing_polls=0 held_at now age token
  while :; do
    if mkdir "$PROMOTE_LOCK" 2>/dev/null; then
      token="$$-$RANDOM"
      if ! printf '%s\n' "$token" > "$PROMOTE_LOCK/owner" 2>/dev/null; then
        rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
        echo "refresh-graph-map: promote lock acquired but its owner token could not be written ($PROMOTE_LOCK/owner) -- released again, nothing acquired" >&2
        return 1
      fi
      date -u +%s > "$PROMOTE_LOCK/acquired" 2>/dev/null || true
      PROMOTE_LOCK_TOKEN="$token"
      PROMOTE_LOCK_HELD=1
      return 0
    fi
    held_at=$(cat "$PROMOTE_LOCK/acquired" 2>/dev/null) || held_at=""
    case "$held_at" in ''|*[!0-9]*) held_at="" ;; esac
    if [ -n "$held_at" ]; then
      missing_polls=0
      now=$(date -u +%s)
      age=$(( now - held_at ))
      if [ "$age" -ge "$PROMOTE_LOCK_STALE_SECONDS" ]; then
        if _promote_lock_takeover "is stale (age ${age}s >= ${PROMOTE_LOCK_STALE_SECONDS}s)"; then
          continue
        fi
        # lost the takeover to another contender -- fall through and wait.
      fi
    else
      missing_polls=$((missing_polls + 1))
      if [ "$missing_polls" -ge 5 ]; then
        missing_polls=0
        if _promote_lock_takeover "has no readable acquired stamp after a ~5s grace window (holder crashed between mkdir and stamp?)"; then
          continue
        fi
      fi
    fi
    if [ "$waited" -ge "$PROMOTE_LOCK_TIMEOUT_SECONDS" ]; then
      echo "refresh-graph-map: promote lock $PROMOTE_LOCK held by another refresh-graph-map run after ${PROMOTE_LOCK_TIMEOUT_SECONDS}s -- giving up (another refresh is in progress against this out dir)" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# _scratch_cleanup -- EXIT-trap cleanup for the owned $SCRATCH subdir
# (HIMMEL-1406). Previously this was a bare `rm -rf "$SCRATCH"`, which ran
# on EVERY exit including a promote-refusal (host-path guard, a missing
# scratch artifact, a failed sideline cache mv, ...) AFTER the paid
# extraction had already completed -- discarding the only copy of a full,
# possibly $2+ extraction (the 2026-07-30 luna/glm regen: 14,569 nodes,
# 16.7M tokens in) with no way to inspect what tripped the refusal. On a
# FAILURE exit where the extraction actually produced a
# $SCRATCH/$GRAPHIFY_OUT_NAME/graph.json, quarantine that dir (graph.json,
# GRAPH_REPORT.md, semantic cache, markers -- the "paid" artifact) to a
# sibling path instead of deleting it, so it survives for inspection/reuse;
# only the disposable corpus md copy under $SCRATCH is then removed. A
# SUCCESS exit already rm -rf's $SCRATCH eagerly before this trap fires (see
# "eager clean on success" below), and a failure BEFORE extraction produced
# anything (graphify not on PATH, corpus scan/copy failure, graphify
# --update itself failing with no output, ...) has nothing worth quarantining
# -- both fall through to the original unconditional rm -rf, unchanged.
_scratch_cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$SCRATCH/$GRAPHIFY_OUT_NAME" ] && [ -f "$SCRATCH/$GRAPHIFY_OUT_NAME/graph.json" ]; then
    local qdir="${SCRATCH}.quarantine"
    rm -rf "$qdir" 2>/dev/null || true
    if mv "$SCRATCH/$GRAPHIFY_OUT_NAME" "$qdir" 2>/dev/null; then
      echo "refresh-graph-map: promote did not complete -- preserved the extracted $GRAPHIFY_OUT_NAME (graph.json, GRAPH_REPORT.md, semantic cache) at $qdir for inspection/reuse; nothing under $CORPUS_ROOT was touched" >&2
    else
      echo "refresh-graph-map: WARN promote did not complete AND quarantining $SCRATCH/$GRAPHIFY_OUT_NAME to $qdir failed -- the extracted artifact may be lost on cleanup" >&2
    fi
  fi
  rm -rf "$SCRATCH" 2>/dev/null || true
}

# _graph_structural_fields <graph.json> <out_txt> -- HIMMEL-1406. Extracts
# ONLY the structural fields graphify itself writes as artifact structure
# (node id/source_file/source_url; link source/target/source_file; hyperedge
# id/source_file/member node ids -- per graph.json's actual schema) into a
# flat text file, so the host-path guard below can scan JUST that instead of
# the full graph.json. Deliberately EXCLUDED: `label` (and anything derived
# from it) -- for an extracted markdown corpus this can be a free-text
# excerpt (e.g. a `file_type: rationale` node's docstring/summary) that
# legitimately QUOTES a Windows path in prose; the luna vault routinely does
# (handover specs quoting C:\Users\...). The artifact lands in the PRIVATE
# vault, not a public repo, so a content-borne host path there is not a leak
# (policy decision, HIMMEL-1406) -- only a path graphify wrote into the
# artifact's own STRUCTURE is.
# jq is preferred (matches this repo's `command -v jq` convention used
# throughout scripts/); python3 is the fallback and is UNCONDITIONALLY
# available whenever this runs (the DO_UPDATE=1 preflight above already
# requires it), so the fallback is never a real degrade on this path.
# Returns the extractor's exit status; a non-zero rc means the scan below
# must fail closed (same "leak SCAN FAILED" convention as a grep scan error).
_graph_structural_fields() {
  local graph_json="$1" out_txt="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      ((.nodes // [])[]      | "node id=\(.id // "") source_file=\(.source_file // "") source_url=\(.source_url // "")"),
      ((((.links // []) + (.edges // []))[]) | "link source=\(.source // "") target=\(.target // "") source_file=\(.source_file // "")"),
      ((.hyperedges // [])[] | "hyperedge id=\(.id // "") source_file=\(.source_file // "") nodes=\(((.nodes // []) | join(",")))")
    ' "$graph_json" > "$out_txt" 2>/dev/null
    return $?
  fi
  python3 - "$graph_json" > "$out_txt" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
def s(v):
    return "" if v is None else str(v)
for n in data.get("nodes") or []:
    print("node id=%s source_file=%s source_url=%s" % (s(n.get("id")), s(n.get("source_file")), s(n.get("source_url"))))
for l in (data.get("links") or []) + (data.get("edges") or []):
    print("link source=%s target=%s source_file=%s" % (s(l.get("source")), s(l.get("target")), s(l.get("source_file"))))
for h in data.get("hyperedges") or []:
    nodes_field = ",".join(s(x) for x in (h.get("nodes") or []))
    print("hyperedge id=%s source_file=%s nodes=%s" % (s(h.get("id")), s(h.get("source_file")), nodes_field))
PYEOF
  return $?
}

if [ "$DO_UPDATE" -eq 1 ]; then
  command -v "$GRAPHIFY_MAP" >/dev/null 2>&1 || { echo "refresh-graph-map: '$GRAPHIFY_MAP' not on PATH (needed for --update; use --no-update to publish from an existing report)" >&2; exit 2; }
  # F3 (HIMMEL-907): python3 writes the freshness manifest (see stamp step
  # below). Preflight it next to the graphify check so a python3-less box fails
  # BEFORE the scratch copy / paid extraction — never after promoting a new graph.
  command -v python3 >/dev/null 2>&1 || { echo "refresh-graph-map: python3 not found (needed to write manifest.json for freshness verification)" >&2; exit 2; }
  # Fence-safe incremental refresh on a scratchpad COPY (never the live corpus).
  # Always work inside a uniquely-named, launcher-OWNED subdir (PID-suffixed) so
  # we never rm -rf an operator-supplied --scratch that may point at an existing
  # directory holding unrelated data (codex-adv [codex-1]). --scratch names only
  # the PARENT under which the owned workdir is created.
  SCRATCH_PARENT="${SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$SCRATCH_PARENT" || { echo "refresh-graph-map: cannot create scratch parent: $SCRATCH_PARENT" >&2; exit 1; }
  SCRATCH="$SCRATCH_PARENT/graphify-refresh-$NAME-$$"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  # Clean the owned subdir on ANY exit — a graphify/cluster-only failure (exit 2)
  # otherwise leaks it (CR suggestion). Scoped to the PID-owned dir only.
  # _scratch_cleanup (HIMMEL-1406) quarantines the extracted graphify-out
  # instead of deleting it when the exit is a FAILURE and extraction had
  # already produced one — see its definition above.
  trap '_scratch_cleanup; _promote_stage_cleanup; _promote_lock_release; _extraction_lock_release' EXIT
  # extraction-wide lock (HIMMEL-1653) -- acquired BEFORE pull/copy/
  # extraction begins (see the EXTRACTION_LOCK definition above for why this
  # is a separate, wider lock than PROMOTE_LOCK) and released by the same
  # EXIT trap just armed above, so it covers this run's entire pull, copy,
  # extraction and promote. A second concurrent invocation for the SAME
  # OUT_DIR (the manual /graph-refresh path racing the cadence runner, or
  # two cadence fires) refuses here rather than duplicating paid extraction
  # or risking an older snapshot winning the promote race.
  # OUT_DIR must exist before mkdir-locking under it -- this runs long before
  # the promote step's own "mkdir -p $OUT_DIR" (a fresh corpus has no
  # graphify-out yet at this point). Without this, mkdir "$EXTRACTION_LOCK"
  # fails on the MISSING PARENT (ENOENT), which _extraction_lock_acquire
  # cannot distinguish from "held by another process" -- it would poll, time
  # out, and refuse every first-ever run with a misleading "held by another
  # refresh-graph-map run" message.
  mkdir -p "$OUT_DIR"
  _extraction_lock_acquire || exit 2
  # Test-only hook (HIMMEL-1653, mirrors GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS
  # above): hold the extraction lock for N seconds right after acquiring it,
  # before any pull/copy/extraction work, so a concurrency test can create a
  # deterministic overlap window. No-op unless set.
  if [ -n "${GRAPHIFY_EXTRACTION_TEST_HOLD_SECONDS:-}" ]; then
    sleep "$GRAPHIFY_EXTRACTION_TEST_HOLD_SECONDS"
  fi
  # pull-before-regenerate (HIMMEL-1050): refresh the corpus from its remote
  # before copying to scratch, so the graph reflects the latest pushed state, not
  # a stale local checkout. Best-effort + advisory: a miss regenerates from the
  # current checkout (a stale-but-present corpus still yields a useful incremental
  # graph). --ff-only stays non-destructive (never a merge commit or a left-behind
  # conflict). Guarded so `set -e` never trips on the miss path.
  #
  # GUARDED (codex-adv-1 on HIMMEL-1049) — pull ONLY when the corpus is BOTH:
  #   (a) the git TOPLEVEL (empty --show-prefix), never a nested corpus whose
  #       pull would mutate an unrelated PARENT repo (a subdir passes
  #       is-inside-work-tree but a pull there updates the whole parent tree); and
  #   (b) a CLEAN tree (empty status --porcelain), never pulling over uncommitted
  #       work the operator/another session is mid-edit on.
  # --show-prefix keeps this Windows-safe (no C:/ vs /c/ path-form comparison).
  #
  # NOT under the promote lock — deliberate (codex-adv-3 + CodeRabbit asked for a
  # lock here; it was tried and REVERTED, and here is why). The promote lock's
  # takeover is AGE-based (PROMOTE_LOCK_STALE_SECONDS): holding it across the
  # pull+copy+extraction — extraction can outlast the stale floor — would let a
  # second refresh judge a STILL-ALIVE holder stale and take over, breaking the
  # very promote exclusivity HIMMEL-910 built (and a heartbeat, or splitting into
  # two holds, each conflicts with that same stale-takeover contract). The lock
  # therefore stays SHORT and promote-only, exactly as designed.
  # The residual it leaves is small and self-healing: only TWO CONCURRENT refreshes
  # of the SAME corpus could interleave a pull against the other's copy, yielding a
  # mixed-revision SCRATCH -> a slightly-off graph, corrected on the next refresh;
  # the promote itself stays serialized, and the scratch manifest always attests
  # exactly what that copy saw (never a lie). What IS hardened below instead — the
  # real teeth of codex-adv-3 — is the pull itself: toplevel-only (never mutate a
  # nested corpus's PARENT repo), clean-tree-only (never pull over uncommitted
  # work), and bounded + non-interactive (never hang).
  # CLEAN-TREE PROBE (CodeRabbit): `git status` must SUCCEED *and* be EMPTY. A
  # FAILED status (permissions, corrupt index, ...) writes nothing to STDOUT, so a
  # bare `[ -z "$(...)" ]` would misread the failure as "clean" and pull over an
  # unknown state. Capture rc via the assignment-in-condition form (set -e exempt).
  # EVERY probe must SUCCEED before its output is tested for emptiness — a failed
  # probe writes nothing to stdout, so a bare `[ -z "$(...)" ]` would read the
  # FAILURE as "empty prefix" (= toplevel) or "empty status" (= clean) and pull
  # over an unknown state (CodeRabbit). Assignment-in-condition captures rc and is
  # set -e exempt.
  # The probe FLAGS matter as much as its rc (public CodeRabbit, HIMMEL-1070):
  # `git status --porcelain` honors the repo/global `status.showUntrackedFiles`
  # setting, so on a machine with `status.showUntrackedFiles=no` a tree full of
  # untracked work reports CLEAN and we pull over it. Submodules are equally
  # suppressible via `status.submoduleSummary`/`diff.ignoreSubmodules`. Force
  # both to the strict setting on the command line, where no config can weaken
  # them: --untracked-files=normal makes untracked files visible again, and
  # --ignore-submodules=none makes dirty submodules count as dirty.
  _corpus_clean() { # -> 0 only if `git status` SUCCEEDS *and* reports nothing
    local out
    # HIMMEL-2160: exclude the script's OWN out dir from the dirty check. Line
    # ~1039 below (`mkdir -p "$OUT_DIR"`) runs BEFORE this pull decision -- on a
    # corpus's first-ever refresh (no committed graphify-out yet) that mkdir
    # alone makes `git status` report an untracked graphify-out/, so the
    # freshness pull permanently refused itself on every such corpus's first
    # run. GRAPHIFY_OUT_NAME is validated above to a single plain path segment
    # (no leading magic-pathspec char, no separators), so it's safe verbatim.
    out="$(git -C "$CORPUS_ROOT" status --porcelain \
             --untracked-files=normal --ignore-submodules=none \
             -- . ":(exclude)$GRAPHIFY_OUT_NAME" 2>/dev/null)" || return 1
    [ -z "$out" ]
  }
  corpus_pullable=0
  if git -C "$CORPUS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if prefix_out="$(git -C "$CORPUS_ROOT" rev-parse --show-prefix 2>/dev/null)" \
       && [ -z "$prefix_out" ]; then
      # Resolve a functional GNU timeout once for BOTH the single-writer commit
      # and the freshness fetch below. GNU installs `timeout`; Homebrew coreutils
      # installs `gtimeout`. Being on PATH is insufficient: both bounded calls
      # need `-k`, so accept only a binary that passes a functional probe.
      timeout_bin=""
      for _t in timeout gtimeout; do
        if command -v "$_t" >/dev/null 2>&1 && "$_t" -k 1 1 true >/dev/null 2>&1; then
          timeout_bin="$_t"; break
        fi
      done
      # Single-writer vaults (a `.single-writer` marker at the corpus root —
      # personal vaults that commit straight to main by design, see himmel
      # CLAUDE.md ENFORCEMENT) are dirty most of the day between their
      # auto-committer sweeps (untracked session notes), which made the strict
      # clean-tree gate below skip the freshness pull on virtually every
      # scheduled fire (HIMMEL-1748, observed daily on luna). For exactly those
      # repos, sweep the dirty state into a commit FIRST — the same thing their
      # own auto-committer does next pass — so the pull can proceed. The commit
      # deliberately runs THROUGH the vault's hooks: its pre-commit secret scan
      # is the protection the auto-committer provides and this path must mirror.
      # Bound the hook run to 60s (+5s kill grace), or skip when no functional
      # timeout exists; never run arbitrary hooks unbounded. Never mix the sweep
      # into a pre-staged operator index. If the bounded commit fails (hook block
      # or timeout) after add -A, reset only the index we verified was clean, then
      # let the ordinary clean gate skip the pull as before.
      # CONCURRENCY (adjudicated, CR codex-adv r3): a reviewer flagged staging
      # that appears DURING the <=60s hook window being lost to the failure
      # reset. Deliberately accepted: `git reset` (mixed) destroys no
      # working-tree content, and mid-window staging requires a SECOND
      # concurrent writer — which the `.single-writer` marker semantically
      # excludes (the vault's own auto-committer is the same writer's
      # mechanical sweep and re-stages everything wholesale on its next pass,
      # so a transiently unstaged selection reconstitutes itself). A
      # repo-scoped writer lock here would guard against a topology the
      # marker's contract already forbids.
      # DIVERGENCE (adjudicated, CR r1 + r3): committing before the fetch can
      # leave local+upstream diverged when BOTH moved; the ff-only merge then
      # fails and the run regenerates from the current checkout — byte-for-byte
      # the pre-change outcome for a dirty tree (which never pulled at all).
      # Divergence reconciliation stays the operator's manual-consolidate
      # policy (vault convention); auto-merging here would violate it.
      if [ -f "$CORPUS_ROOT/.single-writer" ] && ! _corpus_clean; then
        # Sweep ONLY on the default branch (CR codex-adv r4): the marker's
        # commit-straight-to-main design is about main — a vault temporarily
        # on a PR-lane feature branch must not receive sweep commits there.
        corpus_branch="$(git -C "$CORPUS_ROOT" branch --show-current 2>/dev/null)"
        if [ "$corpus_branch" != "main" ] && [ "$corpus_branch" != "master" ]; then
          echo "refresh-graph-map: single-writer corpus is on branch '${corpus_branch:-<detached>}', not its default — pre-pull auto-commit skipped; freshness pull skipped as before" >&2
        elif ! git -C "$CORPUS_ROOT" diff --cached --quiet; then
          echo "refresh-graph-map: single-writer index already has staged work — not auto-committing over it; freshness pull skipped as before" >&2
        elif [ -z "$timeout_bin" ]; then
          echo "refresh-graph-map: single-writer pre-pull auto-commit SKIPPED — no 'timeout'/'gtimeout' supporting GNU -k is available to bound the vault hooks; freshness pull skipped as before" >&2
        elif git -C "$CORPUS_ROOT" add -A >/dev/null 2>&1; then
          if "$timeout_bin" -k 5 60 git -C "$CORPUS_ROOT" commit -q -m "chore: pre-pull auto-commit (refresh-graph-map, HIMMEL-1748)" >/dev/null 2>&1; then
            echo "refresh-graph-map: single-writer corpus was dirty — auto-committed before the freshness pull" >&2
          else
            git -C "$CORPUS_ROOT" reset -q
            echo "refresh-graph-map: single-writer pre-pull auto-commit failed — restored the clean index; freshness pull skipped as before" >&2
          fi
        else
          # A failed `add -A` can still have PARTIALLY staged files before the
          # failure (unreadable path mid-walk, index.lock contention) — reset
          # the index we verified was clean two branches up, same restore as
          # the commit-failure path (CR codex r3).
          git -C "$CORPUS_ROOT" reset -q
          echo "refresh-graph-map: single-writer pre-pull add -A failed — restored the clean index; freshness pull skipped as before" >&2
        fi
      fi
      _corpus_clean && corpus_pullable=1
    fi
  fi
  if [ "$corpus_pullable" = 1 ]; then
    # NEVER RUN THE PULL UNBOUNDED (CodeRabbit-major). This is a best-effort
    # freshness pull, so the safe degradation is to SKIP it — never to risk a hang:
    #   * GRAPHIFY_PULL_TIMEOUT_SECONDS must be a POSITIVE integer; non-numeric or
    #     <=0 DISABLES the pull (an explicit opt-out, not an unbounded run).
    #   * a HARD wall-clock cap requires coreutils `timeout` — absent on stock
    #     macOS, where Homebrew's coreutils installs it as `gtimeout` (CodeRabbit),
    #     so BOTH names are probed. With neither we SKIP rather than pull unbounded
    #     (git's own transport limits bound a STALLED transfer but are not a
    #     wall-clock cap).
    # Belt-and-braces on the bounded path: git's transport limits also abort a
    # stalled transfer early, and GIT_TERMINAL_PROMPT=0 + ssh BatchMode make a
    # credential prompt FAIL FAST instead of hanging. Any miss simply regenerates
    # from the current checkout.
    pull_t="${GRAPHIFY_PULL_TIMEOUT_SECONDS:-60}"
    case "$pull_t" in ''|*[!0-9]*) pull_t=0 ;; esac   # non-numeric -> disabled
    # timeout_bin was functionally probed before the single-writer sweep so the
    # auto-commit and fetch share one bounded-execution decision.
    pull_ok=0
    if [ "$pull_t" -le 0 ]; then
      echo "refresh-graph-map: pull-before-regenerate disabled (GRAPHIFY_PULL_TIMEOUT_SECONDS not a positive integer); regenerating from the current checkout" >&2
    elif [ -z "$timeout_bin" ]; then
      echo "refresh-graph-map: pull-before-regenerate SKIPPED — no 'timeout'/'gtimeout' supporting GNU -k is available to bound the fetch (macOS: brew install coreutils provides gtimeout); refusing to fetch unbounded, regenerating from the current checkout" >&2
    else
      # FETCH (bounded, killable) then MERGE (local, fast, NOT killed) — never a
      # timeout-killed `pull` (CodeRabbit). A `pull` both fetches AND mutates the
      # worktree, so SIGKILLing it mid-flight can strand a half-updated checkout
      # (interrupted merge/checkout, a left-behind index.lock) that we would then
      # silently regenerate from. Splitting them means the only thing the timeout
      # can kill is the NETWORK op, which never touches the worktree (a killed
      # fetch just leaves the object store short of some objects). The worktree
      # mutation is then a purely local `merge --ff-only` against the freshly
      # fetched upstream: fast, offline, and safe to leave unbounded.
      #   -k 5: SIGKILL 5s after SIGTERM so a wedged transport cannot outlive the bound.
      if GIT_TERMINAL_PROMPT=0 "$timeout_bin" -k 5 "$pull_t" \
           git -C "$CORPUS_ROOT" \
             -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$pull_t" \
             -c "core.sshCommand=ssh -o ConnectTimeout=$pull_t -o BatchMode=yes" \
             fetch --quiet >/dev/null 2>&1; then
        # @{u} = the current branch's upstream (empty/absent -> merge fails -> WARN).
        # core.hooksPath=/dev/null: a fast-forward still fires the repo's
        # post-merge hook, which is arbitrary user code and CAN BLOCK — that would
        # hang this unattended refresh (CodeRabbit). We do NOT bound the merge with
        # a kill instead: SIGKILLing a mutating merge is exactly the strand risk we
        # removed by splitting fetch from merge. Disabling hooks keeps it both
        # unhangable and unkilled. Scoped to THIS internal, automated
        # fast-forward only (it is not a user-authored commit/push), and it also
        # stops a post-merge graph-refresh hook (HIMMEL-1050) recursing into us.
        # RE-PROBE (public CodeRabbit, HIMMEL-1070): the clean-tree probe above
        # ran BEFORE the fetch, and the fetch is a bounded NETWORK op that can
        # take the better part of a minute. In that window the operator (or a
        # parallel session) can start editing the corpus — this refresh is
        # unattended and fires on a schedule, so that overlap is routine, not
        # exotic. Merging on the stale verdict would fast-forward the worktree
        # out from under live work. The fetch itself never touches the worktree,
        # so re-checking here costs one local `git status` and makes the
        # clean-tree guarantee hold at the moment it is actually load-bearing.
        if _corpus_clean; then
          git -C "$CORPUS_ROOT" -c core.hooksPath=/dev/null merge --ff-only '@{u}' >/dev/null 2>&1 && pull_ok=1
        fi
      fi
      if [ "$pull_ok" = 1 ]; then
        echo "refresh-graph-map: fast-forwarded $CORPUS_ROOT to its upstream before regenerating" >&2
      else
        echo "refresh-graph-map: WARN could not fast-forward $CORPUS_ROOT (no upstream, offline, fetch timed out, diverged, or the tree went dirty during the fetch); regenerating from the current checkout" >&2
      fi
    fi
  else
    echo "refresh-graph-map: pull-before-regenerate skipped for $CORPUS_ROOT (not a clean git toplevel); regenerating from the current checkout" >&2
  fi
  # Copy only markdown (matches the extraction corpus); carry the fence marker.
  # No 2>/dev/null on find — a scan failure (permission/IO) is aborted by
  # set -euo pipefail, and find's own stderr is the ONLY diagnostic for it (CR).
  #
  # STREAMED, not per-file (HIMMEL-1103). This was a `while read` loop running
  # dirname + mkdir -p + cp PER FILE — three process spawns each. Windows process
  # creation is expensive, so staging the luna vault (15,235 md files) measured
  # ~1.8 files/sec => ~130 MINUTES of copying before extraction even started; the
  # daily HIMMEL-829 cadence firing at 13:00 was still copying at ~15:10. tar
  # streams the same file set in ONE pass (3 processes, not ~45k) and preserves
  # the relative layout, so the scratch mirrors the corpus exactly as before.
  # --null -T - consumes find's -print0 list verbatim, so the predicate and the
  # graphify-out exclusion are byte-identical to the loop's — no re-globbing, and
  # filenames with spaces/newlines stay safe. GNU tar and macOS's bsdtar both
  # accept `--null -T -`.
  # pipefail keeps the failure contract: a find/tar failure at ANY stage fails the
  # pipeline and trips the || below, so a partial corpus can never be silently
  # extracted into a confidently-wrong graph.
  # NOTE tar preserves source mtimes where cp stamped copy-time. The manifest
  # below carries mtimes as free-form provenance only (the guard reads its KEYS,
  # never these values), so nothing depends on the old behaviour — and the
  # preserved mtime is the more honest provenance of what the graph actually saw.
  # -type f is LOAD-BEARING for the tar form (CodeRabbit): `-name '*.md'` also
  # matches DIRECTORIES, and tar -T RECURSES into a directory entry — so a dir
  # named `foo.md` would drag its entire non-md subtree into the corpus and thus
  # into the graph. The old per-file `cp` could not do that (it just failed on a
  # directory), so this predicate is what keeps the streamed form equivalent.
  # Both corpora are 100% regular files today (luna 15,239 / himmel 9,114, zero
  # dirs or symlinks named *.md), so this is a no-op on current data and a guard
  # against a silently-wrong corpus later.
  #
  # HIMMEL-1415: also exclude graphify's OWN published derived pages --
  # <maps-dir>/graph/* (the per-node/community notes graphify mints there) and
  # <maps-dir>/<slug>.md (the curated MOC this script's own publish step,
  # below, writes). Extracting the graph's own published output back into the
  # graph is a feedback loop: a leg-14 luna regen found these derived pages
  # dense enough to blow a rate-limited backend's per-chunk output cap
  # (bisect-retry storms, depth-3 partials, outright-skipped chunks -- ALL
  # from 60-Maps/graph sources). Computed via a plain bash prefix match, NOT
  # a python3 round-trip: --corpus-root and --maps-dir are always constructed
  # by the SAME caller in the SAME invocation (e.g. graphmap-cadence.sh builds
  # both from one $VAULT), so they already share syntactic path form --
  # handing them to a SEPARATE native python3.exe process for
  # os.path.relpath instead invites MSYS's own argv-to-Windows-path
  # translation, which was observed (HIMMEL-1415 CR follow-up test) to
  # resolve the two strings to DIFFERENT drive roots for a maps-dir
  # containing "[", silently disabling the exclusion -- strictly worse than
  # the drive-letter mismatch a python3 round-trip was meant to guard
  # against. When --maps-dir isn't actually a subdirectory of --corpus-root
  # there's nothing under the corpus to exclude and this stays empty (a
  # no-op below). Only "graph/" and the slug MOC are excluded -- a
  # hand-authored, non-derived note living directly under maps-dir is real
  # corpus content and still gets extracted.
  #
  # HIMMEL-1421: the plain lexical prefix match above (git blame: HIMMEL-1415)
  # only catches --maps-dir/--corpus-root spelled with a SHARED literal
  # prefix. Two equivalent-path spellings slip through it:
  #   (a) relative-vs-absolute -- e.g. `--corpus-root . --maps-dir
  #       "$PWD/60-Maps"` share no string prefix even though maps-dir IS
  #       "./60-Maps", silently disabling the exclusion and reopening the
  #       HIMMEL-1415 feedback loop; and
  #   (b) Windows case variants (C:/Users vs c:/users) -- NTFS is
  #       case-insensitive but a bash `case` pattern match is not.
  # Fixed by canonicalizing both to absolute paths FIRST (below), then doing
  # the containment comparison case-insensitively.
  #
  # Resolved with ONLY bash builtins (`cd` + `pwd -P`, in a subshell so the
  # cd never leaks into the script's own $PWD) -- deliberately NOT a
  # python3/external-process round-trip. HIMMEL-1415's CR follow-up TRIED
  # exactly that (os.path.relpath in a spawned python3.exe) and it was
  # WORSE: MSYS's argv-to-Windows-path translation resolved --corpus-root
  # and --maps-dir to DIFFERENT drive roots for a maps-dir containing "[",
  # silently disabling the exclusion (observed live, T28). `cd`/`pwd -P`
  # never cross into a separate native process -- the path stays a plain,
  # always-quoted bash string throughout, so a literal "[" is just a
  # directory-name byte, never glob syntax, and that translation never gets
  # a chance to run.
  #
  # _abs_path -- anchor a possibly-relative path at $PWD. Recognizes
  # POSIX/MSYS-absolute ("/...") and Windows drive-absolute ("C:/..." or
  # "C:\...") forms; anything else is relative and gets $PWD prepended.
  _abs_path() {
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      [A-Za-z]:[/\\]*) printf '%s\n' "$1" ;;
      *) printf '%s\n' "$PWD/$1" ;;
    esac
  }
  # _canon_path -- resolve to a canonical absolute path. Walks up from the
  # absolutized input to the deepest EXISTING ancestor (maps-dir need not
  # exist yet -- e.g. a vault's 60-Maps/ on its first-ever refresh), `cd`s
  # into that ancestor and takes `pwd -P` there to collapse any "." / ".."
  # segments. Any non-existent tail is reattached verbatim in its ORIGINAL
  # case: there is no on-disk truth for a path segment that doesn't exist
  # yet, so preserving the caller's spelling is the closest available
  # truth (and it's exactly the case still needed downstream to build the
  # `find -path` exclusion pattern once the dir DOES exist).
  #
  # CR round 1 (codex-1 + glm-3, HIMMEL-1421): backslashes are normalized to
  # forward slashes UP FRONT -- the walk below only ever splits on "/", and
  # _abs_path accepts a backslash-form Windows-drive-absolute input
  # ("C:\Users\...") as already-absolute without touching its separators.
  # Without this, a non-existent backslash-form path has no "/" to strip,
  # so `${abs%/*}` is a no-op on every iteration and the walk spins
  # forever. The loop also gets an explicit structural terminator for the
  # same failure mode in forward-slash form (e.g. a non-existent
  # drive-absolute path shrinks down to a bare "Q:" with no "/" left to
  # strip) -- break the instant a strip attempt produces no change, rather
  # than relying on eventually reaching "/" or empty (which a bare drive
  # token never does).
  _canon_path() {
    (
      local abs suffix comp new resolved
      abs="$(_abs_path "$1")"
      abs="${abs//\\//}"
      suffix=""
      while [ ! -d "$abs" ] && [ "$abs" != "/" ] && [ -n "$abs" ]; do
        new="${abs%/*}"
        if [ "$new" = "$abs" ]; then
          # Nothing left to strip (e.g. a bare "Q:" that isn't itself a
          # directory) -- stop shrinking. $abs is left OUT of the
          # reattached suffix; the `[ -d "$abs" ]` check right below will
          # correctly find it's not a directory and skip the cd/pwd -P
          # step, so the caller's original spelling for this remainder
          # passes through unchanged.
          break
        fi
        comp="${abs##*/}"
        if [ -n "$suffix" ]; then suffix="$comp/$suffix"; else suffix="$comp"; fi
        abs="$new"
        [ -n "$abs" ] || abs="/"
      done
      if [ -d "$abs" ]; then
        # CR (data integrity): a cd INSIDE a command substitution is NOT
        # guarded by errexit -- a failing cd just yields an empty string,
        # which would overwrite abs with "" and silently disable the
        # maps-directory containment exclusion downstream. Capture into a
        # temp and only adopt it on success; on failure keep the original
        # spelling and warn. Bash 3.2-safe (this repo's compat floor).
        if resolved="$(cd "$abs" 2>/dev/null && pwd -P)" && [ -n "$resolved" ]; then
          abs="$resolved"
        else
          echo "refresh-graph-map: WARN canonicalizing '$abs' via cd/pwd failed -- keeping the original path spelling" >&2
        fi
      fi
      if [ -n "$suffix" ]; then
        printf '%s/%s\n' "${abs%/}" "$suffix"
      else
        printf '%s\n' "$abs"
      fi
    )
  }
  # _lc -- lowercase via `tr`, NOT `${var,,}` (CR round 1 addendum,
  # codex-adv-1): `${var,,}` is a Bash 4+ case-conversion expansion and
  # dies with "bad substitution" on Bash 3.2 (macOS system bash, this
  # repo's documented compatibility floor for scripts outside a narrow
  # exception list) -- which would kill every refresh before extraction
  # even started. `tr` in a command substitution is POSIX and 3.2-safe.
  _lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  # _fs_case_insensitive -- true iff the filesystem the CORPUS actually
  # lives on is case-insensitive. PROBE-FIRST (CR round 3, [codex-1]): the
  # previous implementation keyed off OS TYPE (msys/cygwin/mingw/win32 ->
  # insensitive, everything else -> sensitive), but macOS APFS is
  # case-INSENSITIVE by default while $OSTYPE reports "darwin" -- so on this
  # repo's Bash-3.2 macOS floor, a maps-dir passed with a case-variant
  # corpus-root prefix would still bypass the HIMMEL-1415 exclusion this
  # branch exists to close. A mounted case-sensitive volume anywhere defeats
  # an OS-type guess just the same. So instead we PROBE the corpus's own
  # filesystem and let IT answer. CR round 1 (codex-2) still holds: the
  # containment comparison below must NOT fold unconditionally -- this
  # script also runs on ubuntu CI in the public mirror, where the fs is
  # case-sensitive and folding would treat e.g. "/tmp/Corpus" as contained
  # in "/tmp/corpus" (wrong exclusions, over-matching). Precedence +
  # fallback:
  #   1. GRAPHIFY_FS_CASE_INSENSITIVE=1/0 override still wins, so a test
  #      can force either branch without a real case-(in)sensitive fs.
  #   2. Otherwise PROBE the corpus filesystem ONCE per run -- write a
  #      uniquely-named lowercase file under the canonical corpus root and
  #      test whether the UPPERCASE spelling resolves (cache in
  #      _GRAPHIFY_FS_CASE so a second consult never re-probes).
  #   3. If the probe cannot run (corpus root read-only/unwritable/not a
  #      directory yet), FALL BACK to the OS-type heuristic below -- never
  #      fail the refresh because of the probe itself.
  _fs_case_insensitive() {
    case "${GRAPHIFY_FS_CASE_INSENSITIVE:-}" in
      1) return 0 ;;
      0) return 1 ;;
    esac
    # Replay the cached verdict so the probe is one-shot per run.
    if [ -n "${_GRAPHIFY_FS_CASE:+x}" ]; then
      [ "$_GRAPHIFY_FS_CASE" -eq 1 ] && return 0 || return 1
    fi
    # Probe the filesystem the corpus lives on. The probe file is
    # dot-prefixed (a crashed leftover is recognizable + won't read as
    # content) and removed on every path before returning -- it must never
    # leak into the corpus. CREATE-UNIQUE + NO-CLOBBER + BOTH-TWINS-ABSENT
    # (CR round 4, [codex-r4-1]/[codex-r4-2]), not a single `printf >`:
    #   * NO-CLOBBER (`set -C` inside the subshell ONLY, so the outer
    #     shell's options are untouched): a plain `>` clobbers a pre-existing
    #     file at the candidate name (a stale leftover after PID reuse) and
    #     FOLLOWS a stale symlink there, write-through to its target. `set -C`
    #     makes the redirect FAIL rather than truncate/follow, closing the
    #     TOCTOU between the existence check below and the write.
    #   * BOTH TWINS ABSENT: on a case-SENSITIVE fs a stale UPPERCASE leftover
    #     (.GRAPHIFY-FS-PROBE-...-X) from a crashed prior run (possibly with a
    #     reused PID) would make the post-write `[ -e "$probe_up" ]` wrongly
    #     report case-insensitive, so a candidate whose uppercase twin already
    #     exists is SKIPPED before any verdict is trusted. The check is
    #     `[ -e ] || [ -L ]` (not `[ -e ]` alone): `-L` catches a DANGLING
    #     symlink that `-e` misses (it resolves the link, so a broken link
    #     reads as absent under `-e` but present under `-L`).
    #   * SUFFIX LOOP (0..9, explicit list -- NOT `{0..9}`, which is Bash 4.0+
    #     sequence brace expansion and breaks the 3.2 floor, see T37): makes a
    #     no-clobber candidate almost always available even when a couple of
    #     stale siblings linger; skip any occupied candidate and try the next.
    #     We do NOT use `mktemp` (XXXXXX): its suffix is mixed-case/random, so
    #     the uppercase twin's bytes are UNCONTROLLED and the whole probe
    #     hinges on a controlled lowercase->UPPERCASE contrast.
    #   * Pathological (all 10 occupied, or every no-clobber write still
    #     fails -- e.g. read-only corpus root): fall through to the OS-type
    #     heuristic below; never fail the refresh over the probe itself.
    # Declares are split from the assignments (SC2155), matching _canon_path
    # above: a `local x="$(...)"` would mask the command substitution's
    # status under set -e.
    local probe_lo probe_up i
    for i in 0 1 2 3 4 5 6 7 8 9; do
      probe_lo="$CORPUS_ROOT_CANON/.graphify-fs-probe-$$-$i-x"
      probe_up="$CORPUS_ROOT_CANON/$(printf '%s' ".graphify-fs-probe-$$-$i-x" | tr '[:lower:]' '[:upper:]')"
      # Skip this candidate if EITHER the lowercase name or its uppercase
      # twin already exists as a regular file OR a (possibly dangling) symlink.
      if [ -e "$probe_lo" ] || [ -L "$probe_lo" ] \
         || [ -e "$probe_up" ] || [ -L "$probe_up" ]; then
        continue
      fi
      # NO-CLOBBER create (set -C confined to this subshell): the redirect
      # FAILS -- rather than truncate/follow -- if the path appears between
      # the check above and here, or if the FS rejects the write.
      if ( umask 077; set -C; printf 'x' > "$probe_lo" ) 2>/dev/null; then
        if [ -e "$probe_up" ]; then
          _GRAPHIFY_FS_CASE=1
        else
          _GRAPHIFY_FS_CASE=0
        fi
        # Cleanup the LOWERCASE file only -- we never create the uppercase
        # twin (the case contrast IS the probe), so it is not ours to remove.
        rm -f "$probe_lo" 2>/dev/null || true
        break
      fi
    done
    if [ -z "${_GRAPHIFY_FS_CASE:+x}" ]; then
      # Corpus root unwritable / read-only / not a directory yet, OR every
      # candidate name was occupied (pathological) -- the probe cannot run.
      # Fall back to the former OS-type heuristic (CR round 1) rather than
      # fail the whole refresh over the probe itself; the fold direction it
      # picks is still strictly safer than no fold. NOT silent (CR round 5,
      # codex-adv): on a case-insensitive fs the OS-type answer can be WRONG
      # (macOS/APFS reads as case-sensitive here -- the exact misread the
      # probe exists to avoid), so a fallback is worth a loud advisory: the
      # operator can set GRAPHIFY_FS_CASE_INSENSITIVE=1/0 to pin the truth.
      echo "WARN refresh-graph-map: case-sensitivity probe could not run in $CORPUS_ROOT_CANON (unwritable, or all candidate names occupied) -- falling back to the OS-type heuristic, which can misread e.g. macOS/APFS as case-sensitive. Pin with GRAPHIFY_FS_CASE_INSENSITIVE=1/0 if the exclusion misbehaves." >&2
      local ostype="${OSTYPE:-}"
      [ -n "$ostype" ] || ostype="$(uname 2>/dev/null || true)"
      case "$(_lc "$ostype")" in
        msys*|cygwin*|mingw*|win32*) _GRAPHIFY_FS_CASE=1 ;;
        *) _GRAPHIFY_FS_CASE=0 ;;
      esac
    fi
    [ "$_GRAPHIFY_FS_CASE" -eq 1 ] && return 0 || return 1
  }
  CORPUS_ROOT_CANON="$(_canon_path "$CORPUS_ROOT")"
  MAPS_DIR_CANON="$(_canon_path "$MAPS_DIR")"
  MAPS_EXCL_REL=""
  CORPUS_ROOT_TRIMMED="${CORPUS_ROOT_CANON%/}"
  # Containment test, folded ONLY on a case-insensitive filesystem (CR
  # round 1, codex-2 -- see _fs_case_insensitive above for why this is
  # gated, not unconditional). `_lc` (tr-based, Bash-3.2-safe -- see its
  # definition above) is length-preserving for the ASCII path text these
  # values are built from, so the fold's string length can be used to
  # slice the ORIGINAL-CASE $MAPS_DIR_CANON below -- keeping the real (or
  # caller-supplied, for a not-yet-existing tail) casing in MAPS_EXCL_REL,
  # which the `find -path` exclusion below needs (find's -path match is
  # byte-literal, not case-folded, even on a case-insensitive filesystem).
  # On a case-SENSITIVE filesystem the "fold" is a no-op copy, so the same
  # length-slice logic below stays correct in both branches. A plain
  # `${var#pattern}` prefix-removal was tried instead of the length slice
  # and confirmed NOT to honor `shopt -s nocasematch` in this bash (it
  # silently strips nothing on a case-differing match) -- the length slice
  # is deterministic regardless.
  if _fs_case_insensitive; then
    CORPUS_ROOT_FOLD="$(_lc "$CORPUS_ROOT_TRIMMED")"
    MAPS_DIR_FOLD="$(_lc "$MAPS_DIR_CANON")"
  else
    CORPUS_ROOT_FOLD="$CORPUS_ROOT_TRIMMED"
    MAPS_DIR_FOLD="$MAPS_DIR_CANON"
  fi
  case "$MAPS_DIR_FOLD" in
    "$CORPUS_ROOT_FOLD"/*) MAPS_EXCL_REL="${MAPS_DIR_CANON:$(( ${#CORPUS_ROOT_FOLD} + 1 ))}" ;;
    "$CORPUS_ROOT_FOLD") MAPS_EXCL_REL="." ;;
  esac
  # Ambiguous-form advisory: a maps-dir genuinely OUTSIDE corpus-root stays
  # a sanctioned no-op (nothing to exclude) -- but when the two paths share
  # NO prefix even after canonicalization AND were passed in different form
  # classes (one relative, one absolute), that specific combination is
  # exactly what silently disabled the HIMMEL-1415 exclusion before this
  # fix, so it's worth a loud WARN instead of a silent no-op.
  if [ -z "$MAPS_EXCL_REL" ]; then
    case "$CORPUS_ROOT" in
      /*|[A-Za-z]:[/\\]*) CORPUS_ROOT_WAS_ABS=1 ;;
      *) CORPUS_ROOT_WAS_ABS=0 ;;
    esac
    case "$MAPS_DIR" in
      /*|[A-Za-z]:[/\\]*) MAPS_DIR_WAS_ABS=1 ;;
      *) MAPS_DIR_WAS_ABS=0 ;;
    esac
    if [ "$CORPUS_ROOT_WAS_ABS" != "$MAPS_DIR_WAS_ABS" ]; then
      echo "refresh-graph-map: WARN --corpus-root and --maps-dir share no common path after canonicalization (resolved to '$CORPUS_ROOT_TRIMMED' and '$MAPS_DIR_CANON') and were passed in different forms (one relative, one absolute) -- treating maps-dir as outside the corpus (no derived-page exclusion applied); pass both in the same form if maps-dir is meant to live inside corpus-root" >&2
    fi
  fi
  # HIMMEL-1415 CR follow-up round 3 (codex-adv-3): strip any LEADING
  # slash(es) left on MAPS_EXCL_REL after the prefix-strip above. A caller
  # that builds --maps-dir by naive concatenation against a --corpus-root
  # that ALREADY ends in "/" (e.g. graphmap-cadence.sh accepting
  # `--vault /vault/` and constructing maps-dir as `$VAULT/60-Maps` ->
  # "/vault//60-Maps") leaves an internal double slash that --maps-dir's own
  # trailing-slash trim above never sees (it isn't a TRAILING slash on
  # --maps-dir itself). The case's prefix-strip only consumes ONE "/" as
  # part of the "$CORPUS_ROOT_TRIMMED/" match, so MAPS_EXCL_REL is left as
  # e.g. "/60-Maps" -- MAPS_EXCL_PREFIX would then become ".//60-Maps", and
  # find's -path matcher never matches that literal double slash against a
  # real "./60-Maps/..." target, silently no-opping the exclusion. Looped so
  # it also closes multiple leading slashes, not just one.
  #
  # NOT given the round-4 "preserve a bare all-slash value" guard the
  # --maps-dir parse-time trim above got (CodeRabbit App asked us to verify,
  # not blanket-apply): unlike --maps-dir, this value can never legitimately
  # be reduced to "all slashes" here. --maps-dir's OWN trailing-slash trim
  # (above, already guarded) runs first and strips every trailing slash off
  # the raw flag value before this case statement ever sees it, so the only
  # way MAPS_EXCL_REL could still be all-slashes at this point is if
  # --corpus-root itself is the filesystem root ("/", so
  # CORPUS_ROOT_TRIMMED="") AND --maps-dir is also "/" -- a corpus-root of
  # "/" is already nonsensical on unrelated grounds (the corpus-copy below
  # would try to walk the entire filesystem for *.md) and is not a
  # configuration any of these CR rounds have tried to harden, so adding
  # branching here for a state that can't arise from any real caller would
  # be speculative complexity, not a fix. And unlike the --maps-dir case
  # (where losing "/" silently trips the UNRELATED `-z "$MAPS_DIR"`
  # usage-check), an empty MAPS_EXCL_REL here just disables this one
  # exclusion (`[ -n "$MAPS_EXCL_REL" ]` below) -- a narrower, already-inert
  # failure mode given the corpus-root-is-"/" precondition, not an
  # equivalent-but-different bug worth mirroring the guard for.
  while [ "${MAPS_EXCL_REL#/}" != "$MAPS_EXCL_REL" ]; do MAPS_EXCL_REL="${MAPS_EXCL_REL#/}"; done
  #
  # HIMMEL-1415 CR follow-up (glm panel + codex-adv-1): $MAPS_EXCL_PREFIX and
  # $SLUG land inside `find -path` PATTERN arguments, where *, ?, and [ are
  # fnmatch wildcard syntax even though the arguments are shell-quoted --
  # shell quoting only stops the SHELL from globbing them; find's own -path
  # matcher still interprets them as wildcards. A maps-dir or slug containing
  # one of these (e.g. "60-[Maps]") would fail to match its OWN literal path
  # -- its derived pages re-enter the corpus, reopening the feedback loop --
  # and a stray "*"/"?" could over-match unrelated siblings, silently
  # excluding legitimate notes. Escape backslash FIRST so a backslash
  # inserted by a later replacement isn't itself re-escaped by a subsequent
  # pass. Only the computed PREFIX/SLUG are escaped -- the literal "/graph/*"
  # suffix's trailing "*" stays an intentional wildcard, and the pre-existing
  # graphify-out/* exclusion (a fixed literal with no wildcard chars) is
  # untouched.
  _find_glob_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    printf '%s' "$s"
  }
  # Exclude the DEFAULT out dir as well as the configured one (CR r13). This
  # list used to be the hardcoded ./graphify-out/*; making it follow
  # GRAPHIFY_OUT stopped excluding the default, so switching the override left
  # a previous ./graphify-out/ in the corpus scan -- copied into scratch and
  # semantically extracted as SOURCE, feeding the graph its own GRAPH_REPORT.md
  # and wiki pages. That is the derived-content feedback loop HIMMEL-1903 exists
  # to prevent, re-opened by a rename. Both names are excluded; when the
  # override IS the default the second entry is simply redundant.
  CORPUS_FIND_EXCLUDES=(-not -path "./$GRAPHIFY_OUT_NAME/*" -not -path './graphify-out/*')
  # HIMMEL-1903: optional per-corpus exclusions, read from a
  # `.graphify-corpus-ignore` file at the CORPUS ROOT. One corpus-relative
  # directory per line; `#` comments and blank lines ignored.
  #
  # WHY a file at the corpus root rather than a flag: what to exclude is a
  # property of the CORPUS, not of the invocation. A flag would have to be
  # threaded through both of graphmap-cadence.sh's payload builders and would
  # force re-registering the scheduled tasks on every change; a file is edited
  # by the operator in place and is picked up by the cadence, the /graph-refresh
  # slash command and a manual run alike.
  #
  # The luna case that motivated this (measured 2026-08-17): `sessions/` held
  # 3,779 Claude Code session transcripts -- 11.5% of the vault's 32,876 md
  # files, 503 of them written in three days -- and the luna cadence went from 6
  # chunks to 314 in one day. That is a feedback loop: running sessions writes
  # transcripts into the vault, which enlarges the corpus, which the next
  # extraction bills for. Operator ruling 2026-08-18: graph structure, qmd
  # content. Transcripts are content, so they stay fully searchable through qmd
  # and simply stop being graphed.
  #
  # Deliberately NOT a general glob/gitignore dialect: a plain directory name
  # keeps the escaping honest through _find_glob_escape and there is no second
  # ignore-syntax to learn. graphify has its own ignore handling, but that runs
  # on the scratch copy -- by then the corpus has already been copied, so the
  # exclusion has to happen here to actually save the work.
  CORPUS_IGNORE_FILE="$CORPUS_ROOT/.graphify-corpus-ignore"
  if [ -f "$CORPUS_IGNORE_FILE" ]; then
    if [ ! -r "$CORPUS_IGNORE_FILE" ]; then
      # Unreadable exists-but-can't-read is worse than absent: silently
      # proceeding as if there were no exclusions would graph whatever the
      # file was meant to keep out. Refuse loudly instead (fail-closed),
      # matching the entry-level refusal below.
      echo "refresh-graph-map: .graphify-corpus-ignore exists but is not readable; refusing to guess exclusions" >&2
      exit 1
    fi
    while IFS= read -r _ig_line || [ -n "$_ig_line" ]; do
      _ig_line="${_ig_line%$'\r'}"                          # CRLF-tolerant (Windows)
      _ig_line="${_ig_line#"${_ig_line%%[![:space:]]*}"}"   # ltrim
      _ig_line="${_ig_line%"${_ig_line##*[![:space:]]}"}"   # rtrim
      case "$_ig_line" in
        ''|'#'*) continue ;;
      esac
      # `find` emits paths as ./x/..., so a leading ./ left in the -path
      # pattern below produces a doubled slash (.//x/*) that never matches
      # anything -- a silent no-op paired with the success echo further down
      # is worse than a refusal. Strip a leading ./ (repeated, so .//x and
      # ././x also normalize) before the entry reaches the safety checks.
      _ig_dotted=0
      case "$_ig_line" in ./*) _ig_dotted=1 ;; esac
      if [ "$_ig_dotted" = 1 ]; then
        while :; do
          case "$_ig_line" in
            ./*) _ig_line="${_ig_line#./}" ;;
            /*) _ig_line="${_ig_line#/}" ;;
            *) break ;;
          esac
        done
      fi
      case "$_ig_line" in
        /*|..|../*|*/..|*/../*)
          # Absolute paths and any `..` PATH COMPONENT could reach outside the
          # corpus; refuse loudly rather than silently excluding nothing. This
          # is component-aware, not a substring match -- a name like
          # "notes..archive" or a leading-dot name like "..hidden" is a
          # legitimate directory name, not traversal, and is allowed through.
          echo "refresh-graph-map: ignoring unsafe .graphify-corpus-ignore entry '$_ig_line' (must be a corpus-relative path without '..' as a path component)" >&2
          continue
          ;;
      esac
      _ig_line="${_ig_line%/}"                              # tolerate a trailing slash
      if [ -z "$_ig_line" ] || [ "$_ig_line" = "." ]; then
        # Empty or "." names the corpus root -- excluding the whole corpus is
        # never a meaningful ignore entry.
        echo "refresh-graph-map: ignoring unsafe .graphify-corpus-ignore entry '$_ig_line' (names the corpus root)" >&2
        continue
      fi
      _ig_esc="$(_find_glob_escape "$_ig_line")"
      CORPUS_FIND_EXCLUDES+=(-not -path "./$_ig_esc/*")
      echo "refresh-graph-map: corpus exclusion from .graphify-corpus-ignore: $_ig_line/" >&2
    done < "$CORPUS_IGNORE_FILE"
  fi
  if [ -n "$MAPS_EXCL_REL" ]; then
    MAPS_EXCL_PREFIX="./$MAPS_EXCL_REL"
    [ "$MAPS_EXCL_REL" = "." ] && MAPS_EXCL_PREFIX="."
    MAPS_EXCL_PREFIX_ESC="$(_find_glob_escape "$MAPS_EXCL_PREFIX")"
    SLUG_ESC="$(_find_glob_escape "$SLUG")"
    CORPUS_FIND_EXCLUDES+=(-not -path "$MAPS_EXCL_PREFIX_ESC/graph/*" -not -path "$MAPS_EXCL_PREFIX_ESC/$SLUG_ESC.md")
  fi
  ( cd "$CORPUS_ROOT" && _verify_fs_id "corpus-root" "." "$CORPUS_ID" \
      && find . -type f -name '*.md' "${CORPUS_FIND_EXCLUDES[@]}" -print0 \
      | tar --null -T - -cf - ) | ( cd "$SCRATCH" && tar -xf - ) \
    || { echo "refresh-graph-map: corpus scan/copy failed or refused (see output above)" >&2; exit 1; }
  # HIMMEL-1097: graphify's semantic cache is corpus-relative and content-keyed,
  # but it lives under graphify-out/. Seed only the cache artifacts into the
  # fresh scratch path BEFORE --update so unchanged files are cache hits instead
  # of a full semantic re-extraction. Derived reports/graphs are deliberately not
  # copied back into the corpus scratch.
  SCRATCH_OUT="$SCRATCH/$GRAPHIFY_OUT_NAME"
  if [ -d "$OUT_DIR/cache" ] || [ -f "$OUT_DIR/.graphify_semantic_marker" ] \
     || [ -f "$OUT_DIR/.graphify_analysis.json" ]; then
    mkdir -p "$SCRATCH_OUT"
    if [ -d "$OUT_DIR/cache" ]; then
      cp -R "$OUT_DIR/cache" "$SCRATCH_OUT/cache" \
        || { echo "refresh-graph-map: graphify cache seed failed" >&2; exit 1; }
    fi
    for semantic_artifact in .graphify_semantic_marker .graphify_analysis.json; do
      if [ -f "$OUT_DIR/$semantic_artifact" ]; then
        cp "$OUT_DIR/$semantic_artifact" "$SCRATCH_OUT/$semantic_artifact" \
          || { echo "refresh-graph-map: graphify cache seed failed" >&2; exit 1; }
      fi
    done
  fi
  printf '%s\n' "$CORPUS_CLASS" > "$SCRATCH/.graphify-corpus"
  # CLEAR THE CLAUDE REROUTE SELECTORS before dispatching (HIMMEL-1070,
  # codex-adv-1). graphify-fence.sh hard-denies these, but the fence is a
  # PreToolUse hook — it only sees graphify invocations an AGENT types. THIS
  # script is fired directly by cron/schtasks (graphmap-cadence.sh), so the
  # fence never runs on the scheduled path: an inherited CLAUDE_CODE_USE_BEDROCK
  # would send corpus content to AWS with nothing to stop it, and the hard-deny
  # we document would be true only for the interactive path. Clearing them here
  # makes the property hold where the extraction actually happens. This is
  # exactly what himmel's own scripts/claude-codex does with the same variables,
  # for the same "would silently reroute the session away" reason.
  # Clearing (not refusing) keeps a Bedrock/Vertex-configured operator's cadence
  # working on the intended provider, and fails LOUDLY if their CLI genuinely
  # cannot auth without the reroute — never silently to another cloud. Harmless
  # for non-claude backends, which do not read these at all.
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  unset CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS
  # HIMMEL-1084 residual: the scheduled extraction preflight above now resolves
  # the effective endpoint and runs the matrix for claude/claude-cli/glm/kimi,
  # while deliberately preserving supported Anthropic credentials and custom
  # `--backend claude` endpoints for public himmel-code corpora. Unmapped
  # backends have no provider mapping, so the fail-closed check above refuses
  # them (rc=2, pinned by T44a); mapping remains tracked by HIMMEL-1084.
  # HIMMEL-1901 ask 4 — bank preflight + TOTAL-run deadline.
  #
  # Two independent holes let the 2026-08-17 fire burn ~18x the previous day's
  # input tokens (144,540 -> 2,585,365 on the himmel corpus) and run 6h44m on
  # luna without finishing, contributing to a workstation hang:
  #
  #   1. bank-preflight.sh shipped (HIMMEL-1841) but NOTHING on the graphify
  #      path ever called it. The 13:00 fire proceeded at 86% 5h utilization.
  #   2. GRAPHIFY_API_TIMEOUT bounds ONE chunk, never the run. claude-cli
  #      chunks are serialized by graphify's own clamp, so N chunks x the
  #      per-chunk ceiling is the real worst case and nothing capped it.
  #
  # The upstream defect (graphify treats a hollow response as truncation and
  # bisects, so one failed call fans out exponentially) is HIMMEL-1901 asks
  # 1-3 and lives in Graphify-Labs/graphify, not here. This is the himmel-side
  # containment: refuse to start when the bank is already drawn down, and put
  # a ceiling on the run so a storm costs bounded time instead of a night.

  # Total-run deadline. 0 disables. Default 7200s (2h): the last HEALTHY full
  # luna refresh took 82 min wall (2026-08-16 13:00 -> 14:22), so 2h clears it
  # with headroom while cutting a runaway from 6h44m+ to a bounded 2h. A
  # timeout kills the graphify call, which takes the exit-2 path below and
  # leaves graphify-out UNPROMOTED — a stale graph, never a corrupt one.
  GRAPHIFY_RUN_DEADLINE_SECONDS="${GRAPHIFY_RUN_DEADLINE_SECONDS:-7200}"
  case "$GRAPHIFY_RUN_DEADLINE_SECONDS" in
    ''|*[!0-9]*) echo "refresh-graph-map: GRAPHIFY_RUN_DEADLINE_SECONDS must be a non-negative integer (got '$GRAPHIFY_RUN_DEADLINE_SECONDS')" >&2; exit 1 ;;
  esac
  # 10# forces base-10: a leading-zero value ("08", "0900") would otherwise be
  # read as octal in the $(( )) arithmetic context below (_deadline_left) and
  # a value like "08" errors outright (invalid octal digit) -- see
  # scripts/lib/bank-preflight.sh's identical `stamp=$((10#$stamp))` normalize.
  GRAPHIFY_RUN_DEADLINE_SECONDS=$((10#$GRAPHIFY_RUN_DEADLINE_SECONDS))
  # Both bounded calls need -k, and PATH presence is not proof of a GNU-style
  # timeout, so accept only a binary that passes a functional probe (same shape
  # as the corpus-pull guard above). No functional timeout => no deadline, and
  # say so rather than pretending the run is bounded. Resolved here, ahead of
  # the bank guard below, because the preflight's own fixed bound needs it too.
  _deadline_bin=""
  if [ "$GRAPHIFY_RUN_DEADLINE_SECONDS" -gt 0 ]; then
    for _t in timeout gtimeout; do
      if command -v "$_t" >/dev/null 2>&1 && "$_t" -k 1 1 true >/dev/null 2>&1; then
        _deadline_bin="$_t"; break
      fi
    done
    [ -n "$_deadline_bin" ] || echo "refresh-graph-map: no functional timeout(1) — run deadline DISABLED, extraction is unbounded" >&2
  fi

  # Bank guard: claude-backed extraction only. API backends (kimi/glm) draw no
  # subscription bank, so gating them would be a false refusal. Branch on the
  # VERDICT TOKEN, never the exit code — bank-preflight always exits 0 by
  # design, so `||` here would be dead code. Only SKIPPED-BANK stops the run:
  # BANK-STALE / BANK-UNKNOWN are fail-open verdicts and must not block a
  # refresh on a box with no usage cache.
  #
  # The preflight call itself gets a FIXED small ceiling (120s, 10s kill
  # grace) -- NOT $GRAPHIFY_RUN_DEADLINE_SECONDS. It is a precondition check,
  # not extraction work: it must not eat into the extraction budget, and it
  # must not be sized like a multi-hour run. bank-preflight.sh shells
  # usage-cache-producer.sh, which does a network fetch -- left unbounded,
  # that fetch could hang the cadence indefinitely, inside the very guard
  # whose entire purpose is "nothing on this path runs unbounded".
  case "$BACKEND" in
    claude|claude-cli)
      _bank_preflight="$REPO_ROOT/scripts/lib/bank-preflight.sh"
      if [ -f "$_bank_preflight" ]; then
        if [ -n "$_deadline_bin" ]; then
          _bank_verdict="$(CADENCE_BANK_LEG="graphmap-$NAME" "$_deadline_bin" -k 10 120 bash "$_bank_preflight" || true)"
        else
          _bank_verdict="$(CADENCE_BANK_LEG="graphmap-$NAME" bash "$_bank_preflight" || true)"
        fi
        # bank-preflight always exits 0 by design (see above), but wrapped in
        # timeout a kill yields 124, and `|| true` swallows that so `set -e`
        # never aborts the run over it. Fail-open (proceed unguarded) is
        # correct when the preflight itself could not complete -- but it must
        # never be SILENT about it.
        if [ -z "$_bank_verdict" ]; then
          echo "refresh-graph-map: bank preflight produced no verdict (timed out or failed) -- proceeding UNGUARDED for corpus '$NAME'" >&2
        fi
        if [ "$_bank_verdict" = "SKIPPED-BANK" ]; then
          echo "refresh-graph-map: bank at/over threshold — extraction SKIPPED for corpus '$NAME' (graphify-out left untouched, no graph was refreshed)" >&2
          exit 3
        fi
      else
        echo "refresh-graph-map: bank-preflight.sh not found at $_bank_preflight — proceeding UNGUARDED (checkout may be behind main)" >&2
      fi
      ;;
  esac

  # HIMMEL-1902: claude-cli otherwise inherits the operator's full plugin hook
  # stack. SessionEnd hooks are cancelled during each headless chunk teardown;
  # their failure text contaminates graphify's stdout envelope, which graphify
  # misclassifies as a hollow response and bills a duplicate extraction. Use a
  # dedicated config dir that keeps native subscription auth, disables every
  # hook (including plugin hooks), and applies the validated bare plugin profile.
  # Seed only after the bank preflight passes so a skipped run does not touch auth
  # state, and only for claude-cli (API backends never launch the local CLI).
  if [ "$BACKEND" = "claude-cli" ]; then
    GRAPHIFY_CLAUDE_CONFIG_DIR="${GRAPHIFY_CLAUDE_CONFIG_DIR:-$HOME/.claude-graphify}"
    export GRAPHIFY_CLAUDE_CONFIG_DIR
    if bash "$HERE/seed-claude-config.sh"; then
      CLAUDE_CONFIG_DIR="$GRAPHIFY_CLAUDE_CONFIG_DIR"
      export CLAUDE_CONFIG_DIR
    else
      echo "refresh-graph-map: failed to seed the hook-free Claude config dir; refusing claude-cli extraction" >&2
      exit 2
    fi
  fi

  # Promote shrink guard (HIMMEL-1901 addendum -- operator directive: "graphify
  # should always expand but not just flat rewrite as this is huge costs"). The
  # promote below is a flat `mv`, no floor: HIMMEL-1650 silently collapsed luna
  # from 16,630 to 10,538 nodes on a 0.9.32 replay, HIMMEL-1817 collapsed a
  # single CLAUDE.md extraction from 17 nodes to 1 (134 source files vanished,
  # nothing caught it), and leg 28 of this very chain overwrote a committed
  # 1295-node/1605-edge graph with a 920/854 cluster-only run. Worse than
  # losing one good graph: the semantic cache the NEXT run seeds from
  # (HIMMEL-1097, below) is whatever got promoted, so an uncaught collapse
  # also poisons every future incremental into a full, expensive
  # re-extraction -- this compounds, it does not just cost one bad graph.
  # Default 90 == refuse a promote that drops node OR link counts more
  # than 10% below the graph already on disk. 0 disables the guard outright
  # (operator override for a deliberate, known-good shrink). The actual
  # compare runs later, once the staged graph exists (see GRAPHIFY_PROMOTE_MIN_RETAIN_PCT usage below).
  GRAPHIFY_PROMOTE_MIN_RETAIN_PCT="${GRAPHIFY_PROMOTE_MIN_RETAIN_PCT:-90}"
  case "$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT" in
    ''|*[!0-9]*) echo "refresh-graph-map: GRAPHIFY_PROMOTE_MIN_RETAIN_PCT must be a non-negative integer <= 100 (got '$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT')" >&2; exit 1 ;;
  esac
  [ "$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT" -le 100 ] || { echo "refresh-graph-map: GRAPHIFY_PROMOTE_MIN_RETAIN_PCT must be a non-negative integer <= 100 (got '$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT')" >&2; exit 1; }
  _deadline_start="$(date +%s)"
  # Seconds left of the total budget, floor 0. Callers treat 0 as expired.
  _deadline_left() {
    [ -n "$_deadline_bin" ] || { printf 'unbounded\n'; return; }
    _left=$(( GRAPHIFY_RUN_DEADLINE_SECONDS - ( $(date +%s) - _deadline_start ) ))
    [ "$_left" -gt 0 ] || _left=0
    printf '%s\n' "$_left"
  }
  # Run "$@" under whatever remains of the shared budget. The budget spans BOTH
  # graphify dispatches — giving each the full deadline would let the pair run
  # 2x the ceiling, which is the bug, not the fix.
  _run_bounded() {
    _rem="$(_deadline_left)"
    if [ "$_rem" = unbounded ]; then
      "$@"
      return $?
    fi
    if [ "$_rem" -eq 0 ]; then
      echo "refresh-graph-map: run deadline ${GRAPHIFY_RUN_DEADLINE_SECONDS}s exhausted before this stage" >&2
      return 124
    fi
    "$_deadline_bin" -k 30 "$_rem" "$@"
  }

  echo "refresh-graph-map: incremental update on scratchpad copy ($SCRATCH) backend=$BACKEND deadline=${GRAPHIFY_RUN_DEADLINE_SECONDS}s" >&2
  # Billing note (NOT a gate marker — see below). Under the default BACKEND
  # (claude-cli) graphify shells the claude CLI headlessly from inside these two
  # dispatches. CORRECTED 2026-08-12 (HIMMEL-1748): an earlier cut claimed this
  # billed on a "separate headless bucket" (HIMMEL-128) — measured, it does NOT:
  # headless-claude-ok: documentation of the intentional graphify CLI backend dispatch
  # subscription-authenticated `claude -p` draws from the SAME 5h/weekly usage
  # bank as interactive sessions. The sonnet model pin above is what keeps the
  # cadence's draw acceptable; operators who want zero bank draw use an API
  # backend (kimi, glm) instead.
  # Deliberately NOT a `headless-claude-ok:` marker (HIMMEL-1070, public CR
  # thread): the no-headless-claude gate matches `claude` + `-p|--print|--bg` in
  # THIS repo's shell, and these lines invoke `graphify`. The gate never fires
  # here, so a marker would suppress nothing and would imply an enforcement that
  # does not exist. (It also matches PROSE - an earlier cut of this very comment
  # tripped the gate by containing the literal flag, so the marker would only
  # have been suppressing itself.) The real control for what those nested calls
  # can reach is the reroute-selector clearing above + the egress fence.
  _rc=0
  _run_bounded "$GRAPHIFY_MAP" "$SCRATCH" --update --backend "$BACKEND" --max-concurrency "$GRAPHIFY_MAX_CONCURRENCY" --api-timeout "$GRAPHIFY_API_TIMEOUT" >&2 || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    if [ "$_rc" -eq 124 ]; then
      echo "refresh-graph-map: graphify --update exceeded the ${GRAPHIFY_RUN_DEADLINE_SECONDS}s run deadline (HIMMEL-1901) -- graphify-out left unpromoted" >&2
    else
      echo "refresh-graph-map: graphify --update failed" >&2
    fi
    exit 2
  fi
  _rc=0
  _run_bounded "$GRAPHIFY_MAP" cluster-only "$SCRATCH" --backend "$BACKEND" --max-concurrency "$GRAPHIFY_MAX_CONCURRENCY" >&2 || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    if [ "$_rc" -eq 124 ]; then
      echo "refresh-graph-map: cluster-only exceeded the ${GRAPHIFY_RUN_DEADLINE_SECONDS}s run deadline (HIMMEL-1901) -- graphify-out left unpromoted" >&2
    else
      echo "refresh-graph-map: cluster-only failed" >&2
    fi
    exit 2
  fi
  # HIMMEL-907: stamp freshness artifacts so the companion guard
  # check-graph-freshness.sh can VERIFY this graph (not "fresh by age" only).
  # Source-of-truth for shape is the guard's parser: manifest.json = flat
  # non-empty JSON object of corpus-relative path -> {mtime} (the parser uses
  # the KEYS to prove the corpus still exists; values are free-form, so we carry
  # the file mtime as honest provenance — stored as an INT epoch for compact,
  # human-greppable provenance — and invent nothing else); .graphify_root =
  # first non-blank line is the corpus root. graphify emits its own differently
  # shaped graphify-out/manifest.json; we separately synthesize the HIMMEL-907
  # freshness manifest from the same corpus predicate the extraction copy used
  # (`find -name '*.md'` minus the resolved AND default out dirs) and explicitly install
  # ours during promote (never graphify's native manifest). A zero-md corpus stamps
  # `{}`, which the guard rejects with rc=2 — fail-loud by design, no
  # special-casing. Only written on a SUCCESSFUL refresh — this branch is reached
  # solely after graphify --update + cluster-only both succeeded; a failed run
  # exits above before reaching here, so we never stamp a failed run as fresh.
  #
  # F1: walk the SCRATCH copy (the exact corpus the graph saw), NOT the live
  # corpus — a file added/removed mid-extraction would otherwise make
  # manifest.json attest a corpus state the graph never saw. The scratch's own
  # graphify-out is pruned so GRAPH_REPORT.md doesn't leak into the keys. Keys
  # stay corpus-relative (scratch mirrors the corpus's relative md layout).
  #
  # F2: transactional promote so any interruption (disk full, kill, python3
  # gone mid-run, ...) leaves a stamp-LESS out dir the guard fails closed on —
  # never a NEW graph beside OLD stamps. Order: build the new manifest into a
  # tmp name -> invalidate the old stamps -> promote the derived graph ->
  # atomically install the new stamps (same-dir mv + marker write).
  mkdir -p "$OUT_DIR"
  # (CORPUS_ROOT_ABS removed with HIMMEL-1116 — the .graphify_root marker is now
  # relative, and that assignment was its only consumer.)
  SCRATCH_ABS="$(cd "$SCRATCH" && pwd)"
  # HIMMEL-910: acquire the exclusive per-out-dir lock (see its definition
  # above) around the WHOLE promote block that follows -- steps 1-4 below
  # must run as one atomic unit relative to any OTHER refresh-graph-map
  # promoting into this same out dir. Acquired HERE (not earlier, around the
  # pull/extraction -- see the pull note above for why a long hold breaks the
  # age-based stale takeover) so the hold stays SHORT. exit 2 matches the
  # graphify/cluster-only failure exit code above (a refuse-to-clobber is a
  # fence/tooling failure, not a usage error).
  _promote_lock_acquire || exit 2
  # Test-only hook (HIMMEL-910): hold the lock for N seconds before doing any
  # promote work, so a concurrency test can create a deterministic overlap
  # window. No-op unless set.
  if [ -n "${GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS:-}" ]; then
    sleep "$GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS"
  fi
  # HIMMEL-1134 CR follow-up round 5: sanitize + guard-scan now run on the
  # SCRATCH artifacts (staging), BEFORE anything in $OUT_DIR is touched.
  # Previously this block invalidated the old manifest.json/.graphify_root
  # stamps and cp'd the new graph.json/GRAPH_REPORT.md into the TRACKED
  # $OUT_DIR first, then sanitized + guard-scanned those PROMOTED copies --
  # so a REJECTED (leaking) refresh had already (a) invalidated the prior
  # stamps and (b) written leaked bytes into graphify-out/ before the
  # guard's `exit 2` ever ran. The reject still failed closed on PUBLISH
  # (nothing shipped to the vault's 60-Maps), but the tracked out dir was
  # left holding leaked bytes a later `git add -A` could commit, and the
  # corpus's prior-good stamps were gone. Scanning the scratch copies gives
  # IDENTICAL coverage (byte-for-byte what would be promoted) while
  # guaranteeing $OUT_DIR's prior clean artifacts + stamps are completely
  # untouched on rejection.
  SCRATCH_REPORT="$SCRATCH/$GRAPHIFY_OUT_NAME/GRAPH_REPORT.md"
  SCRATCH_GRAPH="$SCRATCH/$GRAPHIFY_OUT_NAME/graph.json"
  # HIMMEL-1134 CR follow-up (CodeRabbit App, PR #1274): assert BOTH staging
  # artifacts exist BEFORE the sanitize/guard even start. Without this, a
  # missing graph.json (or report) would fall through every check below --
  # `head ... 2>/dev/null || true` silently swallows the read failure, the
  # `case` has no default so an empty/garbage header just skips the
  # sanitize, and the scan loop's (now-removed) `[ -f ] || continue` would
  # skip a missing artifact rather than refuse -- letting a malformed
  # staging area reach $OUT_DIR mutation before some LATER cp happened to
  # fail, defeating the round-5 preservation guarantee this whole reorder
  # exists for.
  for required_artifact in "$SCRATCH_REPORT" "$SCRATCH_GRAPH"; do
    if [ ! -f "$required_artifact" ]; then
      echo "refresh-graph-map: missing required scratch artifact ${required_artifact##*/}" >&2
      exit 2
    fi
  done
  # HIMMEL-1134: sanitize the scratch report's HEADER, before promotion.
  # graphify titles GRAPH_REPORT.md by the EXTRACTION path -- here that's
  # $SCRATCH, a PID-suffixed scratchpad dir = the operator's home dir +
  # username -- and that header would otherwise land in a TRACKED,
  # public-mirrored artifact (graphify-out/ went tracked in HIMMEL-1123).
  # Rewrite line 1 to carry the corpus NAME instead, preserving a trailing
  # " (YYYY-MM-DD)" stamp if present. Matched on the generic
  # `# Graph Report - <anything>` SHAPE, not the specific scratch string
  # (MSYS vs Windows give different separator forms). awk, not
  # sed/parameter-expansion: $NAME lands as an awk -v value (no
  # regex-replacement escaping of & or \ to worry about).
  if ! report_line1="$(head -n 1 "$SCRATCH_REPORT" 2>/dev/null)"; then
    echo "refresh-graph-map: failed to read report header" >&2
    exit 2
  fi
  case "$report_line1" in
    '# Graph Report - '*)
      report_date="$(printf '%s\n' "$report_line1" | grep -oE '\([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' || true)"
      if [ -n "$report_date" ]; then
        report_header="# Graph Report - $NAME  $report_date"
      else
        report_header="# Graph Report - $NAME"
      fi
      # HIMMEL-1134 CR follow-up round 4: explicit success/failure branches,
      # not `awk ... && mv` -- under `set -euo pipefail` a command on the
      # LEFT of `&&` is EXEMPT from set -e, so an awk failure there would
      # short-circuit the `&&` (skipping the mv) and fall through SILENTLY.
      # Fail loudly on either awk or mv failing, and clean up the tmp file
      # on both paths (belt-and-braces -- it now lives inside $SCRATCH, so
      # the EXIT trap's `rm -rf "$SCRATCH"` would also catch it).
      if awk -v h="$report_header" 'NR==1 { print h; next } { print }' "$SCRATCH_REPORT" > "$SCRATCH_REPORT.tmp"; then
        if ! mv "$SCRATCH_REPORT.tmp" "$SCRATCH_REPORT"; then
          echo "refresh-graph-map: failed to install sanitized report header" >&2
          rm -f "$SCRATCH_REPORT.tmp"
          exit 2
        fi
      else
        echo "refresh-graph-map: failed to sanitize report header (awk)" >&2
        rm -f "$SCRATCH_REPORT.tmp"
        exit 2
      fi
      ;;
    *)
      # HIMMEL-1134 CR follow-up (CodeRabbit App, PR #1274): the `case`
      # previously had no default -- an unexpected header format (not
      # starting with the fixed `# Graph Report - ` prefix graphify always
      # emits) silently SKIPPED the sanitize and fell through to the guard
      # with whatever line 1 already was. Fail loudly instead: a header
      # this script doesn't recognize is itself a signal something is
      # wrong upstream (empty/corrupted report, a different tool's output,
      # ...), not a shape to quietly pass through.
      echo "refresh-graph-map: failed to sanitize report header (unexpected format)" >&2
      exit 2
      ;;
  esac
  # HIMMEL-1134: host-path GUARD, failing LOUDLY, BEFORE any $OUT_DIR
  # mutation (CR follow-up round 5). The sanitize above only touches line 1
  # -- a leak elsewhere in the report (or in graph.json) would otherwise
  # ship silently until a reviewer happened to catch it by eye. Scan both
  # SCRATCH artifacts about to be promoted for a host-path SHAPE (case
  # insensitive): a Users dir (POSIX or Windows-drive form, either slash
  # direction), a bare \Users\, a /home/<user>/ dir, or an AppData PATH
  # SEGMENT -- PLUS explicit JSON-escaped double-backslash alternatives
  # (graph.json is JSON, so a Windows path in it is serialized with each
  # backslash doubled, e.g. C:\\Users\\name). The single-backslash
  # drive-letter alternative above ([A-Za-z]:\Users\, anchored right after
  # the colon) does NOT match that doubled form; the bare \Users\
  # alternative already happens to catch most doubled-backslash cases too (a
  # run of 2 backslashes contains 1 as a substring), but the explicit
  # doubled-backslash alternatives make that coverage textual instead of
  # incidental, so it survives if the bare alternative is ever narrowed or
  # removed. AppData is bounded by path delimiters -- (^|[/\])AppData([/\]|$)
  # -- rather than a bare substring: an UNBOUNDED "AppData" would false-
  # positive-refuse a clean refresh over a legit node name or prose mentioning
  # it (e.g. "MyAppDataStore", "AppData sync"), which have no delimiter
  # immediately before/after the word (CR-caught, HIMMEL-1134 follow-up). A
  # hit refuses the promote -- same exit-2 convention as the
  # graphify/cluster-only and lock-acquire failures above (a leak
  # fence-tripping is a tooling failure, not a usage error).
  leak_pattern='(/Users/|[A-Za-z]:\\Users\\|[A-Za-z]:/Users/|\\Users\\|[A-Za-z]:\\\\Users\\\\|\\\\Users\\\\|/home/[^/]+/|(^|[/\\])AppData([/\\]|$))'
  # The upfront existence check above already guarantees both artifacts are
  # present, so no `[ -f ] || continue` skip is needed here (CR follow-up,
  # CodeRabbit App PR #1274 -- that skip is now dead code the existence
  # check made redundant, and a redundant skip is one more place a real gap
  # could silently hide).
  for leak_artifact in "$SCRATCH_REPORT" "$SCRATCH_GRAPH"; do
    # basenamed (CR follow-up round 5): the FULL path (now under $SCRATCH,
    # previously $OUT_DIR/graph.json) can itself carry the corpus/home path
    # -- error messages below print only the filename, never the full path.
    leak_artifact_name="${leak_artifact##*/}"
    scan_target="$leak_artifact"
    scan_target_note=""
    if [ "$leak_artifact" = "$SCRATCH_GRAPH" ]; then
      # HIMMEL-1406: scope graph.json's scan to STRUCTURAL fields only,
      # instead of the full raw JSON text -- see _graph_structural_fields
      # above for the field list + why (a vault note's content-borne host
      # path, e.g. a rationale/summary quoting C:\Users\..., is
      # policy-allowed here; a path graphify wrote into the artifact's own
      # structure is not).
      scan_target="$SCRATCH/.graph-structural-fields.$$"
      if ! _graph_structural_fields "$SCRATCH_GRAPH" "$scan_target"; then
        echo "refresh-graph-map: REFUSING to promote -- leak SCAN FAILED for $leak_artifact_name (could not extract structural fields for the scoped host-path scan)" >&2
        exit 2
      fi
      scan_target_note=" (structural field; line number refers to the scoped extract, not the raw file -- see the quarantined copy for the full artifact)"
    fi
    # -m1: grep stops after its OWN first match (rc 0 hit / rc 1 miss) -- no
    # pipe to `head`, so no SIGPIPE. Under `set -o pipefail` (line 30), a
    # `grep | head -n 1` pipeline where grep gets SIGPIPE'd by head closing
    # early reports a NON-ZERO pipeline rc even on a real match, which made
    # `&&` short-circuit past the `exit 2` below -- the guard failed OPEN on
    # exactly the leaks with a second match past the closed pipe (CR-caught,
    # HIMMEL-1134 follow-up).
    #
    # grep has THREE exit statuses, not two (CR-caught, HIMMEL-1134 follow-up
    # round 3): 0 = match, 1 = no match, >1 = SCAN ERROR (unreadable
    # artifact, bad regex, out of memory, ...). `leak_line=$(...) && [ -n ]`
    # treated rc>1 the same as rc 1 (no match) -- a scan the guard couldn't
    # even perform was silently read as "clean", so a real leak in an
    # artifact grep failed to read would still ship. Capture the rc
    # explicitly (`|| grep_rc=$?` stays set -e safe) and fail CLOSED on
    # rc>1, distinct from the rc-0 leak-found path.
    #
    # -a (--binary-files=text, CR follow-up, CodeRabbit App PR #1274): a NUL
    # byte anywhere in the artifact flips GNU grep into "Binary file
    # matches" mode, which drops the line-number extraction this guard's
    # error message depends on and makes a real leak's detectability
    # unpredictable on adversarial/binary content. Force text mode instead
    # -- both artifacts are supposed to be text (a report is markdown, the
    # graph is JSON -- or, for graph.json, a flat text extract of it), so
    # treating a NUL as just another byte is correct here, not a workaround.
    leak_line=""
    grep_rc=0
    leak_line="$(grep -a -m1 -inE "$leak_pattern" "$scan_target")" || grep_rc=$?
    if [ "$grep_rc" -eq 0 ]; then
      # HIMMEL-1134 CR follow-up: do NOT echo $leak_line -- it's the matched
      # grep line, i.e. it CONTAINS the leaked host path. Printing it here
      # would have the guard leak the very secret it's refusing to promote,
      # straight into stderr (and from there into CI logs / captured
      # output). Report only the file NAME + the line NUMBER (grep's own
      # "N:..." prefix, stripped at the first colon).
      leak_line_number="${leak_line%%:*}"
      # HIMMEL-1406: save a FEW lines of context around the match into the
      # scratch graphify-out, so it travels with the quarantine copy
      # _scratch_cleanup preserves on this refusal (see its definition
      # above) -- for offline inspection only. This file DOES contain the
      # leaked path (that's the point), so -- same rule as $leak_line above
      # -- it must never be echoed to stdout/stderr here.
      leak_context_file="$SCRATCH_OUT/.leak-context-${leak_artifact_name}.txt"
      leak_ctx_start=$(( leak_line_number > 2 ? leak_line_number - 2 : 1 ))
      leak_ctx_end=$(( leak_line_number + 2 ))
      sed -n "${leak_ctx_start},${leak_ctx_end}p" "$scan_target" > "$leak_context_file" 2>/dev/null || true
      echo "refresh-graph-map: REFUSING to promote -- host path detected in $leak_artifact_name at line $leak_line_number${scan_target_note} (context saved to graphify-out/${leak_context_file##*/} in the quarantined copy -- not printed here to avoid leaking the path into logs)" >&2
      exit 2
    elif [ "$grep_rc" -gt 1 ]; then
      echo "refresh-graph-map: REFUSING to promote -- leak SCAN FAILED for $leak_artifact_name (grep rc=$grep_rc)" >&2
      exit 2
    fi
    # grep_rc -eq 1: no leak found in this artifact, continue.
  done
  # ONLY past this point (guard passed clean) does anything in $OUT_DIR
  # change -- everything above ran against $SCRATCH only.
  # 1. STAGE every promoted artifact inside $OUT_DIR (same filesystem as the
  #    final paths). Files and the cache directory are fully copied under a
  #    hidden per-run name before any prior artifact is invalidated, so final
  #    installs use atomic rename rather than exposing a half-copied cache.
  PROMOTE_STAGE="$OUT_DIR/.promote-stage.$$.$RANDOM"
  rm -rf "$PROMOTE_STAGE"
  mkdir "$PROMOTE_STAGE"
  cp "$SCRATCH_GRAPH" "$PROMOTE_STAGE/graph.json"
  cp "$SCRATCH_REPORT" "$PROMOTE_STAGE/GRAPH_REPORT.md"
  if [ -d "$SCRATCH_OUT/cache" ]; then
    cp -R "$SCRATCH_OUT/cache" "$PROMOTE_STAGE/cache"
  fi
  for semantic_artifact in .graphify_semantic_marker .graphify_analysis.json; do
    if [ -f "$SCRATCH_OUT/$semantic_artifact" ]; then
      cp "$SCRATCH_OUT/$semantic_artifact" "$PROMOTE_STAGE/$semantic_artifact"
    fi
  done
  # Build the synthesized HIMMEL-907 freshness manifest directly in the stage.
  # graphify's native scratch manifest is intentionally NOT among the promoted
  # artifacts: the guard consumes this corpus-path-keyed shape instead.
  # The out-dir NAME is passed in (CR r13): this prune was hardcoded to
  # "graphify-out", so under a GRAPHIFY_OUT override it pruned a directory that
  # does not exist and the real one -- carrying GRAPH_REPORT.md -- leaked
  # straight into the manifest keys. The default name is pruned as well, so a
  # leftover from a previous default-named run cannot leak either.
  python3 - "$SCRATCH_ABS" "$PROMOTE_STAGE/manifest.json" "$GRAPHIFY_OUT_NAME" <<'PYEOF'
import json, os, sys
root, manifest_path = sys.argv[1], sys.argv[2]
out_names = {sys.argv[3], "graphify-out"} if len(sys.argv) > 3 else {"graphify-out"}
scratch_outs = {os.path.join(root, n) for n in out_names}
manifest = {}
for dirpath, dirs, files in os.walk(root):
    # prune the derived out dir graphify wrote into the scratch so it doesn't
    # leak GRAPH_REPORT.md into the manifest keys.
    dirs[:] = [d for d in dirs if os.path.join(dirpath, d) not in scratch_outs]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root).replace(os.sep, "/")
        try:
            mtime = int(os.path.getmtime(full))
        except OSError:
            mtime = 0
        manifest[rel] = {"mtime": mtime}
with open(manifest_path, "w") as fh:
    json.dump(manifest, fh, sort_keys=True)
    fh.write("\n")
PYEOF
  printf '%s\n' "." > "$PROMOTE_STAGE/.graphify_root"
  # Version stamp (HIMMEL-1901 addendum) -- captures the graphify version that
  # produced THIS promoted graph, so a later refresh's shrink guard (1b, below)
  # can tell "the extractor changed" (an expected shrink -- e.g. the upcoming
  # 0.9.44 -> 0.9.46 dedup/prune fixes) apart from "the extractor is unchanged
  # and the graph just got smaller" (the actual collapse the guard exists to
  # catch). `--version` prints an update-nag WARNING line to stdout ahead of
  # the real version ("skill is from graphify 0.9.40, package is 0.9.44."), so
  # take the LAST semver-looking token in its output, not the first. Bounded
  # (a few seconds) when a functional timeout is available; empty on any
  # failure/timeout, which the guard below treats as "unknown" and never gates
  # on.
  _graphify_version=""
  if [ -n "$_deadline_bin" ]; then
    _graphify_version="$("$_deadline_bin" -k 2 5 "$GRAPHIFY_MAP" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1)" || _graphify_version=""
  else
    _graphify_version="$("$GRAPHIFY_MAP" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1)" || _graphify_version=""
  fi
  printf '%s\n' "$_graphify_version" > "$PROMOTE_STAGE/.graphify_promoted_version"
  # 1b. PROMOTE SHRINK GUARD (HIMMEL-1901 addendum, see GRAPHIFY_PROMOTE_MIN_RETAIN_PCT
  #     above for the WHY). Must run here: both graph.json files exist and are
  #     countable (staged just landed in $PROMOTE_STAGE above; the prior one is
  #     still untouched at $OUT_DIR/graph.json -- the mv that replaces it is
  #     step 3, below), and nothing destructive has happened yet -- a refusal
  #     here must leave $OUT_DIR, including its freshness stamps, exactly as
  #     it was. Running this AFTER the stamp-invalidating rm -f two lines down
  #     would leave a refused-but-untouched graph looking stamp-less, and
  #     check-graph-freshness.sh would then fail closed on a graph that is
  #     actually fine.
  #
  #     Gates on NODES and LINKS only. graph.json is networkx node-link format
  #     (top-level nodes/links; edges may appear as "edges" on older/other
  #     outputs, hence the fallback below) -- there is no top-level "edges" key
  #     in current output, and the "links" array IS what every incident count
  #     (leg 28's 920/854, the committed 1295/1605) has always meant. HYPEREDGES
  #     are informational only, never gating: on a live graph they number in
  #     the tens, so a 90% floor trips on a swing of five, and they are exactly
  #     what upstream's dedup/hyperedge-rewire fixes reshape -- thresholding
  #     them produces constant false refusals.
  #
  #     Before comparing, check whether the extractor VERSION changed since the
  #     graph currently on disk was promoted (.graphify_promoted_version,
  #     staged just above). A shrink at a CHANGED version is explained by
  #     upstream improvements (e.g. hyperedge-member rewiring onto survivors,
  #     orphaned external-import sweep, isolated-node pruning); a shrink at a
  #     CONSTANT version is the bug this guard exists to catch. Unknown/absent/
  #     unchanged all fall through to the normal comparison.
  if [ "$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT" -gt 0 ]; then
    _prior_version=""
    if [ -f "$OUT_DIR/.graphify_promoted_version" ]; then
      _prior_version="$(cat "$OUT_DIR/.graphify_promoted_version" 2>/dev/null)" || _prior_version=""
    fi
    if [ -n "$_prior_version" ] && [ -n "$_graphify_version" ] && [ "$_prior_version" != "$_graphify_version" ]; then
      echo "refresh-graph-map: shrink guard SKIPPED -- graphify version changed ($_prior_version -> $_graphify_version); a node/link drop from upstream extraction changes is expected here, not a collapse" >&2
    else
      _rc=0
      _guard_out="$(python3 - "$PROMOTE_STAGE/graph.json" "$OUT_DIR/graph.json" "$GRAPHIFY_PROMOTE_MIN_RETAIN_PCT" <<'PYEOF'
import json, sys
staged_path, prior_path, pct_s = sys.argv[1], sys.argv[2], sys.argv[3]
pct = int(pct_s)

def links_of(data):
    v = data.get("links")
    if not isinstance(v, list):
        v = data.get("edges")
    return v if isinstance(v, list) else []

def counts(path, require_nodes_list):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    nodes = data.get("nodes")
    if require_nodes_list and not isinstance(nodes, list):
        return None
    if not isinstance(nodes, list):
        nodes = []
    links = links_of(data)
    hyperedges = data.get("hyperedges")
    hyperedges = hyperedges if isinstance(hyperedges, list) else []
    return (len(nodes), len(links), len(hyperedges))

staged = counts(staged_path, False)
if staged is None:
    print("STAGED_UNPARSEABLE")
    sys.exit(2)
staged_nodes, staged_links, staged_hyper = staged

try:
    open(prior_path, encoding="utf-8").close()
    has_prior = True
except OSError:
    has_prior = False
if not has_prior:
    print("NO_PRIOR 0 0 0 %d %d %d" % (staged_nodes, staged_links, staged_hyper))
    sys.exit(0)

prior = counts(prior_path, True)
if prior is None:
    print("PRIOR_UNPARSEABLE 0 0 0 %d %d %d" % (staged_nodes, staged_links, staged_hyper))
    sys.exit(0)
prior_nodes, prior_links, prior_hyper = prior

# Missing links/edges keys on either side fall back to an empty list above,
# which floors prior_links at 0 -- link_floor is then 0 too, so a prior with
# no readable edge data never gates (the spec's "no prior signal" case falls
# out for free; it never needs special-casing here).
node_floor = prior_nodes * pct // 100
link_floor = prior_links * pct // 100
if staged_nodes < node_floor or staged_links < link_floor:
    print("SHRINK %d %d %d %d %d %d" % (prior_nodes, prior_links, prior_hyper, staged_nodes, staged_links, staged_hyper))
    sys.exit(2)
print("OK %d %d %d %d %d %d" % (prior_nodes, prior_links, prior_hyper, staged_nodes, staged_links, staged_hyper))
PYEOF
)" || _rc=$?
      case "$_guard_out" in
        STAGED_UNPARSEABLE*)
          echo "refresh-graph-map: REFUSING to promote -- staged graph $PROMOTE_STAGE/graph.json is missing or unparseable JSON; refusing to promote something we cannot verify" >&2
          exit 2
          ;;
        PRIOR_UNPARSEABLE*)
          echo "refresh-graph-map: WARN existing graph $OUT_DIR/graph.json is unreadable or has no node array -- shrink guard skipped for this promote (proceeding)" >&2
          ;;
        SHRINK*)
          read -r _guard_tag _prior_n _prior_l _prior_h _staged_n _staged_l _staged_h <<< "$_guard_out"
          echo "refresh-graph-map: REFUSING to promote -- staged graph is below ${GRAPHIFY_PROMOTE_MIN_RETAIN_PCT}% of the existing graph (nodes $_prior_n -> $_staged_n, links $_prior_l -> $_staged_l; override via GRAPHIFY_PROMOTE_MIN_RETAIN_PCT) -- the existing graph at $OUT_DIR/graph.json was left in place" >&2
          exit 2
          ;;
        NO_PRIOR*|OK*)
          read -r _guard_tag _prior_n _prior_l _prior_h _staged_n _staged_l _staged_h <<< "$_guard_out"
          echo "refresh-graph-map: promote graph nodes $_prior_n -> $_staged_n, links $_prior_l -> $_staged_l (hyperedges $_prior_h -> $_staged_h, informational only)" >&2
          ;;
        *)
          echo "refresh-graph-map: REFUSING to promote -- shrink guard produced unexpected output (rc=$_rc): $_guard_out" >&2
          exit 2
          ;;
      esac
    fi
  fi
  # 2. INVALIDATE the old stamps so a half-promoted out dir is never mistaken
  #    for fresh (no manifest marker <-> guard fails closed).
  rm -f "$OUT_DIR/manifest.json" "$OUT_DIR/.graphify_root"
  # 3. PROMOTE the already sanitized + guard-scanned artifacts by same-dir
  #    atomic rename. Replacing a directory needs a short cache swap: sideline
  #    the prior complete cache, rename the fully staged cache into place, then
  #    remove the backup. The EXIT cleanup restores the prior cache if the
  #    second rename fails; at no point is a partially copied cache final.
  mv "$PROMOTE_STAGE/graph.json" "$OUT_DIR/graph.json"
  mv "$PROMOTE_STAGE/GRAPH_REPORT.md" "$REPORT"
  if [ -d "$PROMOTE_STAGE/cache" ]; then
    CACHE_BACKUP="$OUT_DIR/.cache.previous.$$.$RANDOM"
    rm -rf "$CACHE_BACKUP"
    if [ -e "$OUT_DIR/cache" ] || [ -L "$OUT_DIR/cache" ]; then
      if ! mv "$OUT_DIR/cache" "$CACHE_BACKUP"; then
        echo "refresh-graph-map: failed to sideline existing cache" >&2
        CACHE_BACKUP=""
        exit 2
      fi
    else
      CACHE_BACKUP=""
    fi
    if ! mv "$PROMOTE_STAGE/cache" "$OUT_DIR/cache"; then
      echo "refresh-graph-map: failed to install staged semantic cache" >&2
      exit 2
    fi
    if [ -n "$CACHE_BACKUP" ]; then
      rm -rf "$CACHE_BACKUP"
      CACHE_BACKUP=""
    fi
  else
    # No staged semantic cache this refresh (the refreshed scratch output
    # produced none): mirror the sibling semantic artifacts handled just below
    # (they rm -f the marker/analysis that are absent from scratch) so a prior
    # $OUT_DIR/cache does NOT survive and silently reseed later runs (HIMMEL-
    # 1097). Guard the target the same way _promote_stage_cleanup guards its
    # rm -rf below ([ -n "$VAR" ]) -- an empty/unset OUT_DIR must not
    # degenerate to a bare-root rm (rm -rf "/cache").
    if [ -n "$OUT_DIR" ]; then
      rm -rf "$OUT_DIR/cache"
    fi
  fi
  for semantic_artifact in .graphify_semantic_marker .graphify_analysis.json; do
    if [ -f "$PROMOTE_STAGE/$semantic_artifact" ]; then
      mv "$PROMOTE_STAGE/$semantic_artifact" "$OUT_DIR/$semantic_artifact"
    else
      rm -f "$OUT_DIR/$semantic_artifact"
    fi
  done
  # 4. STAMP: same-dir renames atomically install the synthesized manifest,
  #    marker, and version stamp. The guard joins the corpus-relative manifest
  #    keys against the resolved corpus root.
  #
  #    .graphify_root is RELATIVE (".") — not CORPUS_ROOT_ABS (HIMMEL-1116).
  #    OUT_DIR is always <corpus>/graphify-out, so the guard's relative branch
  #    (`CORPUS_RESOLVED="$OUT/../$MARKER_ROOT"`) resolves "$OUT/../." == the
  #    corpus root on EVERY machine. An absolute marker only works on the host
  #    that wrote it: the derived graph is now a tracked, SHARED artifact
  #    (HIMMEL-1123 — stations that cannot afford extraction pull it instead of
  #    building it), so a marker carrying THIS host's path would make the guard
  #    resolve a non-existent corpus on win2, fail closed "corpus orphaned", and
  #    tell that station to rebuild the very graph we shipped it to avoid
  #    rebuilding. The guard already supported relative markers; nothing there
  #    changes.
  #
  #    .graphify_promoted_version (HIMMEL-1901 addendum) rides the same
  #    staging + atomic-rename discipline as the two stamps above -- staged in
  #    step 1, only ever installed here, on the success path. A REFUSED
  #    promote never reaches this line (the guard above exits 2 first), so the
  #    out dir's version stamp is untouched by a refusal, same as graph.json.
  mv "$PROMOTE_STAGE/manifest.json" "$OUT_DIR/manifest.json"
  mv "$PROMOTE_STAGE/.graphify_root" "$OUT_DIR/.graphify_root"
  mv "$PROMOTE_STAGE/.graphify_promoted_version" "$OUT_DIR/.graphify_promoted_version"
  rm -rf "$PROMOTE_STAGE"
  PROMOTE_STAGE=""
  # CR r2 [codex-adv-r2]: do NOT release here -- the publish step below
  # READS $REPORT from the shared out dir, and a second refresh's promote can
  # replace it before that read; releasing early could publish the wrong run's
  # report despite the serialized promote.
  # The lock is held THROUGH publish and released after it (the EXIT trap
  # stays the failure-path backstop).
  rm -rf "$SCRATCH"   # eager clean on success; the EXIT trap is the failure-path backstop
  # Test-only hook (CR r2): hold between promote and publish, so the
  # promote-vs-publish overlap test can create a deterministic window.
  # No-op unless set.
  if [ -n "${GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS:-}" ]; then
    sleep "$GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS"
  fi
fi

# CR r2 [codex-adv-r2]: the --no-update path publishes by READING the same
# shared $REPORT a concurrent full refresh WRITES (non-atomic cp) -- take
# the same lock so reader-vs-writer is serialized in both directions (the
# update path arrives here already holding it). Same timeout/exit-2
# semantics as the writer side. mkdir -p: the lock dir lives inside
# $OUT_DIR, and a publish-only run against a never-refreshed corpus must
# still reach the "no report" exit-1 below instead of spinning on an
# uncreatable lock.
if [ "$DO_UPDATE" -eq 0 ]; then
  mkdir -p "$OUT_DIR"
  trap '_promote_lock_release' EXIT
  _promote_lock_acquire || exit 2
fi

[ -f "$REPORT" ] || { echo "refresh-graph-map: no GRAPH_REPORT.md at $REPORT (run without --no-update, or generate one first)" >&2; exit 1; }

# Publish the curated MOC into the vault's 60-Maps (the tracked artifact).
OUT_NOTE="$MAPS_DIR/$SLUG.md"
# --report/--source-graph live under CORPUS_ROOT, not MAPS_DIR, so
# absolutize them against the ORIGINAL cwd once, up front (bash 3.2-safe, no
# external tools) -- both identity-bound branches below need them.
case "$REPORT" in
  /*|[A-Za-z]:[/\\]*) REPORT_ABS="$REPORT" ;;
  *) REPORT_ABS="$PWD/$REPORT" ;;
esac
SRC_GRAPH_REL="$GRAPHIFY_OUT_NAME/graph.json"
case "$SRC_GRAPH_REL" in
  /*|[A-Za-z]:[/\\]*) SOURCE_GRAPH_ABS="$SRC_GRAPH_REL" ;;
  *) SOURCE_GRAPH_ABS="$PWD/$SRC_GRAPH_REL" ;;
esac
if [ -n "$MAPS_ID" ]; then
  # HIMMEL-1704 (codex-2): re-verifying MAPS_DIR's identity and then handing
  # that same PATHNAME to a separate node process still leaves a race -- an
  # attacker can swap MAPS_DIR's parent-directory entry between the check
  # returning and node's own open(). Close it the same way the corpus-root
  # copy above does: cd into MAPS_DIR (a process's cwd is bound to the
  # directory's INODE, not the path string, so a later parent-entry swap
  # cannot retarget an already-cd'd shell) and hand the publish helper a
  # RELATIVE --out resolved against that bound cwd, instead of an absolute
  # path node would re-resolve itself. Only taken when an identity was
  # actually pinned (MAPS_ID non-empty): a caller only ever pins one when
  # 60-Maps already existed at preflight time (graph-refresh.sh's sentinel),
  # so `cd` is expected to succeed here.
  ( cd "$MAPS_DIR" && _verify_fs_id "maps-dir" "." "$MAPS_ID" \
      && node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
           --report "$REPORT_ABS" --out "./$SLUG.md" --title "$TITLE" --slug "$SLUG" \
           ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "$SOURCE_GRAPH_ABS" ) \
    || { echo "refresh-graph-map: publish failed or refused (see output above)" >&2; exit 1; }
elif [ -n "$MAPS_PARENT_ID" ]; then
  # HIMMEL-1704 round 3 (codex-1): MAPS_ID is empty because 60-Maps did NOT
  # exist at the caller's preflight -- a legitimate first-ever publish -- so
  # there was no identity to pin for IT. But the VAULT that contains it
  # (MAPS_DIR's parent) WAS validated, and its identity is MAPS_PARENT_ID.
  # Silently falling through to node's own mkdirSync (the final `else`
  # branch) would let an attacker who plants a symlink named "60-Maps"
  # AFTER preflight but before this write ride node's own path resolution
  # straight through it. Instead: cd into the verified vault (bound to its
  # inode, same trick as above), re-check ITS identity, then create 60-Maps
  # OURSELVES via a bare `mkdir` -- which fails atomically (EEXIST) if
  # ANYTHING already occupies that name, symlink included, rather than
  # following it. Either mkdir wins the race (a genuinely fresh directory
  # we just created -- safe to publish into) or it loses (something
  # appeared where preflight said "absent" -- refuse, fail-closed).
  MAPS_LEAF="${MAPS_DIR##*/}"
  VAULT_DIR="${MAPS_DIR%/*}"
  if [ "$VAULT_DIR" = "$MAPS_DIR" ] || [ -z "$MAPS_LEAF" ]; then
    echo "refresh-graph-map: TOCTOU guard: --maps-dir '$MAPS_DIR' has no parent/leaf to split for the first-publish identity check -- refusing (HIMMEL-1704)" >&2
    exit 1
  fi
  # HIMMEL-1704 round 4 (codex-1): `mkdir` and the `cd` right after it are
  # still two SEPARATE syscalls on the same name -- an actor could rmdir the
  # (still-empty) directory mkdir just created and drop a symlink in its
  # place before `cd` runs. Once `cd` SUCCEEDS the race is over for good:
  # the shell's cwd is then bound to that directory's INODE (the OS tracks
  # cwd by open dentry, not by name), so node inherits that same bound cwd
  # via fork/exec and every relative write after this point is immune to
  # ANY later swap of the name "60-Maps" in the parent -- this is exactly
  # why the corpus-root copy above is airtight once cd'd. The remaining
  # window is JUST the gap between mkdir returning and cd running: a
  # genuinely-fresh mkdir can only ever be EMPTY, so verifying that
  # immediately after cd catches a swap onto any already-populated
  # substitute. ponytail: a decoy target pre-staged as an empty directory
  # elsewhere would still pass this check -- closing that needs an
  # openat()-style atomic create+enter bash does not expose; upgrade path is
  # a small native helper (mkdirat/O_DIRECTORY) if this residual is ever
  # judged worth it.
  ( cd "$VAULT_DIR" && _verify_fs_id "maps-dir parent" "." "$MAPS_PARENT_ID" \
      && mkdir "$MAPS_LEAF" \
      && cd "$MAPS_LEAF" \
      && [ -z "$(ls -A . 2>/dev/null)" ] \
      && node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
           --report "$REPORT_ABS" --out "./$SLUG.md" --title "$TITLE" --slug "$SLUG" \
           ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "$SOURCE_GRAPH_ABS" ) \
    || { echo "refresh-graph-map: publish failed or refused -- maps-dir did not exist at preflight and could not be safely created (see output above, HIMMEL-1704)" >&2; exit 1; }
else
  node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
    --report "$REPORT" --out "$OUT_NOTE" --title "$TITLE" --slug "$SLUG" \
    ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "$GRAPHIFY_OUT_NAME/graph.json"
fi

_promote_lock_release   # eager release after the report is fully consumed; EXIT trap = backstop
echo "refresh-graph-map: published $OUT_NOTE" >&2
