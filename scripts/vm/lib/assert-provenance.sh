#!/usr/bin/env bash
# assert-provenance.sh — the named checks of the install-provenance round trip
# (HIMMEL-3332 S9b, spec §11 steps 5 and 7). Runs ON the guest after inventory
# C, from scripts/vm/provenance-roundtrip.sh, and only reports: every check is
# one line
#     CHECK <group> <direction> <PASS|FAIL|SKIP> <name> — <detail>
# and the verdict is the host's. Directions:
#     too-much    uninstall removed or broke something of the user's
#     too-little  uninstall left something of himmel's behind
#     identity    a seeded file differs from its seeded bytes (either cause)
#     ledger      the install ledger is missing, incomplete or unrecording
#     precondition  the run could not observe a direction at all (RT_PROFILE=all
#                 only: install armed no cadence crontab line, so a leftover one
#                 would be invisible); a FAIL is never green, and it is in
#                 neither count of the RED verdict
# Inputs: $INV_BASE (default /tmp)/inv-{A,B,C} (inventory.sh), and next to this
# script seeded.list, state.list, seed-state/ (all seed-provenance.sh),
# ledger-B.jsonl (the harness's copy of the ledger after install, absent when
# install wrote none) and, under RT_PROFILE=all, crontab-B.txt (`crontab -l`
# after install). RT_PURGE=1 when the uninstall ran with --purge-state.
# Exit 0 after reporting; 2 when an input is missing (nothing is judged).
#
# ponytail: residue is grouped by its first three path components under HOME
# and printed with one sample path per group, so a group hiding several
# unrelated leftovers reads as one line; the full lists are the inventories.
# shellcheck disable=SC2016 # jq programs and literal shell lines are single-quoted on purpose.
set -u
export LC_ALL=C

[ "${HIMMEL_RT_GUEST:-}" = 1 ] || { echo "assert-provenance.sh: refusing: guest-only (set HIMMEL_RT_GUEST=1 on the guest)" >&2; exit 2; }
H="$HOME"
D="$(cd "$(dirname "$0")" && pwd)"
ST="$D/seed-state"
PURGE="${RT_PURGE:-0}"
PROFILE="${RT_PROFILE:-core}"
INV="${INV_BASE:-/tmp}"  # the inventories' base dir; only the hermetic test sets INV_BASE
for f in "$INV"/inv-{A,B,C}/home.{meta,sha} "$D/seeded.list" "$D/state.list" "$ST/settings.json"; do
    [ -f "$f" ] || { echo "assert-provenance.sh: missing input $f" >&2; exit 2; }
done

check() {  # <group> <direction> <PASS|FAIL|SKIP> <name> <detail>
    printf 'CHECK %s %s %s %s — %s\n' "$1" "$2" "$3" "$4" "$5"
}
# ok <group> <direction> <name> <detail-on-fail> <command...> — PASS when the command succeeds.
ok() {
    local g="$1" dir="$2" n="$3" det="$4"; shift 4
    if "$@" >/dev/null 2>&1; then check "$g" "$dir" PASS "$n" "ok"; else check "$g" "$dir" FAIL "$n" "$det"; fi
}
rel() { printf '~%s' "${1#"$H"}"; }
sha_of() { awk -v p="$2" 'substr($0, 67) == p { print substr($0, 1, 64) }' "$INV/inv-$1/home.sha"; }
meta_of() { awk -F'\t' -v p="$2" '$4 == p { print $1 "\t" $2 "\t" $5 }' "$INV/inv-$1/home.meta"; }

