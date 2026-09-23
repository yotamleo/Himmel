#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows, jq only
# (no sha256sum/shasum requirement of its own -- prov_sha_file/prov_sha_json,
# reused from provenance.sh, bring their own hasher fallback).
#
# provenance-read.sh -- reads and interprets the install-provenance ledger
# written by provenance.sh (HIMMEL-3332 S6). scripts/uninstall.sh sources this
# to decide, per recorded artifact, whether uninstall owns it (remove/restore)
# or must leave it alone (keep/skip/heuristic). It never writes install-* rows;
# it writes only the uninstall-* rows (uninstall-begin, removed/restored/kept/
# failed, uninstall-end) via prov_read_session_begin/_outcome/_session_end,
# reusing provenance.sh's private _prov_append/_prov_now/_prov_new_iid so those
# rows land byte-shaped the same way the writer's own rows do.
#
# SOURCE it (it sets no shell options, defines only prov_read_* / _provread_*
# names):
#
#   . "$SCRIPT_DIR/lib/provenance-read.sh"
#   prov_read_load
#   case "$PROV_READ_STATE" in
#     ok) ... prov_read_units --path "$f" | while read -r ...; do
#             prov_read_verdict "$unit" ...
#         done ;;
#     missing|unparsable|foreign) echo "$PROV_READ_REASON" ;;
#   esac
#   prov_read_cleanup
#
# Design contract: HIMMEL-3332-install-provenance.md (spec) + the S6 design
# note (ledger facts, fold, verdict, excision, this API) -- read those before
# touching the fold/verdict logic below, they are not re-derived here.

