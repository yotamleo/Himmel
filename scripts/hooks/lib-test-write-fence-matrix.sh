# The HIMMEL-2592 generated grammar matrix, shared by the sliced matrix shards
# test-block-write-into-main-checkout-matrix{1,2,3}.sh (HIMMEL-4164: one loop
# over every cell took ~6 min, so the cell stream is split across three suites
# to stay under the CI per-suite cap). SOURCED after lib-test-write-fence.sh;
# not a suite (no test- prefix). `_matrix_run_slice K N` runs the cells whose
# 1-based index i satisfies i % N == K % N, so slices 1..N partition the stream.
# One-off assertions (the ordering guard, the enumerator check, and the two
# non-empty guards' ok line) are emitted by slice 1 ONLY, so the summed PASS
# count across the shards equals the pre-split single suite's; every slice
# still FAILS on an empty class or a broken enumerator.
# shellcheck shell=bash
# sourced-lib


# WHY THIS EXISTS: three CR rounds each found one more cell of the SAME finite
# grammar (verb x destination-kind x placement x source-kind) and fixed it one
# cell at a time. Enumerating the whole grammar and letting the real commands
# decide each verdict is what replaces predicting the next cell by hand.
#
# THE THREE-CLASS CONTRACT (console ruling). Two classes would force the
# known OS-refused over-blocks to be either red rows or silently tolerated
# ones; neither is acceptable, so each cell is classified from GROUND TRUTH:
#   (A) the primary CHANGED            -> the fence MUST deny.  STRICT.
#                                         This is the fail-open guard.
#   (B) the command SUCCEEDED and the
#       primary is unchanged           -> the fence MUST allow. STRICT.
#                                         This is the false-positive guard —
#                                         what stops the fence degenerating
#                                         into "deny everything".
#   (C) the command FAILED at the OS
#       level and the primary is
#       unchanged                      -> an over-block is TOLERATED. Counted
#                                         and PRINTED, asserted neither way.
# The class-C over-blocks are DOCUMENTED, not defects: modelling each verb's
# OS-level failure conditions is the shell-parser line this file refuses to
# cross, and relaxing them would move in the fail-OPEN direction for zero
# security gain. Do not "fix" a class-C cell.

# ---- the grammar, GENERATED (four plainly-named axes, nested loops) ----

# _matrix_src_verbs / _matrix_srcless_verbs — the VERB axis, generated.
#
# SPELLING AXIS (HIMMEL-2592 CR round 4): an option that takes a destination
# DIRECTORY has FOUR spellings, and the option that FLIPS destination
# semantics to ENTRY has TWO. Round 4 found `--target-directory DIR`
# (long-spaced) as a fail-open precisely because the axis listed only one
# spelling — so the GENERATOR owns them now, across cp/mv/ln alike. Fixing
# one spelling and leaving three is the Mode-1 pattern in miniature; making
# the spelling an axis is what stops a fifth form appearing in round 5.
# Each entry is "label<TAB>command-template" so there is no second, separately
# maintained label->template lookup to drift out of step.
#
# ROUND 5 (RETASK R-N1-SED-4b91d7): round 4's own prediction came true, but
# not as a fifth ENUMERABLE spelling — GNU getopt_long's unambiguous long-
# option ABBREVIATION makes the spelling axis INFINITE (`--targ`, `--tar`,
# `--ta`, ... are all live). An infinite axis cannot be enumerated, so the
# fix moved from the axis to a RULE (_bwimc_is_long_abbrev, a prefix test).
# Below, each abbreviation-eligible option gets exactly ONE representative
# abbreviated entry, not a fourth spelling-family: the fix is prefix-based
# and every abbreviation of a given option runs through the SAME helper call,
# so one abbreviation exercises the rule and every shorter or longer one is
# the same code path. The negative control (an unrelated long option must
# NOT be claimed) lives as hand-written suite rows (58g/58h), not here — it
# is a single fixed case, not a member of a generated axis.
_matrix_srcless_verbs() {
    printf '%s\t%s\n' "rm"     "rm {DEST}"
    printf '%s\t%s\n' "rm -r"  "rm -rf {DEST}"
    printf '%s\t%s\n' "tee"    "printf 'x\\n' | tee {DEST} >/dev/null"
    printf '%s\t%s\n' "touch"  "touch {DEST}"
    printf '%s\t%s\n' "sed -i" "sed -i 's/x/y/' {DEST}"
    # HIMMEL-2592 round 4: `sed -i`'s destination has TWO spellings of its
    # own, and `--follow-symlinks`/`--in-place` FLIP its resolution mode —
    # the exact fifth-form-in-round-5 shape this SPELLING AXIS comment warns
    # about, now applied to sed instead of cp/mv/ln. Both listed here so the
    # generator owns them rather than a fifth spelling appearing unlisted.
    printf '%s\t%s\n' "sed -i --follow-symlinks" "sed -i --follow-symlinks 's/x/y/' {DEST}"
    printf '%s\t%s\n' "sed --in-place"           "sed --in-place 's/x/y/' {DEST}"
    # ROUND 5: one representative ABBREVIATION of --follow-symlinks (see the
    # SPELLING AXIS / ROUND 5 comment above for why one, not several).
    printf '%s\t%s\n' "sed -i --follow" "sed -i --follow 's/x/y/' {DEST}"
    printf '%s\t%s\n' ">"      "printf 'x\\n' > {DEST}"
    printf '%s\t%s\n' ">|"     "printf 'x\\n' >| {DEST}"
}

