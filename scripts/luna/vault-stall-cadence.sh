#!/usr/bin/env bash
# vault-stall-cadence.sh — detect a luna vault auto-commit STALL and remediate
# the known-benign pre-commit refusals; alert on everything else (HIMMEL-4471).
#
# WHY: the vault auto-commits every ~10 min (Obsidian github-sync, through the
# vault's no-stash pre-commit wrapper). When a hook refuses, the commit just
# stops: the paths stay STAGED and nothing alerts. Five stalls of one class so
# far (session artefacts under handovers/ tripping shellcheck, check-json or a
# gitleaks entropy rule), each fixed by hand hours later.
#
#   vault-stall-cadence.sh run [--vault PATH] [--dry-run]   one pass (cron fires this)
#   vault-stall-cadence.sh arm [--vault PATH] [--force] [--dry-run]
#   vault-stall-cadence.sh status
#   vault-stall-cadence.sh disarm [--dry-run]
#
# The vault defaults to $LUNA_VAULT_PATH, else ~/Documents/luna.
#
# DETECT: staged paths exist AND the newest commit is older than
# VAULT_STALL_MIN minutes (default 25, two missed syncs). The refusal is
# reproduced with `git hook run pre-commit` (the vault's own wrapper) with
# SKIP=trailing-whitespace,end-of-file-fixer: those two are fixers, so running
# them would rewrite content, and their refusals self-heal anyway (the next
# sync's `git add` stages the fixed file). They are a template-exclude-only
# class, never remediated here.
#
# CLASSIFY: failed hook ids come from pre-commit's `- hook id:` lines, files from
# the `In <file> line <n>:` lines of shellcheck and check-json's `<file>: Failed…`. gitleaks
# findings come from a second gitleaks scan whose JSON report goes straight
# into jq; jq emits only rule/file/line and the id of the CLOSED shape the
# secret fully matches. The secret never reaches a shell variable, a file or a
# log. The raw hook output is never written anywhere either (shellcheck echoes
# source lines).
#
# REMEDIATE, all-or-nothing: only when EVERY finding is benign —
#   a shellcheck / check-json finding on a file under handovers/
#       → that hook's `exclude:` gains the canonical `^handovers/` alternative;
#   gitleaks on a file under handovers/ whose secret fully matches CLOSED_SHAPES
#       → that shape's canonical regex line is added to .gitleaks.toml.
# The edit is always a canonical line from this file, never one derived from
# the finding. The toml regex is global, not path-scoped: this gitleaks build
# ignores paths-AND-regexes allowlists (see the template's .gitleaks.toml), so
# handovers/-only is enforced here, at classify time. The hook is re-run; on
# rc 0 ONLY the edited config files are committed (`git commit --only`, through
# pre-commit, never --no-verify), and the next sync flushes the staged backlog,
# which this script never touches. It never runs `pre-commit install` (that
# clobbers the no-stash wrapper).
#
# ALERT (scripts/luna/cadence-alert.sh: Telegram once + cadence-alerts.log),
# no commit: any other hook, rule or shape; any file outside handovers/; a
# remediation already present; a class that stalls again within 24 h of its
# own remediation (the fix did not hold, e.g. a luna-upgrade clobbered it); or
# a hook still failing after the edit (the edit is then rolled back). An alert
# names hook, rule, file and line, never the secret. A healthy pass clears it.
#
# Concurrency: github-sync is the vault's other writer. A run skips (`busy`,
# exit 0) while .git/index.lock exists, and a flock keeps runs from overlapping.
#
# Seams (tests): VAULT_STALL_STATE_DIR, VAULT_STALL_MIN, VAULT_STALL_GITLEAKS,
# VAULT_STALL_CRONTAB, VAULT_STALL_RUNNER_DIR, plus cadence-alert.sh's own.
# Platform: cron (Linux/macOS). Windows development is parked (HIMMEL-4102).
set -uo pipefail