# guard double-source
# shellcheck disable=SC2317  # the exit is reached only when EXECUTED rather than sourced
if [ -n "${_PROV_READ_LIB_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_PROV_READ_LIB_LOADED=1

_PROVREAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _provread_guarded <cmd> [args] -- <path>... -- every destructive site here
# (a removal, or an mv over a target) goes through uninstall.sh's `guarded`
# when the sourcing script defines it (HIMMEL-3415: it re-judges each path
# against the real home at the moment of use and exits rc=3 on refusal);
# otherwise the command just runs. Temp-file cleanups stay bare.
_provread_guarded() {
    if declare -F guarded >/dev/null 2>&1; then guarded "$@"; else "$@"; fi
}
# shellcheck source=scripts/lib/provenance.sh
. "$_PROVREAD_LIB_DIR/provenance.sh"
# shellcheck source=scripts/lib/provenance-identity.sh
. "$_PROVREAD_LIB_DIR/provenance-identity.sh"

_provread_err() { printf 'provenance-read: %s\n' "$*" >&2; }

# ── jq programs (kept as heredoc constants; both take the raw ledger / the
#    valid-rows JSONL on stdin and never loop per-row in shell) ─────────────

# Program 1: parse the ledger + classify load state, in one pass. Reads the
# WHOLE FILE as a single raw string (-R -s), splits it into physical lines
# itself so bad-row counts and _line numbers match the file's real line
# numbers. Prints the header object first, then (state==ok only) each valid
# row, annotated with its physical line number.
read -r -d '' _PROVREAD_LOAD_JQ <<'JQ'
def is_row($p): ($p|type)=="object" and ($p|has("op")) and (($p.op)|type=="string");
. as $raw
| ($raw | split("\n")) as $rawlines
| (if (($rawlines|length) > 0 and ($rawlines[-1] == "")) then $rawlines[0:-1] else $rawlines end) as $lines
| ([ range(0; ($lines|length)) as $i
     | ($lines[$i]) as $l
     | (try ($l | fromjson) catch null) as $p
     | if ($p != null and is_row($p)) then ($p + {_line: ($i+1)}) else null end
   ]) as $parsed
| ([$parsed[] | select(. != null)]) as $valid
| ($lines | length) as $total
| ($valid | length) as $nvalid
| ($total - $nvalid) as $bad
| ( if $nvalid == 0 then
      {state:"unparsable", reason:"no valid rows in the ledger", rows:$nvalid, bad_rows:$bad, partial:0}
    elif ($valid[0].op != "install-begin") then
      {state:"unparsable", reason:"the first row is not install-begin", rows:$nvalid, bad_rows:$bad, partial:0}
    else
      ([$valid[] | select(.op=="install-begin")]) as $begins
      | ([$begins[] | select((.home // "") != $home)] | first) as $foreign
      | if $foreign != null then
          {state:"foreign", reason:("ledger home " + ($foreign.home // "?") + " does not match current home " + $home),
           rows:$nvalid, bad_rows:$bad, partial:0}
        else
          ($begins[-1]) as $lastbegin
          | ([$valid[] | select(.op=="install-end") | .iid]) as $endids
          | (if ($endids | index($lastbegin.iid)) then 0 else 1 end) as $partial
          | {state:"ok",
             reason:(if $partial==1 then "the last install did not finish (no install-end); proceeding" else "" end),
             rows:$nvalid, bad_rows:$bad, partial:$partial}
        end
    end
  ) as $header
| $header, (if $header.state=="ok" then $valid[] else empty end)
JQ

# Program 2: fold artifact rows into units. Input: a JSON ARRAY (slurped) of
# valid rows already filtered to the artifact ops. See the design doc "Fold"
# section for the grouping/eff_pre/eff_post/ours rules this implements.
read -r -d '' _PROVREAD_FOLD_JQ <<'JQ'
# git-hook is not a register kind (HIMMEL-3525 Q4): a hook is a file, and a
# writer that lands will record it as kind file.
def is_register_kind: . as $k | (["plugin","marketplace","mcp","collection","job","unit","tool"] | index($k)) != null;
def presha(r): if (r|has("pre"))|not then null elif r.pre.state=="absent" then "ABSENT" else r.pre.sha end;
def extra_fields(r): r | del(.t,.iid,.op,.kind,.path,.unit,.scope,.class,.pre,.post,.writer,.manifest_row,._line);
def refline(r): (r.iid) + ":" + ((r._line)|tostring);
def eff_pre_of($N):
  if ($N|length)==0 then null
  else
    ( reduce range(1;($N|length)) as $i
        ( {pre:$N[0].pre};
          if presha($N[$i]) != (($N[$i-1].post.sha) // null) then {pre:$N[$i].pre} else . end
        )
    ).pre
  end;
def group_key(r):
  if (r.kind|is_register_kind) then ["reg", r.kind, (r.unit // "")]
  else ["path", (r.path // ""), (r.unit // "")]
  end;
def build_chains($rows):
  reduce $rows[] as $row
    ( [];
      . as $chains
      | (presha($row)) as $ps
      | ([range(0;($chains|length)) | select($chains[.].cur == $ps)] | first) as $idx
      | if $idx != null then
          $chains | .[$idx] = {eff_pre: $chains[$idx].eff_pre, cur: $row.post.sha, last: $row, ops: ($chains[$idx].ops + [$row.op]), cc: ($chains[$idx].cc or ($row.container_created == true))}
        else
          $chains + [{eff_pre: (if ($row|has("pre")) then $row.pre else null end), cur: $row.post.sha, last: $row, ops: [$row.op], cc: ($row.container_created == true)}]
        end
    );
(map(select(.kind=="json-elem"))) as $elemrows
| (map(select(.kind!="json-elem"))) as $otherrows
| ( $otherrows | group_by(group_key(.)) | map(
      . as $rows
      | ($rows[0].kind) as $kind
      | ($kind|is_register_kind) as $isreg
      | ($rows | map(select(.op != "noop"))) as $N
      | ($rows[-1]) as $lastRow
      | (if ($N|length) > 0 then $N[-1] else $lastRow end) as $lastForFields
      | {
          key: group_key($rows[0]), kind: $kind,
          path: ($rows[0].path // null), unit: ($rows[0].unit // null),
          class: ($lastForFields.class // null), scope: ($lastForFields.scope // null), row: ($lastForFields.manifest_row // null),
          governed: (($N|length) > 0),
          preexisted_only: (if ($N|length)==0 then ($rows | any(.preexisted==true)) else false end),
          ours: (if $isreg then ($rows | any(.preexisted==false)) else null end),
          # HIMMEL-3525 §4.1: the identities himmel recorded for registrations
          # IT created. A later preexisted=true row (a re-run over a
          # registration the user re-pointed) must never join this set.
          ours_ids: (if $isreg then ([ $rows[] | select(.preexisted==false and .identity_v!=null and .post.sha!=null) | .post.sha ] | unique) else null end),
          eff_pre: (if ($N|length)>0 then eff_pre_of($N) else null end),
          eff_post: (if ($N|length)>0 then $N[-1].post else $lastRow.post end),
          fields: extra_fields($lastForFields),
          ref: refline($lastForFields),
          ops: [$rows[]|.op]
        }
  ) ) as $foldOther
| ( $elemrows | group_by([(.path//""),(.unit//"")]) | map(
      . as $rows
      | ($rows[0].path) as $path | ($rows[0].unit) as $unit
      | ($rows | map(select(.op != "noop"))) as $nonnoop
      | build_chains($nonnoop) as $chains
      | ($chains | map(.cur)) as $curs
      | ( $chains | map(
            {
              key: [$path, $unit, .cur], kind:"json-elem", path:$path, unit:$unit,
              class: (.last.class // null), scope: (.last.scope // null), row: (.last.manifest_row // null),
              governed: true, preexisted_only: false, ours: null,
              eff_pre: .eff_pre, eff_post: .last.post,
              fields: (extra_fields(.last) + {elem_sha: .cur} + (if .cc then {container_created: true} else {} end)),
              ref: refline(.last), ops: .ops
            }
        ) ) as $chainUnits
      | ( $rows
          | map(select(.op=="noop" and (has("elem_sha")) and (((.elem_sha) as $e | ($curs|index($e))) == null)))
          | group_by(.elem_sha)
          | map(
              . as $g | ($g[-1]) as $last
              | {
                  key: [$path, $unit, "noop", $last.elem_sha], kind:"json-elem", path:$path, unit:$unit,
                  class: ($last.class // null), scope: ($last.scope // null), row: ($last.manifest_row // null),
                  governed: false, preexisted_only: ($g | any(.preexisted==true)), ours: null,
                  eff_pre: null, eff_post: $last.post,
                  fields: (extra_fields($last) + {elem_sha: $last.elem_sha}),
                  ref: refline($last), ops: ["noop"]
                }
          )
        ) as $orphanUnits
      | ($chainUnits + $orphanUnits)
  ) | flatten(1) ) as $foldElem
| ($foldOther + $foldElem)[]
JQ

# _provread_ptr_path <pointer> -- RFC 6901-ish JSON Pointer ("/env/KEY", "~1"
# -> "/", "~0" -> "~") turned into a jq path array literal (JSON on stdout).
_provread_ptr_path() {
    jq -nc --arg p "${1:-}" \
        '$p | if . == "" then [] else (ltrimstr("/") | split("/") | map(gsub("~1";"/") | gsub("~0";"~"))) end'
}

# ── prov_read_load ───────────────────────────────────────────────────────
# Sets PROV_READ_STATE (ok|missing|unparsable|foreign), PROV_READ_REASON,
# PROV_READ_ROWS, PROV_READ_BAD_ROWS, PROV_READ_PARTIAL (0|1) and
# PROV_READ_FOLD (a mktemp'd file of fold-unit JSONL; empty unless ok). rc 0
# always, unless jq is missing (rc 1).
prov_read_load() {
    PROV_READ_STATE="" PROV_READ_REASON="" PROV_READ_ROWS=0 PROV_READ_BAD_ROWS=0 PROV_READ_PARTIAL=0
    command -v jq >/dev/null 2>&1 || { _provread_err "jq required"; return 1; }
    PROV_READ_FOLD=$(mktemp "${TMPDIR:-/tmp}/prov-read-fold.XXXXXX") || { _provread_err "mktemp failed"; return 1; }
    : > "$PROV_READ_FOLD"

    local ledger home_now
    ledger=$(prov_ledger_path) || { PROV_READ_STATE="missing"; PROV_READ_REASON="no ledger dir"; return 0; }

    if [ -L "$ledger" ]; then
        PROV_READ_STATE="unparsable"; PROV_READ_REASON="symlinked ledger at $ledger"
        return 0
    fi
    if [ ! -e "$ledger" ]; then
        PROV_READ_STATE="missing"; PROV_READ_REASON="no ledger at $ledger"
        return 0
    fi

    home_now=$(canon_path_native "${HOME:-}" 2>/dev/null) || home_now="${HOME:-}"

    local out header
    out=$(mktemp "${TMPDIR:-/tmp}/prov-read-load.XXXXXX") || { _provread_err "mktemp failed"; return 1; }
    if ! jq -R -s -c --arg home "$home_now" "$_PROVREAD_LOAD_JQ" "$ledger" > "$out" 2>/dev/null; then
        rm -f "$out"
        PROV_READ_STATE="unparsable"; PROV_READ_REASON="the ledger could not be parsed"
        return 0
    fi
    header=$(head -n1 "$out")
    PROV_READ_STATE=$(printf '%s' "$header" | jq -r '.state')
    # shellcheck disable=SC2034  # public API: read by the sourcing caller (uninstall.sh), not this file
    PROV_READ_REASON=$(printf '%s' "$header" | jq -r '.reason')
    PROV_READ_ROWS=$(printf '%s' "$header" | jq -r '.rows')
    PROV_READ_BAD_ROWS=$(printf '%s' "$header" | jq -r '.bad_rows')
    # shellcheck disable=SC2034  # public API: read by the sourcing caller (uninstall.sh), not this file
    PROV_READ_PARTIAL=$(printf '%s' "$header" | jq -r '.partial')

    if [ "$PROV_READ_STATE" = "ok" ]; then
        local _fold_rc0 _fold_rc1 _fold_rc2
        # artifact rows only: the op vocabulary from _PROV_OPS in provenance.sh,
        # minus "noop" exclusion (noop rows are handled inside the fold itself)
        tail -n +2 "$out" | jq -c 'select(.op as $o | (["create","replace","insert","append","register","link","noop"] | index($o)) != null)' \
            | jq -s -c "$_PROVREAD_FOLD_JQ" > "$PROV_READ_FOLD" 2>/dev/null
        # F1 (parent review): the pipeline's own rc is only the LAST stage's;
        # a failing tail/select/fold stage must fail closed rather than leave
        # state "ok" with a silently empty fold. Capture all three PIPESTATUS
        # slots in ONE bare assignment (bash 3.2-safe) -- any command run
        # after the pipeline, even a `[` test, overwrites PIPESTATUS with its
        # own single-element status first.
        _fold_rc0="${PIPESTATUS[0]}" _fold_rc1="${PIPESTATUS[1]}" _fold_rc2="${PIPESTATUS[2]}"
        if [ "$_fold_rc0" -ne 0 ] || [ "$_fold_rc1" -ne 0 ] || [ "$_fold_rc2" -ne 0 ]; then
            PROV_READ_STATE="unparsable"
            # shellcheck disable=SC2034  # public API: read by the sourcing caller (uninstall.sh), not this file
            PROV_READ_REASON="the ledger could not be folded"
            : > "$PROV_READ_FOLD"
        fi
    fi
    rm -f "$out"
    return 0
}

# prov_read_cleanup -- removes PROV_READ_FOLD's temp file and the identity
# reader's per-run cache beside it.
prov_read_cleanup() {
    [ -n "${PROV_READ_FOLD:-}" ] && [ -d "$PROV_READ_FOLD.identity.d" ] && rm -rf "$PROV_READ_FOLD.identity.d"
    [ -n "${PROV_READ_FOLD:-}" ] && [ -f "$PROV_READ_FOLD" ] && rm -f "$PROV_READ_FOLD"
    PROV_READ_FOLD=""
}

# prov_read_units [--path P] [--row R] [--kind K]... -- prints matching fold
# units (JSONL) from PROV_READ_FOLD. --path compares canonically.
prov_read_units() {
    local path="" row="" kinds="[]" have_path=0 have_row=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --path) path=$(_prov_abs_path "$2" 2>/dev/null || printf '%s' "$2"); have_path=1; shift 2 ;;
            --row)  row="$2"; have_row=1; shift 2 ;;
            --kind) kinds=$(jq -nc --argjson acc "$kinds" --arg k "$2" '$acc + [$k]'); shift 2 ;;
            *) _provread_err "prov_read_units: unknown option $1"; return 2 ;;
        esac
    done
    [ -n "${PROV_READ_FOLD:-}" ] && [ -f "$PROV_READ_FOLD" ] || return 0
    jq -c --arg path "$path" --argjson havepath "$have_path" --arg row "$row" --argjson haverow "$have_row" --argjson kinds "$kinds" \
        'select(($havepath==0) or (.path == $path))
         | select(($haverow==0) or ((.row // "") == $row))
         | select(($kinds|length)==0 or (.kind as $k | ($kinds | index($k)) != null))' \
        "$PROV_READ_FOLD"
}

# ── current-state readers ────────────────────────────────────────────────

# _provread_json_present <file> <pointer> -- prints `{"present":true,"value":V}`
# or `{"present":false}`; a missing/invalid file counts as not-present.
_provread_json_present() {
    local file="$1" ptr="$2" patharr
    if [ ! -f "$file" ] || [ -L "$file" ]; then printf '{"present":false}'; return 0; fi
    patharr=$(_provread_ptr_path "$ptr") || return 1
    jq -c --argjson p "$patharr" '
        def haspath($p):
          if ($p|length)==0 then true
          else reduce $p[0:-1][] as $k (.; if (type=="object" and has($k)) then .[$k] else null end)
               | (type=="object") and has($p[-1])
          end;
        if haspath($p) then {present:true, value:getpath($p)} else {present:false} end
    ' "$file" 2>/dev/null || printf '{"present":false}'
}

# _provread_json_elem_locate <container-json> <elemsha> -- prints a jq path
# array (relative to the container), e.g. "[2]" or "[1,\"hooks\",0]", rc 0; or
# rc 1 with no output if no element matches. Two levels deep: a top-level
# array item, or (one level down) an item of that top-level item's own
# `.hooks` array. This covers both shapes wire-pretooluse-hooks.sh's single
# writer produces today -- the PreToolUse trio, whose tracked element IS the
# top-level stanza, and the SessionStart hook, whose tracked element is the
# hook OBJECT nested inside a stanza's `.hooks[]` (HIMMEL-3332 S6: without
# this, a SessionStart unit's current element is never found and every
# verdict on it reads `keep already-absent`, which then falsely PROTECTS it
# and skips the whole hooks helper -- test-e2e-symmetry.sh caught this).
# ponytail: fixed at exactly two levels with a hardcoded `.hooks` field name,
# matching this codebase's one json-elem writer -- not a general recursive
# JSON walk; a future writer that nests elements any other way needs its own
# case added here.
_provread_json_elem_locate() {
    local container="$1" elemsha="$2" n i elem esha sub m j sj
    n=$(printf '%s' "$container" | jq -r 'if type=="array" then length else 0 end')
    i=0
    while [ "$i" -lt "$n" ]; do
        elem=$(printf '%s' "$container" | jq -c ".[$i]")
        esha=$(prov_sha_json "$elem" 2>/dev/null)
        if [ "$esha" = "$elemsha" ]; then printf '[%d]' "$i"; return 0; fi
        sub=$(printf '%s' "$elem" | jq -c 'if (type=="object" and has("hooks") and (.hooks|type=="array")) then .hooks else null end')
        if [ "$sub" != "null" ]; then
            m=$(printf '%s' "$sub" | jq -r 'length')
            j=0
            while [ "$j" -lt "$m" ]; do
                sj=$(printf '%s' "$sub" | jq -c ".[$j]")
                esha=$(prov_sha_json "$sj" 2>/dev/null)
                if [ "$esha" = "$elemsha" ]; then printf '[%d,"hooks",%d]' "$i" "$j"; return 0; fi
                j=$((j + 1))
            done
        fi
        i=$((i + 1))
    done
    return 1
}

# prov_read_current <unit-json> -- prints the current sha / ABSENT / SYMLINK.
prov_read_current() {
    local u="$1" kind path ptr elemsha
    kind=$(printf '%s' "$u" | jq -r '.kind')
    path=$(printf '%s' "$u" | jq -r '.path // ""')
    case "$kind" in
        file)
            if [ -L "$path" ]; then printf 'SYMLINK'
            elif [ -f "$path" ]; then prov_sha_file "$path"
            else printf 'ABSENT'
            fi
            ;;
        json-key)
            ptr=$(printf '%s' "$u" | jq -r '.unit // ""')
            local pj present value
            pj=$(_provread_json_present "$path" "$ptr")
            present=$(printf '%s' "$pj" | jq -r '.present')
            if [ "$present" = "true" ]; then
                value=$(printf '%s' "$pj" | jq -c '.value')
                prov_sha_json "$value"
            else
                printf 'ABSENT'
            fi
            ;;
        json-elem)
            ptr=$(printf '%s' "$u" | jq -r '.unit // ""')
            elemsha=$(printf '%s' "$u" | jq -r '.fields.elem_sha // .eff_post.sha // ""')
            local pj present container
            pj=$(_provread_json_present "$path" "$ptr")
            present=$(printf '%s' "$pj" | jq -r '.present')
            if [ "$present" != "true" ]; then printf 'ABSENT'; return 0; fi
            container=$(printf '%s' "$pj" | jq -c '.value')
            if _provread_json_elem_locate "$container" "$elemsha" >/dev/null; then
                printf '%s' "$elemsha"
            else
                printf 'ABSENT'
            fi
            ;;
        *)
            printf 'ABSENT'
            ;;
    esac
}

# _provread_register_verdict <unit-json> <kind> -- the verdict for a register
# unit himmel created (ours=true), HIMMEL-3525 design §4.2 and §5. The live
# identity token must be one himmel recorded for a registration it created
# (ours_ids); anything else keeps. The writer records the token with
# --post-text, which stores its sha, so the live token is hashed once more
# before the lookup. A row with no recorded identity (a legacy ledger, or a
# kind with no reader yet) takes the per-kind default of §5.
_provread_register_verdict() {
    local u="$1" kind="$2" ids live rc live_sha
    ids=$(printf '%s' "$u" | jq -c '.ours_ids // []')
    if [ "$ids" != "[]" ]; then
        live=$(prov_identity_live "$kind" "$u"); rc=$?
        if [ "$rc" -eq 0 ]; then
            case "$live" in
                UNREADABLE) printf 'keep identity-unreadable\n'; return 0 ;;
                ABSENT)     printf 'keep already-absent\n'; return 0 ;;
            esac
            live_sha=$(prov_sha_text "$live") || { printf 'keep identity-unreadable\n'; return 0; }
            if printf '%s' "$ids" | jq -e --arg s "$live_sha" 'index($s) != null' >/dev/null 2>&1; then
                printf 'remove ours\n'
            else
                printf 'keep user-modified\n'
            fi
            return 0
        fi
    fi
    case "$kind" in
        collection) _provread_collection_salvage "$u" ;;
        *) printf 'remove ours-unverified\n' ;;
    esac
}

# _provread_collection_salvage <unit-json> -- a legacy collection row recorded
# --post-text <path arg>, so post.sha = sha(path). Compare it with the live
# Path (as qmd prints it, or canonicalized): equal -> remove ours; different
# (or nothing recorded) -> keep user-modified; qmd unreadable -> keep.
_provread_collection_salvage() {
    local u="$1" name post_sha
    name=$(printf '%s' "$u" | jq -r '.unit // ""')
    post_sha=$(printf '%s' "$u" | jq -r '.eff_post.sha // ""')
    _provid_qmd_show "$name"
    case "$_PROVID_STATE" in
        UNREADABLE) printf 'keep identity-unreadable\n'; return 0 ;;
        ABSENT)     printf 'keep already-absent\n'; return 0 ;;
    esac
    if [ -n "$post_sha" ] && { [ "$(prov_sha_text "$_PROVID_PATH")" = "$post_sha" ] \
            || [ "$(prov_sha_text "$(_provid_canon_path "$_PROVID_PATH")")" = "$post_sha" ]; }; then
        printf 'remove ours\n'
    else
        printf 'keep user-modified\n'
    fi
}

# prov_read_verdict <unit-json> -- prints "<action> <reason>".
# action in remove restore keep skip heuristic; see the design doc "Verdict"
# section for the order of tests this follows.
prov_read_verdict() {
    local u="$1" class kind governed ours preexisted_only cur eff_post_sha eff_pre_state backup
    class=$(printf '%s' "$u" | jq -r '.class // ""')
    kind=$(printf '%s' "$u" | jq -r '.kind')
    governed=$(printf '%s' "$u" | jq -r '.governed')
    ours=$(printf '%s' "$u" | jq -r '.ours')
    preexisted_only=$(printf '%s' "$u" | jq -r '.preexisted_only')

    if [ "$kind" = "tool" ]; then printf 'keep class-keep\n'; return 0; fi
    case "$kind" in
        # the unit's register row carries no preexisted flag; its teardown takes
        # ownership from the hash-checked file row at the unit path (§3.5)
        unit) printf 'skip delegated-file-row\n'; return 0 ;;
        plugin|marketplace|mcp|collection|job)
            if [ "$ours" != "true" ]; then printf 'keep preexisted\n'; return 0; fi
            _provread_register_verdict "$u" "$kind"
            return 0 ;;
    esac
    if [ "$class" = "state" ]; then printf 'skip class-state\n'; return 0; fi
    if [ "$class" = "keep" ]; then printf 'keep class-keep\n'; return 0; fi
    if [ "$governed" != "true" ]; then
        if [ "$preexisted_only" = "true" ]; then printf 'keep noop-preexisted\n'
        # ponytail: the design leaves the ungoverned/non-preexisted-only case
        # to the caller's own heuristic; we surface it as one action word with
        # no fold-derived reason (the caller decides, the ledger stays silent).
        else printf 'heuristic heuristic\n'
        fi
        return 0
    fi
    cur=$(prov_read_current "$u") || return 1
    if [ "$cur" = "ABSENT" ]; then printf 'keep already-absent\n'; return 0; fi
    eff_post_sha=$(printf '%s' "$u" | jq -r '.eff_post.sha // ""')
    if [ "$cur" != "$eff_post_sha" ]; then printf 'keep user-modified\n'; return 0; fi
    # F2 (parent review): `.eff_pre.state // "absent"` fail-coalesces a NULL
    # or missing eff_pre (no recorded pre-state at all) into the same
    # "absent" as an EXPLICIT `{"state":"absent"}` -- only the latter is real
    # evidence the unit didn't exist before himmel; a missing eff_pre must
    # fall through to the backup check below (fail closed to keep no-backup).
    eff_pre_state=$(printf '%s' "$u" | jq -r 'if (.eff_pre != null) and (.eff_pre.state == "absent") then "absent" else "" end')
    if [ "$eff_pre_state" = "absent" ]; then printf 'remove ours\n'; return 0; fi
    backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
    if [ -n "$backup" ] && [ -r "$backup" ]; then printf 'restore ours\n'; else printf 'keep no-backup\n'; fi
}

# _provread_atomic_write <target-file> -- writes stdin to a temp file beside
# <target-file>, keeps its mode, then mv's it into place (the unwire-* idiom).
_provread_atomic_write() {
    local target="$1" tmp mode
    tmp="$target.provread.$$.tmp"
    cat > "$tmp" || return 1
    if [ ! -s "$tmp" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
        _provread_err "_provread_atomic_write: refusing empty/invalid JSON for $target"
        rm -f "$tmp"
        return 1
    fi
    mode=$(_prov_mode "$target" 2>/dev/null) || mode=""
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    _provread_guarded mv -f -- "$tmp" "$target"
}

# prov_read_apply <unit-json> <remove|restore> [--dry-run] -- performs the
# excision for kinds json-key, json-elem, file. rc 0 done, rc 1 failed
# (stderr), rc 2 unsupported kind.
prov_read_apply() {
    local u="$1" action="$2" dry=0 kind path ptr
    shift 2
    while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=1; shift ;; *) shift ;; esac; done
    kind=$(printf '%s' "$u" | jq -r '.kind')
    path=$(printf '%s' "$u" | jq -r '.path // ""')
    ptr=$(printf '%s' "$u" | jq -r '.unit // ""')

    case "$kind" in file|json-key|json-elem) ;; *) _provread_err "prov_read_apply: unsupported kind $kind"; return 2 ;; esac
    case "$action" in remove|restore) ;; *) _provread_err "prov_read_apply: action must be remove or restore"; return 2 ;; esac

    if [ "$dry" = 1 ]; then
        if [ -n "$path" ]; then printf 'DRY: would %s %s %s %s\n' "$action" "$kind" "$ptr" "$path"
        else printf 'DRY: would %s %s %s\n' "$action" "$kind" "$ptr"
        fi
        return 0
    fi

    case "$kind" in
        file)
            if [ "$action" = "remove" ]; then
                if [ -f "$path" ] && [ ! -L "$path" ]; then _provread_guarded rm -f -- "$path" || { _provread_err "cannot remove $path"; return 1; }; fi
                return 0
            fi
            local backup mode eff_sha
            backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
            mode=$(printf '%s' "$u" | jq -r '.eff_pre.mode // empty')
            eff_sha=$(printf '%s' "$u" | jq -r '.eff_pre.sha // empty')
            if [ -z "$backup" ] || [ ! -f "$backup" ]; then _provread_err "no readable backup for $path"; return 1; fi
            local tmp
            tmp="$path.provread.$$.tmp"
            cp -p "$backup" "$tmp" || { _provread_err "cannot stage restore of $path"; return 1; }
            # HIMMEL-3332 S6 R2-codex3: verify the STAGED copy's sha BEFORE it
            # ever replaces the target -- a corrupted backup must be caught
            # here, not after it has already overwritten a working file.
            if [ -n "$eff_sha" ] && [ "$(prov_sha_file "$tmp" 2>/dev/null)" != "$eff_sha" ]; then
                _provread_err "backup for $path does not match its recorded sha"
                rm -f "$tmp"
                return 1
            fi
            [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
            _provread_guarded mv -f -- "$tmp" "$path" || { _provread_err "cannot restore $path"; return 1; }
            return 0
            ;;
        json-key)
            local patharr
            patharr=$(_provread_ptr_path "$ptr") || return 1
            if [ ! -f "$path" ] || ! jq -e . "$path" >/dev/null 2>&1; then _provread_err "$path is not valid JSON -- refusing to modify"; return 1; fi
            if [ "$action" = "remove" ]; then
                jq --argjson p "$patharr" 'delpaths([$p])' "$path" | _provread_atomic_write "$path" || { _provread_err "cannot write $path"; return 1; }
            else
                local backup val eff_sha
                backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
                eff_sha=$(printf '%s' "$u" | jq -r '.eff_pre.sha // empty')
                if [ -z "$backup" ] || [ ! -f "$backup" ]; then _provread_err "no readable backup for $ptr in $path"; return 1; fi
                val=$(cat "$backup") || { _provread_err "cannot read backup $backup"; return 1; }
                # HIMMEL-3332 S6 R2-codex3: verify the backup's content hash
                # against eff_pre.sha (the writer computes it with
                # prov_sha_json over the same pre-value, provenance.sh's
                # _prov_body json-key case) BEFORE it is spliced into the
                # target -- a corrupted-but-valid-JSON backup must not
                # overwrite it.
                if [ -n "$eff_sha" ] && [ "$(prov_sha_json "$val" 2>/dev/null)" != "$eff_sha" ]; then
                    _provread_err "backup for $ptr in $path does not match its recorded sha"
                    return 1
                fi
                jq --argjson p "$patharr" --argjson v "$val" 'setpath($p; $v)' "$path" | _provread_atomic_write "$path" || { _provread_err "cannot write $path"; return 1; }
            fi
            return 0
            ;;
        json-elem)
            local patharr elemsha created
            patharr=$(_provread_ptr_path "$ptr") || return 1
            elemsha=$(printf '%s' "$u" | jq -r '.fields.elem_sha // .eff_post.sha // ""')
            created=$(printf '%s' "$u" | jq -r '.fields.container_created // false')
            if [ ! -f "$path" ] || ! jq -e . "$path" >/dev/null 2>&1; then _provread_err "$path is not valid JSON -- refusing to modify"; return 1; fi
            if [ "$action" = "remove" ]; then
                # element identity is a content hash (prov_sha_json), which jq
                # cannot compute the same way our hasher does -- locate it in
                # shell (flat, or nested one level under `.hooks`; see
                # _provread_json_elem_locate) and splice by its jq path.
                local container relpath depth
                container=$(jq -c --argjson p "$patharr" 'getpath($p)' "$path")
                relpath=$(_provread_json_elem_locate "$container" "$elemsha") || relpath=""
                if [ -n "$relpath" ]; then
                    depth=$(printf '%s' "$relpath" | jq 'length')
                    if [ "$depth" -eq 1 ]; then
                        local idx
                        idx=$(printf '%s' "$relpath" | jq '.[0]')
                        jq --argjson p "$patharr" --argjson idx "$idx" --argjson created "$created" '
                            getpath($p) as $c
                            | (setpath($p; ([$c[0:$idx][], $c[($idx+1):][]]))) as $doc
                            | ( ($doc | getpath($p)) ) as $newc
                            | if ($created and ($newc|length)==0) then delpaths([$p]) else $doc end
                        ' "$path" | _provread_atomic_write "$path" || { _provread_err "cannot write $path"; return 1; }
                    else
                        # nested (e.g. a SessionStart hook OBJECT inside a
                        # stanza's .hooks[]): delete the leaf, then -- exactly
                        # like unwire-pretooluse-hooks.sh -- unconditionally
                        # prune the wrapper stanza if its .hooks[] is now empty.
                        local full stanzapath
                        full=$(jq -c -n --argjson p "$patharr" --argjson r "$relpath" '$p + $r')
                        stanzapath=$(jq -c -n --argjson p "$patharr" --argjson r "$relpath" '$p + [$r[0]]')
                        jq --argjson full "$full" --argjson sp "$stanzapath" '
                            delpaths([$full])
                            | (getpath($sp).hooks // []) as $h
                            | if ($h|length)==0 then delpaths([$sp]) else . end
                        ' "$path" | _provread_atomic_write "$path" || { _provread_err "cannot write $path"; return 1; }
                    fi
                fi
            else
                local backup val container relpath eff_sha
                backup=$(printf '%s' "$u" | jq -r '.eff_pre.backup // empty')
                eff_sha=$(printf '%s' "$u" | jq -r '.eff_pre.sha // empty')
                if [ -z "$backup" ] || [ ! -f "$backup" ]; then _provread_err "no readable backup for $ptr in $path"; return 1; fi
                val=$(cat "$backup") || { _provread_err "cannot read backup $backup"; return 1; }
                # HIMMEL-3386: same guard as the json-key restore above -- the
                # writer hashes a json-elem pre-value with prov_sha_json too
                # (_prov_body's json case), so a corrupted-but-valid-JSON
                # backup is refused BEFORE it is spliced into the array.
                if [ -n "$eff_sha" ] && [ "$(prov_sha_json "$val" 2>/dev/null)" != "$eff_sha" ]; then
                    _provread_err "backup for $ptr in $path does not match its recorded sha"
                    return 1
                fi
                container=$(jq -c --argjson p "$patharr" 'getpath($p)' "$path")
                relpath=$(_provread_json_elem_locate "$container" "$elemsha") || relpath=""
                [ -n "$relpath" ] || { _provread_err "current element not found in $ptr of $path"; return 1; }
                jq --argjson p "$patharr" --argjson r "$relpath" --argjson v "$val" \
                    'setpath($p + $r; $v)' "$path" | _provread_atomic_write "$path" || { _provread_err "cannot write $path"; return 1; }
            fi
            return 0
            ;;
    esac
}

