#!/usr/bin/env bash
# shellcheck disable=SC2016 # single quotes below are deliberate: $1/$2 are
# the sub-shell's OWN positional args (via `-c '...' _ "$LIBF" ...`), not
# this script's — double-quoting would expand the wrong scope's variables.
# scripts/lib/test-sha256-bin.sh — tests for scripts/lib/sha256-bin.sh
# (HIMMEL-3177). Hermetic: every PATH is a stub dir.
#
#   T1  sha256sum present -> resolved, sha256_hex hashes a file AND stdin
#   T2  only shasum (the stock-macOS shape) -> "shasum -a 256" resolved,
#       sha256_hex still returns the bare hex digest
#   T3  neither sha256sum nor shasum -> empty, ONE stderr note, sha256_hex
#       fails (rc != 0) instead of hashing anything
#   T4  sourcing under set -u with an empty PATH does not error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBF="$SCRIPT_DIR/sha256-bin.sh"
BASH_BIN="$(command -v bash)"   # absolute: the stub PATHs below hold no bash
KNOWN_HEX="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"  # sha256("abc")

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-sha256-bin.XXXXXX")" || exit 1; trap 'rm -rf "$W"' EXIT

# stub_dir <name> [tool ...] — a dir holding symlinks to just <tool>s (found on
# the REAL path, resolved before PATH is replaced).
stub_dir() {
    local d="$W/$1" t p; shift
    mkdir -p "$d"
    for t in "$@"; do
        p="$(command -v "$t")" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}

# resolve <PATH> — print "<_SHA256_CMD>|<stderr>" from a fresh shell on that PATH.
resolve() {
    local p="$1" err
    err="$W/err.$$"
    PATH="$p" "$BASH_BIN" -c '. "$1"; printf "%s" "$_SHA256_CMD"' _ "$LIBF" 2>"$err"
    printf '|%s' "$(cat "$err")"
}

echo "[test-sha256-bin] T1 sha256sum present: resolved, hashes a file and stdin"
if command -v sha256sum >/dev/null 2>&1; then
    d1="$(stub_dir t1 sha256sum awk)"
    got="$(resolve "$d1")"
    eq "T1 resolved sha256sum" "${got%%|*}" "sha256sum"
    eq "T1 no stderr note when resolved" "${got#*|}" ""
    printf 'abc' > "$W/abc.txt"
    out="$(PATH="$d1" "$BASH_BIN" -c '. "$1"; sha256_hex "$2"' _ "$LIBF" "$W/abc.txt")"
    eq "T1 sha256_hex(file) is the bare hex digest" "$out" "$KNOWN_HEX"
    out="$(printf 'abc' | PATH="$d1" "$BASH_BIN" -c '. "$1"; sha256_hex' _ "$LIBF")"
    eq "T1 sha256_hex(stdin) is the bare hex digest" "$out" "$KNOWN_HEX"
else
    echo "  SKIP T1: no sha256sum on this host"
fi

echo "[test-sha256-bin] T2 only shasum (stock-macOS shape): resolved as 'shasum -a 256'"
if command -v shasum >/dev/null 2>&1; then
    d2="$(stub_dir t2 shasum awk)"
    got="$(resolve "$d2")"
    eq "T2 resolved shasum -a 256" "${got%%|*}" "shasum -a 256"
    printf 'abc' > "$W/abc2.txt"
    out="$(PATH="$d2" "$BASH_BIN" -c '. "$1"; sha256_hex "$2"' _ "$LIBF" "$W/abc2.txt")"
    eq "T2 sha256_hex(file) via shasum is the bare hex digest" "$out" "$KNOWN_HEX"
else
    echo "  SKIP T2: no shasum on this host"
fi

echo "[test-sha256-bin] T3 neither sha256sum nor shasum: empty, one note, sha256_hex fails closed"
d3="$(stub_dir t3 awk)"
got="$(resolve "$d3")"
eq "T3 _SHA256_CMD empty" "${got%%|*}" ""
case "${got#*|}" in *"no 'sha256sum'/'shasum'"*) ok "T3 stderr note names the miss" ;; *) bad "T3 note missing: [${got#*|}]" ;; esac
eq "T3 exactly one note line" "$(printf '%s\n' "${got#*|}" | grep -c .)" "1"
rc=0
out="$(PATH="$d3" "$BASH_BIN" -c '. "$1"; sha256_hex "$2"' _ "$LIBF" "$W/abc.txt" 2>/dev/null)" || rc=$?
eq "T3 sha256_hex fails closed (rc != 0)" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
eq "T3 sha256_hex prints nothing on failure" "$out" ""

echo "[test-sha256-bin] T4 sourcing under set -u with an empty PATH"
rc=0
out="$(PATH="$W/nonexistent" "$BASH_BIN" -c 'set -u; . "$1"; printf "[%s]" "$_SHA256_CMD"' _ "$LIBF" 2>/dev/null)" || rc=$?
eq "T4 rc 0" "$rc" "0"
eq "T4 empty" "$out" "[]"

echo "[test-sha256-bin] T5 hasher present but fails at runtime (missing file): sha256_hex fails closed, not a silent empty success"
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    d5="$(stub_dir t5 sha256sum shasum awk)"
    rc=0
    out="$(PATH="$d5" "$BASH_BIN" -c '. "$1"; sha256_hex "$2"' _ "$LIBF" "$W/does-not-exist.txt" 2>/dev/null)" || rc=$?
    eq "T5 sha256_hex fails closed on hasher error (rc != 0)" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
    eq "T5 sha256_hex prints nothing on hasher error" "$out" ""
else
    echo "  SKIP T5: neither sha256sum nor shasum on this host"
fi

echo "[test-sha256-bin] T6 GNU-style backslash-escaped output line: sha256_hex strips the leading backslash"
d6="$(stub_dir t6 awk)"
ln -sf "$BASH_BIN" "$d6/bash"
cat > "$d6/sha256sum" <<'STUB'
#!/usr/bin/env bash
printf '\\%s  file.txt\n' "$KNOWN_HEX_STUB"
STUB
chmod +x "$d6/sha256sum"
out="$(PATH="$d6" KNOWN_HEX_STUB="$KNOWN_HEX" "$BASH_BIN" -c '. "$1"; sha256_hex "$2"' _ "$LIBF" "$W/whatever" 2>/dev/null)"
eq "T6 sha256_hex strips the leading backslash from an escaped digest line" "$out" "$KNOWN_HEX"

echo "[test-sha256-bin] $pass passed, $fail failed"
[ "$fail" -eq 0 ]
