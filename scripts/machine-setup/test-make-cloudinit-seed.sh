#!/usr/bin/env bash
# Smoke test for scripts/machine-setup/make-cloudinit-seed.py (HIMMEL-2512):
# --dry-run must emit user-data containing the user, pubkey, and package
# list, while NEVER leaking the plaintext password (or its hash) it was
# given; the openssl-fallback subprocess env is scrubbed of secrets; blank
# passwords, embedded-newline passwords, malformed/empty-payload hashes,
# and an empty/malformed --pubkey are all rejected (rc=2); ssh_pwauth
# defaults off and only --allow-password-ssh flips it; user-controlled
# scalars (hostname etc.) are JSON/YAML-quoted so a stray colon/quote
# cannot restructure the document; a CRLF password file derives the same
# plaintext as an LF one; and the written seed (and _open_private's target
# generally) always ends up mode 0600. Hermetic — never writes an ISO via
# --dry-run, never needs pycdlib or python-dotenv installed for most rows
# (--user/--pubkey are passed explicitly so no .env lookup fires); the
# PyYAML-based parse assertion and the real ISO-write permissions row run
# only when PyYAML / pycdlib happen to be importable, else print a SKIP line.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a test
# fixture needs no .ps1 twin (WS5 T15 convention).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/make-cloudinit-seed.py"

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cloudinit-seed.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected output to contain '$needle'"
        FAILED=$((FAILED + 1))
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "FAIL $label — output leaked '$needle'"
        FAILED=$((FAILED + 1))
    else
        echo "PASS $label"
    fi
}

PUBKEY_FILE="$TMP/id_ed25519.pub"
echo "ssh-ed25519 AAAAFAKEKEYFIXTURE test@example" > "$PUBKEY_FILE"

PLAIN_PASSWORD="S3cr3t-plaintext-marker"