TASK_NAME="HIMMEL-VaultStall"
LEG="vault-stall"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/observability-registry.sh
. "$SCRIPT_DIR/../lib/observability-registry.sh"
STATE_DIR="${VAULT_STALL_STATE_DIR:-${HOME:-}/.himmel/state/vault-stall}"
CRONTAB_BIN="${VAULT_STALL_CRONTAB:-crontab}"
RUNNER_DIR="${VAULT_STALL_RUNNER_DIR:-${HOME:-}/.claude/vault-stall-cadence}"
GITLEAKS_BIN="${VAULT_STALL_GITLEAKS:-gitleaks}"
ALERT="$SCRIPT_DIR/cadence-alert.sh"
CAP_SECS=86400
CANON_EXCLUDE='^handovers/'
SKIP_FIXERS="trailing-whitespace,end-of-file-fixer"
# The CLOSED list: id<TAB>regex, verbatim copies of the anchored regexes in
# templates/luna-second-brain/.gitleaks.toml. Never extended at runtime.
CLOSED_SHAPES='lock-token	^[a-z0-9]+-[a-z0-9]+-pid[0-9]+[.,;:)]?$
sha40	^[0-9a-f]{40}[.,;:)]?$
retask-nonce	^[A-Z]{1,2}-N[0-9]+[a-z]?-[0-9a-f]{4,16}[.,;:)]?$'

