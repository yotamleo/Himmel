#!/usr/bin/env bash
# Branch-scoped /pr-check review-round state and round-4 cap (HIMMEL-2780).
# HIMMEL-4600: after three full rounds the only round left is ONE delta round,
# scoped to the last critic-reviewed head..the new head and allowed only when
# that head raised a finding (the new head answers it) or the new head only
# merges the base into it. A 4th full round and a second delta are refused.
# State lives under the repository's shared git common directory, so head
# commits and merge-forwards do not reset it and linked worktrees agree.
# HIMMEL-4700: a third trigger - a judge NO-GO on the last reviewed head, as
# console-kit/write-verdict.sh records it in this repo's verdict scope - buys
# one more delta round per reviewed head, even after the fix/merge-forward
# delta was used. Consumed records are kept in <branch>.verdicts.
# HIMMEL-4995: a CLEAN merge of the base (conflict-free, the PR's own diff
# unchanged) is admitted past the cap without spending the one delta round; a
# conflict-resolving merge needs a judge GO carrying `delta-scope:
# merge-resolution` and `delta-from:`, bound like the HIMMEL-4952 scope records.
# HIMMEL-4984: every verdict record read here (NO-GO delta, layer-decision,
# scope) must carry write-verdict.sh's mac under the GO key; a hand-written or
# edited record disqualifies its qid. Scope records also bind to this branch's
# PR/branch, and any NO-GO for the new head blocks the scope round. The key is
# readable by the same uid, so the ceiling is a same-uid forger (HIMMEL-3578);
# a lint-only record still rests on the judge's word.
# Bash 3.2-safe.
# Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.
set -uo pipefail
# HIMMEL-3495: a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    echo "usage: review-round.sh start --branch <name> [--head <sha> [--base-sha <sha>]]" >&2
    echo "       review-round.sh defer --branch <name> --head <sha> [--defer-to <ticket>]" >&2
    echo "       review-round.sh promote --branch <name> --head <sha>" >&2
    exit 2
}

verb="${1:-}"
[ -n "$verb" ] || usage
shift
branch=""
head_sha=""
base_sha=""
defer_to="${CR_DEFER_TO:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || usage; head_sha="$2"; shift 2 ;;
        --base-sha) [ $# -ge 2 ] || usage; base_sha="$2"; shift 2 ;;
        --defer-to) [ $# -ge 2 ] || usage; defer_to="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$branch" ] || usage
case "$verb" in
    start) [ -n "$head_sha" ] || [ -z "$base_sha" ] || usage ;;
    defer) [ -n "$head_sha" ] || usage ;;
    promote) [ -n "$head_sha" ] || usage ;;
    *) usage ;;
esac

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "review-round: invalid branch name '$branch'" >&2
    exit 2
fi
# HIMMEL-3495: every verb writes shared per-branch state (round counter,
# ledger amends, marker clearance), and a relative run is auto-allowed from any
# leg's worktree - so only the branch checked out in cwd may be written. A
# detached HEAD has no branch and is refused too.
current_branch="$(git branch --show-current 2>/dev/null)" || current_branch=""
if [ -z "$current_branch" ] || [ "$current_branch" != "$branch" ]; then
    echo "review-round: --branch '$branch' is not the branch checked out in this directory ('${current_branch:-detached HEAD}') - run it from that branch's worktree" >&2
    exit 2
fi

git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || git_dir=""
if [ -z "$git_dir" ]; then
    echo "review-round: cannot resolve the shared git common directory" >&2
    exit 5
fi
state="$git_dir/cr-review-rounds/$branch.round"
# HIMMEL-4600: "<from> <to> <trigger>" of the one delta round, once it ran.
delta_state="$git_dir/cr-review-rounds/$branch.delta"
delta_run="$git_dir/cr-review-rounds/$branch.delta.run"
# HIMMEL-4700: "<from> <to> <qid>/<name>", one line per judge-triggered round.
verdict_state="$git_dir/cr-review-rounds/$branch.verdicts"
# HIMMEL-4600: the head the last counted round ran on (start --head).
head_state="$git_dir/cr-review-rounds/$branch.head"
state_dir="$(dirname "$state")"
mkdir -p "$state_dir" || {
    echo "review-round: cannot create state directory $state_dir" >&2
    exit 5
}

read_round() {
    round=0
    if [ -f "$state" ]; then
        round="$(cat "$state" 2>/dev/null)" || round=""
        case "$round" in
            ''|*[!0-9]*)
                echo "review-round: invalid counter state in $state — refusing to reset it silently" >&2
                return 5
                ;;
        esac
    fi
    return 0
}

# HIMMEL-4600: ledger_query <avail|finding|row> <full sha> reads only critic-panel
# rows on this branch at that sha (full or >=7-char prefix); claude,
# claude-floor and codex-adv rows are the session's own and never count (the
# clear-cr-marker gate 3b exclusion). "avail" prints "ok" when a critic
# reviewed the sha. "finding" prints "finding" when a critic finding there
# still asks for a fix: its verdict after amends is agreed, fixed or unset,
# and no row ever deferred or disproved it. "row" (HIMMEL-4638) prints "row"
# when any critic finding row exists there, whatever its verdict.
ledger_query() {
    LEDGER="$git_dir/cr-critic-scores.jsonl" BRANCH="$branch" MODE="$1" FROM="$2" node -e '
const fs = require("fs"), e = process.env;
let lines = [];
try { lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean); } catch { process.exit(0); }
const at = (h) => { h = String(h || "").toLowerCase(); return h.length >= 7 && e.FROM.startsWith(h); };
const critic = (m) => m !== "claude" && m !== "claude-floor" && m !== "codex-adv";
let reviewed = false, rowed = false;
const verdicts = new Map(), settled = new Set();
// HIMMEL-4634: one finding is id + artifact + perspective, as the defer
// analysis and clear-cr-marker key it; a bare id merges distinct findings.
const keyOf = (o) => [String(o.finding_id), o.artifact || "diff", o.perspective || "off"].join("\u001f");
const note = (id, v) => {
  verdicts.set(id, v);
  if (v === "deferred" || v === "disproved") settled.add(id);
};
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  if (!o || o.branch !== e.BRANCH) continue;
  if (o.kind === "avail" && o.status === "ok" && critic(o.model) && at(o.head)) reviewed = true;
  if (o.kind === "finding" && critic(o.model) && at(o.head)) { rowed = true; note(keyOf(o), String(o.verdict || "")); }
  if (o.kind === "amend" && at(o.target_head) && verdicts.has(keyOf(o))
      && o.set && typeof o.set.verdict === "string") note(keyOf(o), o.set.verdict);
}
if (e.MODE === "avail") { if (reviewed) process.stdout.write("ok"); }
else if (e.MODE === "row") { if (rowed) process.stdout.write("row"); }
else if ([...verdicts].some(([id, v]) => !settled.has(id) && (v === "" || v === "agreed" || v === "fixed"))) process.stdout.write("finding");
'
}

