#!/usr/bin/env bash
# luna-upgrade-all.sh — multi-vault luna template upgrade sweep (HIMMEL-462).
#
# Discovers candidate luna-second-brain vaults from the registry
# (~/.claude/luna-vaults.json) and a depth-1 scan of configured roots,
# classifies each, and optionally sweeps or applies upgrades using the proven
# single-vault engine at templates/luna-second-brain/scripts/upgrade.sh.
#
# This is the MULTI-vault layer above upgrade.sh. It never reimplements any
# classification / 3-way-merge / fail-closed logic — all of that stays in
# upgrade.sh. We always shell out to HIMMEL's copy of upgrade.sh.
#
# Cross-platform note: bash 3.2-safe (no mapfile, no associative arrays,
# no GNU-only flags). Tested on Windows Git Bash (Git for Windows).
#
# Usage:
#   bash scripts/luna-upgrade-all.sh [sweep] [--roots <dirs>] [--registry <path>]
#       [--template-dir <path>] [--porcelain]
#   bash scripts/luna-upgrade-all.sh apply --vault <path> [--template-dir <path>]
#       [--force-unstamped]
#   bash scripts/luna-upgrade-all.sh restore --vault <path> [--from <ts>] [--list]
set -uo pipefail

# ---------------------------------------------------------------------------
# Manifest header field parser — BSD/macOS-sed-safe (C1 fix: HIMMEL-462).
# GNU sed treats \t in bracket-classes as TAB, but BSD sed treats it literally,
# so [^\t]* would truncate at the first 't' character.  Use a literal tab and
# shell parameter-expansion instead.
#
# Manifest header format (single line):
#   # vault=<abs>\t<from=v>\t<to=v>\t<ts=s>
#
# parse_manifest_field <header-line> <field-name>
#   Echoes the value for field-name (vault|from|to|ts), or empty string.
_MANIFEST_TAB="$(printf '\t')"
parse_manifest_field() {
    local _line="$1" _field="$2"
    # Strip leading "# "
    _line="${_line#\# }"
    # Walk tab-separated key=value segments; stop on first match.
    local _rest="$_line" _seg="" _key="" _val=""
    while [ -n "$_rest" ]; do
        # Take segment up to (but not including) next tab
        _seg="${_rest%%"$_MANIFEST_TAB"*}"
        # Advance _rest past the tab (or clear if no more tabs)
        if [ "$_seg" = "$_rest" ]; then
            _rest=""
        else
            _rest="${_rest#*"$_MANIFEST_TAB"}"
        fi
        _key="${_seg%%=*}"
        _val="${_seg#*=}"
        if [ "$_key" = "$_field" ]; then
            printf '%s\n' "$_val"
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Arg parsing — subcommand dispatch
SUBCOMMAND="sweep"
VAULT_PATH=""
ROOTS=""
REGISTRY=""
TEMPLATE_DIR=""
PORCELAIN=0
FORCE_UNSTAMPED=0
FROM_TS=""
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        sweep|apply|restore)
            SUBCOMMAND="$1"; shift ;;
        --vault)
            VAULT_PATH="${2:-}"; shift 2 ;;
        --roots)
            ROOTS="${2:-}"; shift 2 ;;
        --registry)
            REGISTRY="${2:-}"; shift 2 ;;
        --template-dir)
            TEMPLATE_DIR="${2:-}"; shift 2 ;;
        --porcelain)
            PORCELAIN=1; shift ;;
        --force-unstamped)
            FORCE_UNSTAMPED=1; shift ;;
        --from)
            FROM_TS="${2:-}"; shift 2 ;;
        --list)
            LIST_ONLY=1; shift ;;
        -h|--help)
            cat <<'USAGE'
luna-upgrade-all.sh — multi-vault luna template upgrade sweep (HIMMEL-462)

Usage:
  bash scripts/luna-upgrade-all.sh [sweep] [OPTIONS]
    Discover vaults, classify, and dry-run sweep.
    --roots <dir[,dir]>   comma-separated scan roots (default: $HOME/Documents)
    --registry <path>     registry JSON (default: ~/.claude/luna-vaults.json)
    --template-dir <path> himmel template dir (default: auto-resolved)
    --porcelain           emit TSV: state\tfrom\tto\tdirty\tpath

  bash scripts/luna-upgrade-all.sh apply --vault <path> [OPTIONS]
    Apply upgrade to a single vault (classify-guard -> dry-run -> backup -> upgrade.sh --yes).
    --vault <path>        vault to upgrade (required)
    --template-dir <path> himmel template dir
    --force-unstamped     allow applying to an unstamped vault (risky — see spec)

  bash scripts/luna-upgrade-all.sh restore --vault <path> [OPTIONS]
    Restore a backup for a vault.
    --vault <path>        vault to restore (required)
    --from <ts>           specific backup timestamp to restore
    --list                list matching backups and exit