_matrix_src_verbs() {
    # Base verbs that take a SOURCE, with their command prefix.
    local bases=( "mv" "cp" "ln -s" )
    # The four spellings of a destination-DIRECTORY option, plus ROUND 5's
    # one representative ABBREVIATION (see the SPELLING AXIS / ROUND 5
    # comment above _matrix_srcless_verbs for why one, not several).
    local tdir_labels=( "-tDIR" "-t DIR" "--target-directory=DIR" "--target-directory DIR" "--targ DIR" )
    local tdir_tmpls=(  "-t{DEST}" "-t {DEST}" "--target-directory={DEST}" "--target-directory {DEST}" "--targ {DEST}" )
    # The two spellings of the option that flips the destination to ENTRY.
    # These take no directory value; they are enumerated for what they CHANGE.
    local notgt_labels=( "-T" "--no-target-directory" )
    local notgt_tmpls=(  "-T" "--no-target-directory" )
    # ln's own no-dereference pair, same reasoning.
    local nodrf_labels=( "-n" "--no-dereference" )
    local nodrf_tmpls=(  "-n" "--no-dereference" )
    local bi oi bn=${#bases[@]}
    bi=0
    while [ "$bi" -lt "$bn" ]; do
        # plain positional destination
        printf '%s\t%s\n' "${bases[$bi]}" "${bases[$bi]} {SRC} {DEST}"
        oi=0
        while [ "$oi" -lt "${#tdir_labels[@]}" ]; do
            printf '%s\t%s\n' "${bases[$bi]} ${tdir_labels[$oi]}" \
                "${bases[$bi]} ${tdir_tmpls[$oi]} {SRC}"
            oi=$((oi + 1))
        done
        oi=0
        while [ "$oi" -lt "${#notgt_labels[@]}" ]; do
            printf '%s\t%s\n' "${bases[$bi]} ${notgt_labels[$oi]}" \
                "${bases[$bi]} ${notgt_tmpls[$oi]} {SRC} {DEST}"
            oi=$((oi + 1))
        done
        if [ "${bases[$bi]}" = "ln -s" ]; then
            oi=0
            while [ "$oi" -lt "${#nodrf_labels[@]}" ]; do
                printf '%s\t%s\n' "${bases[$bi]} ${nodrf_labels[$oi]}" \
                    "${bases[$bi]} ${nodrf_tmpls[$oi]} {SRC} {DEST}"
                oi=$((oi + 1))
            done
        fi
        bi=$((bi + 1))
    done
}

# _matrix_cells — the WHOLE grammar, one
# "verb<TAB>kind<TAB>placement<TAB>srckind<TAB>template" line per cell. A verb
# with no source operand emits ONCE at srckind="n/a": neither duplicated
# across the source axis nor dropped. The template travels WITH the cell, so
# a new spelling cannot be added to the verb axis and forgotten in a lookup.
_matrix_cells() {
    local kinds=(
        "plain-file" "plain-dir" "symlink-file" "symlink-dir"
        "symlink-missing" "symlink-dir-trailing-slash" "child-under-symlink-dir"
    )
    local placements=(
        "entry-in-wt-ref-primary" "entry-in-primary-ref-wt"
    )
    local srckinds=(
        "file" "dir"
    )
    local srcv=() srclessv=() line
    while IFS= read -r line; do [ -n "$line" ] && srcv+=("$line"); done < <(_matrix_src_verbs)
    while IFS= read -r line; do [ -n "$line" ] && srclessv+=("$line"); done < <(_matrix_srcless_verbs)

    local vi ki pi si vlabel vtmpl
    local kn=${#kinds[@]} pn=${#placements[@]} sn=${#srckinds[@]}

    vi=0
    while [ "$vi" -lt "${#srcv[@]}" ]; do
        vlabel="${srcv[$vi]%%	*}"; vtmpl="${srcv[$vi]#*	}"
        ki=0
        while [ "$ki" -lt "$kn" ]; do
            pi=0
            while [ "$pi" -lt "$pn" ]; do
                si=0
                while [ "$si" -lt "$sn" ]; do
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$vlabel" "${kinds[$ki]}" "${placements[$pi]}" "${srckinds[$si]}" "$vtmpl"
                    si=$((si + 1))
                done
                pi=$((pi + 1))
            done
            ki=$((ki + 1))
        done
        vi=$((vi + 1))
    done

    vi=0
    while [ "$vi" -lt "${#srclessv[@]}" ]; do
        vlabel="${srclessv[$vi]%%	*}"; vtmpl="${srclessv[$vi]#*	}"
        ki=0
        while [ "$ki" -lt "$kn" ]; do
            pi=0
            while [ "$pi" -lt "$pn" ]; do
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$vlabel" "${kinds[$ki]}" "${placements[$pi]}" "n/a" "$vtmpl"
                pi=$((pi + 1))
            done
            ki=$((ki + 1))
        done
        vi=$((vi + 1))
    done
}

_matrix_render_cmd() {
    local t="$1" src="$2" dest="$3"
    t="${t//\{SRC\}/$src}"
    t="${t//\{DEST\}/$dest}"
    printf '%s' "$t"
}

_matrix_src() {  # _matrix_src SRCKIND WT -> sets MSRC
    local srckind="$1" wt="$2"
    case "$srckind" in
        file) MSRC="$wt/srcfile.txt"; printf 'src\n' > "$MSRC" ;;
        dir)  MSRC="$wt/srcdir"; mkdir -p "$MSRC"; printf 'src\n' > "$MSRC/inner.txt" ;;
        n/a)  MSRC="" ;;
        *)    return 1 ;;
    esac
    return 0
}