# HIMMEL-4697: plugin-version-bump-required makes a plugin PR bump its
# plugin.json version inside its merge of the base, so that merge never equals
# a clean merge tree. version_only_merge <ours> <theirs> <new> succeeds only
# when every path where <new>'s tree differs from the merge of <ours> and
# <theirs>, and every path that merge conflicts on, is a
# marketplace/plugins/<p>/.claude-plugin/plugin.json whose "version" in <new>
# is strictly above the version in both <ours> and <theirs>, and whose other
# bytes are exactly the clean three-way merge once the version values are set
# aside. Anything else fails, so the caller keeps refusing it.
plugin_json_path() {
    case "$1" in
        marketplace/plugins/*/.claude-plugin/plugin.json) ;;
        *) return 1 ;;
    esac
    _pj_name="${1#marketplace/plugins/}"
    _pj_name="${_pj_name%/.claude-plugin/plugin.json}"
    case "$_pj_name" in ''|*/*) return 1 ;; esac
    return 0
}
# plugin_version <file>: prints the one "version" value, which must sit alone
# on its line as plain X.Y.Z; fails on any other shape or a second version key.
# The key must also be the file's top-level one, not nested (HIMMEL-4703).
# shellcheck disable=SC2016  # JavaScript source is literal here
plugin_version() {
    [ "$(awk '/"version"[[:space:]]*:/ { n++ } END { print n + 0 }' "$1")" = "1" ] || return 1
    _pv_v="$(sed -n -E 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9})"[[:space:]]*,?[[:space:]]*$/\1/p' "$1")"
    [ -n "$_pv_v" ] || return 1
    PV_FILE="$1" PV_WANT="$_pv_v" node -e '
const fs = require("fs"), e = process.env;
const o = JSON.parse(fs.readFileSync(e.PV_FILE, "utf8"));
process.exit(o && typeof o === "object" && !Array.isArray(o) && o.version === e.PV_WANT ? 0 : 1);
' 2>/dev/null || return 1
    printf '%s\n' "$_pv_v"
}
# semver_gt <a> <b>: a > b for two plain X.Y.Z values.
semver_gt() {
    _sg_a="$1"; _sg_b="$2"
    for _sg_i in 1 2 3; do
        _sg_x="${_sg_a%%.*}"; _sg_y="${_sg_b%%.*}"
        _sg_a="${_sg_a#*.}"; _sg_b="${_sg_b#*.}"
        [ "$((10#$_sg_x))" -gt "$((10#$_sg_y))" ] && return 0
        [ "$((10#$_sg_x))" -lt "$((10#$_sg_y))" ] && return 1
    done
    return 1
}
version_only_merge() {
    _vo_out="$(git merge-tree --write-tree --name-only --no-messages "$1" "$2" 2>/dev/null)"
    _vo_rc=$?
    [ "$_vo_rc" -eq 0 ] || [ "$_vo_rc" -eq 1 ] || return 1
    _vo_tree="$(printf '%s\n' "$_vo_out" | sed -n '1p')"
    _vo_new_tree="$(git rev-parse --verify --quiet "$3^{tree}" 2>/dev/null)" || return 1
    _vo_changed="$(git diff-tree -r --name-only --no-renames "$_vo_tree" "$_vo_new_tree" 2>/dev/null)" || return 1
    _vo_paths="$( { printf '%s\n' "$_vo_out" | sed '1d'; printf '%s\n' "$_vo_changed"; } | sed '/^$/d' | sort -u)"
    [ -n "$_vo_paths" ] || return 1
    _vo_mb="$(git merge-base --all "$1" "$2" 2>/dev/null)" || return 1
    case "$_vo_mb" in ''|*"
"*) return 1 ;; esac
    _vo_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-round.XXXXXX")" || return 1
    _vo_ok=0
    while IFS= read -r _vo_p; do
        _vo_ok=1
        plugin_json_path "$_vo_p" || { _vo_ok=0; break; }
        for _vo_side in "$_vo_mb:base" "$1:ours" "$2:theirs" "$3:new"; do
            _vo_c="${_vo_side%:*}"
            if [ "${_vo_side##*:}" != base ] \
                && [ "$(git ls-tree "$_vo_c" -- "$_vo_p" 2>/dev/null | cut -c1-6)" != "100644" ]; then
                _vo_ok=0; break
            fi
            git cat-file blob "$_vo_c:$_vo_p" > "$_vo_tmp/${_vo_side##*:}" 2>/dev/null || { _vo_ok=0; break; }
            plugin_version "$_vo_tmp/${_vo_side##*:}" > "$_vo_tmp/${_vo_side##*:}.v" || { _vo_ok=0; break; }
            sed -E 's/^([[:space:]]*"version"[[:space:]]*:[[:space:]]*")[0-9.]*"/\1"/' \
                "$_vo_tmp/${_vo_side##*:}" > "$_vo_tmp/${_vo_side##*:}.n" || { _vo_ok=0; break; }
        done
        [ "$_vo_ok" -eq 1 ] || break
        _vo_vn="$(cat "$_vo_tmp/new.v")"
        if ! semver_gt "$_vo_vn" "$(cat "$_vo_tmp/ours.v")" \
            || ! semver_gt "$_vo_vn" "$(cat "$_vo_tmp/theirs.v")" \
            || ! git merge-file -p "$_vo_tmp/ours.n" "$_vo_tmp/base.n" "$_vo_tmp/theirs.n" > "$_vo_tmp/merged.n" 2>/dev/null \
            || ! cmp -s "$_vo_tmp/merged.n" "$_vo_tmp/new.n"; then
            _vo_ok=0; break
        fi
    done <<EOF
$_vo_paths
EOF
    rm -rf "$_vo_tmp"
    [ "$_vo_ok" -eq 1 ]
}

# HIMMEL-4885: a branch is one PR. Its consumed qids plus the candidate
# qid are its verdict history, not every other PR in the verdict scope.
# Legacy classless records contribute no classes. A decision in the current
# candidate evidence is the explicit way out of a repeated-class stop.
# shellcheck disable=SC2016  # JavaScript template fields are literal here
judge_class_check() {
    VERDICT_DIR="$dir" HISTORY="$verdict_state" CANDIDATE="$1" WANT="$2" node -e '
const fs = require("fs"), path = require("path"), cp = require("child_process"), e = process.env;
const allowed = new Set(["option-parsing", "cwd-indirection", "shell-parsing", "tool-defaults", "reader-allowlist", "other"]);
const seg = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const candidates = e.CANDIDATE.split(" ").map(r => r.split("/")[0]);
const records = (qid) => {
  const dir = path.join(e.VERDICT_DIR, qid);
  if (!seg.test(qid) || !fs.lstatSync(dir).isDirectory() || fs.lstatSync(dir).isSymbolicLink()) throw Error("invalid history qid " + qid);
  return fs.readdirSync(dir).filter(n => n.endsWith(".md")).map(n => {
    const file = path.join(dir, n), name = n.slice(0, -3);
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw Error("invalid history file " + file);
    const lines = fs.readFileSync(file, "utf8").split("\n");
    if (!seg.test(name) || lines[0] !== `# VERDICT ${qid} - ${name}` || lines[1] || lines[4] || lines[6]
        || !/^writer-session: [A-Za-z0-9-]+$/.test(lines[2])
        || !/^written-at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(lines[3]) || lines[5] !== "## Verdict") throw Error("invalid history record " + file);
    const verdict = /^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/.exec(lines[7]);
    if (!verdict) throw Error("invalid history verdict " + file);
    const evidence = lines.slice(8);
    const fields = evidence.filter(l => l.startsWith("class:"));
    let classes = [];
    if (verdict[1] === "NO-GO" && fields.length) {
      classes = fields[0].slice(6).trim().split(",").map(s => s.trim());
      if (fields.length !== 1 || classes.some(c => !allowed.has(c))) throw Error("invalid history class " + file);
    }
    return { head: verdict[2], nogo: verdict[1] === "NO-GO", classes,
      decision: evidence.some(l => /^layer-decision: (text|os|classifier|accept)\s+\S.*$/.test(l)) };
  });
};
try {
  const candidateRecords = candidates.flatMap(records);
  const current = candidateRecords.filter(r => r.nogo && r.head === e.WANT);
  if (current.some(r => r.decision)) process.exit(0);
  const classes = new Set(current.flatMap(r => r.classes));
  const prior = [];
  let history = "";
  try { history = fs.readFileSync(e.HISTORY, "utf8"); } catch (err) { if (err.code !== "ENOENT") throw err; }
  for (const line of history.split("\n").filter(Boolean)) {
    const [head, , record] = line.split(" ");
    if (!record || !/^[0-9a-f]{40}$/.test(head)) throw Error("invalid consumed verdict history");
    if (head !== e.WANT) prior.push(...records(record.split("/")[0]).filter(r => r.nogo && r.head === head));
  }
  for (const r of candidateRecords) {
    if (!r.nogo || r.head === e.WANT) continue;
    // HIMMEL-4945: only a clean exit 1 means "not an ancestor"; a git error
    // (128: missing or shallow history), a spawn error or a signal keeps the
    // record, so an unreadable history never drops an earlier NO-GO.
    const anc = cp.spawnSync("git", ["merge-base", "--is-ancestor", r.head, e.WANT]);
    if (anc.status === 1) continue;
    if (anc.status !== 0) console.error(`review-round: ancestry check could not run for ${r.head} (${anc.error ? anc.error.message : anc.signal || "git exit " + anc.status}) - keeping its NO-GO record (HIMMEL-4945)`);
    prior.push(r);
  }
  const repeated = [...new Set(prior.flatMap(r => r.classes).filter(c => classes.has(c)))];
  if (repeated.length) {
    console.error(`review-round: repeated NO-GO class ${repeated.join(", ")} across heads of this PR - delta round refused (HIMMEL-4885); record layer-decision: text|os|classifier|accept <reason> in the candidate evidence`);
    process.exit(8);
  }
} catch (err) {
  console.error("review-round: cannot read class history - delta round refused: " + err.message);
  process.exit(8);
}
'
}