USAGE
            exit 0 ;;
        *)
            echo "luna-upgrade-all: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Tool guard — required by upgrade.sh, our delegate
for _t in python3 git sha256sum; do
    command -v "$_t" >/dev/null 2>&1 || {
        echo "luna-upgrade-all: required tool not on PATH: $_t" >&2; exit 2
    }
done

# ---------------------------------------------------------------------------
# resolve_template: locate himmel's upgrade.sh.
# Order: --template-dir > $HIMMEL_DIR > $HOME-relative candidates.
# Sets global TEMPLATE_DIR and UPGRADE.
resolve_template() {
    local rel="templates/luna-second-brain"

    if [ -n "$TEMPLATE_DIR" ]; then
        # Validate: a real luna-second-brain template has marketplace.json
        if [ -f "$TEMPLATE_DIR/marketplace/.claude-plugin/marketplace.json" ]; then
            UPGRADE="$TEMPLATE_DIR/scripts/upgrade.sh"
            return 0
        fi
        echo "luna-upgrade-all: --template-dir does not look like a luna-second-brain template (missing marketplace/.claude-plugin/marketplace.json): $TEMPLATE_DIR" >&2
        return 1
    fi

    if [ -n "${HIMMEL_DIR:-}" ] && \
       [ -f "$HIMMEL_DIR/$rel/marketplace/.claude-plugin/marketplace.json" ]; then
        TEMPLATE_DIR="$(cd "$HIMMEL_DIR/$rel" && pwd)"
        UPGRADE="$TEMPLATE_DIR/scripts/upgrade.sh"
        return 0
    fi

    if [ -n "${HOME:-}" ]; then
        local cand
        for cand in \
            "$HOME/github/himmel" "$HOME/github/Himmel" \
            "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel"; do
            if [ -f "$cand/$rel/marketplace/.claude-plugin/marketplace.json" ]; then
                TEMPLATE_DIR="$(cd "$cand/$rel" && pwd)"
                UPGRADE="$TEMPLATE_DIR/scripts/upgrade.sh"
                return 0
            fi
        done
    fi

    echo "luna-upgrade-all: could not locate himmel template. Pass --template-dir DIR or set HIMMEL_DIR." >&2
    return 1
}

UPGRADE=""
if ! resolve_template; then
    exit 2
fi
TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" && pwd)"
UPGRADE="$TEMPLATE_DIR/scripts/upgrade.sh"

# ---------------------------------------------------------------------------
# classify_vault <path>: stdout one of luna-family | unstamped | not-a-vault
classify_vault() {
    local v="$1"
    local stamp="$v/.vault-template.json"
    if [ -f "$stamp" ]; then
        local tmpl py_rc
        py_rc=0
        tmpl="$(python3 -c \
            'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("template",""))' \
            "$stamp" 2>/dev/null | tr -d '\r')" || py_rc=$?
        if [ "$py_rc" -ne 0 ]; then
            echo "classify_vault: WARNING: could not parse stamp at $stamp (json/read error); classifying as unstamped" >&2
        elif [ "$tmpl" = "luna-second-brain" ]; then
            echo "luna-family"
            return
        fi
    fi
    if [ -d "$v/.obsidian" ]; then
        echo "unstamped"
        return
    fi
    echo "not-a-vault"
}