# prov_read_drop_empty_if_ours <settings-file> <key> [--dry-run] -- drop the
# now-empty top-level object <key> (`env`, `hooks`), but ONLY when the fold shows
# a governed /<key> unit himmel itself created (eff_pre absent).
prov_read_drop_empty_if_ours() {
    local file="$1" key="$2" dry=0
    shift 2
    while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=1; shift ;; *) shift ;; esac; done
    [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1 || return 0
    local is_empty
    is_empty=$(jq -r --arg k "$key" '(.[$k] // null) as $e | ($e != null and ($e|type)=="object" and ($e|length)==0)' "$file" 2>/dev/null)
    [ "$is_empty" = "true" ] || return 0
    local cpath created=no
    cpath=$(_prov_abs_path "$file" 2>/dev/null || printf '%s' "$file")
    if [ -n "${PROV_READ_FOLD:-}" ] && [ -f "$PROV_READ_FOLD" ]; then
        created=$(jq -r --arg path "$cpath" --arg unit "/$key" \
            'select(.path==$path and .unit==$unit and .governed==true and (.eff_pre != null) and (.eff_pre.state=="absent")) | "yes"' \
            "$PROV_READ_FOLD" | head -n1)
        [ -n "$created" ] || created=no
    fi
    [ "$created" = "yes" ] || return 0
    if [ "$dry" = 1 ]; then printf 'DRY: would remove now-empty /%s from %s\n' "$key" "$file"; return 0; fi
    jq --arg k "$key" 'del(.[$k])' "$file" | _provread_atomic_write "$file" || { _provread_err "cannot write $file"; return 1; }
}