default_vault() { printf '%s\n' "${LUNA_VAULT_PATH:-${HOME:-}/Documents/luna}"; }
shape_regex() { printf '%s\n' "$CLOSED_SHAPES" | awk -F'\t' -v id="$1" '$1 == id { print $2 }'; }

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# gitleaks_findings <vault> — one TSV row per finding: rule, file, line, shape
# id ("" when the secret fits no closed shape). rc 1 = the scan itself failed.
gitleaks_findings() {
    local vault="$1" shapes cfg=()
    shapes="$(printf '%s\n' "$CLOSED_SHAPES" | jq -Rn '[inputs | split("\t") | {id: .[0], re: .[1]}]')" || return 1
    [ -f "$vault/.gitleaks.toml" ] && cfg=(--config "$vault/.gitleaks.toml")
    (cd "$vault" && "$GITLEAKS_BIN" git --pre-commit --staged --no-banner --log-level error \
        --exit-code 0 "${cfg[@]}" --report-format json --report-path - . 2>/dev/null) \
        | jq -r --argjson shapes "$shapes" '.[] | . as $f
            | ([$shapes[] | select(. as $s | $f.Secret | test($s.re)) | .id] | first // "") as $shape
            | [$f.RuleID, $f.File, ($f.StartLine | tostring), $shape] | @tsv'
    local rcs=("${PIPESTATUS[@]}")
    [ "${rcs[0]}" -eq 0 ] && [ "${rcs[1]}" -eq 0 ]
}

# classify <vault> <hook-output> — FINDINGS rows: verdict, class, hook, rule,
# file, line, joined by US (\x1f: not IFS whitespace, so empty fields survive).
US=$'\x1f'
row() { local IFS="$US"; printf '%s' "$*"; }
classify() {
    local vault="$1" out="$2" hook files rows f l rule file line shape verdict
    FINDINGS=""
    while IFS= read -r hook; do
        [ -n "$hook" ] || continue
        rows=""
        case "$hook" in
            shellcheck)
                files="$(printf '%s\n' "$out" | sed -n -E 's/^In (.+) line ([0-9]+):$/\1\t\2/p' | sort -u)"
                while IFS=$'\t' read -r f l; do
                    [ -n "$f" ] || continue
                    verdict=alert; case "$f" in handovers/*) verdict=benign ;; esac
                    rows="$rows$(row "$verdict" shellcheck shellcheck "" "$f" "$l")"$'\n'
                done <<<"$files" ;;
            check-json)
                files="$(printf '%s\n' "$out" | sed -n -E 's/^(.+): Failed to json decode.*/\1/p' | sort -u)"
                while IFS= read -r f; do
                    [ -n "$f" ] || continue
                    verdict=alert; case "$f" in handovers/*) verdict=benign ;; esac
                    rows="$rows$(row "$verdict" check-json check-json "" "$f" "")"$'\n'
                done <<<"$files" ;;
            gitleaks)
                if files="$(gitleaks_findings "$vault")"; then
                    while IFS=$'\t' read -r rule file line shape; do
                        [ -n "$rule" ] || continue
                        verdict=alert
                        case "$file" in handovers/*) [ -n "$shape" ] && verdict=benign ;; esac
                        rows="$rows$(row "$verdict" "gitleaks:${shape:-none}" gitleaks "$rule" "$file" "$line")"$'\n'
                    done <<<"$files"
                else
                    rows="$(row alert gitleaks gitleaks classify-failed "" "")"$'\n'
                fi ;;
        esac
        # A failed hook this script cannot attribute to a file is never benign.
        [ -n "$rows" ] || rows="$(row alert "$hook" "$hook" no-file-reported "" "")"$'\n'
        FINDINGS="$FINDINGS$rows"
    done < <(printf '%s\n' "$out" | sed -n 's/^- hook id: //p' | sort -u)
}

# describe <row> — "hook [rule] file:line", the only shape that leaves this script.
describe() {
    local v c hook rule file line
    IFS="$US" read -r v c hook rule file line <<<"$1"
    printf '%s%s%s%s' "$hook" "${rule:+ $rule}" "${file:+ $file}" "${line:+:$line}"
}

# yaml_exclude <file> <hook> <out> — writes the edited config to <out>.
# rc 0 = changed, 3 = the canonical alternative is already there, 4 = cannot edit safely.
yaml_exclude() {
    awk -v id="$2" -v canon="$CANON_EXCLUDE" '
        function flush_insert() { if (on && !done) { print pad "exclude: '\''" canon "'\''"; done = 1; changed = 1 } }
        {
            if ($0 ~ "^[ \t]*- id: " id "[ \t]*$") {
                on = 1; found = 1; match($0, /^[ \t]*/); pad = substr($0, 1, RLENGTH) "  "
                print; next
            }
            if (on && ($0 ~ /^[ \t]*- (id|repo):/ || $0 ~ /^[^ \t]/)) { flush_insert(); on = 0 }
            if (on && !done && $0 ~ /^[ \t]*exclude:/) {
                v = $0; sub(/^[ \t]*exclude:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
                if (v ~ /^".*"$/ || v ~ /^[|>]/) { bad = 1 }
                else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v) - 2) }
                if (index(v, "'\''")) bad = 1
                done = 1
                if (v == canon || index(v, canon "|") == 1) { same = 1; print; next }
                # An empty exclude takes the canonical regex alone: "canon|" would add
                # an empty alternative that matches every path.
                if (!bad) { print pad "exclude: '\''" canon (v == "" ? "" : "|" v) "'\''"; changed = 1; next }
            }
            print
        }
        END {
            if (on) flush_insert()
            if (!found || bad) exit 4
            if (same) exit 3
            exit 0
        }' "$1" > "$3"
}