# ---------------------------------------------------------------------------
# discover_vaults: emit one canonical vault path per line.
# Sources: registry JSON + depth-1 scan of roots. Deduped by canonical path.
# Excludes the himmel checkout when TEMPLATE_DIR looks like a real himmel path.
discover_vaults() {
    local reg="${REGISTRY:-${HOME:-}/.claude/luna-vaults.json}"
    local roots_raw="${ROOTS:-${HOME:-}/Documents}"

    # Himmel-checkout exclusion: only when TEMPLATE_DIR is truly a himmel path
    # (basename==luna-second-brain AND parent basename==templates).
    local himmel_root=""
    local td_base; td_base="$(basename "$TEMPLATE_DIR")"
    local td_parent_base; td_parent_base="$(basename "$(dirname "$TEMPLATE_DIR")")"
    if [ "$td_base" = "luna-second-brain" ] && [ "$td_parent_base" = "templates" ]; then
        himmel_root="$(cd "$TEMPLATE_DIR/../.." && pwd)"
    fi

    # We accumulate paths in a temp file for dedup (no assoc arrays in bash 3.2).
    local seen_file; seen_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "$seen_file"; trap - EXIT' EXIT

    emit_if_new() {
        local p="$1"
        [ -d "$p" ] || return 0
        local canon; canon="$(cd "$p" && pwd)"
        # Skip himmel checkout
        if [ -n "$himmel_root" ] && [ "$canon" = "$himmel_root" ]; then return 0; fi
        # Dedup: grep for an exact-line match
        if grep -qxF "$canon" "$seen_file" 2>/dev/null; then return 0; fi
        printf '%s\n' "$canon" >> "$seen_file"
        printf '%s\n' "$canon"
    }

    # 1. Registry
    # I2: use temp-file pattern (not pipe-subshell) so python3 exit code is
    # captured; malformed/unreadable registry warns + falls through to roots scan.
    if [ -f "$reg" ]; then
        local reg_tmp; reg_tmp="$(mktemp)"
        local reg_py_rc; reg_py_rc=0
        python3 - "$reg" <<'PY' > "$reg_tmp" 2>/dev/null || reg_py_rc=$?
import json, sys, os, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, newline='\n')
data = json.load(open(sys.argv[1]))
vaults = data.get("vaults", {})
for name, path in vaults.items():
    if path.startswith("~/"):
        path = os.path.expanduser(path)
    print(path)