# record_binds <l9> <l10> <l11> - HIMMEL-4632, shared with the HIMMEL-4984 scope
# path. A record binds to this branch's PR: its `pr:` line (line 10,
# write-verdict.sh's fixed place) must name the PR gh resolves for the branch,
# and a `branch:` line (line 11, optional) must name the branch. No pr: line, or
# no resolvable PR, binds nothing. The binding only picks which records BUY the
# round: every NO-GO for the head still feeds the HIMMEL-4885 class veto, and an
# unresolvable PR (pr_want="-") refuses (exit 8) in the caller. The PR is
# resolved by --head, never `gh pr view <branch>` (a branch named 42 would
# resolve to PR 42), and bounded: this runs under the counter lock. pr_want
# caches it for the calling subshell, which must set it to "" first.
# ponytail: the binding is covered by the record mac (HIMMEL-4984), whose key
# is same-uid readable (HIMMEL-3578).
record_binds() {
    [ -z "$1" ] || return 1
    case "$2" in 'pr: '[1-9]*) ;; *) return 1 ;; esac
    case "${2#pr: }" in *[!0-9]*) return 1 ;; esac
    case "$3" in 'branch: '*) [ "${3#branch: }" = "$branch" ] || return 1 ;; esac
    if [ -z "$pr_want" ]; then
        # shellcheck source=scripts/lib/timeout-bin.sh
        # shellcheck disable=SC1091
        . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
        pr_want="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} gh pr list --head "$branch" --state open \
            --json number -q '.[].number' 2>/dev/null)" || pr_want=""
        case "$pr_want" in ''|0*|*[!0-9]*)
            echo "review-round: cannot resolve the one open PR for $branch (gh pr list --head) - no judge record is honoured" >&2
            pr_want="-" ;;
        esac
    fi
    [ "${2#pr: }" = "$pr_want" ]
}

# HIMMEL-4700: print space-separated "<qid>/<name>" records ruling NO-GO for
# head $1 (one per qid), in console-kit/write-verdict.sh format, under this repo's
# verdict scope; rc 1 when there is none. A qid counts only when every record
# in it parses, so a hand-written or edited file disqualifies its qid.
# HIMMEL-4720: a consumed qid buys no other round. HIMMEL-4885: a qid
# consumed on this branch still contributes current-head class vetoes.
# ponytail: same-uid ceiling - the writer's stamp is a format check, not
# authentication, and any same-uid process can write into verdicts/; the
# upgrade path is a separate-uid verdict store (HIMMEL-4714 security note,
# HIMMEL-3578).
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
judge_nogo_record() (
    want="$1"
    lib="$HIMMEL_ROOT/scripts/lib"
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$lib/handover-path.sh" 2>/dev/null || exit 1
    # Not followed: its function locals (head_sha) read as subshell writes (SC2031).
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . "$lib/go-gate.sh" 2>/dev/null || exit 1
    root="$(go_resolve_root "$HIMMEL_ROOT")" && [ -n "$root" ] || exit 1
    scope="$(go_verdict_scope "$HIMMEL_ROOT")" && [ -n "$scope" ] || exit 1
    dir="$root"
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    for seg in "${scope%%/*}" "${scope#*/}" verdicts; do
        dir="$dir/$seg"
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    pr_want=""
    re_session='^writer-session: [A-Za-z0-9-]+$'
    re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    hits="" check_hits=""
    for qdir in "$dir"/*/; do
        qdir="${qdir%/}"
        qid="${qdir##*/}"
        if [ ! -d "$qdir" ] || [ -L "$qdir" ]; then continue; fi
        case "$qid" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        # HIMMEL-4720: a qid consumed on any branch buys no other round, so
        # two branches sharing a last reviewed head cannot each spend it.
        # HIMMEL-4738: a scan that fails (rc 2) refuses the record - only rc 1
        # means "not consumed".
        consumed=0 bound=""
        if [ -d "$git_dir/cr-review-rounds" ]; then
            scan=0
            grep -rqsF --include='*.verdicts' " $qid/" "$git_dir/cr-review-rounds" 2>/dev/null || scan=$?
            if [ "$scan" -eq 0 ]; then
                consumed=1
                local_scan=1
                if [ -e "$verdict_state" ] || [ -L "$verdict_state" ]; then
                    local_scan=0
                    grep -qsF " $qid/" "$verdict_state" 2>/dev/null || local_scan=$?
                fi
                [ "$local_scan" -ne 1 ] || continue
                if [ "$local_scan" -ne 0 ]; then
                    echo "review-round: cannot read $verdict_state for class history - delta round refused" >&2
                    exit 8
                fi
            elif [ "$scan" -ne 1 ]; then
                echo "review-round: cannot scan $git_dir/cr-review-rounds for a consumed $qid (grep rc $scan) - the judge record is refused" >&2
                exit 1
            fi
        fi
        hit="" bad=0 macbad=0
        for f in "$qdir"/*.md; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ] || [ ! -f "$f" ]; then bad=1; break; fi
            name="${f##*/}"; name="${name%.md}"
            case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) bad=1; break ;; esac
            l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
            { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
              IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
              IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } < "$f" 2>/dev/null
            if [ "$l1" != "# VERDICT $qid - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
                || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
                bad=1; break
            fi
            word="$(printf '%s\n' "$l8" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\1 \2/p')"
            [ -n "$word" ] || { bad=1; break; }
            # HIMMEL-4984: a record buys a round only when write-verdict.sh signed
            # it; one hand-written or edited withholds the round from its qid, but
            # its NO-GO still feeds the class veto (a NO-GO only narrows).
            go_verdict_mac_ok "$f" "$scope" "$qid" "$name" || macbad=1
            if [ "$word" = "NO-GO $want" ]; then
                [ -n "$hit" ] || hit="$qid/$name"
                if [ -z "$bound" ] && record_binds "$l9" "$l10" "$l11"; then bound="$qid/$name"; fi
            fi
        done
        if [ "$bad" -eq 0 ] && [ -n "$hit" ]; then
            check_hits="${check_hits:+$check_hits }$hit"
            if [ "$consumed" -eq 0 ] && [ "$macbad" -eq 0 ] && [ -n "$bound" ]; then hits="${hits:+$hits }$bound"; fi
        fi
    done
    [ -n "$check_hits" ] || exit 1
    judge_class_check "$check_hits" "$want" || exit 8
    [ "$pr_want" != "-" ] || exit 8
    [ -n "$hits" ] || exit 1
    printf '%s\n' "$hits"
)

# HIMMEL-4995: merge_forward_shape <from> <to> succeeds when <to> merges the
# captured base into <from> and nothing else: at least one merge, every
# non-merge commit it brought already on the base. Sets mf_merged_base.
merge_forward_shape() {
    [ -n "$base_sha" ] || return 1
    [ -n "$(git rev-list --merges "$1..$2" 2>/dev/null)" ] || return 1
    [ -z "$(git rev-list --no-merges "$1..$2" "^$base_sha" 2>/dev/null)" ] || return 1
    for _mf_m in $(git rev-list --merges "$1..$2" 2>/dev/null); do
        _mf_ok=0
        for _mf_p in $(git rev-list --parents -n 1 "$_mf_m" 2>/dev/null | cut -d' ' -f2-); do
            ! git merge-base --is-ancestor "$_mf_p" "$base_sha" 2>/dev/null || _mf_ok=1
        done
        [ "$_mf_ok" = 1 ] || return 1
    done
    mf_merged_base="$(git merge-base "$2" "$base_sha" 2>/dev/null)" || return 1
    [ -n "$mf_merged_base" ]
}
# own_diff <base> <head>: the PR's own diff as text, minus the index and
# hunk-header lines a moved base shifts.
own_diff() {
    _od_raw="$(git diff --no-ext-diff --no-color --no-renames "$1" "$2" 2>/dev/null)" || return 1
    printf '%s\n' "$_od_raw" | sed -e '/^index /d' -e 's/^@@ [^@]* @@.*$/@@/'
}
# clean_merge_forward <from> <to> succeeds only for a CLEAN merge-forward:
# <to>'s tree is exactly the conflict-free merge of <from> with the base point
# it merged, and the PR's own diff is the same text at <to> as at <from>. A
# merge that edits or resolves anything fails.
clean_merge_forward() {
    merge_forward_shape "$1" "$2" || return 1
    _cm_tree="$(git merge-tree --write-tree "$1" "$mf_merged_base" 2>/dev/null)" || return 1
    [ "$_cm_tree" = "$(git rev-parse "$2^{tree}" 2>/dev/null)" ] || return 1
    _cm_old="$(git merge-base "$1" "$base_sha" 2>/dev/null)" || return 1
    [ -n "$_cm_old" ] || return 1
    _cm_a="$(own_diff "$_cm_old" "$1")" || return 1
    _cm_b="$(own_diff "$mf_merged_base" "$2")" || return 1
    [ "$_cm_a" = "$_cm_b" ]
}

