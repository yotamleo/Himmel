#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh (HIMMEL-4164 split, so each
# suite stays under its CI per-suite cap): slice 1 of 3 of the HIMMEL-2592
# generated grammar matrix (this slice also carries the one-off ordering and
# enumerator guards) plus the round-9 POSITION x ARM rows.
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh and
# lib-test-write-fence-matrix.sh; the FIXTURE RULE lives in
# test-block-write-into-main-checkout.sh.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"
# shellcheck source=lib-test-write-fence-matrix.sh
. "$(dirname "$0")/lib-test-write-fence-matrix.sh"

_matrix_run_slice 1 3

echo "== HIMMEL-2592 round 9 (RETASK R-N1-SED-4b91d7) — POSITION x ARM: a redirect leading/mid/trailing =="
#
# Console-mandated STANDING GUARD, not a scratch probe: three rounds each
# fixed one shape a redirect could take relative to an option/operand
# (round 6: before a separated option value; round 7: input vs output
# direction; round 8: a bare fd digit as a real value) and round 8's fix
# still had a live fail-open because TRAILING position — the redirect after
# every real operand — had never been tested in ANY arm. Round 9 replaced
# the point fixes with a structural one (see _bwimc_space_before_redirects'
# header): a bare fd number now never becomes a separate token at all, so
# no arm can see one. This matrix is what proves that holds across EVERY
# arm this fence models, at all three redirect positions, not just cp
# (where the round-8 panel happened to find it) — "re-ask the question per
# arm rather than reasoning from cp," per the retask.
#
# `dd` is on the console's arm list but is NOT modelled by this fence at
# all — no verb-scan arm matches it (grep the five `grep -E
# '^[[:space:]]*<verb>...'` anchors above: sed, cp|mv, rm|touch, ln, git —
# no dd). No coverage is invented for it; this is the explicit "say so"
# answer, not an oversight.
#
# Two operands per cell (OTHER, always worktree-local and harmless; DEST,
# the one under test) so MID position is real for every verb, including the
# single-target ones (rm/touch/tee all accept multiple operands; ln's
# second operand is its destination). `want` is measured — the REAL command
# is executed and the primary snapshot-diffed, same oracle as the main
# matrix above, gated on the SAME MATRIX_STAT_READY this file already
# established (a degraded stat oracle must skip, not silently pass).
_r9_specs() {
    printf '%s\t%s\t%s\n' cp    leading  "cp 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' cp    mid      "cp {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' cp    trailing "cp {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' mv    leading  "mv 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' mv    mid      "mv {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' mv    trailing "mv {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' rm    leading  "rm 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' rm    mid      "rm {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' rm    trailing "rm {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' touch leading  "touch 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' touch mid      "touch {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' touch trailing "touch {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' ln    leading  "ln -s 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' ln    mid      "ln -s {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' ln    trailing "ln -s {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' tee   leading  "printf 'x\\n' | tee 2>/dev/null {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' tee   mid      "printf 'x\\n' | tee {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' tee   trailing "printf 'x\\n' | tee {OTHER} {DEST} 2>/dev/null"
    printf '%s\t%s\t%s\n' sed   leading  "sed 2>/dev/null -i 's/a/b/' {OTHER} {DEST}"
    printf '%s\t%s\t%s\n' sed   mid      "sed -i 's/a/b/' {OTHER} 2>/dev/null {DEST}"
    printf '%s\t%s\t%s\n' sed   trailing "sed -i 's/a/b/' {OTHER} {DEST} 2>/dev/null"
}

# _r9_build DIR VERB LOC -> sets R9_P R9_W R9_OTHER R9_DEST; DEST lives in
# primary or wt per LOC. `ln`'s DEST must NOT pre-exist (ln refuses an
# existing entry without -f); every other verb's DEST is a real file so
# rm/sed/cp/mv/touch/tee all have something real to act on.
_r9_build() {
    local dir="$1" verb="$2" loc="$3" base
    rm -rf "$dir"; mkdir -p "$dir"
    R9_P="$dir/primary"; R9_W="$dir/wt"
    git init -q "$R9_P" >/dev/null 2>&1 || return 1
    git -C "$R9_P" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    printf 'tracked\n' > "$R9_P/README.md"
    git -C "$R9_P" add README.md >/dev/null 2>&1
    git -C "$R9_P" commit -q -m init >/dev/null 2>&1
    git -C "$R9_P" worktree add -q -b feat/r9 "$R9_W" >/dev/null 2>&1 || return 1
    printf 'other\n' > "$R9_W/other.txt"
    R9_OTHER="$R9_W/other.txt"
    if [ "$loc" = primary ]; then base="$R9_P"; else base="$R9_W"; fi
    if [ "$verb" = ln ]; then
        R9_DEST="$base/newlink.txt"
    else
        printf 'orig\n' > "$base/destfile.txt"
        R9_DEST="$base/destfile.txt"
    fi
    return 0
}

if [ "$MATRIX_STAT_READY" != 1 ]; then
    echo "  SKIP HIMMEL-2592 round 9 position x arm matrix — host stat can't give GNU -c '%i|%y' (inode + SUB-SECOND mtime): $MATRIX_STAT_DIAG -- same degraded-oracle risk the main matrix above already refuses to run under."
else
R9_A=0; R9_B=0; R9_C=0; R9_AV=0; R9_BV=0
R9_DIR="$FIX/r9matrix"
while IFS=$'\t' read -r r9_verb r9_pos r9_tmpl; do
    [ -n "$r9_verb" ] || continue
    for r9_loc in primary wt; do
        if ! _r9_build "$R9_DIR" "$r9_verb" "$r9_loc"; then
            bad "r9 matrix: fixture build failed ($r9_verb | $r9_pos | dest=$r9_loc)"
            continue
        fi
        r9_cmd="${r9_tmpl//\{OTHER\}/$R9_OTHER}"
        r9_cmd="${r9_cmd//\{DEST\}/$R9_DEST}"
        r9_json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$r9_cmd" | jq -Rs .),\"cwd\":\"$R9_W\"}}"
        r9_lbl="$r9_verb | $r9_pos | dest=$r9_loc"
        # ORDER IS LOAD-BEARING, same contract as the main matrix above:
        # snapshot -> ask BOTH fence modes -> run the real command ->
        # snapshot -> derive the class. Never ask post-mutation.
        r9_s1=$(_matrix_snapshot "$R9_P")
        r9_d=$(_run "$DIRECT" "$r9_json")
        r9_f=$(_run "$FENCE" "$r9_json")
        r9_err=$(_run_stderr "$DIRECT" "$r9_json")
        ( cd "$R9_W" && bash -c "$r9_cmd" ) >/dev/null 2>&1
        r9_realrc=$?
        r9_s2=$(_matrix_snapshot "$R9_P")
        if [ "$r9_s1" != "$r9_s2" ]; then
            R9_A=$((R9_A + 1))
            if [ "$r9_d" = block ] && [ "$r9_f" = block ]; then
                case "$r9_err" in
                    *"block-write-into-main-checkout: refusing a write-shaped command"*)
                        ok "r9 matrix A must-deny: $r9_lbl" ;;
                    *) R9_AV=$((R9_AV + 1))
                       bad "r9 matrix A must-deny: $r9_lbl — denied WITHOUT a reason" ;;
                esac
            else
                R9_AV=$((R9_AV + 1))
                bad "r9 matrix A must-deny (FAIL-OPEN): $r9_lbl — direct=$r9_d sourced=$r9_f real_rc=$r9_realrc"
            fi
        elif [ "$r9_realrc" = 0 ]; then
            R9_B=$((R9_B + 1))
            if [ "$r9_d" = allow ] && [ "$r9_f" = allow ]; then
                ok "r9 matrix B must-allow: $r9_lbl"
            else
                R9_BV=$((R9_BV + 1))
                bad "r9 matrix B must-allow (FALSE POSITIVE): $r9_lbl — direct=$r9_d sourced=$r9_f"
            fi
        else
            R9_C=$((R9_C + 1))
        fi
    done
done <<< "$(_r9_specs)"
rm -rf "$R9_DIR" 2>/dev/null || true

printf '  r9 matrix: %d cells (A=%d must-deny, B=%d must-allow, C=%d OS-refused)\n' \
    "$((R9_A + R9_B + R9_C))" "$R9_A" "$R9_B" "$R9_C"
printf '  r9 matrix: A violations=%d  B violations=%d\n' "$R9_AV" "$R9_BV"
if [ "$R9_A" -gt 0 ]; then ok "r9 matrix class A is non-empty ($R9_A cells)"; else bad "r9 matrix class A is EMPTY — the fail-open guard would be vacuous"; fi
if [ "$R9_B" -gt 0 ]; then ok "r9 matrix class B is non-empty ($R9_B cells)"; else bad "r9 matrix class B is EMPTY — the false-positive guard would be vacuous"; fi
fi


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