PY
        if [ "$reg_py_rc" -ne 0 ]; then
            echo "discover_vaults: WARNING: could not parse registry JSON at $reg (rc=$reg_py_rc); skipping registry" >&2
            rm -f "$reg_tmp"
        else
            local p
            while IFS= read -r p; do
                p="$(printf '%s' "$p" | tr -d '\r')"
                emit_if_new "$p"
            done < "$reg_tmp"
            rm -f "$reg_tmp"
        fi
    fi

    # 2. Depth-1 scan of roots
    local IFS_SAVE="$IFS"
    IFS=","
    set -f
    # shellcheck disable=SC2086
    set -- $roots_raw
    set +f
    IFS="$IFS_SAVE"
    local root
    for root in "$@"; do
        [ -d "$root" ] || continue
        local child
        for child in "$root"/*/; do
            child="${child%/}"
            [ -d "$child/.obsidian" ] || continue
            emit_if_new "$child"
        done
    done

    rm -f "$seen_file"
    trap - EXIT
}

# ---------------------------------------------------------------------------
# is_git_dirty <vault>: exit 0 if vault is a git repo with uncommitted changes.
is_git_dirty() {
    local v="$1"
    [ -d "$v/.git" ] || return 1
    local status; status="$(git -C "$v" status --porcelain 2>/dev/null)"
    [ -n "$status" ]
}

# ---------------------------------------------------------------------------
# parse_banner_version <text> <kind>: extract version from banner line.
# kind: template -> matches "    template :" line
#       vault    -> matches "    vault    :" line
# Extracts the LAST (vX.Y.Z) token — path-content-agnostic (paths may have
# spaces or parens). Uses sed to find the last occurrence of (vSOMETHING).
parse_banner_version() {
    local text="$1" kind="$2"
    local pattern
    if [ "$kind" = "template" ]; then
        pattern="template"
    else
        pattern="vault"
    fi
    # Find the line, then extract the last (v...) token on it.
    printf '%s\n' "$text" | grep "^ *$pattern *:" | tail -1 | \
        sed 's/.*(\(v[^)]*\))[^(]*$/\1/' | sed 's/^v//'
}

# ---------------------------------------------------------------------------
# has_plan_lines <text>: exit 0 if the dry-run output has ≥1 plan line.
has_plan_lines() {
    local text="$1"
    # Plan lines are indented with two spaces and contain a class token.
    printf '%s\n' "$text" | grep -qE '^ +(WRITE|MERGE-JSON|MERGE-3WAY|REPORT)'
}

# ---------------------------------------------------------------------------
# has_conflict_line <text>: exit 0 if any plan line is a MERGE-3WAY CONFLICT.
# Whitespace-agnostic: the engine pads with multiple spaces.
# Uses grep so the result propagates through the pipe correctly.
# The pattern matches MERGE-3WAY (any whitespace) _CLAUDE.md (any) (CONFLICT.
has_conflict_line() {
    local text="$1"
    # Write to a temp file to avoid pipe-subshell exit-code loss.
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$text" > "$tmp"
    local found=1
    local line
    while IFS= read -r line; do
        case "$line" in
            *MERGE-3WAY*_CLAUDE.md*"(CONFLICT"*)
                found=0; break ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return $found
}

# ---------------------------------------------------------------------------
# cmd_sweep: discover vaults, classify, dry-run, emit table.
cmd_sweep() {
    local vaults
    vaults="$(discover_vaults)" || { echo "sweep: vault discovery failed" >&2; return 1; }

    if [ -z "$vaults" ]; then
        if [ "$PORCELAIN" = 0 ]; then
            echo "No vaults discovered."
        fi
        return 0
    fi

    # Human table header
    if [ "$PORCELAIN" = 0 ]; then
        printf '%-16s  %-12s  %-12s  %-7s  %s\n' "STATE" "FROM" "TO" "DIRTY" "VAULT"
        printf '%s\n' "----------------  ------------  ------------  -------  -----"
    fi

    local v class dry_out dry_rc vfrom vto dirty state

    # I3: avoid pipe-subshell so we can count errors after the loop.
    # Write vault list to a temp file and read from it directly.
    local sweep_vaults_tmp; sweep_vaults_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "$sweep_vaults_tmp"; trap - EXIT' EXIT
    printf '%s\n' "$vaults" > "$sweep_vaults_tmp"

    local sweep_error_count=0 sweep_luna_count=0
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        class="$(classify_vault "$v")"

        case "$class" in
            not-a-vault) continue ;;

            unstamped)
                state="unstamped"
                vfrom="" vto="" dirty=""
                if [ "$PORCELAIN" = 1 ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$vfrom" "$vto" "$dirty" "$v"
                else
                    printf '%-16s  %-12s  %-12s  %-7s  %s\n' "$state" "" "" "" "$v"
                fi
                ;;

            luna-family)
                sweep_luna_count=$((sweep_luna_count + 1))
                # Dirty check
                dirty=""
                if [ -d "$v/.git" ]; then
                    if is_git_dirty "$v"; then dirty="true"; else dirty="false"; fi
                fi

                # dry-run — best-effort: errors continue
                dry_rc=0
                dry_out="$(bash "$UPGRADE" \
                    --template-dir "$TEMPLATE_DIR" --vault-dir "$v" --dry-run 2>&1)" \
                    || dry_rc=$?

                if [ "$dry_rc" -ge 2 ]; then
                    state="error"
                    sweep_error_count=$((sweep_error_count + 1))
                    vfrom="" vto=""
                    if [ "$PORCELAIN" = 1 ]; then
                        printf '%s\t%s\t%s\t%s\t%s\n' "$state" "" "" "$dirty" "$v"
                    else
                        printf '%-16s  %-12s  %-12s  %-7s  %s\n' "$state" "" "" "$dirty" "$v"
                    fi
                    continue
                fi

                # Check for "already current" / "nothing to do"
                case "$dry_out" in
                    *"already current"*|*"nothing to do"*)
                        state="already-current"
                        vfrom="$(parse_banner_version "$dry_out" "vault")"
                        vto="$(parse_banner_version "$dry_out" "template")"
                        ;;
                    *)
                        vfrom="$(parse_banner_version "$dry_out" "vault")"
                        vto="$(parse_banner_version "$dry_out" "template")"

                        if has_conflict_line "$dry_out"; then
                            state="conflict"
                        elif has_plan_lines "$dry_out"; then
                            state="clean-upgrade"
                        else
                            state="already-current"
                        fi
                        ;;
                esac

                if [ "$PORCELAIN" = 1 ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$vfrom" "$vto" "$dirty" "$v"
                else
                    printf '%-16s  %-12s  %-12s  %-7s  %s\n' "$state" "$vfrom" "$vto" "$dirty" "$v"
                fi
                ;;
        esac
    done < "$sweep_vaults_tmp"
    rm -f "$sweep_vaults_tmp"
    trap - EXIT

    # I3: advisory warning if every discovered luna-family vault returned error state.
    if [ "$sweep_luna_count" -gt 0 ] && [ "$sweep_error_count" -eq "$sweep_luna_count" ]; then
        echo "sweep: WARNING: all $sweep_luna_count discovered luna-family vault(s) returned error state" >&2
    fi
}

# ---------------------------------------------------------------------------
# backup_vault <vault> <template-dir> <plan-text> <vfrom> <vto>
# Creates a timestamped snapshot under $HOME/.claude/luna-upgrade-backups/<slug>/<ts>/
# For each plan target (excluding REPORT), plus .vault-template.json and
# .vault-template.base/, classifies by FILESYSTEM PRESENCE at backup time:
#   existing -> copy bytes to $dest/$rel; manifest row: existing\t$rel
#   absent   -> record path only;          manifest row: new\t$rel
# For .vault-template.base/ (directory): if present, also enumerate its files
# so each round-trips its bytes on restore.
# Echos the $dest path on stdout on success; returns 1 on failure (no dest echoed).
backup_vault() {
    local vault="$1" plan_text="$3" vfrom="$4" vto="$5"
    # $2 (tmpl_dir) is unused here; backup logic only needs vault + plan + versions

    # Slug: basename, sanitize non-[A-Za-z0-9._-] to _
    local slug; slug="$(basename "$vault" | sed 's/[^A-Za-z0-9._-]/_/g')"
    # LUNA_UPGRADE_BACKUP_TS: testability override — fixes the timestamp so tests
    # can pre-create the expected dest and deterministically trigger the -2 suffix.
    local ts; ts="${LUNA_UPGRADE_BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
    local base_dir; base_dir="${HOME:-}/.claude/luna-upgrade-backups/$slug"
    local dest="$base_dir/$ts"

    # Handle same-second collision: append -2, -3, … until unique
    if [ -e "$dest" ]; then
        local n=2
        while [ -e "${dest}-${n}" ]; do
            n=$((n + 1))
        done
        dest="${dest}-${n}"
    fi

    # C1: check mkdir -p — if it fails (e.g. dest path blocked by a file), bail
    if ! mkdir -p "$dest"; then
        echo "backup_vault: ERROR: could not create backup dir: $dest" >&2
        return 1
    fi

    # Collect plan rels (excluding REPORT lines) into a temp file for dedup.
    # C2: use temp file (not pipe-subshell) so write failures propagate.
    local rels_file; rels_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "$rels_file"; trap - EXIT' EXIT

    # Write plan lines to temp file first, then read — no pipe-subshell.
    local plan_tmp; plan_tmp="$(mktemp)"
    printf '%s\n' "$plan_text" > "$plan_tmp"

    local line
    while IFS= read -r line; do
        # Plan lines start with 2 spaces then a class token; skip non-plan and REPORT
        case "$line" in
            "  "REPORT*) continue ;;
            "  "WRITE*|"  "MERGE-JSON*|"  "MERGE-3WAY*)
                # Strip leading whitespace, then grab the second space-delimited field
                local stripped; stripped="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
                # Rel path is everything after the first whitespace-delimited token
                # (class token may be padded with spaces, then path, then optional annotation)
                local rel; rel="$(printf '%s' "$stripped" | sed 's/^[^ ]*[[:space:]]*//' | sed 's/ (.*$//')"
                [ -n "$rel" ] && printf '%s\n' "$rel" >> "$rels_file"
                ;;
        esac
    done < "$plan_tmp"
    rm -f "$plan_tmp"

    # Add synthetic targets (dedup with plan rels)
    printf '%s\n' ".vault-template.json" >> "$rels_file"
    printf '%s\n' ".vault-template.base" >> "$rels_file"

    # Dedup: sort -u (file contents, not dirs)
    local deduped_file; deduped_file="$(mktemp)"
    sort -u "$rels_file" > "$deduped_file"
    rm -f "$rels_file"
    trap 'rm -f "$deduped_file"; trap - EXIT' EXIT

    # Write manifest
    local manifest="$dest/manifest.tsv"
    printf '# vault=%s\tfrom=%s\tto=%s\tts=%s\n' "$vault" "$vfrom" "$vto" "$ts" > "$manifest"

    local backup_rc=0
    local rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        local target="$vault/$rel"

        # Special handling for .vault-template.base/ (directory target)
        if [ "$rel" = ".vault-template.base" ]; then
            if [ -d "$target" ]; then
                # Directory present: record as existing AND enumerate files inside.
                # C2: use temp file for find output — no pipe-subshell so errors propagate.
                printf 'existing\t%s\n' "$rel" >> "$manifest"
                if ! mkdir -p "$dest/$rel"; then
                    echo "backup_vault: ERROR: could not create $dest/$rel" >&2
                    backup_rc=1; continue
                fi
                local base_files_tmp; base_files_tmp="$(mktemp)"
                local base_find_err_tmp; base_find_err_tmp="$(mktemp)"
                # I1: separate stderr from file list; capture find exit code so a
                # failed/partial enumeration doesn't silently produce a bogus list.
                local base_find_rc; base_find_rc=0
                ( cd "$vault" && find ".vault-template.base" -type f ) \
                    > "$base_files_tmp" 2>"$base_find_err_tmp" || base_find_rc=$?
                if [ "$base_find_rc" -ne 0 ]; then
                    cat "$base_find_err_tmp" >&2
                    echo "backup_vault: ERROR: find .vault-template.base failed (rc=$base_find_rc) in $vault" >&2
                    rm -f "$base_files_tmp" "$base_find_err_tmp"
                    backup_rc=1; continue
                fi
                rm -f "$base_find_err_tmp"
                local frel
                while IFS= read -r frel; do
                    [ -n "$frel" ] || continue
                    if ! mkdir -p "$dest/$(dirname "$frel")"; then
                        echo "backup_vault: ERROR: could not create dir for $frel in backup" >&2
                        backup_rc=1; continue
                    fi
                    if ! cp "$vault/$frel" "$dest/$frel"; then
                        echo "backup_vault: ERROR: could not copy $vault/$frel to backup" >&2
                        backup_rc=1; continue
                    fi
                    printf 'existing\t%s\n' "$frel" >> "$manifest"
                done < "$base_files_tmp"
                rm -f "$base_files_tmp"
            else
                # Directory absent: record as new
                printf 'new\t%s\n' "$rel" >> "$manifest"
            fi
            continue
        fi

        if [ -e "$target" ] && [ ! -d "$target" ]; then
            # File exists: copy bytes — C1: check mkdir and cp
            if ! mkdir -p "$dest/$(dirname "$rel")"; then
                echo "backup_vault: ERROR: could not create parent dir for $rel in backup" >&2
                backup_rc=1; continue
            fi
            if ! cp "$target" "$dest/$rel"; then
                echo "backup_vault: ERROR: could not copy $target to backup" >&2
                backup_rc=1; continue
            fi
            printf 'existing\t%s\n' "$rel" >> "$manifest"
        elif [ -d "$target" ]; then
            # It's a directory (but not .vault-template.base handled above):
            # treat as new (we don't copy whole dirs for arbitrary plan targets)
            printf 'new\t%s\n' "$rel" >> "$manifest"
        else
            # Absent: record as new
            printf 'new\t%s\n' "$rel" >> "$manifest"
        fi
    done < "$deduped_file"
    rm -f "$deduped_file"
    trap - EXIT

    if [ "$backup_rc" -ne 0 ]; then
        echo "backup_vault: ERROR: one or more files could not be backed up; backup at $dest may be incomplete" >&2
        return 1
    fi

    printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# cmd_apply: apply upgrade to a single vault (Tasks 5-6)
cmd_apply() {
    if [ -z "$VAULT_PATH" ]; then
        echo "apply: --vault <path> is required" >&2
        exit 2
    fi

    # Canonicalize vault path
    local vault
    if ! vault="$(cd "$VAULT_PATH" 2>/dev/null && pwd)"; then
        echo "apply: vault path does not exist: $VAULT_PATH" >&2
        exit 2
    fi

    # Classify
    local class; class="$(classify_vault "$vault")"

    case "$class" in
        not-a-vault)
            echo "apply: $vault is not a vault (no .obsidian/ or stamp)" >&2
            exit 2
            ;;
        unstamped)
            if [ "$FORCE_UNSTAMPED" = 0 ]; then
                echo "apply: $vault is unstamped (no .vault-template.json)." >&2
                echo "  Without --force-unstamped, apply refuses unstamped vaults." >&2
                echo "  Risk: upgrade.sh runs a FULL pass that can overwrite .obsidian/ config," >&2
                echo "  README.md, scripts/, docs/, and other template-owned paths." >&2
                echo "  Only use --force-unstamped if you know this is a luna vault." >&2
                exit 2
            fi
            if [ ! -f "$vault/_CLAUDE.md" ]; then
                echo "apply: --force-unstamped requires _CLAUDE.md to be present (heuristic that this is a luna vault): $vault" >&2
                exit 2
            fi
            ;;
        luna-family)
            : # normal path
            ;;
    esac

    # Dirty-git precondition (applies to luna-family; unstamped with git also checked)
    if [ -d "$vault/.git" ]; then
        local git_status; git_status="$(git -C "$vault" status --porcelain 2>/dev/null)"
        if [ -n "$git_status" ]; then
            printf 'SKIPPED-DIRTY\t%s\n' "$vault"
            exit 3
        fi
    fi

    # Fresh dry-run (NOT a stale plan) — compute plan and banner versions now
    local dry_out dry_rc
    dry_rc=0
    dry_out="$(bash "$UPGRADE" \
        --template-dir "$TEMPLATE_DIR" --vault-dir "$vault" --dry-run 2>&1)" \
        || dry_rc=$?

    if [ "$dry_rc" -ge 2 ]; then
        echo "apply: upgrade.sh --dry-run failed (rc=$dry_rc) for $vault" >&2
        printf '%s\n' "$dry_out" >&2
        exit "$dry_rc"
    fi

    local vfrom vto
    vfrom="$(parse_banner_version "$dry_out" "vault")"
    vto="$(parse_banner_version "$dry_out" "template")"

    # Create backup from fresh dry-run plan (before any writes to the vault itself).
    # C1: capture exit status separately — 'local' always returns 0.
    local backup_dest backup_rc
    backup_rc=0
    backup_dest="$(backup_vault "$vault" "$TEMPLATE_DIR" "$dry_out" "$vfrom" "$vto")" \
        || backup_rc=$?
    if [ "$backup_rc" -ne 0 ] || [ -z "$backup_dest" ] || [ ! -d "$backup_dest" ]; then
        echo "apply: backup failed — aborting to protect vault (no upgrade ran)" >&2
        exit 2
    fi
    printf 'BACKUP\t%s\n' "$backup_dest"

    # Run upgrade.sh --yes
    local upgrade_rc
    upgrade_rc=0
    bash "$UPGRADE" --template-dir "$TEMPLATE_DIR" --vault-dir "$vault" --yes 2>&1 \
        || upgrade_rc=$?

    case "$upgrade_rc" in
        0)
            printf 'OK\t%s\n' "$vault"
            exit 0
            ;;
        1)
            local sidecar="$vault/_CLAUDE.md.template-merge"
            if [ -f "$sidecar" ]; then
                printf 'CONFLICT\t%s\t%s\n' "$vault" "$sidecar"
            else
                printf 'PARTIAL\t%s\n' "$vault"
            fi
            exit 1
            ;;
        *)
            exit "$upgrade_rc"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# cmd_restore: restore a backup for a vault (Task 7)