# HIMMEL-4952: print "<qid>/<name> <scope>" for a judge GO on head $2 (the
# delta's new head) written by console-kit/write-verdict.sh, whose evidence
# carries exactly one `delta-scope: test-only|lint-only` and one
# `delta-from: $1` line; rc 1 when there is none, rc 8 when a record is
# refused. A test-only record also needs every changed path to be a test path,
# checked here and not taken from the record. A qid already consumed on any
# branch is skipped, so one record buys one round.
# ponytail: lint-only has no path rule (lint is not recognisable from a path),
# so the judge's record alone admits it, same-uid ceiling as judge_nogo_record;
# the upgrade path is a lint-config path allowlist plus HIMMEL-3578.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
judge_scope_record() (
    from="$1" want="$2"
    lib="$HIMMEL_ROOT/scripts/lib"
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$lib/handover-path.sh" 2>/dev/null || exit 1
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . "$lib/go-gate.sh" 2>/dev/null || exit 1
    root="$(go_resolve_root "$HIMMEL_ROOT")" && [ -n "$root" ] || exit 1
    scope="$(go_verdict_scope "$HIMMEL_ROOT")" && [ -n "$scope" ] || exit 1
    dir="$root"
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    for seg in "${scope%%/*}" "${scope#*/}" verdicts; do
        dir="$dir/$seg"
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    re_session='^writer-session: [A-Za-z0-9-]+$'
    re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    pr_want=""
    # HIMMEL-4984: any NO-GO for the new head, in any qid (consumed or not, signed
    # or not - a NO-GO only narrows), blocks the scope round: a GO beside it is
    # not the judges' last word.
    for nf in "$dir"/*/*.md; do
        [ -f "$nf" ] && [ ! -L "$nf" ] || continue
        nl8=$(sed -n '8p' "$nf" 2>/dev/null | tr -d '\r')
        case "$nl8" in
            "**NO-GO** for head \`$want\`"|"**NO-GO** for head \`$want\`.")
                echo "review-round: ${nf#"$dir"/} rules NO-GO for $want - the scope round is refused (HIMMEL-4984)" >&2
                exit 8 ;;
        esac
    done
    for qdir in "$dir"/*/; do
        qdir="${qdir%/}"
        qid="${qdir##*/}"
        if [ ! -d "$qdir" ] || [ -L "$qdir" ]; then continue; fi
        case "$qid" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        if [ -d "$git_dir/cr-review-rounds" ]; then
            scan=0
            grep -rqsF --include='*.verdicts' " $qid/" "$git_dir/cr-review-rounds" 2>/dev/null || scan=$?
            [ "$scan" -ne 0 ] || continue
            if [ "$scan" -ne 1 ]; then
                echo "review-round: cannot scan $git_dir/cr-review-rounds for a consumed $qid (grep rc $scan) - the scope record is refused" >&2
                exit 8
            fi
        fi
        hit="" bad=0
        for f in "$qdir"/*.md; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ] || [ ! -f "$f" ]; then bad=1; break; fi
            name="${f##*/}"; name="${name%.md}"
            case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) bad=1; break ;; esac
            l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
            { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
              IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
              IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } < "$f" 2>/dev/null
            if [ "$l1" != "# VERDICT $qid - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
                || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
                bad=1; break
            fi
            word="$(printf '%s\n' "$l8" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\1 \2/p')"
            [ -n "$word" ] || { bad=1; break; }
            # HIMMEL-4984: signed by write-verdict.sh, or the qid is disqualified.
            go_verdict_mac_ok "$f" "$scope" "$qid" "$name" || { bad=1; break; }
            if [ -n "$hit" ] || [ "$word" != "GO $want" ]; then continue; fi
            # HIMMEL-4984: the record names this branch's PR (and branch, when it
            # carries one); a record for another PR or branch is refused.
            if ! record_binds "" "$l10" "$l11"; then
                [ "$pr_want" != "-" ] || exit 8
                continue
            fi
            evidence="$(sed -n '9,$p' "$f")"
            n_from="$(printf '%s\n' "$evidence" | grep -cE '^delta-from: ')"
            n_from_ok="$(printf '%s\n' "$evidence" | grep -cFx "delta-from: $from")"
            n_scope="$(printf '%s\n' "$evidence" | grep -cE '^delta-scope: ')"
            if [ "$n_from" -eq 1 ] && [ "$n_from_ok" -eq 1 ] && [ "$n_scope" -eq 1 ]; then
                kind="$(printf '%s\n' "$evidence" | sed -nE 's/^delta-scope: (test-only|lint-only|merge-resolution)$/\1/p')"
                [ -z "$kind" ] || hit="$qid/$name $kind"
            fi
        done
        if [ "$bad" -ne 0 ] || [ -z "$hit" ]; then continue; fi
        if [ "${hit#* }" = "test-only" ]; then
            while IFS= read -r changed; do
                # filename patterns match the basename only: * crosses / in case
                scope_ok=0
                case "$changed" in
                    */tests/*|tests/*|*/test/*|test/*|*/__tests__/*) scope_ok=1 ;;
                esac
                case "${changed##*/}" in
                    test-*.sh|*.test.[a-z]*) scope_ok=1 ;;
                esac
                if [ "$scope_ok" -ne 1 ]; then
                    echo "review-round: scope record ${hit%% *} is test-only but $from..$want changes non-test path $changed - delta round refused (HIMMEL-4952)" >&2
                    exit 8
                fi
            done <<EOF
$(git -c core.quotepath=off diff --no-renames --name-only "$from" "$want" 2>/dev/null)
EOF
        fi
        if [ "${hit#* }" = "merge-resolution" ] && ! merge_forward_shape "$from" "$want"; then
            echo "review-round: scope record ${hit%% *} is merge-resolution but $want is not a merge of the base into $from - delta round refused (HIMMEL-4995)" >&2
            exit 8
        fi
        printf '%s\n' "$hit"
        exit 0
    done
    exit 1
)

