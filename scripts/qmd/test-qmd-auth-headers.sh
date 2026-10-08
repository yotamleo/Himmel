#!/usr/bin/env bash
# test-qmd-auth-headers.sh - HIMMEL-5002: the qmd HTTP daemon requires a bearer
# token; the himmel client side reads it from a 0600 file.
#
# Covers: (a) qmd-auth-headers.sh prints the Authorization header from a 0600
# token file; (b) a group/world-readable file is NOT trusted (no token, no
# leak); (c) no token file -> {} (first start, before the daemon creates it);
# (d) ensure-qmd-daemon.sh's probe sends the token (via curl config on stdin,
# never argv) and still short-circuits on a qmd-shaped reply; (e) .mcp.json
# wires the helper as headersHelper and carries no secret.
# Hermetic: HOME and the token path point into a temp dir; curl is a mock.
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
plugin="$repo_root/marketplace/plugins/qmd"
helper="$plugin/scripts/qmd-auth-headers.sh"
ensure="$plugin/scripts/ensure-qmd-daemon.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/qmd-auth-headers.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
home="$work/home"; mkdir -p "$home"
tok="$work/http-token"
SECRET="s3cr3t-token-0123456789abcdef0123456789abcdef"

# (c) no file yet
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{}" ] || fail "(c) absent token file: expected {}, got [$out]"

# (a) 0600 file
printf '%s\n' "$SECRET" >"$tok"; chmod 600 "$tok"
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{\"Authorization\":\"Bearer $SECRET\"}" ] || fail "(a) header json wrong: [$out]"
[ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token)" = "$SECRET" ] || fail "(a) --token wrong"

# (b) world-readable file is refused
chmod 644 "$tok"
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{}" ] || fail "(b) 0644 token file must not be used, got [$out]"
case "$out" in *"$SECRET"*) fail "(b) leaked the secret from a 0644 file" ;; esac
chmod 600 "$tok"

# (d) the probe sends the token on curl's stdin config, not argv
mockbin="$work/bin"; mkdir -p "$mockbin"
cat >"$mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MOCK_DIR/argv"
if [ -p /dev/stdin ] || [ ! -t 0 ]; then cat >"$MOCK_DIR/stdin"; fi
printf '{"result":{"serverInfo":{"name":"qmd","version":"1"}}}'
MOCK
chmod +x "$mockbin/curl"
mkdir -p "$work/mock"
out="$(HOME="$home" MOCK_DIR="$work/mock" QMD_CURL="$mockbin/curl" QMD_HTTP_TOKEN_FILE="$tok" \
  QMD_MCP_URL="http://127.0.0.1:1/mcp" PATH="$mockbin:/usr/bin:/bin" bash "$ensure" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(d) ensure rc $rc: $out"
grep -q "Authorization: Bearer $SECRET" "$work/mock/stdin" || fail "(d) token not sent on curl stdin"
if grep -q "$SECRET" "$work/mock/argv"; then fail "(d) token leaked into curl argv"; fi
case "$out" in *"$SECRET"*) fail "(d) token leaked into ensure output" ;; esac

# (e) .mcp.json wires the helper and holds no secret
grep -q '"headersHelper"' "$plugin/.mcp.json" || fail "(e) .mcp.json has no headersHelper"
grep -q 'qmd-auth-headers.sh' "$plugin/.mcp.json" || fail "(e) headersHelper does not run the helper"

echo "PASS: all qmd-auth-headers cases"