_matrix_dest() {  # _matrix_dest KIND PLACEMENT PRIMARY WT -> sets MDEST
    local klabel="$1" plabel="$2" primary="$3" wt="$4" entry_base referent_base
    case "$plabel" in
        entry-in-wt-ref-primary) entry_base="$wt"; referent_base="$primary" ;;
        entry-in-primary-ref-wt) entry_base="$primary"; referent_base="$wt" ;;
        *) return 1 ;;
    esac
    local entry="$entry_base/destentry" referent="$referent_base/destreferent"
    case "$klabel" in
        plain-file) printf 'orig\n' > "$entry"; MDEST="$entry" ;;
        plain-dir)  mkdir -p "$entry"; printf 'orig\n' > "$entry/inner.txt"; MDEST="$entry" ;;
        symlink-file) printf 'orig\n' > "$referent"; ln -sf "$referent" "$entry"; MDEST="$entry" ;;
        symlink-dir) mkdir -p "$referent"; printf 'orig\n' > "$referent/inner.txt"
                     ln -sfn "$referent" "$entry"; MDEST="$entry" ;;
        symlink-missing) ln -sfn "${referent}-missing" "$entry"; MDEST="$entry" ;;
        symlink-dir-trailing-slash) mkdir -p "$referent"; printf 'orig\n' > "$referent/inner.txt"
                     ln -sfn "$referent" "$entry"; MDEST="$entry/" ;;
        child-under-symlink-dir) mkdir -p "$referent"; printf 'orig\n' > "$referent/child"
                     ln -sfn "$referent" "$entry"; MDEST="$entry/child" ;;
        *) return 1 ;;
    esac
    return 0
}