# HIMMEL-4600: decide whether the round after the third may run, as the one
# delta round. Sets delta_from/delta_to/delta_trigger, or says why not and
# returns 8 (2 for an unresolvable --head). HIMMEL-4700: a judge NO-GO on the
# last reviewed head is a third trigger, checked even once the delta was used;
# it sets delta_verdict.
delta_check() {
    full_note="a 4th full round is refused (HIMMEL-4600)"
    delta_reuse=0
    delta_free=0
    delta_used=""
    delta_verdict=""
    if [ -f "$delta_state" ]; then
        # HIMMEL-4616: a delta round whose panel produced no critic rows is
        # still pending, so the SAME <from> <to> pair may start again. Any
        # other pair, or a head a critic already reviewed, has used it up.
        read -r pend_from pend_to pend_trigger < "$delta_state" 2>/dev/null || pend_from=""
        if [ -n "$head_sha" ] && [ -n "$pend_from" ] && [ -n "$pend_to" ] \
            && cur_to="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" \
            && [ "$cur_to" = "$pend_to" ] \
            && [ "$(ledger_query avail "$pend_to")" != "ok" ] \
            && [ "$(ledger_query row "$pend_to")" != "row" ]; then
            # HIMMEL-4638: the first start's caller is still alive, so its
            # panel may be running; a second panel would only burn the bank.
            run_pid=""
            [ ! -f "$delta_run" ] || read -r run_pid < "$delta_run" || run_pid=""
            case "$run_pid" in
                ''|*[!0-9]*) run_pid="" ;;
            esac
            if [ -n "$run_pid" ] && [ "$run_pid" != "$PPID" ] && kill -0 "$run_pid" 2>/dev/null; then
                echo "review-round: the delta round on $branch is already running (start by pid $run_pid) - wait for it" >&2
                return 8
            fi
            delta_from="$pend_from"
            delta_to="$pend_to"
            delta_trigger="${pend_trigger:-fix}"
            delta_reuse=1
            return 0
        fi
        delta_used="$(cat "$delta_state" 2>/dev/null)"
        [ -n "$delta_used" ] || delta_used="unreadable"
    fi
    if [ -z "$head_sha" ]; then
        delta_refuse "review-round: $branch already ran 3 full rounds - $full_note; only a delta round (start --head) can run"
        return 8
    fi
    if ! delta_to="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$delta_to" ]; then
        if [ -n "$delta_used" ]; then
            delta_refuse ""
            return 8
        fi
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        return 2
    fi
    # The scope starts at the head the last counted round ran on, as start
    # persisted it - never at a ledger row the session could append itself.
    last_reviewed="$(cat "$head_state" 2>/dev/null)" || last_reviewed=""
    delta_from=""
    if [ -n "$last_reviewed" ]; then
        delta_from="$(git rev-parse --verify --quiet "$last_reviewed^{commit}" 2>/dev/null)" || delta_from=""
    fi
    if [ -z "$delta_from" ] || [ "$(ledger_query avail "$delta_from")" != "ok" ]; then
        delta_refuse "review-round: no critic-reviewed head of the last counted round on $branch to scope a delta round from - $full_note"
        return 8
    fi
    if [ "$delta_from" = "$delta_to" ]; then
        delta_refuse "review-round: $delta_to is the last reviewed head on $branch - $full_note"
        return 8
    fi
    if ! git merge-base --is-ancestor "$delta_from" "$delta_to" 2>/dev/null; then
        delta_refuse "review-round: $delta_to does not descend from the last reviewed head $delta_from - $full_note"
        return 8
    fi
    if git diff --quiet "$delta_from" "$delta_to" 2>/dev/null; then
        delta_refuse "review-round: $delta_from..$delta_to changes nothing - no delta round to run"
        return 8
    fi
    # A repeated-class veto also applies when a finding or merge-forward
    # could otherwise buy the delta: changing the trigger must not evade it.
    delta_verdict="$(judge_nogo_record "$delta_from")"
    judge_rc=$?
    [ "$judge_rc" -ne 8 ] || return 8
    # HIMMEL-4995: a clean merge-forward is admitted without spending the one
    # delta round, whether or not it was already used. It is checked before the
    # fix trigger: a clean merge carries no fix, so it must not spend the round.
    if clean_merge_forward "$delta_from" "$delta_to"; then
        delta_trigger="clean-merge"
        delta_free=1
        return 0
    fi
    if [ -z "$delta_used" ]; then
        if [ "$(ledger_query finding "$delta_from")" = "finding" ]; then
            delta_trigger="fix"
            return 0
        fi
    fi
    if [ -z "$delta_used" ]; then
        # Merge-forward: at least one merge since the reviewed head, every
        # non-merge commit it brought is already on the captured base, and the
        # new head's tree is exactly a clean merge of the reviewed head with the
        # base point it merged - so a merge carrying its own edits or conflict
        # resolutions is new work, not a merge-forward.
        if [ -n "$base_sha" ] \
            && [ -n "$(git rev-list --merges "$delta_from..$delta_to" 2>/dev/null)" ] \
            && [ -z "$(git rev-list --no-merges "$delta_from..$delta_to" "^$base_sha" 2>/dev/null)" ] \
            && merged_base="$(git merge-base "$delta_to" "$base_sha" 2>/dev/null)"; then
            if clean_tree="$(git merge-tree --write-tree "$delta_from" "$merged_base" 2>/dev/null)" \
                && [ "$clean_tree" = "$(git rev-parse "$delta_to^{tree}" 2>/dev/null)" ]; then
                delta_trigger="merge-forward"
                return 0
            fi
            if version_only_merge "$delta_from" "$merged_base" "$delta_to"; then
                delta_trigger="merge-forward"
                return 0
            fi
        fi
    fi
    # HIMMEL-4700: one judge-triggered round per last reviewed head.
    # HIMMEL-4738: an unreadable .verdicts refuses, never reads as unconsumed.
    head_scan=1
    if [ -e "$verdict_state" ] || [ -L "$verdict_state" ]; then
        head_scan=0
        grep -q "^$delta_from " "$verdict_state" 2>/dev/null || head_scan=$?
        if [ "$head_scan" -gt 1 ]; then
            echo "review-round: cannot read $verdict_state (grep rc $head_scan) - no judge NO-GO is honoured for $delta_from" >&2
        fi
    fi
    if [ "$head_scan" -eq 1 ] && [ "$judge_rc" -eq 0 ] && [ -n "$delta_verdict" ]; then
        first_verdict="${delta_verdict%% *}"
        delta_trigger="verdict:${first_verdict%%/*}"
        return 0
    fi
    # HIMMEL-4952: a judge-signed test- or lint-only record for the new head.
    scope_hit="$(judge_scope_record "$delta_from" "$delta_to")"
    scope_rc=$?
    [ "$scope_rc" -ne 8 ] || return 8
    if [ "$scope_rc" -eq 0 ] && [ -n "$scope_hit" ]; then
        scope_hit="${scope_hit%% *}"
        delta_verdict="$scope_hit"
        delta_trigger="scope:${scope_hit%%/*}"
        return 0
    fi
    delta_verdict=""
    delta_refuse "review-round: $delta_to neither answers a round-3 finding nor only merges the base into $delta_from, and no judge NO-GO for $delta_from is recorded (console-kit/write-verdict.sh) - $full_note; new work after the cap goes to the console"
    return 8
}

# Once the delta was used every refusal keeps naming it; otherwise print $1.
delta_refuse() {
    if [ -n "$delta_used" ]; then
        echo "review-round: the one delta round was already used on $branch ($delta_used) - a second delta round is refused, and $full_note; only a judge NO-GO on the last reviewed head (console-kit/write-verdict.sh) buys another; ask the console" >&2
    else
        echo "$1" >&2
    fi
}

if [ "$verb" = "start" ]; then
    lock_lib="$HIMMEL_ROOT/scripts/lib/shared-branch-lock.sh"
    if [ ! -f "$lock_lib" ]; then
        echo "review-round: counter lock library is missing at $lock_lib" >&2
        exit 5
    fi
    lock_out=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$lock_lib" acquire-wait "." "$branch" "review-round" 10 300 2>&1)
    lock_rc=$?
    [ -z "$lock_out" ] || printf '%s\n' "$lock_out" >&2
    if [ "$lock_rc" -ne 0 ]; then
        echo "review-round: cannot acquire the counter lock for $branch (rc=$lock_rc)" >&2
        exit 5
    fi
    lock_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    # lock_owner is a single small JSON status line (well under the pipe
    # buffer), so printf's write completes atomically before grep could
    # exit early and SIGPIPE it (HIMMEL-1430 class).
    if ! printf '%s' "$lock_owner" | grep -q '^{"pid":'; then  # pipefail-ok: bounded small input, see comment above
        echo "review-round: counter lock holder state for $branch is missing or unreadable — refusing" >&2
        exit 5
    fi
    if ! read_round; then
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
        exit 5
    fi
    delta_from=""
    delta_reuse=0
    delta_free=0
    if [ "$round" -ge 3 ]; then
        delta_check
        delta_rc=$?
        if [ "$delta_rc" -eq 0 ] && [ "${delta_reuse:-0}" -eq 0 ] && [ "${delta_free:-0}" -eq 0 ]; then
            # HIMMEL-4700: the delta round is recorded first and the judge
            # record consumed after it; a failed consume restores the prior
            # .delta, so a record is never spent on a round that never started.
            # Once both land, a failed counter write below is the HIMMEL-4616
            # pending pair, which restarts without the record.
            tmp_delta="$delta_state.tmp.$$"
            bak_delta="$delta_state.bak.$$"
            had_delta=0
            if [ -n "$delta_verdict" ] && [ -f "$delta_state" ]; then
                had_delta=1
                cp -p "$delta_state" "$bak_delta" 2>/dev/null || delta_rc=5
            fi
            if [ "$delta_rc" -ne 0 ] \
                || ! printf '%s %s %s\n' "$delta_from" "$delta_to" "$delta_trigger" > "$tmp_delta" \
                || ! mv "$tmp_delta" "$delta_state"; then
                rm -f "$tmp_delta" "$bak_delta"
                echo "review-round: cannot record the delta round for $branch" >&2
                delta_rc=5
            elif [ -n "$delta_verdict" ]; then
                tmp_verdicts="$verdict_state.tmp.$$"
                if ! { cat "$verdict_state" 2>/dev/null || [ ! -e "$verdict_state" ]; } > "$tmp_verdicts" \
                    || ! ( for record in $delta_verdict; do
                        printf '%s %s %s\n' "$delta_from" "$delta_to" "$record" || exit 1
                    done ) >> "$tmp_verdicts" \
                    || ! mv "$tmp_verdicts" "$verdict_state"; then
                    rm -f "$tmp_verdicts"
                    if [ "$had_delta" -eq 1 ]; then
                        # A failed restore keeps the new pair: still "used".
                        mv -f "$bak_delta" "$delta_state" 2>/dev/null || true
                    else
                        rm -f "$delta_state"
                    fi
                    echo "review-round: cannot record the judge record $delta_verdict for $branch" >&2
                    delta_rc=5
                fi
                rm -f "$bak_delta"
            fi
        fi
        if [ "$delta_rc" -ne 0 ]; then
            SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
                bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
            exit "$delta_rc"
        fi
    fi
    # A reused pending delta round keeps the counter it already took.
    [ "${delta_reuse:-0}" -eq 1 ] || round=$((round + 1))
    tmp_state="$state.tmp.$$"
    current_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    if [ "$current_owner" != "$lock_owner" ] \
        || ! printf '%s\n' "$round" > "$tmp_state" \
        || ! mv "$tmp_state" "$state"; then
        rm -f "$tmp_state"
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
        echo "review-round: cannot persist round $round for $branch under the counter lock" >&2
        exit 5
    fi
    # Record the head this counted round runs on, the next delta scope's
    # start. Without --head, or on a failed write, no head is kept, so a later
    # delta round fails closed instead of scoping from an older round.
    round_head=""
    if [ -n "$head_sha" ]; then
        round_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || round_head=""
    fi
    tmp_head="$head_state.tmp.$$"
    if [ -z "$round_head" ] \
        || ! printf '%s\n' "$round_head" > "$tmp_head" \
        || ! mv "$tmp_head" "$head_state"; then
        rm -f "$tmp_head" "$head_state"
    fi
    if [ -n "$delta_from" ]; then
        # HIMMEL-4638: written under the counter lock, so the pid check in
        # delta_check and this claim cannot interleave between two starts.
        # Best effort - a failed write only loses the guard.
        printf '%s\n' "$PPID" > "$delta_run" 2>/dev/null || rm -f "$delta_run" 2>/dev/null
    fi
    if ! SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1; then
        echo "review-round: persisted round $round for $branch but could not release its counter lock" >&2
        exit 5
    fi
    if [ -n "$delta_from" ]; then
        printf '%s delta %s\n' "$round" "$delta_from"
    else
        printf '%s\n' "$round"
    fi
    exit 0
