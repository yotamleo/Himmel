#!/usr/bin/env bash
# HIMMEL-4013: every script that execs `claude` applies a profile-derived
# --settings or carries a `launch-profile-ok: <reason>` marker.
# Platform: POSIX bash 3.2+, node.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCAN="$HERE/launch-site-scan.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# T1 (control): the scanner flags an unprofiled site and passes covered ones.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
printf '#!/usr/bin/env bash\nclaude --model x "hi"\n' > "$T/scripts/a.sh"
printf '#!/usr/bin/env bash\nclaude --settings "$S" --model x "hi"\n' > "$T/scripts/b.sh"
printf '#!/usr/bin/env bash\n# launch-profile-ok: probe\nclaude -p "hi"\n' > "$T/scripts/c.sh"
printf '#!/usr/bin/env bash\n# launch-profile-ok-file: probes\nclaude -p "a"\nclaude -p "b"\n' > "$T/scripts/d.sh"
out="$(node "$SCAN" "$T")"
case "$out" in *a.sh:2*) ok "T1 flags unprofiled site" ;; *) bad "T1 did not flag a.sh: $out" ;; esac
case "$out" in *b.sh*|*c.sh*|*d.sh*) bad "T1 flagged a covered site: $out" ;; *) ok "T1 covered sites pass" ;; esac

# T2: the real tree has no unprofiled launch site.
out="$(node "$SCAN" "$REPO")"
if [ -z "$out" ]; then ok "T2 every launch site applies a profile or is allowlisted"; else bad "T2 unprofiled launch sites:"; echo "$out"; fi

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