_matrix_hashfile() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'; fi
}

# _matrix_stat_probe — RETASK R-N1-SED-4b91d7 round 2. A ONE-TIME check (run
# once before the matrix's cell loop, never per snapshot call, never per
# cell) of whether THIS host's `stat` can give _matrix_snapshot what it
# needs: an inode AND a SUB-SECOND mtime, via GNU's `-c '%i|%y'`. This is NOT
# "try GNU, fall back to BSD" — BSD/macOS `stat -f` has no sub-second mtime
# format across the BSD family (`%m`/`%Sm` are whole-second only), the exact
# resolution gap that already hid a same-second `touch` once (see
# _matrix_snapshot's header). A coarser oracle is not an acceptable
# degradation here, so a non-GNU stat is a SKIP case for the matrix's cell
# execution, not a silently-coarser-and-still-green one. Captures stderr
# (not `2>/dev/null`) because this is the ONE place that should explain
# itself if it fails — a per-path suppression inside the hot loop is a
# different case, see _matrix_snapshot.
_matrix_stat_probe() {
    MATRIX_STAT_READY=0
    MATRIX_STAT_DIAG=""
    local probe
    probe=$(stat -c '%i|%y' "$0" 2>&1)  # gnu-ok: deliberately PROBES for GNU stat -c; failure here is caught below and treated as SKIP (MATRIX_STAT_READY=0), never as silently degraded
    # Anchored on a LEADING DIGIT (a real inode), not merely "contains a
    # pipe" — a BSD stat's usage-banner error text also contains literal
    # `|` characters ("-f format | -l | -r ..."), which a bare `*'|'*` match
    # would misread as success. Caught by stubbing a BSD-shaped rejection
    # and finding this passed anyway before the digit anchor was added.
    case "$probe" in
        [0-9]*'|'*) MATRIX_STAT_READY=1 ;;
        *) MATRIX_STAT_DIAG="$probe" ;;
    esac
}