fi

# promote (HIMMEL-2911): the /pr-check flow writes verdict=agreed as a leg-agrees
# intermediate (write-verdicts.sh + step 4.5's ledger-append.sh amend) and
# nothing ever promotes it to a terminal verdict — until now it was only ever
# hand-amended to `fixed`. Given a CLEAN round at --head (the caller asserts
# this — promote does not itself re-check the panel, same posture as `defer`
# not re-running it), every `finding` row on --branch whose LATEST amend
# (joined on target_head + finding_id + artifact + perspective — NOT branch,
# since pre-HIMMEL-2911 rows can carry branch:"") is `agreed` is promoted to
# `fixed` UNLESS (a) its OWN row is recorded exactly at --head — a finding
# raised and agreed in the very round being certified clean has had no later
# commit that could have fixed it, so it is left agreed rather than stamped
# resolved on zero evidence (codex-1, HIMMEL-2911 CR round 1) — or (b) it is
# re-raised at --head: a DIFFERENT finding row on the same branch, at --head,
# sharing the same stored `fingerprint` (ledger-append.sh already computes
# this at write time — promote reads it, never recomputes it) whose OWN
# effective verdict is still live (empty/agreed/conflict/unaddressed/deferred,
# never fixed/disproved — codex-2, HIMMEL-2911 CR round 1: a matching
# occurrence that is itself already fixed/disproved is not an open re-raise;
# codex-1, HIMMEL-2911 CR round 3: `deferred` stays live — it means the issue
# is REAL and tracked, so it must not let an older occurrence be stamped
# fixed) — or (c) --head is not actually a git descendant of that finding own
# head (codex-2, HIMMEL-2911 CR round 3: an unrelated or divergent --head
# never reviewed past that commit, so its absence there is not evidence of
# anything). Terminal rows (fixed/disproved/deferred) are left untouched;
# conflict/unaddressed were never agreed and are only WARNed. A finding whose
# stored fingerprint is empty (pre-fingerprint row, or no --text was ever
# supplied) cannot be safely checked for re-raise, so it is conservatively
# left agreed (counted as still-open) rather than guessed at. Idempotent: a
# second run sees the fixed amend via the same effective-state merge and
# skip-terminals it, writing nothing.
# A row whose effective verdict is EMPTY (no amend at all) is also still-open,
# tagged `(unadjudicated)`: nobody looked, so the round cannot be certified
# clean over it either — never counted as WARN (that means a human already
# disagreed) and never silently skipped (HIMMEL-2917).
# Exit 0 = no still-open findings; exit 3 = one or more rows are still-open
# (the caller's round was not actually clean for that finding, whether it was
# left agreed or never adjudicated at all); exit 1 = a malformed ledger row
# or a ledger write failure; exit 2 = --head does not resolve to a commit;
# exit 5 = the CR ledger file itself is missing.
if [ "$verb" = "promote" ]; then
    if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    ledger="$git_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "review-round: CR ledger is missing at $ledger" >&2
        exit 5
    fi
    decisions_tmp="$(mktemp -t cr-promote-decisions.XXXXXX)" || { echo "review-round: cannot create scratch state" >&2; exit 1; }
    analysis="$(FULL_HEAD="$full_head" LEDGER="$ledger" BRANCH="$branch" DECISIONS_FILE="$decisions_tmp" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31);