# prov_read_drop_env_if_ours <settings-file> [--dry-run] -- the /env case.
prov_read_drop_env_if_ours() {
    local file="$1"
    shift
    prov_read_drop_empty_if_ours "$file" env "$@"
}

# ── uninstall session rows (written directly with _prov_append, like
#    prov_record's own private helpers -- these ops are NOT in _PROV_OPS) ──

_PROV_READ_IID="" _PROV_READ_MODE="" PROV_READ_N_REMOVED=0 PROV_READ_N_RESTORED=0
PROV_READ_N_KEPT=0 PROV_READ_N_FAILED=0 _PROV_READ_FAILED_BACKUPS="" _PROV_READ_DONE_BACKUPS=""

# prov_read_session_begin <wet|dry> <argv...> -- writes uninstall-begin. A
# no-op (no append, no ledger created) unless PROV_READ_STATE is ok.
prov_read_session_begin() {
    local mode="$1"
    shift
    _PROV_READ_MODE="$mode"
    PROV_READ_N_REMOVED=0 PROV_READ_N_RESTORED=0 PROV_READ_N_KEPT=0 PROV_READ_N_FAILED=0
    _PROV_READ_FAILED_BACKUPS=""
    _PROV_READ_DONE_BACKUPS=""
    [ "${PROV_READ_STATE:-}" = "ok" ] || return 0
    _PROV_READ_IID=$(_prov_new_iid)
    [ "$mode" = "dry" ] && return 0
    local argv='[]' a
    for a in "$@"; do argv=$(jq -nc --argjson acc "$argv" --arg v "$a" '$acc + [$v]') || return 1; done
    _prov_append "$(jq -nc --arg t "$(_prov_now)" --arg iid "$_PROV_READ_IID" --argjson argv "$argv" \
        --arg mode "$mode" --argjson rows "${PROV_READ_ROWS:-0}" --argjson bad "${PROV_READ_BAD_ROWS:-0}" \
        --argjson unknown "${PROV_READ_UNKNOWN_ROWS:-0}" \
        '{t:$t,iid:$iid,op:"uninstall-begin",argv:$argv,mode:$mode,ledger_rows:$rows,ledger_bad_rows:$bad,ledger_unknown_rows:$unknown}')" || return 1
}