S="$H/.claude/settings.json"
SEEDS="$ST/settings.json"
L="$D/ledger-B.jsonl"
PL="$H/.claude/plugins"
MK="$PL/marketplaces"
# led_units <marketplace|plugin> — "<unit><TAB><preexisted>" once per unit
# install-plugins.sh registered, the flag taken from the unit's FIRST row (a
# later scope's run sees the first one's registration as pre-existing).
led_units() {
    [ -f "$L" ] || return 0
    jq -rs --arg k "$1" '[.[] | select(.kind == $k and .op == "register" and (.unit // "") != "")]
        | group_by(.unit) | .[] | "\(.[0].unit)\t\(.[0].preexisted)"' "$L" 2>/dev/null
}
# HIMMEL-3541 class 1: the marketplaces the operator had ALREADY registered
# (the ledger says preexisted, and the clone dir is in inventory A). The
# Claude Code CLI re-fetches such a clone when install-plugins.sh's
# "Registering marketplaces" step runs `claude plugin marketplace add` for it,
# so its clone is the CLI's refresh of the operator's own marketplace.
# json_delta <A copy> <C file> [keys to ignore, JSON array] [top-level
# defaults, JSON object: a key at its default counts as absent]: the first leaf
# paths (an empty container counts as a leaf) whose values differ, each as
# path=A->C, so a FAIL names what changed instead of only two shas; when no
# value differs, the top-level key order of both.
json_delta() {
    jq -rn --slurpfile a "$1" --slurpfile c "$2" --argjson k "${3:-[]}" --argjson f "${4:-{\}}" '
        def nodflt: if type == "object" then with_entries(select(.key as $x | ($f | has($x) | not) or .value != $f[$x])) else . end;
        ($k | map([.])) as $d | ($a[0] | delpaths($d) | nodflt) as $A | ($c[0] | delpaths($d) | nodflt) as $C
        | def leaves: paths((type != "object" and type != "array") or length == 0);
          [($A | leaves), ($C | leaves)] | unique
        | map(select(. as $q | ($A | getpath($q)) != ($C | getpath($q))))
        | .[:6] | map(. as $q | ($q | map(tostring) | join(".")) + "=" + ($A | getpath($q) | tojson | .[:40])
            + "->" + ($C | getpath($q) | tojson | .[:40]))
        | if length > 0 then join(", ")
          else "no value differs; key order A=" + ($a[0] | keys_unsorted | join(",")) + " C=" + ($c[0] | keys_unsorted | join(","))
          end' 2>/dev/null
}
MKT_PRE_A=" "
while IFS=$'\t' read -r m pre; do
    case "$m" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "$pre" = true ] && [ -n "$(meta_of A "$MK/$m")" ] && MKT_PRE_A="$MKT_PRE_A$m "
done < <(led_units marketplace)
# The keys the Claude Code CLI writes into ~/.claude.json on its own start (the
# uninstall runs `claude plugin ...`), none of them ever written by himmel:
# first-run stamps, the machine/user ids, and its settings migrations.
# ponytail: an exact list, so a future CLI key fails claude-json-restored until
# it is added here (the safe direction); re-derive from the RT's A-vs-C diff.
# The CLI also saves ~/.claude.json without every key equal to its default
# (Claude Code 2.1.281 saveGlobalConfig keeps only keys whose JSON differs from
# its default config), so a key at one of these defaults counts as absent.
CLI_DEFAULTS='{"theme":"dark","preferredNotifChannel":"auto","verbose":false,"editorMode":"normal","autoCompactEnabled":true,"autoScrollEnabled":true,"showTurnDuration":true,"numStartups":0}'
CLI_KEYS='["firstStartTime","firstStartVersion","hasResetAutoModeOptInForDefaultOffer","machineID","migrationVersion","opusProMigrationComplete","seenNotifications","sonnet1m45MigrationComplete","userID"]'