let malformed = 0;
const rows = [];
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  rows.push(o);
}
if (malformed !== 0) {
  process.stdout.write(JSON.stringify({malformed}));
  process.exit(0);
}
const resolveCache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_HEAD) return true;
  if (!/^[0-9a-f]{7,64}$/i.test(h)) return false;
  if (!resolveCache.has(h)) {
    let resolved = "";
    try {
      resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
        {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]}).trim();
    } catch { resolved = ""; }
    resolveCache.set(h, resolved);
  }
  return resolveCache.get(h) === e.FULL_HEAD;
}
// codex-2, HIMMEL-2911 CR round 3: "not re-raised at --head" is only
// meaningful evidence of a fix when --head actually descends from the
// finding own commit — otherwise an unrelated or divergent clean head
// (a stale/incomparable --head) would let a later, never-reviewed commit
// findings get marked fixed with no real evidence either way.
const ancestorCache = new Map();
function isAncestorOfHead(commit) {
  const h = String(commit || "");
  if (!h) return false;
  if (h === e.FULL_HEAD) return true;
  if (!ancestorCache.has(h)) {
    let ok = false;
    try {
      cp.execFileSync("git", ["merge-base", "--is-ancestor", h, e.FULL_HEAD], {stdio: "ignore"});
      ok = true;
    } catch { ok = false; }
    ancestorCache.set(h, ok);
  }
  return ancestorCache.get(h);
}
// Merge every amend.set for a (branch, target_head, finding_id, artifact,
// perspective) key in ledger (chronological) order — a later amend field
// wins, a field a later amend never touched keeps its earlier value. Same
// shape as ledger-append.shs own amendsByKey/effective().
// HIMMEL-3461: the key gains branch, matching ledger-append.sh,
// clear-cr-marker.sh and handover-bridge.sh byte-for-byte (HIMMEL-2405). Two
// branches can legitimately sit at the same head (HIMMEL-1175), and finding
// ids are minted in per-producer stream order (not globally unique), so an
// amend recorded while judging one branch must never leak into this gate
// judgment of another. A legacy amend row with an empty branch (written
// before branches were stamped) still applies to ANY branch — looked up
// through the same "" bucket every branch checks, merged under whatever
// branch-specific amend exists (branch-specific merges LAST and wins field
// conflicts, since every branch-specific amend post-dates the legacy ones).
const amendsByKey = new Map();
for (const o of rows) {
  if (o.kind !== "amend" || !o.set || typeof o.set !== "object") continue;
  const k = [o.branch || "", o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  amendsByKey.set(k, Object.assign({}, amendsByKey.get(k) || {}, o.set));
}
const amendSetFor = (branch, head, id, artifact, perspective) => {
  const legacy = amendsByKey.get(["", head, id, artifact, perspective].join(SEP));
  const scoped = amendsByKey.get([branch || "", head, id, artifact, perspective].join(SEP));
  return (legacy || scoped) ? Object.assign({}, legacy || {}, scoped || {}) : null;
};
const findingRows = rows.filter((o) => o.kind === "finding" && o.branch === e.BRANCH);
const atHead = findingRows.filter((o) => resolvesToHead(o.head));
// Only a LIVE occurrence at --head is a genuine re-raise (codex-2, HIMMEL-2911
// CR round 1): a matching finding at --head that is itself already
// fixed/disproved is a DISPOSITIONED instance, not an open one, and must not
// keep an older agreed row still-open forever just because its fingerprint
// once reappeared. deferred stays LIVE (codex-1, HIMMEL-2911 CR round 3):
// deferred means the issue is REAL and tracked, never fixed, so a deferred
// reappearance must not let an older agreed occurrence of the SAME issue be
// promoted to fixed — that would be a false claim the code changed.
const liveVerdicts = new Set(["", "agreed", "conflict", "unaddressed", "deferred"]);
const fpAtHead = new Map();
for (const o of atHead) {
  if (!o.fingerprint) continue;
  const idKey = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  const effectiveAtHead = Object.assign({}, o, amendSetFor(o.branch || "", o.head, o.finding_id, o.artifact || "diff", o.perspective || "off") || {});
  if (!liveVerdicts.has(String(effectiveAtHead.verdict || "").trim())) continue;
  if (!fpAtHead.has(o.fingerprint)) fpAtHead.set(o.fingerprint, new Set());
  fpAtHead.get(o.fingerprint).add(idKey);
}
const outLines = [];
for (const row of findingRows) {
  const idKey = [row.head, row.finding_id, row.artifact || "diff", row.perspective || "off"].join(SEP);
  const effective = Object.assign({}, row, amendSetFor(row.branch || "", row.head, row.finding_id, row.artifact || "diff", row.perspective || "off") || {});
  const verdict = String(effective.verdict || "").trim();
  let action;
  if (verdict === "fixed" || verdict === "disproved" || verdict === "deferred") action = "skip-terminal";
  else if (verdict === "conflict" || verdict === "unaddressed") action = "warn-unadjudicated";
  else if (verdict === "") action = "still-open-unadjudicated";
  else if (verdict !== "agreed") continue;
  else if (resolvesToHead(row.head)) {
    // codex-1, HIMMEL-2911 CR round 1: a finding raised (and agreed) AT the
    // very head being asserted clean has had no later commit that could have
    // fixed it — promoting it here would stamp an untouched, still-present
    // issue as resolved on zero evidence. Leave it agreed; it needs a real
    // disposition (a follow-up fix at a fresh head, or a deferral), the same
    // way the round-4 cap defers a same-head pending suggestion instead of
    // fabricating a fix for it.
    action = "still-open";
  } else if (!isAncestorOfHead(row.head)) {
    // Not an ancestor of --head: the clean round at --head never actually
    // reviewed past this commit, so its absence there proves nothing.
    action = "still-open";
  } else {
    const fp = effective.fingerprint || "";
    const present = fp ? fpAtHead.get(fp) : null;
    const reraised = !fp || (present && [...present].some((k) => k !== idKey));
    action = reraised ? "still-open" : "promote";
  }
  outLines.push(JSON.stringify({
    action, id: row.finding_id, head: row.head, branch: row.branch,
    artifact: row.artifact || "diff", perspective: row.perspective || "off", verdict,
  }));
}
fs.writeFileSync(e.DECISIONS_FILE, outLines.length ? outLines.join("\n") + "\n" : "");
process.stdout.write(JSON.stringify({malformed: 0}));
' 2>/dev/null)"
    node_rc=$?
    malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
    if [ "$node_rc" -ne 0 ] || [ -z "$malformed" ]; then
        rm -f "$decisions_tmp"
        echo "review-round: could not evaluate the ledger for promotion" >&2
        exit 1
    fi
    if [ "$malformed" -ne 0 ]; then
        rm -f "$decisions_tmp"
        echo "review-round: malformed CR ledger row(s) — refusing automatic promotion" >&2
        exit 1
    fi
    head8="$(printf '%s' "$full_head" | cut -c1-8)"
    promoted=0 still_open=0 skip_terminal=0 warn_count=0 write_fail=0
    while IFS= read -r decision || [ -n "$decision" ]; do
        [ -n "$decision" ] || continue
        action="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).action))' 2>/dev/null)" || action=""
        id="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || id=""
        row_head="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).head))' 2>/dev/null)" || row_head=""
        row_branch="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).branch))' 2>/dev/null)" || row_branch=""
        row_artifact="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || row_artifact=""
        row_perspective="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || row_perspective=""
        row_verdict="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).verdict))' 2>/dev/null)" || row_verdict=""
        if [ -z "$action" ] || [ -z "$id" ] || [ -z "$row_head" ]; then
            write_fail=1
            break
        fi
        row_head8="$(printf '%s' "$row_head" | cut -c1-8)"
        case "$action" in
            promote)
                if ! CR_LEDGER="$ledger" bash "$SCRIPT_DIR/ledger-append.sh" amend \
                    --branch "$row_branch" --head "$row_head" --id "$id" \
                    --artifact "$row_artifact" --perspective "$row_perspective" \
                    --set verdict=fixed \
                    --reason "Promoted from agreed: no re-raise at clean round head $head8 (HIMMEL-2911)"; then
                    write_fail=1
                    break
                fi
                echo "promoted ${id}@${row_head8}"
                promoted=$((promoted + 1))
                ;;
            still-open)
                echo "still-open ${id}@${row_head8}"
                still_open=$((still_open + 1))
                ;;
            still-open-unadjudicated)
                echo "still-open ${id}@${row_head8} (unadjudicated)"
                still_open=$((still_open + 1))
                ;;
            skip-terminal)
                echo "skip-terminal ${id}@${row_head8} (verdict=${row_verdict})"
                skip_terminal=$((skip_terminal + 1))
                ;;
            warn-unadjudicated)
                echo "WARN unadjudicated ${id}@${row_head8} (verdict=${row_verdict})"
                warn_count=$((warn_count + 1))
                ;;
        esac
    done < "$decisions_tmp"
    rm -f "$decisions_tmp"
    if [ "$write_fail" -ne 0 ]; then
        echo "review-round: ledger write failed during promotion" >&2
        exit 1
    fi
    echo "review-round promote: $promoted promoted, $still_open still-open, $skip_terminal skip-terminal, $warn_count warn (head $head8)"
    [ "$still_open" -eq 0 ] || exit 3
    exit 0
fi

read_round || exit $?

if [ "$round" -lt 4 ]; then
    echo "review-round: $branch is at round $round; automatic deferral starts at round 4" >&2
    exit 2
fi
if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
    echo "review-round: --head $head_sha does not resolve to a commit" >&2
    exit 2
fi
ledger="$git_dir/cr-critic-scores.jsonl"
if [ ! -f "$ledger" ]; then
    echo "review-round: CR ledger is missing at $ledger" >&2
    exit 5
fi
cap_reason='Suggestion deferred after the three-round /pr-check cap.'
delta_reason='Finding deferred in the one delta round after the three-round /pr-check cap.'
# HIMMEL-4600: --head is the head the one delta round reviewed.
delta_mode=0
if [ -f "$delta_state" ]; then
    delta_reviewed="$(awk '{print $2; exit}' "$delta_state" 2>/dev/null)" || delta_reviewed=""
    [ "$delta_reviewed" = "$full_head" ] && delta_mode=1
fi
if [ "$delta_mode" -eq 1 ]; then
    defer_reason="$delta_reason"
    round_label="the delta round"
else
    defer_reason="$cap_reason"
    round_label="round $round"
fi