# T0: the openssl fallback's subprocess env is scrubbed of anything
# password/secret/token/key/credential/auth-shaped (and explicitly
# ubuntu_vm_pass), PATH kept.
SCRUB_OK=$(FAKE_SECRET_TOKEN=leak ubuntu_vm_pass=leak FAKE_API_KEY=leak FAKE_CREDENTIAL=leak FAKE_AUTH=leak python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('seed', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
env = m._scrubbed_env()
assert 'ubuntu_vm_pass' not in env
assert 'FAKE_SECRET_TOKEN' not in env
assert 'FAKE_API_KEY' not in env
assert 'FAKE_CREDENTIAL' not in env
assert 'FAKE_AUTH' not in env
assert 'PATH' in env
print('scrub-ok')
" 2>&1)
assert_contains "openssl subprocess env is scrubbed of secrets, keeps PATH" "$SCRUB_OK" "scrub-ok"

# T1: plaintext supplied via env (ubuntu_vm_pass) — no --password argv flag
# exists at all (finding 1: argv leaks via shell history + ps).
OUT=$(ubuntu_vm_pass="$PLAIN_PASSWORD" python3 "$SCRIPT" \
    --user himmeltest \
    --pubkey "$PUBKEY_FILE" \
    --hostname test-vm \
    --instance-id test-vm-001 \
    --dry-run 2>/dev/null)
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "FAIL script exited $RC (env-password run)"
    FAILED=$((FAILED + 1))
fi

assert_contains "user-data contains the user" "$OUT" 'name: "himmeltest"'
assert_contains "user-data contains the pubkey" "$OUT" \
    '"ssh-ed25519 AAAAFAKEKEYFIXTURE test@example"'
assert_contains "user-data contains the package list" "$OUT" \
    "packages: [git, jq, curl, rsync, openssh-server]"
assert_not_contains "env-password run never leaks the plaintext password" "$OUT" "$PLAIN_PASSWORD"
assert_contains "ssh_pwauth defaults to false" "$OUT" "ssh_pwauth: false"

# T2: plaintext supplied via --password-file (finding 1's other source).
PW_FILE="$TMP/pw.txt"
printf '%s\n' "$PLAIN_PASSWORD" > "$PW_FILE"
OUT2=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-file "$PW_FILE" \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>/dev/null)
RC2=$?

if [ "$RC2" -ne 0 ]; then
    echo "FAIL script exited $RC2 (password-file run)"
    FAILED=$((FAILED + 1))
fi
assert_not_contains "password-file run never leaks the plaintext password" "$OUT2" "$PLAIN_PASSWORD"

# T2b: an empty (or whitespace-only) --password-file is rejected with rc=2
# instead of being hashed and used to provision a blank console password.
EMPTY_PW_FILE="$TMP/empty-pw.txt"
printf '\n' > "$EMPTY_PW_FILE"
OUT2B=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-file "$EMPTY_PW_FILE" \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC2B=$?
if [ "$RC2B" -eq 2 ]; then
    echo "PASS empty --password-file rejected with rc=2"
else
    echo "FAIL empty --password-file exited $RC2B (expected 2) — output: $OUT2B"
    FAILED=$((FAILED + 1))
fi

# T3: --allow-password-ssh flips ssh_pwauth on (finding 2).
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT3=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$fakehash$abc' \
    --pubkey "$PUBKEY_FILE" \
    --allow-password-ssh \
    --dry-run 2>/dev/null)
assert_contains "--allow-password-ssh enables ssh_pwauth" "$OUT3" "ssh_pwauth: true"

# T4: a hostname with a colon and a quote stays a single valid YAML/JSON-
# quoted scalar (finding 3) — never breaks the document structure.
HOSTNAME_TRICKY='evil: "host"'
EXPECTED_HOSTNAME_LINE=$(python3 -c 'import json,sys; print("hostname: " + json.dumps(sys.argv[1]))' "$HOSTNAME_TRICKY")
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT4=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$fakehash$abc' \
    --pubkey "$PUBKEY_FILE" \
    --hostname "$HOSTNAME_TRICKY" \
    --dry-run 2>/dev/null)
assert_contains "tricky hostname stays one JSON/YAML-quoted scalar" "$OUT4" "$EXPECTED_HOSTNAME_LINE"

# T5: a bogus --password-hash (whitespace/quotes, not a crypt(3) shape) is
# rejected with rc=2 (finding 2) — never reaches the YAML interpolation.
OUT5=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash 'x"y' \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC5=$?
if [ "$RC5" -eq 2 ]; then
    echo "PASS bogus --password-hash rejected with rc=2"
else
    echo "FAIL bogus --password-hash exited $RC5 (expected 2) — output: $OUT5"
    FAILED=$((FAILED + 1))
fi

# T6: a well-shaped --password-hash validates and the run still succeeds;
# --dry-run's passwd line stays the redaction marker either way (the hash
# itself is only ever quoted in the real, non-dry-run user-data).
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT6=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$salt$abcDEF123' \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>/dev/null)
RC6=$?
if [ "$RC6" -ne 0 ]; then
    echo "FAIL script exited $RC6 (valid --password-hash run)"
    FAILED=$((FAILED + 1))
fi
assert_contains "valid --password-hash still redacts the passwd line in --dry-run" \
    "$OUT6" 'passwd: "***REDACTED***"'

# T6b: the same valid hash, rendered non-redacted (the real write_iso path),
# comes out as exactly one JSON/YAML-quoted scalar via build_user_data().
QUOTED_HASH_LINE=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('seed', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
data = m.build_user_data('himmeltest', '\$6\$salt\$abcDEF123', 'k', 'h', 'i', redact=False)
print([l for l in data.splitlines() if l.strip().startswith('passwd:')][0].strip())
")
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
assert_contains "valid hash round-trips as one quoted scalar (non-redacted path)" \
    "$QUOTED_HASH_LINE" 'passwd: "$6$salt$abcDEF123"'

# T7: --password-hash '$6$' (empty salt AND hash) is rejected with rc=2 —
# the regex now requires non-empty salt/hash segments, not just a shape.
# shellcheck disable=SC2016  # a literal (bogus) crypt(3)-shaped string, no expansion intended
OUT7=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$' \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC7=$?
if [ "$RC7" -eq 2 ]; then
    echo "PASS empty-payload --password-hash '\$6\$' rejected with rc=2"
else
    echo "FAIL empty-payload --password-hash exited $RC7 (expected 2) — output: $OUT7"
    FAILED=$((FAILED + 1))
fi

# T7b: a real $6$salt$hash (and the $rounds=N form) still validates.
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT7B=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$salt$hash' \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC7B=$?
if [ "$RC7B" -eq 0 ]; then
    echo "PASS real \$6\$salt\$hash still accepted"
else
    echo "FAIL real \$6\$salt\$hash exited $RC7B (expected 0) — output: $OUT7B"
    FAILED=$((FAILED + 1))
fi
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT7C=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$rounds=5000$salt$hash' \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC7C=$?
if [ "$RC7C" -eq 0 ]; then
    echo "PASS \$rounds=N\$ hash form still accepted"
else
    echo "FAIL \$rounds=N\$ hash form exited $RC7C (expected 0) — output: $OUT7C"
    FAILED=$((FAILED + 1))
fi

# T8: a CRLF password file yields the exact same derived plaintext as an
# LF one (only one trailing newline sequence stripped, not a general
# rstrip — a password ending in a real space also survives).
CRLF_LF_OK=$(python3 -c "
import importlib.util, tempfile, os
spec = importlib.util.spec_from_file_location('seed', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = tempfile.mkdtemp()
lf = os.path.join(d, 'lf.txt')
crlf = os.path.join(d, 'crlf.txt')
with open(lf, 'w', newline='') as f:
    f.write('MyPass123\n')
with open(crlf, 'w', newline='') as f:
    f.write('MyPass123\r\n')
a = m._read_password_file(lf)
b = m._read_password_file(crlf)
assert a == b == 'MyPass123', (a, b)
trailing_space = os.path.join(d, 'ts.txt')
with open(trailing_space, 'w', newline='') as f:
    f.write('pass \n')
c = m._read_password_file(trailing_space)
assert c == 'pass ', repr(c)
print('crlf-lf-ok')
" 2>&1)
assert_contains "CRLF and LF password files derive identical plaintext; trailing space survives" \
    "$CRLF_LF_OK" "crlf-lf-ok"

# T9: an empty --pubkey file is rejected with rc=2 — an unreachable
# key-only guest is a real bug, not a warning.
EMPTY_PUBKEY="$TMP/empty.pub"
: > "$EMPTY_PUBKEY"
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT9=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$salt$hash' \
    --pubkey "$EMPTY_PUBKEY" \
    --dry-run 2>&1)
RC9=$?
if [ "$RC9" -eq 2 ]; then
    echo "PASS empty --pubkey file rejected with rc=2"
else
    echo "FAIL empty --pubkey file exited $RC9 (expected 2) — output: $OUT9"
    FAILED=$((FAILED + 1))
fi

# T9b: a garbage (non-key-shaped) --pubkey line is rejected with rc=2.
GARBAGE_PUBKEY="$TMP/garbage.pub"
printf 'this is not a key\n' > "$GARBAGE_PUBKEY"
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT9B=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$salt$hash' \
    --pubkey "$GARBAGE_PUBKEY" \
    --dry-run 2>&1)
RC9B=$?
if [ "$RC9B" -eq 2 ]; then
    echo "PASS garbage --pubkey line rejected with rc=2"
else
    echo "FAIL garbage --pubkey line exited $RC9B (expected 2) — output: $OUT9B"
    FAILED=$((FAILED + 1))
fi

# T9c: a valid "ssh-ed25519 AAAA... comment" line is still accepted (fixed
# fake base64 payload — no real key material) and lands in the output.
VALID_PUBKEY_LINE="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakePayloadNoRealKey comment@host"
VALID_PUBKEY="$TMP/valid.pub"
printf '%s\n' "$VALID_PUBKEY_LINE" > "$VALID_PUBKEY"
# shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
OUT9C=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-hash '$6$salt$hash' \
    --pubkey "$VALID_PUBKEY" \
    --dry-run 2>/dev/null)
assert_contains "a valid ssh-ed25519 pubkey line is still accepted" "$OUT9C" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$VALID_PUBKEY_LINE")"

# T10: a --password-file with an embedded newline ("a\nb\n") is rejected
# with rc=2 — it would hash differently via openssl -stdin (first line
# only) than via stdlib crypt (whole string), and was never intended.
EMBEDDED_NL_FILE="$TMP/embedded-nl.txt"
printf 'a\nb\n' > "$EMBEDDED_NL_FILE"
OUT10=$(python3 "$SCRIPT" \
    --user himmeltest \
    --password-file "$EMBEDDED_NL_FILE" \
    --pubkey "$PUBKEY_FILE" \
    --dry-run 2>&1)
RC10=$?
if [ "$RC10" -eq 2 ]; then
    echo "PASS password file with an embedded newline rejected with rc=2"
else
    echo "FAIL password file with an embedded newline exited $RC10 (expected 2) — output: $OUT10"
    FAILED=$((FAILED + 1))
fi

if python3 -c 'import yaml' >/dev/null 2>&1; then
    PARSE_OK=$(printf '%s' "$OUT4" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin.read())
assert data['hostname'] == sys.argv[1], f'hostname mismatch: {data[\"hostname\"]!r}'
print('yaml-parse-ok')
" "$HOSTNAME_TRICKY" 2>&1)
    if [ "$PARSE_OK" = "yaml-parse-ok" ]; then
        echo "PASS tricky hostname parses back correctly as YAML"
    else
        echo "FAIL tricky hostname failed to round-trip through PyYAML: $PARSE_OK"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP PyYAML not installed — textual assertion above stands alone"
fi

# No ISO must have been written anywhere under TMP in --dry-run mode.
if find "$TMP" -name '*.iso' | grep -q .; then
    echo "FAIL --dry-run wrote an ISO file"
    FAILED=$((FAILED + 1))
else
    echo "PASS --dry-run wrote no ISO file"
fi

# T-open-private: _open_private() fchmods an EXISTING 0644 file down to
# 0600 — os.open()'s mode argument alone only applies at creation, so this
# runs unconditionally on POSIX hosts and SKIPs on Windows (POSIX mode bits
# are advisory there; NTFS ACLs govern).
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*)
    echo "SKIP T-open-private: POSIX mode bits are advisory on Windows (NTFS ACLs govern)"
    ;;
  *)
    OPEN_PRIVATE_OK=$(python3 -c "
import importlib.util, os, stat, tempfile
spec = importlib.util.spec_from_file_location('seed', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = tempfile.mkdtemp()
p = os.path.join(d, 'preexisting.iso')
open(p, 'w').close()
os.chmod(p, 0o644)
fd = m._open_private(p)
os.close(fd)
mode = stat.S_IMODE(os.stat(p).st_mode)
assert mode == 0o600, oct(mode)
print('open-private-ok')
" 2>&1)
    assert_contains "_open_private() fchmods a pre-existing 0644 file to 0600" \
        "$OPEN_PRIVATE_OK" "open-private-ok"
    ;;
esac

# T-open-private-symlink: a pre-existing symlink at the out path must NOT be
# followed — without O_NOFOLLOW, _open_private() would truncate, chmod and
# overwrite whatever the symlink points at. SKIPs on Windows (O_NOFOLLOW
# does not exist there).
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*)
    echo "SKIP T-open-private-symlink: O_NOFOLLOW does not exist on Windows"
    ;;
  *)
    OPEN_PRIVATE_SYMLINK_OK=$(python3 -c "
import importlib.util, os, stat, tempfile
spec = importlib.util.spec_from_file_location('seed', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = tempfile.mkdtemp()
victim = os.path.join(d, 'victim')
link = os.path.join(d, 'link')
with open(victim, 'wb') as f:
    f.write(b'keep me')
os.chmod(victim, 0o644)
os.symlink(victim, link)
raised = False
try:
    m._open_private(link)
except OSError:
    raised = True
assert raised, 'expected OSError for pre-existing symlink'
with open(victim, 'rb') as f:
    assert f.read() == b'keep me'
mode = stat.S_IMODE(os.stat(victim).st_mode)
assert mode == 0o644, oct(mode)
print('open-private-symlink-ok')
" 2>&1)
    assert_contains "_open_private() refuses a pre-existing symlink and leaves its target untouched" \
        "$OPEN_PRIVATE_SYMLINK_OK" "open-private-symlink-ok"
    ;;
esac

# T-iso-perms: the written ISO embeds an offline-crackable password hash, so
# it must land mode 0600, never umask-default — even when the out path
# already existed with looser permissions. Only runs if pycdlib happens to
# be importable (it's a real write, not --dry-run); skips cleanly if not.
# Also SKIPs on Windows (POSIX mode bits are advisory there; NTFS ACLs
# govern).
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*)
    echo "SKIP T-iso-perms: POSIX mode bits are advisory on Windows (NTFS ACLs govern)"
    ;;
  *)
    if python3 -c 'import pycdlib' >/dev/null 2>&1; then
        ISO_OUT="$TMP/iso-perms-test/cidata.iso"
        mkdir -p "$(dirname "$ISO_OUT")"
        : > "$ISO_OUT"
        chmod 644 "$ISO_OUT"
        RC_ISO=0
        # shellcheck disable=SC2016  # a literal crypt(3) hash, no expansion intended
        python3 "$SCRIPT" \
            --user himmeltest \
            --password-hash '$6$salt$abcDEF123' \
            --pubkey "$PUBKEY_FILE" \
            --out "$ISO_OUT" >/dev/null 2>&1 || RC_ISO=$?
        if [ "$RC_ISO" -ne 0 ]; then
            echo "FAIL writing the ISO exited $RC_ISO"
            FAILED=$((FAILED + 1))
        elif [ ! -f "$ISO_OUT" ]; then
            echo "FAIL ISO was not written to $ISO_OUT"
            FAILED=$((FAILED + 1))
        else
            PERMS=$(stat -c %a "$ISO_OUT" 2>/dev/null || stat -f %Lp "$ISO_OUT")
            if [ "$PERMS" = "600" ]; then
                echo "PASS written ISO is mode 0600 (even though the path pre-existed 0644)"
            else
                echo "FAIL written ISO is mode $PERMS, expected 600"
                FAILED=$((FAILED + 1))
            fi
        fi
    else
        echo "SKIP pycdlib not installed — cannot exercise the real ISO-write path"
    fi
    ;;
esac

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILED"
    exit 1
fi
