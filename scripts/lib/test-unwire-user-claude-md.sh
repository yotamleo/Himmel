#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2059 # A && B || C is the sibling suites' check() idiom; the backticks in fixtures are literal fence text; a case's printf format IS its fixture
# test-unwire-user-claude-md.sh -- hermetic fixture matrix for
# unwire-user-claude-md.sh (HIMMEL-3333). Every case is a file under one
# mktemp dir, removed on exit; no $HOME, no install, no network. The verdicts
# are BYTE verdicts (cmp against the expected bytes), never "the BEGIN line is
# gone": exactness means the operator's text is identical before and after,
# and a refusal means the file is identical to what we were handed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
uw="$here/unwire-user-claude-md.sh"
fails=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
same() { cmp -s "$2" "$3" && ok "$1" || { bad "$1: bytes differ"; diff "$2" "$3" | head -20; }; }
gone() { [ ! -e "$2" ] && [ ! -L "$2" ] && ok "$1" || bad "$1: still present: $2"; }
there(){ [ -e "$2" ] && ok "$1" || bad "$1: missing: $2"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: output lacks [$2]"; printf '%s\n' "$3" | head -5 ;; esac; }
td="$(mktemp -d "${TMPDIR:-/tmp}/unwire-ucm-suite.XXXXXX")" || { echo "cannot create a scratch dir -- not running against /" >&2; exit 1; }
trap 'chmod -R u+rw "$td" 2>/dev/null; rm -rf "$td"' EXIT
export TMPDIR="$td/tmp"; mkdir -p "$TMPDIR"

B='<!-- BEGIN HIMMEL:working-principles -->'
E='<!-- END HIMMEL:working-principles -->'
# The block exactly as wire_user_claude_md writes it into a file it CREATES.
BLOCK="$(printf '%s\n## Working principles\n- think first\n%s' "$B" "$E")"
# run <file> [dry] -- runs the strip, captures rc + output
run(){ out="$(bash "$uw" "$@" 2>&1)"; rc=$?; }
# strip <name> <before-printf-fmt> <expect-printf-fmt> -- the exactness shape:
# file starts as <before>, must end as <expect>, rc 0, and the backup holds the
# ORIGINAL bytes.
strip(){
  local n="$1" f="$td/$1.md"
  printf -- "$2" "$BLOCK" > "$f"; cp "$f" "$td/$n.before"; printf -- "$3" > "$td/$n.expect"
  run "$f"
  check "$n: rc 0" "$rc" 0
  same  "$n: surrounding bytes identical" "$f" "$td/$n.expect"
  same  "$n: backup is the file as found" "$f.himmel-uninstall-backup" "$td/$n.before"
}
# noop <name> <before-printf-fmt> -- nothing to strip: rc 0, byte-identical, no backup
noop(){
  local n="$1" f="$td/$1.md"
  printf -- "$2" > "$f"; cp "$f" "$td/$n.before"
  run "$f"
  check "$n: rc 0" "$rc" 0
  has   "$n: says nothing to strip" "nothing to strip" "$out"
  same  "$n: file left byte-identical" "$f" "$td/$n.before"
  gone  "$n: no backup written" "$f.himmel-uninstall-backup"
}

# ── the empty / whitespace / no-marker controls ─────────────────────────────
noop  empty        ''
noop  whitespace   '\n\n  \n\t\n'
noop  no-marker    '# mine\nsimplicity first\n'
# prose that mentions the marker is not a marker line
noop  prose        'notes about <!-- BEGIN HIMMEL:working-principles --> in prose\n'
there "empty: a 0-byte file with no block is kept" "$td/empty.md"

# ── our block, alone -- the DECIDED empty case ──────────────────────────────
# install created the file (block only, no leading blank): removed, no backup
f="$td/block-only.md"; printf '%s\n' "$BLOCK" > "$f"; run "$f"
check "block-only: rc 0" "$rc" 0
gone  "block-only: install-created file removed" "$f"
gone  "block-only: no backup for a file that held nothing of the operator's" "$f.himmel-uninstall-backup"
has   "block-only: says why it was removed" "install created it" "$out"
# install APPENDED to an empty file (its blank line is there): given back empty
f="$td/was-empty.md"; printf '\n%s\n' "$BLOCK" > "$f"; cp "$f" "$td/was-empty.before"; run "$f"
check "was-empty: rc 0" "$rc" 0
there "was-empty: the operator's file is kept" "$f"
check "was-empty: and is empty again" "$(wc -c < "$f")" 0
same  "was-empty: backup is the file as found" "$f.himmel-uninstall-backup" "$td/was-empty.before"
has   "was-empty: says it was empty before install" "empty again" "$out"
# the operator's file was a lone newline: that newline is theirs and stays
strip was-newline '\n\n%s\n' '\n'

# ── exactness: text before / after / both, with and without install's blank ─
strip before        'top\n\n%s\n'          'top\n'
strip before-noblank 'top\n%s\n'           'top\n'
strip after         '%s\nbottom\n'         'bottom\n'
strip both          'top\n\n%s\nbottom\n'  'top\nbottom\n'
strip both-multi    '# a\n\nb  \n\n%s\n\n## c\nd\n' '# a\n\nb  \n\n## c\nd\n'
# no trailing newline: the operator's last byte is preserved, never "fixed"
strip after-nonl    'top\n\n%s\nbottom'    'top\nbottom'
strip end-nonl      'top\n\n%s'            'top\n'
# a quoted marker inside a fence INSIDE our block goes with the block
printf 'top\n\n%s\n```\n%s\n```\n%s\n' "$B" "$B" "$E" > "$td/inner-fence-2.md"  # fenced copy of BEGIN inside the block
run "$td/inner-fence-2.md"; check "inner-fence-2: a quoted marker inside our block is part of the block" "$rc" 0
check "inner-fence-2: only top remains" "$(cat "$td/inner-fence-2.md")" "top"

# ── refuse rather than guess ────────────────────────────────────────────────
# refuse2 <name> <line>... -- the refusal shape: rc 1, file byte-identical, no
# backup written, message names the file and says by hand.
refuse2(){ local n="$1" dry; shift; local f="$td/$n.md"; printf '%s\n' "$@" > "$f"; cp "$f" "$td/$n.before"
  for dry in 1 0; do run "$f" "$dry"; check "$n (dry=$dry): rc 1" "$rc" 1; same "$n (dry=$dry): byte-identical" "$f" "$td/$n.before"
    has "$n (dry=$dry): names the file" "$f" "$out"; has "$n (dry=$dry): says by hand" "by hand" "$out"; done
  gone "$n: no backup" "$f.himmel-uninstall-backup"; }
refuse2 begin-no-end-2 top "$B" body bottom;            has "begin-no-end-2: counts" '1 BEGIN and 0 END' "$out"
refuse2 end-no-begin-2 top body "$E" bottom;            has "end-no-begin-2: counts" '0 BEGIN and 1 END' "$out"
refuse2 two-begins-2   top "$B" x "$B" y "$E" bottom;   has "two-begins-2: counts"   '2 BEGIN and 1 END' "$out"
refuse2 two-blocks-2   top "$B" x "$E" mid "$B" y "$E"; has "two-blocks-2: counts"   '2 BEGIN and 2 END' "$out"
refuse2 inverted-2     top "$E" body "$B" bottom;       has "inverted-2: says inverted" 'END above BEGIN' "$out"
refuse2 open-fence-2   top '```' 'never closed' "$B" body "$E" bottom; has "open-fence-2: names the fence" 'never closes' "$out"
printf 'top\r\n\r\n%s\r\nbody\r\n%s\r\nbottom\r\n' "$B" "$E" > "$td/crlf-2.md"; cp "$td/crlf-2.md" "$td/crlf-2.before"
run "$td/crlf-2.md"; check "crlf-2: rc 1" "$rc" 1; same "crlf-2: byte-identical" "$td/crlf-2.md" "$td/crlf-2.before"; has "crlf-2: says CRLF" CRLF "$out"
# a CRLF block is NOT "nothing to strip": the block is still there and the
# operator is told so, instead of an uninstall that quietly leaves it wired.
bash "$uw" --probe "$td/crlf-2.md" >/dev/null 2>&1; check "crlf-2: probe reports a marker present" "$?" 3

# ── marker text inside a fenced code block: a file ABOUT himmel ─────────────
# (the HIMMEL-3333 RED: today's code stripped the fence's contents, rc 0)
printf '# notes\n\nthe installer appends:\n\n```markdown\n%s\n## Working principles\n- think first\n%s\n```\n\nthat is all.\n' "$B" "$E" > "$td/fenced.md"
cp "$td/fenced.md" "$td/fenced.before"; run "$td/fenced.md"
check "fenced-only: rc 0" "$rc" 0
same  "fenced-only: a file about himmel is left byte-identical" "$td/fenced.md" "$td/fenced.before"
has   "fenced-only: reads as not wired" "nothing to strip" "$out"
gone  "fenced-only: no backup" "$td/fenced.md.himmel-uninstall-backup"
bash "$uw" --probe "$td/fenced.md" >/dev/null 2>&1; check "fenced-only: probe agrees (0)" "$?" 0
# tilde fence, indented up to 3 spaces, longer closing run
printf 'a\n  ~~~\n%s\n%s\n  ~~~~\nb\n' "$B" "$E" > "$td/fenced-tilde.md"; cp "$td/fenced-tilde.md" "$td/fenced-tilde.before"
run "$td/fenced-tilde.md"; check "fenced-tilde: rc 0" "$rc" 0; same "fenced-tilde: byte-identical" "$td/fenced-tilde.md" "$td/fenced-tilde.before"
# a ``` inside a ~~~ fence does not close it
printf 'a\n~~~\n```\n%s\n%s\n~~~\nb\n' "$B" "$E" > "$td/fenced-mixed.md"; cp "$td/fenced-mixed.md" "$td/fenced-mixed.before"
run "$td/fenced-mixed.md"; check "fenced-mixed: rc 0" "$rc" 0; same "fenced-mixed: byte-identical" "$td/fenced-mixed.md" "$td/fenced-mixed.before"
# inline code at line start is not a fence opener (info string may not hold a backtick)
printf 'see ```x``` here\n\n%s\n' "$BLOCK" > "$td/inline-code.md"; run "$td/inline-code.md"
check "inline-code: rc 0" "$rc" 0; check "inline-code: block stripped, prose kept" "$(cat "$td/inline-code.md")" 'see ```x``` here'
# fenced copy PLUS the real block: the real one goes, the quoted one is untouched
printf 'docs:\n\n```\n%s\n%s\n```\n\n%s\nafter\n' "$B" "$E" "$BLOCK" > "$td/fenced-plus-real.md"
printf 'docs:\n\n```\n%s\n%s\n```\nafter\n' "$B" "$E" > "$td/fenced-plus-real.expect"
run "$td/fenced-plus-real.md"; check "fenced-plus-real: rc 0" "$rc" 0
same "fenced-plus-real: quoted copy intact, real block gone" "$td/fenced-plus-real.md" "$td/fenced-plus-real.expect"
bash "$uw" --probe "$td/fenced-plus-real.md" >/dev/null 2>&1; check "fenced-plus-real: probe reads the result as clean" "$?" 0
# A complete, unfenced block ABOVE an unrelated fence that never closes: the
# markers sit outside the open fence, so they are unambiguous and the block is
# stripped; only markers UNDER the unclosed fence are refused (HIMMEL-3335).
printf 'mine\n\n%s\n\n```sh\nnever closed\n' "$BLOCK" > "$td/valid-block-then-open.md"
cp "$td/valid-block-then-open.md" "$td/valid-block-then-open.before"
printf 'mine\n\n```sh\nnever closed\n' > "$td/valid-block-then-open.expect"
run "$td/valid-block-then-open.md"; check "valid-block-then-open: rc 0" "$rc" 0
same "valid-block-then-open: block stripped, open fence kept" "$td/valid-block-then-open.md" "$td/valid-block-then-open.expect"
same "valid-block-then-open: backup is the file as found" "$td/valid-block-then-open.md.himmel-uninstall-backup" "$td/valid-block-then-open.before"
bash "$uw" --probe "$td/valid-block-then-open.md" >/dev/null 2>&1; check "valid-block-then-open: probe 0 after" "$?" 0
# A balanced quote followed by an unrelated fence that never closes: the quoted
# markers belong to the CLOSED fence, so this is neither wired nor ambiguous.
printf 'docs:\n\n```\n%s\n%s\n```\n\n```sh\necho never closed\n' "$B" "$E" > "$td/fenced-then-open.md"
cp "$td/fenced-then-open.md" "$td/fenced-then-open.before"
run "$td/fenced-then-open.md"; check "fenced-then-open: rc 0" "$rc" 0
has "fenced-then-open: nothing to strip" "nothing to strip" "$out"
same "fenced-then-open: byte-identical" "$td/fenced-then-open.md" "$td/fenced-then-open.before"
gone "fenced-then-open: no backup" "$td/fenced-then-open.md.himmel-uninstall-backup"
bash "$uw" --probe "$td/fenced-then-open.md" >/dev/null 2>&1; check "fenced-then-open: probe 0" "$?" 0

# ── file absent / unreadable / symlink ──────────────────────────────────────
run "$td/absent/CLAUDE.md"; check "absent: rc 0" "$rc" 0; has "absent: says so" "nothing to strip" "$out"
gone "absent: nothing created" "$td/absent"
bash "$uw" --probe "$td/absent/CLAUDE.md"; check "absent: probe 0" "$?" 0
printf 'mine\n\n%s\n' "$BLOCK" > "$td/unreadable.md"; cp "$td/unreadable.md" "$td/unreadable.before"; chmod 000 "$td/unreadable.md"
if [ -r "$td/unreadable.md" ]; then echo "SKIP - unreadable: chmod 000 is still readable here (root); case not exercised"
else
  for dry in 0 1; do run "$td/unreadable.md" "$dry"; check "unreadable (dry=$dry): rc 1" "$rc" 1; has "unreadable (dry=$dry): says cannot read" "cannot read" "$out"; done
  bash "$uw" --probe "$td/unreadable.md" 2>/dev/null; check "unreadable: probe 1" "$?" 1
  chmod 644 "$td/unreadable.md"; same "unreadable: byte-identical" "$td/unreadable.md" "$td/unreadable.before"
  gone "unreadable: no backup" "$td/unreadable.md.himmel-uninstall-backup"
fi
chmod 644 "$td/unreadable.md"
# symlink: the link survives, its target is written through, the backup sits
# beside the LINK path (that is the path the operator knows)
mkdir -p "$td/dots"; printf 'mine\n\n%s\n' "$BLOCK" > "$td/dots/CLAUDE.md"; cp "$td/dots/CLAUDE.md" "$td/symlink.before"
ln -s "$td/dots/CLAUDE.md" "$td/symlink.md"; run "$td/symlink.md"
check "symlink: rc 0" "$rc" 0
[ -L "$td/symlink.md" ] && ok "symlink: link preserved" || bad "symlink: link replaced by a file"
check "symlink: target stripped exactly" "$(cat "$td/dots/CLAUDE.md")" mine
same  "symlink: backup beside the link is the file as found" "$td/symlink.md.himmel-uninstall-backup" "$td/symlink.before"
# a symlink already AT THE BACKUP PATH: cp would follow it and overwrite its
# target, so the strip is refused and both files are left as found.
printf 'mine\n\n%s\n' "$BLOCK" > "$td/bk-symlink.md"; cp "$td/bk-symlink.md" "$td/bk-symlink.before"
printf 'unrelated sentinel\n' > "$td/bk-sentinel"; ln -s "$td/bk-sentinel" "$td/bk-symlink.md.himmel-uninstall-backup"
run "$td/bk-symlink.md"
check "backup-symlink: rc 1" "$rc" 1
has   "backup-symlink: names the backup path" "bk-symlink.md.himmel-uninstall-backup" "$out"
has   "backup-symlink: says untouched" "left untouched" "$out"
same  "backup-symlink: file byte-identical" "$td/bk-symlink.md" "$td/bk-symlink.before"
check "backup-symlink: symlink target untouched" "$(cat "$td/bk-sentinel")" "unrelated sentinel"
[ -L "$td/bk-symlink.md.himmel-uninstall-backup" ] && ok "backup-symlink: the planted link is kept" || bad "backup-symlink: link removed or replaced"
# a directory at the backup path is refused the same way
printf 'mine\n\n%s\n' "$BLOCK" > "$td/bk-dir.md"; cp "$td/bk-dir.md" "$td/bk-dir.before"; mkdir "$td/bk-dir.md.himmel-uninstall-backup"
run "$td/bk-dir.md"
check "backup-dir: rc 1" "$rc" 1
same  "backup-dir: file byte-identical" "$td/bk-dir.md" "$td/bk-dir.before"
[ -d "$td/bk-dir.md.himmel-uninstall-backup" ] && ok "backup-dir: directory kept" || bad "backup-dir: directory gone"
# a HARD-LINKED regular file at the backup path passes -f, but cp would write
# through the shared inode and overwrite the link's twin: refused, both kept
# (HIMMEL-3341). Control: the plain regular-file case below is still replaced.
printf 'mine\n\n%s\n' "$BLOCK" > "$td/bk-hardlink.md"; cp "$td/bk-hardlink.md" "$td/bk-hardlink.before"
printf 'twin sentinel\n' > "$td/bk-twin"; ln "$td/bk-twin" "$td/bk-hardlink.md.himmel-uninstall-backup"
run "$td/bk-hardlink.md"
check "backup-hardlink: rc 1" "$rc" 1
has   "backup-hardlink: names the backup path" "bk-hardlink.md.himmel-uninstall-backup" "$out"
has   "backup-hardlink: says hard link" "hard link" "$out"
has   "backup-hardlink: says untouched" "left untouched" "$out"
same  "backup-hardlink: file byte-identical" "$td/bk-hardlink.md" "$td/bk-hardlink.before"
check "backup-hardlink: twin untouched" "$(cat "$td/bk-twin")" "twin sentinel"
check "backup-hardlink: planted link still the twin" "$(cat "$td/bk-hardlink.md.himmel-uninstall-backup")" "twin sentinel"
[ "$td/bk-twin" -ef "$td/bk-hardlink.md.himmel-uninstall-backup" ] && ok "backup-hardlink: link count intact (same inode)" || bad "backup-hardlink: link broken or replaced"
bash "$uw" --probe "$td/bk-hardlink.md" >/dev/null 2>&1; check "backup-hardlink: probe 3 (still wired)" "$?" 3
# a REGULAR file at the backup path (a previous run's backup) is replaced
printf 'mine\n\n%s\n' "$BLOCK" > "$td/bk-file.md"; cp "$td/bk-file.md" "$td/bk-file.before"; printf 'older backup\n' > "$td/bk-file.md.himmel-uninstall-backup"
run "$td/bk-file.md"
check "backup-file: rc 0" "$rc" 0
same  "backup-file: backup is now the file as found" "$td/bk-file.md.himmel-uninstall-backup" "$td/bk-file.before"
check "backup-file: stripped" "$(cat "$td/bk-file.md")" mine
# a symlinked file that held only the block is emptied, never unlinked
printf '%s\n' "$BLOCK" > "$td/dots/AGENTS.md"; ln -s "$td/dots/AGENTS.md" "$td/symlink-only.md"; run "$td/symlink-only.md"
check "symlink-only: rc 0" "$rc" 0
[ -L "$td/symlink-only.md" ] && ok "symlink-only: link never deleted" || bad "symlink-only: link gone"
check "symlink-only: target emptied" "$(wc -c < "$td/dots/AGENTS.md")" 0

# ── idempotent + dry-run ────────────────────────────────────────────────────
f="$td/twice.md"; printf 'top\n\n%s\nbottom\n' "$BLOCK" > "$f"; cp "$f" "$td/twice.before"
run "$f"; check "twice: first run rc 0" "$rc" 0
cp "$f" "$td/twice.after1"
run "$f"; check "twice: second run rc 0" "$rc" 0; has "twice: second run is a no-op" "nothing to strip" "$out"
same "twice: file unchanged by the second run" "$f" "$td/twice.after1"
same "twice: backup still the ORIGINAL (not re-taken from the stripped file)" "$f.himmel-uninstall-backup" "$td/twice.before"
f="$td/dry.md"; printf 'top\n\n%s\nbottom\n' "$BLOCK" > "$f"; cp "$f" "$td/dry.before"
run "$f" 1; check "dry: rc 0" "$rc" 0; has "dry: previews" "DRY: would strip himmel working-principles block from $f" "$out"
has "dry: names the backup" "$f.himmel-uninstall-backup" "$out"
same "dry: file untouched" "$f" "$td/dry.before"; gone "dry: no backup written" "$f.himmel-uninstall-backup"

# ── --probe on the plain shapes ─────────────────────────────────────────────
printf 'top\n\n%s\nbottom\n' "$BLOCK" > "$td/probe.md"
bash "$uw" --probe "$td/probe.md"; check "probe: intact block -> 3" "$?" 3
printf 'top\n%s\n' "$E" > "$td/probe-frag.md"
bash "$uw" --probe "$td/probe-frag.md"; check "probe: lone END fragment -> 3" "$?" 3
printf 'top\n' > "$td/probe-none.md"
bash "$uw" --probe "$td/probe-none.md"; check "probe: no marker -> 0" "$?" 0
bash "$uw" --probe >/dev/null 2>&1; check "probe: missing path -> usage 2" "$?" 2
bash "$uw" >/dev/null 2>&1; check "no args -> usage 2" "$?" 2

# nothing escapes the scratch dir
check "hermetic: no temp files left by the helper" "$(find "$TMPDIR" -type f | wc -l)" 0

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILURE(S)"; exit 1; fi