# _matrix_snapshot ROOT — every path under ROOT except .git: type, inode,
# mtime, plus content hash / link target. mtime uses stat '%y' (NANOSECOND),
# never the integer-second '%Y': a fixture is built and probed inside one
# wall-clock second, so a metadata-only write (`touch` on a file whose
# content and inode never change) is INVISIBLE at second granularity. That
# bug made rows vacuous once already — do not "simplify" it back. Callers
# MUST check MATRIX_STAT_READY (_matrix_stat_probe) before calling this — GNU
# `-c` support is a precondition, not something re-verified per call.
_matrix_snapshot() {
    local root="$1" p ino mtime tgt hash
    find "$root" \( -path "$root/.git" -o -path "$root/.git/*" \) -prune -o -print 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r p; do
            # 2>/dev/null below guards ONLY the TOCTOU case — a path `find`
            # already listed being removed before this stat/readlink call
            # runs — never a stat-flavour mismatch: MATRIX_STAT_READY (checked
            # by the caller before this function ever runs) already
            # guarantees GNU `-c` works on this host.
            if [ -L "$p" ]; then
                tgt=$(readlink "$p" 2>/dev/null); ino=$(stat -c '%i' "$p" 2>/dev/null)  # gnu-ok: only called once _matrix_stat_probe confirms GNU stat -c (MATRIX_STAT_READY=1)
                mtime=$(stat -c '%y' "$p" 2>/dev/null)  # gnu-ok: same precondition — GNU sub-second %y, confirmed by _matrix_stat_probe before this function ever runs
                printf 'L|%s|ino=%s|mtime=%s|target=%s\n' "$p" "$ino" "$mtime" "$tgt"
            elif [ -d "$p" ]; then
                ino=$(stat -c '%i' "$p" 2>/dev/null); mtime=$(stat -c '%y' "$p" 2>/dev/null)  # gnu-ok: same precondition — see _matrix_snapshot's header
                printf 'D|%s|ino=%s|mtime=%s\n' "$p" "$ino" "$mtime"
            elif [ -f "$p" ]; then
                ino=$(stat -c '%i' "$p" 2>/dev/null); mtime=$(stat -c '%y' "$p" 2>/dev/null)  # gnu-ok: same precondition — see _matrix_snapshot's header
                hash=$(_matrix_hashfile "$p")
                printf 'F|%s|ino=%s|mtime=%s|hash=%s\n' "$p" "$ino" "$mtime" "$hash"
            else
                printf 'O|%s\n' "$p"
            fi
        done
}

# ---- HARNESS RED CONTROL: the ask-before-mutate ordering, asserted --------
#
# This proves the ordering fix is REAL, not merely present in the source.
# Take a cell whose command DELETES its destination and ask the fence about
# the IDENTICAL command text twice: once in a fixture where that command then
# actually runs, and once in a fixture where it is stubbed to a no-op
# (`true`). Under the correct ordering both queries happen pre-mutation, so
# the two verdicts MUST be identical. Under the post-mutation ordering bug
# the first query resolved a path the `rm` had already removed while the
# second resolved a path still present — exactly the divergence this asserts
# away. It is a first-class row, not a comment, so it survives any future
# refactor of the cell loop.
_matrix_order_selftest() {
    local mutate="$1" dir="$FIX/matrixorder" primary wt dest cmd json verdict
    rm -rf "$dir"; mkdir -p "$dir"
    primary="$dir/primary"; wt="$dir/wt"
    git init -q "$primary" >/dev/null 2>&1 || { printf 'FIXTURE-FAIL'; return 0; }
    git -C "$primary" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    printf 'tracked\n' > "$primary/README.md"
    git -C "$primary" add README.md >/dev/null 2>&1
    git -C "$primary" commit -q -m init >/dev/null 2>&1
    git -C "$primary" worktree add -q -b feat/order "$wt" >/dev/null 2>&1 || { printf 'FIXTURE-FAIL'; return 0; }
    dest="$primary/destentry"
    printf 'orig\n' > "$dest"
    cmd="rm $dest"
    json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | jq -Rs .),\"cwd\":\"$wt\"}}"
    # THE ORDERING UNDER TEST: ask first, mutate second.
    verdict=$(_run "$DIRECT" "$json")
    if [ "$mutate" = mutate ]; then
        ( cd "$wt" && bash -c "$cmd" ) >/dev/null 2>&1
    else
        ( cd "$wt" && bash -c "true" ) >/dev/null 2>&1
    fi
    rm -rf "$dir"
    printf '%s' "$verdict"
}