analysis="$(FULL_SHA="$full_head" LEDGER="$ledger" DELTA="$delta_mode" CAP_REASON="$cap_reason" DELTA_REASON="$delta_reason" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31), amends = new Map(), findings = new Map();
let malformed = 0;
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  if (o.kind === "amend" && o.set && typeof o.set === "object") {
    const key = [o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
    amends.set(key, Object.assign({}, amends.get(key) || {}, o.set));
  }
}
const cache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_SHA) return true;
  if (!/^[0-9a-f]{7,64}$/.test(h) || !e.FULL_SHA.startsWith(h)) return false;
  if (!cache.has(h)) {
    let resolved = "";
    try { resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"], {encoding:"utf8", stdio:["ignore","pipe","ignore"]}).trim(); }
    catch { resolved = ""; }
    cache.set(h, resolved);
  }
  return cache.get(h) === e.FULL_SHA;
}
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  if (o.kind !== "finding") continue;
  const original = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  if (amends.has(original)) o = Object.assign({}, o, amends.get(original));
  if (!resolvesToHead(o.head)) continue;
  const key = [o.finding_id || "?", o.artifact || "diff", o.perspective || "off"].join(SEP);
  findings.set(key, o);
}
const pending = [], capDeferred = [], blocking = [], unclassified = [];
const CAP_REASONS = [e.CAP_REASON, e.DELTA_REASON];
for (const o of findings.values()) {
  const id = String(o.finding_id || "?");
  const severity = String(o.severity || "");
  const verdict = typeof o.verdict === "string" ? o.verdict.trim() : "";
  const ticket = typeof o.deferred_to === "string" ? o.deferred_to.trim() : "";
  const reason = typeof o.reason === "string" ? o.reason.trim() : "";
  const trackedDeferred = verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && reason;
  const resolved = verdict === "disproved" || trackedDeferred;
  if (e.DELTA === "1") {
    // HIMMEL-4600: the delta round blocks only on Critical or escape-class;
    // every other open finding is deferred. An Important needs an explicit
    // fu_class amend from the adjudicator first: an escape-class Important
    // is fixed in the PR, so it is never deferred by default.
    const fuClass = typeof o.fu_class === "string" ? o.fu_class.trim() : "";
    if ((severity === "crit" || fuClass === "escape") && !resolved) blocking.push(id);
    else if (!resolved && (!verdict || verdict === "agreed") && severity === "imp" && fuClass !== "hardening") unclassified.push(id);
    else if (!resolved && (!verdict || verdict === "agreed")) pending.push({
      id,
      artifact: o.artifact || "diff",
      perspective: o.perspective || "off",
      fu_class: severity === "imp" ? fuClass : "polish"
    });
    else if (trackedDeferred && CAP_REASONS.includes(reason)) capDeferred.push({id, ticket});
    else if (!resolved && verdict !== "fixed") blocking.push(id);
    continue;
  }
  if ((severity === "crit" || severity === "imp") && !resolved) blocking.push(id);
  else if (!verdict && (severity === "sug" || severity === "nit")) pending.push({
    id,
    artifact: o.artifact || "diff",
    perspective: o.perspective || "off",
    fu_class: "polish"
  });
  else if ((severity === "sug" || severity === "nit") && trackedDeferred &&
           reason === e.CAP_REASON) {
    capDeferred.push({id, ticket});
  }
  else if (!verdict) blocking.push(id);
}
process.stdout.write(JSON.stringify({malformed, pending, capDeferred, blocking, unclassified}));
' 2>/dev/null)"
if [ -z "$analysis" ]; then
    echo "review-round: could not evaluate findings at $full_head" >&2
    exit 5
fi
malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
blocking="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).blocking.join(" ")))' 2>/dev/null)" || blocking=""
pending_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).pending.length)))' 2>/dev/null)" || pending_count=""
cap_deferred_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).capDeferred.length)))' 2>/dev/null)" || cap_deferred_count=""
if [ -z "$malformed" ] || [ -z "$pending_count" ] || [ -z "$cap_deferred_count" ]; then
    echo "review-round: could not parse the ledger evaluation" >&2
    exit 5
fi
if [ "$malformed" -ne 0 ]; then
    echo "review-round: malformed CR ledger row(s) — refusing automatic disposition" >&2
    exit 5
fi
if [ -n "$blocking" ] && [ "$delta_mode" -eq 1 ]; then
    echo "review-round: Critical or escape-class finding(s) remain blocking in the delta round: $blocking" >&2
    exit 4
fi
unclassified="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).unclassified.join(" ")))' 2>/dev/null)" || unclassified=""
if [ -n "$unclassified" ]; then
    echo "review-round: Important finding(s) in the delta round need an explicit fu_class amend before they can be deferred: $unclassified - amend each with --set fu_class=escape (fix it in this PR) or --set fu_class=hardening (exactly; polish or any other class does not qualify), then re-run defer" >&2
    exit 4
fi
if [ -n "$blocking" ]; then
    echo "review-round: Critical or Important finding(s) remain blocking at round $round: $blocking" >&2
    exit 4
fi
if [ "$pending_count" -eq 0 ] && [ "$cap_deferred_count" -eq 0 ]; then
    exit 0
fi

# defer_to is a single small ticket-key string (well under the pipe
# buffer), so printf's write completes atomically before grep could exit
# early and SIGPIPE it (HIMMEL-1430 class).
if [ "$pending_count" -gt 0 ] && ! printf '%s' "$defer_to" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then  # pipefail-ok: bounded small input, see comment above
    primary_root="$HIMMEL_ROOT"
    himmel_common="$(git -C "$HIMMEL_ROOT" rev-parse --git-common-dir 2>/dev/null)" || himmel_common=""
    if [ -n "$himmel_common" ]; then
        case "$himmel_common" in
            /*) ;;
            *) himmel_common="$HIMMEL_ROOT/$himmel_common" ;;
        esac
        resolved_primary="$(cd "$himmel_common/.." 2>/dev/null && pwd)" || resolved_primary=""
        [ -n "$resolved_primary" ] && primary_root="$resolved_primary"
    fi
    echo "review-round: $round_label has deferrable findings only, but no valid defer ticket was supplied." >&2
    printf "node '%s/scripts/jira/dist/index.js' create --type Task --title 'Track deferred /pr-check round 4+ suggestions' --desc 'Track suggestion/nit-only findings deferred after the three-round review cap.'\n" "$primary_root" >&2
    printf "Then resume without rerunning the panel:\nCR_DEFER_TO=HIMMEL-NNNN bash '%s/review-round.sh' defer --head '%s' --branch '%s'\n" "$SCRIPT_DIR" "$full_head" "$branch" >&2
    exit 6
fi

ids_tmp="$(mktemp -t cr-round-ids.XXXXXX)" || exit 5
verdicts_tmp="$(mktemp -t cr-round-verdicts.XXXXXX)" || { rm -f "$ids_tmp"; exit 5; }
if ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).pending) process.stdout.write(JSON.stringify(finding)+"\n")})' > "$ids_tmp" \
    || ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).capDeferred) process.stdout.write("VERDICT ["+finding.id+"] = deferred -> "+finding.ticket+"\n")})' > "$verdicts_tmp"; then
    rm -f "$ids_tmp" "$verdicts_tmp"
    echo "review-round: could not prepare the deferred finding recovery state" >&2
    exit 5
fi
amend_rc=0
while IFS= read -r finding_identity || [ -n "$finding_identity" ]; do
    [ -n "$finding_identity" ] || continue
    finding_id="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || finding_id=""
    artifact="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || artifact=""
    perspective="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || perspective=""
    fu_class="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).fu_class))' 2>/dev/null)" || fu_class=""
    if [ -z "$finding_id" ] || [ -z "$artifact" ] || [ -z "$perspective" ] || [ -z "$fu_class" ]; then
        amend_rc=5
        break
    fi
    if ! bash "$SCRIPT_DIR/ledger-append.sh" amend \
        --branch "$branch" --head "$full_head" --id "$finding_id" \
        --artifact "$artifact" --perspective "$perspective" \
        --set verdict=deferred --set "deferred_to=$defer_to" --set "fu_class=$fu_class" \
        --set "reason=$defer_reason" \
        --reason 'deferred by review-round.sh after the three-round cap'; then
        amend_rc=5
        break
    fi
    printf 'VERDICT [%s] = deferred -> %s\n' "$finding_id" "$defer_to" >> "$verdicts_tmp"
done < "$ids_tmp"
rm -f "$ids_tmp"
if [ "$amend_rc" -ne 0 ]; then
    rm -f "$verdicts_tmp"
    exit "$amend_rc"
fi

write_recovered_verdicts() {
    verdict_mode="$1"
    existing_verdicts="$2"
    merged_tmp="$(mktemp -t cr-round-merged.XXXXXX)" || return 5
    dedup_tmp="$(mktemp -t cr-round-dedup.XXXXXX)" || { rm -f "$merged_tmp"; return 5; }
    : > "$merged_tmp"
    if [ -f "$existing_verdicts" ] && ! cat "$existing_verdicts" >> "$merged_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    if ! cat "$verdicts_tmp" >> "$merged_tmp" \
        || ! awk 'NF && !seen[$0]++' "$merged_tmp" > "$dedup_tmp" \
        || ! bash "$SCRIPT_DIR/write-verdicts.sh" "$verdict_mode" --branch "$branch" < "$dedup_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    rm -f "$merged_tmp" "$dedup_tmp"
    return 0
}

if ! write_recovered_verdicts prior-blocking "$git_dir/cr-prior-blocking/$branch" \
    || ! write_recovered_verdicts aggregate "$git_dir/cr-aggregate-verdicts/$branch"; then
    rm -f "$verdicts_tmp"
    exit 5
fi
rm -f "$verdicts_tmp"
bash "$SCRIPT_DIR/clear-cr-marker.sh" "$branch"