# toml_regex <file> <regex> <out> — rc as yaml_exclude.
toml_regex() {
    if grep -qF "'''$2'''" "$1"; then return 3; fi
    # Only the global [allowlist] table's regexes; a rule-scoped array is not it.
    awk -v re="$2" -v q="'''" '
        /^[ \t]*\[/ { sec = $0; sub(/[ \t]*(#.*)?$/, "", sec); sub(/^[ \t]*/, "", sec) }
        { print }
        !done && sec == "[allowlist]" && /^[ \t]*regexes[ \t]*=[ \t]*\[/ { print "  " q re q ","; done = 1 }
        END { exit !done }' "$1" > "$3" || return 4
}

alert() {
    local reason="$1" dry="$2"
    reason="${reason:0:160}"
    if [ "$dry" -eq 1 ]; then echo "vault-stall: would alert: $reason"; return 0; fi
    echo "vault-stall: ALERT $reason"
    bash "$ALERT" fail "$LEG" "$reason" "$STATE_DIR/last-run.log"
}

cmd_run() {
    local vault dry=0 gitdir staged last now age thr out hook_rc v c
    vault="$(default_vault)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --vault) [ $# -ge 2 ] || { echo "ERR vault-stall: --vault needs a path" >&2; return 1; }
                     vault="$2"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR vault-stall: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    gitdir="$(git -C "$vault" rev-parse --absolute-git-dir 2>/dev/null)" \
        || { echo "ERR vault-stall: not a git repo: $vault" >&2; return 2; }
    vault="$(cd "$vault" && pwd -P)" || return 2   # later steps cd into it
    if [ "$dry" -eq 0 ]; then
        mkdir -p "$STATE_DIR" || return 2
        command -v flock >/dev/null 2>&1 || { echo "ERR vault-stall: flock not on PATH (needed to serialize runs)" >&2; return 2; }
        exec 9>"$STATE_DIR/run.lock"
        flock -n 9 || { echo "vault-stall: busy (another run holds $STATE_DIR/run.lock)"; return 0; }
    fi
    if [ -e "$gitdir/index.lock" ]; then echo "vault-stall: busy (index.lock held - the sync is mid-commit)"; return 0; fi

    staged="$(git -C "$vault" diff --cached --name-only | wc -l | tr -d ' ')"
    last="$(git -C "$vault" log -1 --format=%ct 2>/dev/null)"; last="${last:-0}"
    now="$(date +%s)"; age=$(((now - last) / 60))
    thr="${VAULT_STALL_MIN:-25}"; case "$thr" in '' | *[!0-9]*) thr=25 ;; esac
    if [ "$staged" -eq 0 ] || [ "$age" -lt "$((10#$thr))" ]; then
        echo "vault-stall: ok ($staged staged, newest commit ${age}m old)"
        [ "$dry" -eq 1 ] || bash "$ALERT" clear "$LEG"
        return 0
    fi
    echo "vault-stall: STALL ($staged staged, newest commit ${age}m old)"

    out="$(cd "$vault" && SKIP="$SKIP_FIXERS" git hook run pre-commit </dev/null 2>&1)"; hook_rc=$?
    if [ "$hook_rc" -eq 0 ]; then
        out=""
        alert "stall-but-pre-commit-passes ($staged staged, ${age}m)" "$dry"
        return 0
    fi
    classify "$vault" "$out"
    out=""
    [ "$dry" -eq 1 ] || : > "$STATE_DIR/last-run.log"
    local bad="" classes="" nbad=0 r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        IFS="$US" read -r v c _ <<<"$r"
        echo "  $v $c $(describe "$r")"
        [ "$dry" -eq 1 ] || echo "$v $c $(describe "$r")" >> "$STATE_DIR/last-run.log"
        if [ "$v" = benign ]; then
            case " $classes " in *" $c "*) ;; *) classes="${classes:+$classes }$c" ;; esac
        else
            nbad=$((nbad + 1))
            [ "$nbad" -le 4 ] && bad="$bad$(describe "$r"); "
        fi
    done <<<"$FINDINGS"
    if [ -n "$bad" ]; then alert "unremediable: ${bad%; }" "$dry"; return 0; fi
    [ -n "$classes" ] || { alert "unclassified refusal" "$dry"; return 0; }

    # Loop cap: one remediation per class per vault per 24 h.
    for c in $classes; do
        if [ -f "$STATE_DIR/remediated.tsv" ] && awk -F'\t' -v c="$c" -v t="$((now - CAP_SECS))" \
            -v v="$vault" '$2 == c && $3 == v && $1 + 0 >= t { f = 1 } END { exit !f }' "$STATE_DIR/remediated.tsv"; then
            alert "did-not-hold $c (remediated within 24h, stalled again)" "$dry"; return 0
        fi
    done

    # Plan every edit into a scratch copy first; nothing is live until all succeed.
    local work rc files="" f re wf
    work="$(mktemp -d "${TMPDIR:-/tmp}/vault-stall.XXXXXX")" || return 2
    cp "$vault/.pre-commit-config.yaml" "$work/yaml" 2>/dev/null
    cp "$vault/.gitleaks.toml" "$work/toml" 2>/dev/null
    cp "$vault/.pre-commit-config.yaml" "$work/yaml.orig" 2>/dev/null
    cp "$vault/.gitleaks.toml" "$work/toml.orig" 2>/dev/null
    for c in $classes; do
        case "$c" in
            shellcheck | check-json)
                f=.pre-commit-config.yaml
                yaml_exclude "$work/yaml" "$c" "$work/next"; rc=$?
                [ "$rc" -eq 0 ] && mv -f "$work/next" "$work/yaml"
                [ "$dry" -eq 1 ] && [ "$rc" -eq 0 ] && echo "vault-stall: would add $CANON_EXCLUDE to the $c exclude in $f" ;;
            gitleaks:*)
                f=.gitleaks.toml
                re="$(shape_regex "${c#gitleaks:}")"
                toml_regex "$work/toml" "$re" "$work/next"; rc=$?
                [ "$rc" -eq 0 ] && mv -f "$work/next" "$work/toml"
                [ "$dry" -eq 1 ] && [ "$rc" -eq 0 ] && echo "vault-stall: would add the canonical ${c#gitleaks:} regex to $f" ;;
        esac
        if [ "$rc" -eq 3 ]; then rm -rf "$work"; alert "remediation-already-present $c (still refused)" "$dry"; return 0; fi
        if [ "$rc" -ne 0 ]; then rm -rf "$work"; alert "cannot-edit $f for $c" "$dry"; return 0; fi
        case " $files " in *" $f "*) ;; *) files="${files:+$files }$f" ;; esac
    done
    # An operator's own uncommitted edit to a config file would be overwritten
    # and then committed under the cadence's name: never touch a dirty one.
    local dirty
    # shellcheck disable=SC2086  # $files is a space-separated list of fixed names
    dirty="$(git -C "$vault" status --porcelain -- $files 2>/dev/null)"
    if [ -n "$dirty" ]; then rm -rf "$work"; alert "config-dirty $files (uncommitted edits; not remediated)" "$dry"; return 0; fi
    if [ "$dry" -eq 1 ]; then rm -rf "$work"; echo "vault-stall: would commit $files"; return 0; fi

    # The sync may have committed a config change since planning (the tree is
    # clean again): writing the stale plan would revert it.
    for f in $files; do
        case "$f" in .pre-commit-config.yaml) wf="$work/yaml.orig" ;; .gitleaks.toml) wf="$work/toml.orig" ;; esac
        if ! cmp -s "$wf" "$vault/$f"; then
            rm -rf "$work"; alert "config-changed-during-run $f (not written)" 0; return 0
        fi
    done
    for f in $files; do
        case "$f" in .pre-commit-config.yaml) cp "$work/yaml" "$vault/$f" ;; .gitleaks.toml) cp "$work/toml" "$vault/$f" ;; esac
    done
    # Restore a file only while it still holds exactly this run's edit and HEAD
    # does not: another writer's change, or a commit that landed the edit
    # (the sync shares no lock with this run), is left alone.
    rollback() {
        local f new orig
        for f in $files; do
            case "$f" in
                .pre-commit-config.yaml) new="$work/yaml"; orig="$work/yaml.orig" ;;
                .gitleaks.toml) new="$work/toml"; orig="$work/toml.orig" ;;
            esac
            cmp -s "$new" "$vault/$f" || continue
            git -C "$vault" diff --quiet HEAD -- "$f" && continue
            [ -f "$orig" ] && cp "$orig" "$vault/$f"
        done
    }
    if ! (cd "$vault" && SKIP="$SKIP_FIXERS" git hook run pre-commit </dev/null >/dev/null 2>&1); then
        rollback; rm -rf "$work"; alert "still-refused-after-remediation $classes (rolled back)" 0; return 0
    fi
    # Another writer may have changed a config file since it was written: never
    # commit someone else's edit under this cadence's name.
    for f in $files; do
        case "$f" in .pre-commit-config.yaml) wf="$work/yaml" ;; .gitleaks.toml) wf="$work/toml" ;; esac
        if ! cmp -s "$wf" "$vault/$f"; then
            rm -rf "$work"; alert "config-changed-during-run $f (not committed)" 0; return 0
        fi
    done
    # shellcheck disable=SC2086  # $files is a space-separated list of fixed names
    if ! SKIP="$SKIP_FIXERS" git -C "$vault" commit -q --only -m "chore(vault): [HIMMEL-4471] remediate stall class ${classes// /, }" -- $files >/dev/null 2>&1; then
        # The vault sync shares no lock with this run: it may have staged and
        # committed the edit itself between the re-run and this commit. Then
        # HEAD already holds it, and a rollback would revert a landed fix.
        # shellcheck disable=SC2086  # $files is a space-separated list of fixed names
        if ! git -C "$vault" diff --quiet HEAD -- $files; then
            rollback; rm -rf "$work"; alert "remediation-commit-refused $classes (rolled back)" 0; return 0
        fi
        echo "vault-stall: the edit landed through another commit (the sync); not rolled back"
    fi
    rm -rf "$work"
    for c in $classes; do printf '%s\t%s\t%s\n' "$now" "$c" "$vault" >> "$STATE_DIR/remediated.tsv"; done
    echo "vault-stall: REMEDIATED $classes - committed $files; the next sync flushes the backlog"
    bash "$ALERT" clear "$LEG"
    return 0
}