# _matrix_run_slice K N — see the file header.
_matrix_run_slice() {
MATRIX_SLICE_K="$1"; MATRIX_SLICE_N="$2"
# ok_first: a one-off assertion's ok line, emitted by slice 1 only.
ok_first() { if [ "$MATRIX_SLICE_K" = 1 ]; then ok "$1"; fi; return 0; }
echo "== HIMMEL-2592 GENERATED GRAMMAR MATRIX (the real interpreter is the oracle) — slice $MATRIX_SLICE_K/$MATRIX_SLICE_N =="
if [ "$MATRIX_SLICE_K" = 1 ]; then  # one-off guard: slice 1 only (see the file header)
M_ORDER_MUT=$(_matrix_order_selftest mutate)
M_ORDER_NOP=$(_matrix_order_selftest noop)
if [ "$M_ORDER_MUT" = "$M_ORDER_NOP" ] && [ "$M_ORDER_MUT" != FIXTURE-FAIL ] && [ -n "$M_ORDER_MUT" ]; then
    ok "matrix ordering guard: delete-cell verdict == no-op-cell verdict ($M_ORDER_MUT) — the fence is asked PRE-mutation"
else
    bad "matrix ordering guard: delete-cell=$M_ORDER_MUT vs no-op-cell=$M_ORDER_NOP — the fence is seeing POST-mutation state"
fi
fi

# ---- structural guard: the cell count is ASSERTED, never merely printed ----
#
# Every number is derived from _matrix_cells' OWN emitted stream, never from a
# second hand-maintained copy of the lists, so a defect INSIDE the enumerator
# (a dropped kind, a duplicated verb, a verb in the wrong group) surfaces here
# rather than as a quiet "0 cells" that reads green.
MATRIX_CELLS=$(_matrix_cells)
M_TOTAL_N=$(printf '%s\n' "$MATRIX_CELLS" | grep -c . || true)
M_VERB_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '{print $1}' | sort -u | wc -l | tr -d ' ')
M_KIND_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '{print $2}' | sort -u | wc -l | tr -d ' ')
M_PLACE_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '{print $3}' | sort -u | wc -l | tr -d ' ')
M_SRCTAKING_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '$4 != "n/a"' | wc -l | tr -d ' ')
M_SRCLESS_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '$4 == "n/a"' | wc -l | tr -d ' ')
M_SRCTAKING_VERBS=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '$4 != "n/a" {print $1}' | sort -u | wc -l | tr -d ' ')
M_SRCLESS_VERBS=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '$4 == "n/a" {print $1}' | sort -u | wc -l | tr -d ' ')
M_SRCKIND_N=$(printf '%s\n' "$MATRIX_CELLS" | awk -F'\t' '$4 != "n/a" {print $4}' | sort -u | wc -l | tr -d ' ')
M_EXP_SRCTAKING=$((M_SRCTAKING_VERBS * M_KIND_N * M_PLACE_N * M_SRCKIND_N))
M_EXP_SRCLESS=$((M_SRCLESS_VERBS * M_KIND_N * M_PLACE_N))
M_EXPECTED=$((M_EXP_SRCTAKING + M_EXP_SRCLESS))

printf '  matrix: %d source-taking + %d sourceless = %d cells (expected %d + %d = %d)\n' \
    "$M_SRCTAKING_N" "$M_SRCLESS_N" "$M_TOTAL_N" "$M_EXP_SRCTAKING" "$M_EXP_SRCLESS" "$M_EXPECTED"

if [ "$M_TOTAL_N" -gt 0 ] \
   && [ "$M_TOTAL_N" -eq "$M_EXPECTED" ] \
   && [ "$M_SRCTAKING_N" -eq "$M_EXP_SRCTAKING" ] \
   && [ "$M_SRCLESS_N" -eq "$M_EXP_SRCLESS" ] \
   && [ "$((M_SRCTAKING_VERBS + M_SRCLESS_VERBS))" -eq "$M_VERB_N" ]; then
    ok_first "matrix enumerator yields $M_TOTAL_N cells (>0, and equal to the computed group sum)"
else
    bad "matrix enumerator is broken — $M_SRCTAKING_N + $M_SRCLESS_N = $M_TOTAL_N cells, expected $M_EXPECTED over $M_VERB_N verbs"