# =========================================================== 1. byte identity
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$p" = "$H/.claude.json" ]; then
        # HIMMEL-3541 class 4: uninstall removes the trust entry install added
        # for ~/proj (a ledger row, parent included when install created it),
        # so ~/.claude.json must equal A again -- outside CLI_KEYS, which the
        # Claude Code CLI itself writes whenever the install or uninstall runs it.
        if [ -z "$(meta_of C "$p")" ]; then
            check identity too-much FAIL claude-json-restored "removed (present at A)"
        elif jq -en --slurpfile a "$ST/claude.json" --slurpfile c "$p" --argjson k "$CLI_KEYS" --argjson f "$CLI_DEFAULTS" '
                def nodflt: with_entries(select(.key as $x | ($f | has($x) | not) or .value != $f[$x]));
                ($k | map([.])) as $d | ($a[0] | delpaths($d) | nodflt) == ($c[0] | delpaths($d) | nodflt)' >/dev/null 2>&1; then
            check identity identity PASS claude-json-restored "equal to A outside the CLI's own keys and defaults"
        else
            check identity identity FAIL claude-json-restored "differs from A outside the CLI's own keys at: $(json_delta "$ST/claude.json" "$p" "$CLI_KEYS" "$CLI_DEFAULTS")"
        fi
        continue
    fi
    case "$p" in "$MK"/*/.claude-plugin/marketplace.json)
        m=${p#"$MK"/}; m=${m%%/*}
        if [ "${MKT_PRE_A#* "$m" }" != "$MKT_PRE_A" ] && [ -n "$(meta_of C "$p")" ]; then
            check identity identity PASS "seeded:$(rel "$p")" "not compared: the CLI refreshed marketplace $m (registered at A) during install-plugins.sh's marketplace add"
            continue
        fi ;;
    esac
    ma=$(meta_of A "$p") mc=$(meta_of C "$p")
    if [ -z "$mc" ]; then
        check identity too-much FAIL "seeded:$(rel "$p")" "removed (present at A)"
    elif [ "$(sha_of A "$p")" != "$(sha_of C "$p")" ]; then
        delta="" acopy=""
        case "$p" in
            "$H/.claude/settings.json") acopy="$ST/settings.json" ;;
            "$H/proj/.claude/settings.json") acopy="$ST/proj-settings.json" ;;
        esac
        # `claude plugin marketplace add|install` (install-plugins.sh) rewrites
        # settings.json in the CLI's own key order: the same values restored.
        if [ -n "$acopy" ] && jq -en --slurpfile a "$acopy" --slurpfile c "$p" '$a[0] == $c[0]' >/dev/null 2>&1; then
            check identity identity PASS "seeded:$(rel "$p")" "same JSON values as A; only the key order differs (the Claude Code CLI's own serialization)"
            continue
        fi
        [ -z "$acopy" ] || delta=" at: $(json_delta "$acopy" "$p")"
        check identity identity FAIL "seeded:$(rel "$p")" "content changed (sha A=$(sha_of A "$p" | cut -c1-12) C=$(sha_of C "$p" | cut -c1-12))$delta"
    elif [ "$ma" != "$mc" ]; then
        check identity identity FAIL "seeded:$(rel "$p")" "type/mode/target changed ($(printf '%s' "$ma" | tr '\t' ' ') -> $(printf '%s' "$mc" | tr '\t' ' '))"
    else
        check identity identity PASS "seeded:$(rel "$p")" "bytes, mode and target equal to A"
    fi
done <"$D/seeded.list"

# ============================================ 2. semantic: the user's settings
jseed() { jq -c "$1" "$SEEDS"; }
# shellcheck disable=SC2317,SC2329 # invoked through ok()
jeq() { [ -f "$S" ] && [ "$(jq -c "$1" "$S" 2>/dev/null)" = "$(jseed "$1")" ]; }
ok semantic too-much context7-enabled 'enabledPlugins["context7@claude-plugins-official"] is not true' \
    jq -e '.enabledPlugins["context7@claude-plugins-official"] == true' "$S"
ok semantic too-much my-tool-enabled 'enabledPlugins["my-tool@my-market"] is not true' \
    jq -e '.enabledPlugins["my-tool@my-market"] == true' "$S"
ok semantic too-much user-statusline "statusLine is $(jq -c '.statusLine // "absent"' "$S" 2>/dev/null)" jeq '.statusLine'
ok semantic too-much handover-dir "env.HANDOVER_DIR is $(jq -c '.env.HANDOVER_DIR // "absent"' "$S" 2>/dev/null)" jeq '.env.HANDOVER_DIR'
ok semantic too-much user-mcp 'mcpServers["my-mcp"] differs from the seed' jeq '.mcpServers["my-mcp"]'
ok semantic too-much user-marketplaces 'extraKnownMarketplaces lost or changed a seeded entry' \
    jeq '.extraKnownMarketplaces | {"claude-plugins-official": .["claude-plugins-official"], "my-market": .["my-market"]}'
user_hook=$(jseed '.hooks.PreToolUse[0].hooks[0].command')
ok semantic too-much user-pretooluse-hook 'the seeded PreToolUse Bash hook is gone' \
    jq -e --argjson c "$user_hook" '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command] | index($c) != null' "$S"
HUD="$H/.claude/plugins/claude-hud/config.json"
if [ -f "$HUD" ]; then
    ok semantic too-much hud-config 'customLineCommand differs from the seed' \
        test "$(jq -c .customLineCommand "$HUD" 2>/dev/null)" = "$(jq -c .customLineCommand "$ST/hud-config.json")"
else
    check semantic too-much FAIL hud-config "$(rel "$HUD") is gone"
fi
WT="$H/proj/scripts/worktree.sh"
wt_sha=$( [ -f "$WT" ] && sha256sum "$WT" | cut -d' ' -f1 )
ok semantic too-much worktree-sh "sha is ${wt_sha:-absent}, seeded $(cut -c1-12 "$ST/worktree.sha")" test "$wt_sha" = "$(cat "$ST/worktree.sha")"
ok semantic too-much claude-md-user-content 'the user text of ~/.claude/CLAUDE.md is gone' \
    grep -q "Nothing after this is himmel's" "$H/.claude/CLAUDE.md"
ok semantic too-much trust-entry-other-project 'the trusted ~/other-project entry is gone from ~/.claude.json' \
    jq -e --arg o "$H/other-project" '.projects[$o].hasTrustDialogAccepted == true' "$H/.claude.json"
ok semantic too-much proj-settings-key 'the seeded permission is gone from ~/proj/.claude/settings.json' \
    jq -e '.permissions.allow | index("Bash(make test)") != null' "$H/proj/.claude/settings.json"
ok semantic too-much himmel-config-user-value 'the user choice luna.cadence.models.harvest="opus" is gone from ~/.himmel/config.json' \
    jq -e '.luna.cadence.models.harvest == "opus"' "$H/.himmel/config.json"

# ================================== 3. semantic: himmel's settings entries left
extra_keys() {  # <jq path to an object> — its keys at C that the seed did not have
    [ -f "$S" ] || return 0
    jq -r --slurpfile s "$SEEDS" "($1 // {} | keys) - (\$s[0] | $1 // {} | keys) | .[]" "$S" 2>/dev/null | tr '\n' ' '
}
if [ -f "$S" ] && jq -e '.env | has("CLAUDE_HUD_ALLOW_EXTRA_CMD")' "$S" >/dev/null 2>&1; then
    check semantic too-little FAIL hud-allow-extra-cmd-removed "env.CLAUDE_HUD_ALLOW_EXTRA_CMD still set ($(jq -c '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD' "$S"))"
else
    check semantic too-little PASS hud-allow-extra-cmd-removed "absent"
fi
for spec in 'top-level-keys:.' 'env-keys:.env' 'plugins:.enabledPlugins' 'marketplaces:.extraKnownMarketplaces' 'mcp:.mcpServers' 'hook-events:.hooks'; do
    name=${spec%%:*} path=${spec#*:}
    left=$(extra_keys "$path")
    [ "$name" != env-keys ] || left=$(printf '%s' "$left" | sed 's/CLAUDE_HUD_ALLOW_EXTRA_CMD //')
    if [ -n "$left" ]; then check semantic too-little FAIL "settings-$name-removed" "left: $left"
    else check semantic too-little PASS "settings-$name-removed" "none beyond the seed"; fi
done
hooks_left=$( [ -f "$S" ] && jq -r --argjson c "$user_hook" '[.hooks[]?[]?.hooks[]?.command | select(. != $c)] | length' "$S" 2>/dev/null )
if [ "${hooks_left:-0}" -gt 0 ]; then check semantic too-little FAIL settings-hook-commands-removed "$hooks_left hook command(s) beyond the seed"
else check semantic too-little PASS settings-hook-commands-removed "none beyond the seed"; fi
B_MARK='<!-- BEGIN HIMMEL:working-principles -->'
n=$(grep -cxF "$B_MARK" "$H/.claude/CLAUDE.md" 2>/dev/null)
if [ "${n:-0}" -le 1 ]; then check semantic too-little PASS working-principles-block-removed "marker lines: ${n:-0} (the seeded fenced one)"
else check semantic too-little FAIL working-principles-block-removed "marker lines: $n (seeded: 1)"; fi

# ============================================================ 4. parse
for f in "$S" "$H/.claude.json" "$H/proj/.claude/settings.json" "$HUD"; do
    if [ -f "$f" ]; then ok parse too-much "json:$(rel "$f")" 'does not parse' jq -e . "$f"
    else check parse too-much SKIP "json:$(rel "$f")" "absent (reported above)"; fi
done
for f in "$H"/proj/scripts/*.sh "$H"/proj/scripts/hooks/*.sh "$H/.bashrc"; do
    [ -f "$f" ] || continue
    ok parse too-much "bash-n:$(rel "$f")" 'bash -n fails' bash -n "$f"
done
if command -v systemd-analyze >/dev/null 2>&1; then
    ok parse too-much unit:mine.service 'systemd-analyze verify fails' systemd-analyze --user verify "$H/.config/systemd/user/mine.service"
else
    check parse too-much SKIP unit:mine.service "no systemd-analyze"
fi

# ============================================================ 5. execute
ok execute too-much worktree-version "does not print USER-WORKTREE-v1" \
    bash -c '[ "$("$1" --version)" = USER-WORKTREE-v1 ]' _ "$WT"
pc_out=$(git -C "$H/proj" -c user.name=rt -c user.email=rt@invalid commit --allow-empty -qm 'rt probe' 2>&1); pc_rc=$?
if [ "$pc_rc" -eq 0 ] && printf '%s' "$pc_out" | grep -q USER-PRECOMMIT; then
    check execute too-much PASS user-pre-commit "ran and exited 0"
else
    check execute too-much FAIL user-pre-commit "rc=$pc_rc out=$(printf '%s' "$pc_out" | head -c 160 | tr '\n' ' ')"
fi
ok execute too-much login-shell-myfn "myfn is not defined in a login shell" bash -lc 'type myfn'

# ================================================== 6. path resolution + jobs
mt=$(bash -lc 'command -v mytool' 2>/dev/null)
ok path too-much mytool-resolves "command -v mytool = '${mt:-none}'" test "$mt" = "$H/.local/bin/mytool"
hc=$(bash -lc 'command -v himmelctl' 2>/dev/null)
ok path too-little himmelctl-gone "command -v himmelctl = '$hc'" test -z "$hc"
ok removal too-little launcher-removed "$(rel "$H/.local/bin/himmelctl") present" test ! -e "$H/.local/bin/himmelctl"
ok removal too-little claude-himmel-dir-removed "$(rel "$H/.claude/himmel") present" test ! -e "$H/.claude/himmel"
cron_now=$(crontab -l 2>/dev/null)
cron_extra=$(printf '%s\n' "$cron_now" | grep -vxF -f "$ST/crontab.txt" | grep -v '^$')
if [ -n "$cron_extra" ]; then
    check removal too-little FAIL cadence-crontab-removed "$(printf '%s\n' "$cron_extra" | wc -l) line(s) left: $(printf '%s' "$cron_extra" | head -c 200 | tr '\n' '|')"
else
    check removal too-little PASS cadence-crontab-removed "no line beyond the seed"
fi
if printf '%s\n' "$cron_now" | grep -qxF -f "$ST/crontab.txt"; then check path too-much PASS user-crontab "seeded line present"
else check path too-much FAIL user-crontab "the seeded crontab line is gone"; fi
en=$(systemctl --user is-enabled mine.service 2>/dev/null)
ok path too-much mine-service-enabled "is-enabled '$en', seeded '$(cat "$ST/mine-enabled.txt")'" test "$en" = "$(cat "$ST/mine-enabled.txt")"
# Judged against A, not seeded.list: everything under the user's unit dir at A
# is theirs (a unit beyond it is himmel's), whatever put it there.
units_left=$(awk -F'\t' -v u="$H/.config/systemd/user/" 'NR == FNR { a[$4] = 1; next } ($1 == "f" || $1 == "l") && index($4, u) == 1 && !($4 in a) { printf "%s ", $4 }' \
    "$INV/inv-A/home.meta" "$INV/inv-C/home.meta")
if [ -n "$units_left" ]; then check removal too-little FAIL user-units-removed "left: $units_left"
else check removal too-little PASS user-units-removed "nothing new since A"; fi

# ============================ 6b. the seeded telegram + bridge state (state.list)
# A plain uninstall keeps every path, byte-identical to A; --purge-state removes
# every one of them.
while IFS= read -r p; do
    [ -n "$p" ] || continue
    mc=$(meta_of C "$p")
    if [ "$PURGE" = 1 ]; then
        if [ -z "$mc" ]; then check state too-little PASS "state-purged:$(rel "$p")" "gone"
        else check state too-little FAIL "state-purged:$(rel "$p")" "still present after --purge-state"; fi
    elif [ -z "$mc" ]; then
        check state too-much FAIL "state-kept:$(rel "$p")" "removed by a plain uninstall (present at A)"
    elif [ "$(sha_of A "$p")" != "$(sha_of C "$p")" ]; then
        check state too-much FAIL "state-kept:$(rel "$p")" "content changed (sha A=$(sha_of A "$p" | cut -c1-12) C=$(sha_of C "$p" | cut -c1-12))"
    else
        check state too-much PASS "state-kept:$(rel "$p")" "kept, equal to A"
    fi
done <"$D/state.list"

# ========================= 6c. --profile all: the stubs, and the armed cadences
# The qmd and graphify stubs are the USER's own pre-existing files (seeded, in
# seeded.list; the byte-identity loop above judges them too): uninstall removing
# one is a too-much witness, and they are never counted as himmel's.
if [ "$PROFILE" = all ]; then
    for b in qmd graphify; do
        ok stub too-much "user-stub-$b-survives" "$(rel "$H/.local/bin/$b") is gone or not executable" test -x "$H/.local/bin/$b"
    done
    # The too-little direction of cadence-crontab-removed is only observable when
    # install armed a crontab line of each cadence the profile asks for.
    CB="$D/crontab-B.txt"
    missing=""
    for fam in Pipeline Qmd GraphMap; do
        [ -f "$CB" ] && grep -q "# HIMMEL-$fam" "$CB" || missing="$missing $fam"
    done
    if [ -z "$missing" ]; then
        check precondition precondition PASS cadence-crontab-armed-at-B "a HIMMEL-{Pipeline,Qmd,GraphMap}* line is armed after install"
    else
        check precondition precondition FAIL cadence-crontab-armed-at-B "no armed line for:$missing (crontab-B.txt $([ -f "$CB" ] && echo "read" || echo absent)): cadence-crontab-removed cannot observe a leftover"
    fi
fi

# ==================================================== 7. residue (C vs A)
# The 3330 allowlist: caches install may fill and uninstall may keep. The
# ledger, the standalone uninstall bundle (S13) and provenance-backups/ are
# allowed too, except after --purge-state, which is the step that removes all
# three (HIMMEL-3541: a plain run must not flag them as leftover residue).
#
# HIMMEL-3541 sizing (N444, 2026-09-24) added three more, each with a named
# writer and a citation -- no path is allowlisted without both:
#   - $H/.npm/_update-notifier-last-checked: npm's own update-notifier module
#     writes this on any `npm` invocation himmel's install runs; covered by
#     the `third-party-caches` manifest row (uninstall-manifest.tsv:56,
#     HIMMEL-3330: "caches other tools wrote while himmel ran ... theirs,
#     never himmel-provenanced, so not removed").
#   - $H/proj/scripts/(guardrails|lib): himmel's own file copies into the
#     adopter's scripts/ tree; uninstall removes the recorded FILES (see the
#     "removed .../guard-gh.sh" etc. lines) but the manifest's `scripts` row
#     is class NEVER for the containing tree -- "himmel scripts copied into
#     a project-scope adopter's scripts/ -- code for recorded files;
#     unrecorded copies kept ... drop them with git if unwanted" (printed
#     verbatim by uninstall.sh) -- the now-empty directories are that same
#     documented non-cleanup, not a bug.
#   - $H/.codex: himmel only ever manages the FILE $H/.codex/AGENTS.md
#     (manifest row `user-agents-md`, class block/STRIP); the directory
#     itself is grouped with ~/.claude, ~/.ssh, ~/.gitconfig, ~/.config,
#     ~/.local as an operator-owned dir uninstall.sh deliberately never
#     deletes wholesale (uninstall.sh:43,615,1486,1492,1496).
#   - $H/.local/share/himmel: HIMMEL-3059 S6 (--install-from tarball). The
#     versioned tree + `current` symlink the tarball recipe extracts. For a
#     tarball tree, bin.js's himmelRoot() resolves to this `current` path and
#     uninstall.sh:116 derives its own REPO_ROOT the same way (dirname of the
#     running script's own tree) -- so the manifest's `himmel-clone` row
#     (class keep, target {REPO_ROOT}: "the himmel clone itself ... uninstall
#     never removes it") already covers it; this is that same keep, generalized
#     from a git clone to a tarball-installed root, not a new exemption.
allow="^($H/\\.npm/_cacache|$H/\\.npm/_logs|$H/\\.npm/_update-notifier-last-checked|$H/\\.cache/node-gyp|$H/\\.bun/install/cache|$H/\\.claude/plugins/cache|$H/\\.cache/qmd|$H/proj/scripts/guardrails|$H/proj/scripts/lib|$H/\\.codex|$H/\\.local/share/himmel"
[ "$PURGE" = 1 ] || allow="$allow|$H/\\.himmel/provenance(\\.jsonl)?|$H/\\.himmel/uninstall|$H/\\.himmel/provenance-backups"
# HIMMEL-3559: --profile all seeds a real vault at $H/luna (the adopter-<scope>
# profile overlay's .vault.path — see provenance-roundtrip.sh's OVERLAY) so the
# adopter has second-brain content from the first run. It is the operator's
# data, never himmel's: uninstall must never touch it, so it is a residue
# allowance here, not a manifest removal row.
[ "$PROFILE" = all ] && allow="$allow|$H/luna"
# HIMMEL-3541 class 1: the clone of a marketplace registered at A (MKT_PRE_A
# above) -- the CLI's refresh of the operator's own marketplace, which the
# uninstall rightly keeps ("kept (was already yours)"). Only those dirs.
for m in $MKT_PRE_A; do allow="$allow|$MK/${m//./\\.}"; done
allow="$allow)(/|\$)"
# HIMMEL-3541 class 1: files the Claude Code CLI writes for itself whenever
# install-plugins.sh or uninstall.sh runs it -- exact paths, nothing beneath:
# its ~/.claude.json lock and timestamped backups, its in-use sweep stamp, and
# its own marketplace/plugin registries (cli-registries-clean below checks
# those no longer name anything himmel registered).
allow="$allow|^($H/\\.claude\\.json\\.lock|$H/\\.claude/backups|$H/\\.claude/backups/\\.claude\\.json\\.backup\\.[0-9]+|$PL/\\.last_inuse_sweep|$PL/known_marketplaces\\.json|$PL/installed_plugins\\.json)\$"
# paths <a> <b> <mode>: new = in b not a; gone = in a not b; changed = regular
# file in both with a different sha. Directories count only when new/gone.
paths() {
    case "$3" in
        new|gone)
            awk -F'\t' 'NR == FNR { seen[$4] = 1; next } !($4 in seen) { print $4 }' \
                "$INV/inv-$([ "$3" = new ] && echo "$1" || echo "$2")/home.meta" \
                "$INV/inv-$([ "$3" = new ] && echo "$2" || echo "$1")/home.meta" ;;
        changed)
            awk 'NR == FNR { s[substr($0, 67)] = substr($0, 1, 64); next }
                 (substr($0, 67) in s) && s[substr($0, 67)] != substr($0, 1, 64) { print substr($0, 67) }' \
                "$INV/inv-$1/home.sha" "$INV/inv-$2/home.sha" ;;
    esac
}
group() { awk -v h="$H/" '{ r = substr($0, length(h) + 1); n = split(r, a, "/"); k = a[1]; for (i = 2; i <= 3 && i <= n; i++) k = k "/" a[i]; if (!(k in c)) { order[++m] = k; s[k] = $0 } c[k]++ } END { for (i = 1; i <= m; i++) print c[order[i]] "\t~/" order[i] "\t" s[order[i]] }'; }
report_groups() {  # <direction> <name-prefix> <verb> — reads paths on stdin
    local dir="$1" pre="$2" verb="$3" any=0 cnt key sample
    while IFS=$'\t' read -r cnt key sample; do
        any=1
        check residue "$dir" FAIL "$pre:$key" "$cnt path(s) $verb, e.g. $(rel "$sample")"
    done < <(grep -vE "$allow" | grep -vxF -f "$D/seeded.list" -f "$D/state.list" | group | head -n 40)
    [ "$any" = 1 ] || check residue "$dir" PASS "$pre" "none outside the allowlist"
}
paths A C new | report_groups too-little left "left behind (not at A)"
paths A C gone | report_groups too-much gone "gone (present at A)"
paths A C changed | report_groups too-little changed "changed since A and not restored"
# The CLI registries are allowlisted above as files; what they list is not:
# nothing himmel registered (first row not preexisted) may still be named.
reg_left=""
while IFS=$'\t' read -r m pre; do
    [ "$pre" = false ] && jq -e --arg m "$m" 'has($m)' "$PL/known_marketplaces.json" >/dev/null 2>&1 && reg_left="$reg_left$m "
done < <(led_units marketplace)
# installed_plugins.json keeps one entry per install scope, so a plugin is
# checked per (scope, project): himmel's project-scope install of a plugin the
# operator already had at user scope leaves the user entry, legitimately.
if [ -f "$L" ] && [ -f "$PL/installed_plugins.json" ]; then
    while IFS= read -r u; do reg_left="$reg_left$u "; done < <(jq -rs --slurpfile ip "$PL/installed_plugins.json" '
        (($ip[0].plugins // {}) | if type == "object" then . else {} end) as $P
        | [.[] | select(.kind == "plugin" and .op == "register" and (.unit // "") != "")]
        | group_by([.unit, (.cli_scope // ""), (.project_path // "")]) | .[] | .[0]
        | select(.preexisted == false) | . as $r | ($r.cli_scope // "") as $s
        | select(($P | has($r.unit)) and ($s == "" or ([$P[$r.unit][]?
            | select(.scope == $s and ($s != "project" or (.projectPath // "") == ($r.project_path // "")))] | length > 0)))
        | $r.unit + (if $s == "project" then "(project)" else "" end)' "$L" 2>/dev/null)
fi
if [ -n "$reg_left" ]; then check semantic too-little FAIL cli-registries-clean "left: ${reg_left% }"
else check semantic too-little PASS cli-registries-clean "no marketplace or plugin himmel registered"; fi

# ====================================================== 8. ledger (step 5)
if [ -f "$L" ]; then
    check ledger ledger PASS ledger-exists "$(wc -l <"$L") row(s) after install"
    ok ledger ledger ledger-install-begin 'no install-begin row' jq -se 'map(select(.op == "install-begin")) | length > 0' "$L"
    ok ledger ledger ledger-install-end-ok 'no install-end status=ok row' jq -se 'map(select(.op == "install-end" and .status == "ok")) | length > 0' "$L"
    jq -r 'select(.path != null) | .path' "$L" 2>/dev/null | sort -u >"$D/ledger-paths.txt"
    # a registered marketplace's clone is the CLI's write for that register row
    { jq -r 'select(.path != null and .kind == "tree") | .path' "$L" 2>/dev/null
      led_units marketplace | while IFS=$'\t' read -r m _; do
          case "$m" in ''|*[!A-Za-z0-9._-]*) ;; *) printf '%s\n' "$MK/$m" ;; esac
      done; } | sort -u >"$D/ledger-trees.txt"
else
    check ledger ledger FAIL ledger-exists "no provenance.jsonl after install"
    : >"$D/ledger-paths.txt"
    : >"$D/ledger-trees.txt"
fi
# No unrecorded write: every path new or changed at B (outside the allowlist)
# is a ledger row's path, lies under a `tree` row's path, or is a directory
# above a ledger row's path (HIMMEL-3541 class 5: its writer's mkdir -p).
unrec=$( { paths A B new; paths A B changed; } | grep -vE "$allow" | awk -v h="$H/" 'FILENAME == ARGV[1] { if ($0 != "") { p[$0] = 1; x = $0; while (sub(/\/[^\/]*$/, "", x) && x != "" && x "/" != h) a[x] = 1 } next }
    FILENAME == ARGV[2] { if ($0 != "") t[$0] = 1; next }
    { hit = ($0 in p) || ($0 in a) || ($0 in t); x = $0; while (!hit) { sub(/\/[^\/]*$/, "", x); if (x == "" || x "/" == h) break; if (x in t) hit = 1 } if (!hit) print }' "$D/ledger-paths.txt" "$D/ledger-trees.txt" - )
n=$(printf '%s' "$unrec" | grep -c .)
if [ "$n" -eq 0 ]; then check ledger ledger PASS no-unrecorded-write "every write at B has a ledger row"
else check ledger ledger FAIL no-unrecorded-write "$n path(s) written with no ledger row, e.g. $(printf '%s\n' "$unrec" | head -n 3 | while IFS= read -r x; do rel "$x"; printf ' '; done)"; fi
exit 0