# "no crontab for <user>" is an empty table; any other read failure is an error
# (installing over it would drop the operator's other jobs).
cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR vault-stall: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local force=0 dry=0 vault root runner bash_bin entry
    vault="$(default_vault)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --vault) [ $# -ge 2 ] || { echo "ERR vault-stall: --vault needs a path" >&2; return 1; }
                     vault="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR vault-stall: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR vault-stall: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR vault-stall: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    command -v flock >/dev/null 2>&1 || { echo "ERR vault-stall: flock not on PATH (every run needs it; on macOS: brew install flock)" >&2; return 2; }
    git -C "$vault" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERR vault-stall: not a git repo: $vault" >&2; return 2; }
    vault="$(cd "$vault" && pwd -P)" || return 2   # cron runs from $HOME: bake an absolute path
    root="$(resolve_primary)" || { echo "ERR vault-stall: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR vault-stall: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/vault-stall-cadence.sh"
    local pct='%'
    entry="*/15 * * * * \"${runner//"$pct"/\\%}\" # $TASK_NAME"   # cron reads a bare % as a newline
    if [ "$dry" -eq 1 ]; then
        echo "DRY vault-stall: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# vault-stall runner — generated by vault-stall-cadence.sh arm (HIMMEL-4471)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/vault-stall-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run --vault %q >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/luna/vault-stall-cadence.sh" "$vault"
    } > "$runner" || { echo "ERR vault-stall: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR vault-stall: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR vault-stall: crontab install failed" >&2; return 4; }
    observability_register_cadence "$LEG" 900 "$TASK_NAME"
    echo "vault-stall ARMED: every 15 min — $runner (status: bash scripts/luna/vault-stall-cadence.sh status)"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    [ -f "$STATE_DIR/last-run.log" ] && echo "  last stall $(date -r "$STATE_DIR/last-run.log" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "vault-stall: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY vault-stall: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/vault-stall-cadence.sh"
    observability_unregister_cadence "$LEG" "$TASK_NAME"
    echo "vault-stall: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: vault-stall-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