fi

# HIMMEL-4164: this slice runs only its share of the (fully validated) stream.
MATRIX_CELLS=$(printf '%s\n' "$MATRIX_CELLS" | awk -v n="$MATRIX_SLICE_N" -v k="$MATRIX_SLICE_K" 'NR % n == k % n')

# ---- run every cell: ground truth first, then BOTH fence entry modes ----
#
# RETASK R-N1-SED-4b91d7 round 2: gated on _matrix_stat_probe. The snapshot
# diff below is the oracle for classes A/B — an unusable stat would silently
# compare EMPTY inode/mtime fields and could derive the wrong verdict for a
# same-second metadata-only write while still printing a green matrix. A
# skip here is intentionally NOT re-indented into the `if` body below (kept
# flat to keep this round's diff to the gate itself, not a reflow of ~90
# pre-existing lines) — every line from here through the class-B assertion
# only runs when MATRIX_STAT_READY=1.
_matrix_stat_probe
if [ "$MATRIX_STAT_READY" != 1 ]; then
    echo "  SKIP HIMMEL-2592 generated-grammar-matrix CELL EXECUTION — host stat can't give GNU -c '%i|%y' (inode + SUB-SECOND mtime): $MATRIX_STAT_DIAG -- running anyway would silently compare empty inode/mtime fields and could derive the wrong verdict for a same-second metadata-only write (the exact defect class integer-second mtime caused once already)."