# prov_read_outcome <removed|restored|kept|failed> <unit-json> <reason> [backup]
prov_read_outcome() {
    local status="$1" u="$2" reason="$3" backup="${4:-}"
    case "$status" in removed) PROV_READ_N_REMOVED=$((PROV_READ_N_REMOVED + 1))
            [ -n "$backup" ] && _PROV_READ_DONE_BACKUPS="$_PROV_READ_DONE_BACKUPS
$backup" ;;
        restored) PROV_READ_N_RESTORED=$((PROV_READ_N_RESTORED + 1))
            [ -n "$backup" ] && _PROV_READ_DONE_BACKUPS="$_PROV_READ_DONE_BACKUPS
$backup" ;;
        kept) PROV_READ_N_KEPT=$((PROV_READ_N_KEPT + 1)) ;;
        failed) PROV_READ_N_FAILED=$((PROV_READ_N_FAILED + 1))
            [ -n "$backup" ] && _PROV_READ_FAILED_BACKUPS="$_PROV_READ_FAILED_BACKUPS
$backup" ;;
        *) _provread_err "prov_read_outcome: bad status $status"; return 2 ;;
    esac
    [ "${_PROV_READ_MODE:-}" = "dry" ] && return 0
    [ -n "${_PROV_READ_IID:-}" ] || return 0
    local ref path unit kind
    ref=$(printf '%s' "$u" | jq -r '.ref // ""')
    path=$(printf '%s' "$u" | jq -r '.path // empty')
    unit=$(printf '%s' "$u" | jq -r '.unit // empty')
    kind=$(printf '%s' "$u" | jq -r '.kind // ""')
    _prov_append "$(jq -nc --arg t "$(_prov_now)" --arg iid "$_PROV_READ_IID" --arg op "$status" --arg ref "$ref" \
        --argjson path "$(_prov_str_or_null "$path")" --argjson unit "$(_prov_str_or_null "$unit")" \
        --arg kind "$kind" --arg reason "$reason" --argjson bk "$(_prov_str_or_null "$backup")" \
        '{t:$t,iid:$iid,op:$op,ref:$ref}
         + (if $path != null then {path:$path} else {} end)
         + (if $unit != null then {unit:$unit} else {} end)
         + {kind:$kind,reason:$reason}
         + (if $bk != null then {backup_used:$bk} else {} end)')" || return 1
}