cmd_restore() {
    if [ -z "$VAULT_PATH" ]; then
        echo "restore: --vault <path> is required" >&2
        exit 2
    fi

    # Canonicalize vault path
    local vault
    if ! vault="$(cd "$VAULT_PATH" 2>/dev/null && pwd)"; then
        echo "restore: vault path does not exist: $VAULT_PATH" >&2
        exit 2
    fi

    local slug; slug="$(basename "$vault" | sed 's/[^A-Za-z0-9._-]/_/g')"
    local backup_base; backup_base="${HOME:-}/.claude/luna-upgrade-backups/$slug"

    # --list: print matching backups and exit
    if [ "$LIST_ONLY" = 1 ]; then
        if [ ! -d "$backup_base" ]; then
            echo "No backups found for vault: $vault"
            exit 0
        fi
        local found=0
        # List all backup dirs, find ones whose manifest vault= matches
        for bdir in "$backup_base"/*/; do
            bdir="${bdir%/}"
            [ -d "$bdir" ] || continue
            local bmanifest="$bdir/manifest.tsv"
            [ -f "$bmanifest" ] || continue
            local _mhdr; _mhdr="$(head -1 "$bmanifest")"
            local bvault; bvault="$(parse_manifest_field "$_mhdr" "vault")"
            if [ "$bvault" = "$vault" ]; then
                local bfrom bto bts
                bfrom="$(parse_manifest_field "$_mhdr" "from")"
                bto="$(parse_manifest_field "$_mhdr" "to")"
                bts="$(basename "$bdir")"
                printf '%s\t%s->%s\n' "$bts" "$bfrom" "$bto"
                found=$((found + 1))
            fi
        done
        if [ "$found" = 0 ]; then
            echo "No backups found matching vault: $vault"
        fi
        exit 0
    fi

    # Select backup
    local chosen_dir=""
    if [ -n "$FROM_TS" ]; then
        chosen_dir="$backup_base/$FROM_TS"
        if [ ! -d "$chosen_dir" ]; then
            echo "restore: backup not found: $chosen_dir" >&2
            exit 2
        fi
    else
        # Among dirs under backup_base whose manifest vault= matches $vault,
        # pick latest by (ts base, then numeric uniquifier suffix; absent=0).
        # Sort order: parse ts base and numeric suffix, pick highest.
        if [ ! -d "$backup_base" ]; then
            echo "restore: no backups found for vault: $vault" >&2
            exit 2
        fi

        # We sort by emitting "ts_base\tsuffix\tdir" then pick the last one
        local pick_file; pick_file="$(mktemp)"
        # shellcheck disable=SC2064
        trap 'rm -f "$pick_file"; trap - EXIT' EXIT

        local bdir
        for bdir in "$backup_base"/*/; do
            bdir="${bdir%/}"
            [ -d "$bdir" ] || continue
            local bmanifest="$bdir/manifest.tsv"
            [ -f "$bmanifest" ] || continue
            local bvault; bvault="$(parse_manifest_field "$(head -1 "$bmanifest")" "vault")"
            if [ "$bvault" = "$vault" ]; then
                local bname; bname="$(basename "$bdir")"
                # Parse: ts_base is the part matching YYYYMMDDTHHMMSSz
                # suffix is the numeric part after a dash (absent = 0)
                local ts_base suffix
                # bname is either "20260621T120000Z" or "20260621T120000Z-2"
                case "$bname" in
                    *-[0-9]*)
                        ts_base="${bname%-*}"
                        suffix="${bname##*-}"
                        # Validate suffix is numeric
                        case "$suffix" in
                            *[!0-9]*) ts_base="$bname"; suffix="0" ;;
                        esac
                        ;;
                    *)
                        ts_base="$bname"
                        suffix="0"
                        ;;
                esac
                printf '%s\t%010d\t%s\n' "$ts_base" "$suffix" "$bdir" >> "$pick_file"
            fi
        done

        if [ ! -s "$pick_file" ]; then
            rm -f "$pick_file"
            trap - EXIT
            echo "restore: no matching backups found for vault: $vault" >&2
            exit 2
        fi

        # Sort: primary=ts_base (lexical, ISO8601 is lexically monotone),
        #       secondary=suffix (numeric, zero-padded to 10 digits for sort -k2)
        # Last line after sort = latest
        chosen_dir="$(sort -k1,1 -k2,2n "$pick_file" | tail -1 | cut -f3)"
        rm -f "$pick_file"
        trap - EXIT
    fi

    # Guard: check manifest vault= matches our --vault
    local chosen_manifest="$chosen_dir/manifest.tsv"
    if [ ! -f "$chosen_manifest" ]; then
        echo "restore: manifest not found at $chosen_manifest" >&2
        exit 2
    fi
    local manifest_vault; manifest_vault="$(parse_manifest_field "$(head -1 "$chosen_manifest")" "vault")"
    if [ "$manifest_vault" != "$vault" ]; then
        echo "restore: backup vault mismatch. Manifest says '$manifest_vault' but --vault is '$vault'" >&2
        exit 2
    fi

    local chosen_ts; chosen_ts="$(basename "$chosen_dir")"

    # C3: Apply restore rows via temp file (not a pipe-subshell) so failures propagate.
    # Use $_MANIFEST_TAB for IFS to avoid literal-tab fragility.
    local restore_rows_tmp; restore_rows_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "$restore_rows_tmp"; trap - EXIT' EXIT
    tail -n +2 "$chosen_manifest" > "$restore_rows_tmp"

    local restore_rc=0
    local row_class row_rel
    while IFS="$_MANIFEST_TAB" read -r row_class row_rel; do
        [ -n "$row_rel" ] || continue
        case "$row_class" in
            existing)
                local src="$chosen_dir/$row_rel"
                local dst="$vault/$row_rel"
                if [ -f "$src" ]; then
                    if ! mkdir -p "$(dirname "$dst")"; then
                        echo "restore: ERROR: could not create parent dir for $dst" >&2
                        restore_rc=1; continue
                    fi
                    if ! cp "$src" "$dst"; then
                        echo "restore: ERROR: could not copy $src to $dst" >&2
                        restore_rc=1; continue
                    fi
                elif [ -d "$src" ]; then
                    if ! mkdir -p "$dst"; then
                        echo "restore: ERROR: could not create dir $dst" >&2
                        restore_rc=1; continue
                    fi
                else
                    # C3: backup source is missing — warn and fail
                    echo "restore: WARNING: backup source missing for existing entry: $src" >&2
                    restore_rc=1; continue
                fi
                ;;
            new)
                local target="$vault/$row_rel"
                if [ -e "$target" ]; then
                    if ! rm -rf "$target"; then
                        echo "restore: ERROR: could not remove $target" >&2
                        restore_rc=1; continue
                    fi
                fi
                ;;
        esac
    done < "$restore_rows_tmp"
    rm -f "$restore_rows_tmp"
    trap - EXIT

    if [ "$restore_rc" -ne 0 ]; then
        echo "restore: vault may be in partial state; inspect $vault and re-run or restore a different backup" >&2
        exit 1
    fi

    # Delete the sidecar if present
    local sidecar="$vault/_CLAUDE.md.template-merge"
    [ -f "$sidecar" ] && rm -f "$sidecar"

    printf 'RESTORED\t%s\t%s\n' "$vault" "$chosen_ts"
}

# ---------------------------------------------------------------------------
# Dispatch
case "$SUBCOMMAND" in
    sweep)   cmd_sweep ;;
    apply)   cmd_apply ;;
    restore) cmd_restore ;;
    *)
        echo "luna-upgrade-all: unknown subcommand: $SUBCOMMAND" >&2; exit 2 ;;
esac