else
M_A=0; M_B=0; M_C=0; M_AV=0; M_BV=0; M_COVER=0; M_CALLOW=0
M_CDIR="$FIX/matrixcell"
while IFS=$'\t' read -r m_verb m_kind m_place m_srck m_tmpl; do
    [ -n "$m_verb" ] || continue
    if [ -z "$m_tmpl" ]; then bad "matrix: no template for verb [$m_verb]"; continue; fi

    rm -rf "$M_CDIR"; mkdir -p "$M_CDIR"
    M_PRIMARY="$M_CDIR/primary"; M_WT="$M_CDIR/wt"
    m_ok=1
    git init -q "$M_PRIMARY" >/dev/null 2>&1 || m_ok=0
    [ "$m_ok" = 1 ] && { git -C "$M_PRIMARY" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || m_ok=0; }
    if [ "$m_ok" = 1 ]; then
        printf 'tracked\n' > "$M_PRIMARY/README.md"
        git -C "$M_PRIMARY" add README.md >/dev/null 2>&1 || m_ok=0
    fi
    [ "$m_ok" = 1 ] && { git -C "$M_PRIMARY" commit -q -m init >/dev/null 2>&1 || m_ok=0; }
    [ "$m_ok" = 1 ] && { git -C "$M_PRIMARY" worktree add -q -b feat/matrix "$M_WT" >/dev/null 2>&1 || m_ok=0; }
    if [ "$m_ok" != 1 ]; then bad "matrix: fixture build failed for $m_verb | $m_kind | $m_place | src=$m_srck"; continue; fi

    MSRC=""; MDEST=""
    if ! _matrix_src "$m_srck" "$M_WT"; then bad "matrix: src build failed ($m_srck)"; continue; fi
    if ! _matrix_dest "$m_kind" "$m_place" "$M_PRIMARY" "$M_WT"; then bad "matrix: dest build failed ($m_kind/$m_place)"; continue; fi

    m_cmd=$(_matrix_render_cmd "$m_tmpl" "$MSRC" "$MDEST")
    m_json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$m_cmd" | jq -Rs .),\"cwd\":\"$M_WT\"}}"
    m_lbl="$m_verb | $m_kind | $m_place | src=$m_srck"

    # ORDER IS LOAD-BEARING (HIMMEL-2592 CR round 4, codex-1). The contract is
    # exactly:
    #     snapshot
    #  -> ask BOTH fence modes AND capture the deny reason
    #  -> run the real command
    #  -> snapshot
    #  -> derive the class
    # The fence is a PreToolUse hook, so it must NEVER see post-mutation
    # state. Asking after the real command ran made every verdict resolve
    # paths the command had just deleted, replaced or re-pointed — which can
    # hide a bypass in one direction and manufacture a false positive in the
    # other. `_run_stderr` is part of this: it used to be called later, inside
    # the class-A branch, and carried the identical defect. The hook is
    # read-only, so three pre-mutation invocations need no extra fixture.
    # _matrix_order_selftest below is the standing guard on this ordering.
    m_s1=$(_matrix_snapshot "$M_PRIMARY")
    m_d=$(_run "$DIRECT" "$m_json")
    m_f=$(_run "$FENCE" "$m_json")
    m_err=$(_run_stderr "$DIRECT" "$m_json")
    ( cd "$M_WT" && bash -c "$m_cmd" ) >/dev/null 2>&1
    m_realrc=$?
    m_s2=$(_matrix_snapshot "$M_PRIMARY")

    if [ "$m_s1" != "$m_s2" ]; then
        # (A) the primary CHANGED — STRICT must-deny, in BOTH entry modes,
        # and the deny must carry a REASON (a bare rc=2 is the silent-deny
        # class this suite already pins elsewhere).
        M_A=$((M_A + 1))
        if [ "$m_d" = block ] && [ "$m_f" = block ]; then
            case "$m_err" in
                *"block-write-into-main-checkout: refusing a write-shaped command"*)
                    ok "matrix A must-deny: $m_lbl" ;;
                *) M_AV=$((M_AV + 1))
                   bad "matrix A must-deny: $m_lbl — denied WITHOUT a reason" ;;
            esac
        else
            M_AV=$((M_AV + 1))
            bad "matrix A must-deny (FAIL-OPEN): $m_lbl — direct=$m_d sourced=$m_f real_rc=$m_realrc"
        fi
    elif [ "$m_realrc" = 0 ]; then
        # (B) the command SUCCEEDED and the primary is untouched — STRICT
        # must-allow. This is the guard against the fence becoming
        # "deny everything".
        M_B=$((M_B + 1))
        if [ "$m_d" = allow ] && [ "$m_f" = allow ]; then
            ok "matrix B must-allow: $m_lbl"
        else
            M_BV=$((M_BV + 1))
            bad "matrix B must-allow (FALSE POSITIVE): $m_lbl — direct=$m_d sourced=$m_f"
        fi
    else
        # (C) the command FAILED at the OS level — an over-block is
        # TOLERATED and only counted, so the documented residual stays
        # VISIBLE without being either a red row or a silent pass.
        M_C=$((M_C + 1))
        if [ "$m_d" = block ] || [ "$m_f" = block ]; then M_COVER=$((M_COVER + 1)); else M_CALLOW=$((M_CALLOW + 1)); fi
    fi
done <<< "$MATRIX_CELLS"
rm -rf "$M_CDIR" 2>/dev/null || true

printf '  matrix: %d cells (A=%d must-deny, B=%d must-allow, C=%d OS-refused)\n' \
    "$((M_A + M_B + M_C))" "$M_A" "$M_B" "$M_C"
printf '  matrix: A violations=%d  B violations=%d  C over-block=%d (allowed=%d)\n' \
    "$M_AV" "$M_BV" "$M_COVER" "$M_CALLOW"

# A and B must be NON-EMPTY: a generator that silently stopped producing
# cells would otherwise report "0 violations" and read as green.
if [ "$M_A" -gt 0 ]; then ok_first "matrix class A is non-empty ($M_A cells)"; else bad "matrix class A is EMPTY — the fail-open guard would be vacuous"; fi
if [ "$M_B" -gt 0 ]; then ok_first "matrix class B is non-empty ($M_B cells)"; else bad "matrix class B is EMPTY — the false-positive guard would be vacuous"; fi
fi

}