# prov_read_session_end <ok|halted>
prov_read_session_end() {
    local status="$1"
    case "$status" in ok|halted) ;; *) _provread_err "prov_read_session_end: status must be ok|halted"; return 2 ;; esac
    if [ "${_PROV_READ_MODE:-}" != "dry" ] && [ -n "${_PROV_READ_IID:-}" ]; then
        _prov_append "$(jq -nc --arg t "$(_prov_now)" --arg iid "$_PROV_READ_IID" --arg status "$status" \
            --argjson removed "$PROV_READ_N_REMOVED" --argjson restored "$PROV_READ_N_RESTORED" \
            --argjson kept "$PROV_READ_N_KEPT" --argjson failed "$PROV_READ_N_FAILED" \
            '{t:$t,iid:$iid,op:"uninstall-end",status:$status,removed:$removed,restored:$restored,kept:$kept,failed:$failed}')" || return 1
    fi
    _PROV_READ_IID=""
}

# prov_read_prune_backups -- at a clean end: delete ONLY backup files a
# removed or restored outcome row of THIS session named (those units are
# done: the file's been put back or thrown away, so backup no longer needed).
# Everything else under provenance-backups/ -- a kept/no-backup unit's
# backup, a unit this run never touched, one predating per-file recording --
# is left alone; a later run may still need it. Refuses a symlinked backups
# dir.
prov_read_prune_backups() {
    local dir bdir f is_done done_list
    dir=$(prov_dir) || return 1
    bdir="$dir/provenance-backups"
    [ -e "$bdir" ] || return 0
    if [ -L "$bdir" ]; then _provread_err "refusing symlink $bdir"; return 1; fi
    # HIMMEL-3386: the done list is "\n<path>\n<path>..." -- pad it with a
    # trailing newline and match "\n<path>\n" so a finished foo.bak.extra
    # cannot authorise deleting foo.bak (whole entries, not a prefix).
    done_list="$_PROV_READ_DONE_BACKUPS
"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        is_done=0
        case "$done_list" in *"
$f
"*) is_done=1 ;; esac
        [ "$is_done" = 1 ] && _provread_guarded rm -f -- "$f"
    done <<EOF
$(find "$bdir" -type f 2>/dev/null)
EOF
    _provread_guarded : -- "$bdir"
    find "$bdir" -type d -empty -delete 2>/dev/null
    return 0
}

# prov_read_owned <outfile> -- writes uninstall-plugins.sh's --ledger-owned
# file (TAB-separated plugin/marketplace rows) from register units with
# ours=true.
prov_read_owned() {
    local outfile="$1"
    if [ -z "${PROV_READ_FOLD:-}" ] || [ ! -f "$PROV_READ_FOLD" ]; then : > "$outfile"; return 0; fi
    jq -r 'select(.ours==true and (.kind=="plugin" or .kind=="marketplace")) | [.kind, (.unit // ""), (.fields.cli_scope // "")] | @tsv' \
        "$PROV_READ_FOLD" > "$outfile"
}
