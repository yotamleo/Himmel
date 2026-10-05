#!/usr/bin/env bash
# Suite for scripts/observability/install-grafana.sh (HIMMEL-4289): the Linux
# Prometheus + Grafana user-unit installer. Every external tool it drives —
# uname, systemctl, curl, sha256sum, bun, sleep — is a PATH stub, tar is real
# (a fixture tarball), and HOME/XDG point at a throwaway tree, so no case
# touches a real service manager, a real unit dir or the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-grafana.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
assert_contains() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $3" ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) fail "$1" "unexpected '$2' in: $3" ;; *) pass "$1" ;; esac
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/himmel-install-grafana-test.XXXXXX")" || exit 1
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT

# The real pins: the stub sha256sum answers with them for a good fixture, so the
# installer's own pin comparison is what the cases exercise.
PIN_PROM="$(sed -n 's/^PROM_SHA_AMD64="\(.*\)"/\1/p' "$SCRIPT")"
PIN_GRAF="$(sed -n 's/^GRAF_SHA_AMD64="\(.*\)"/\1/p' "$SCRIPT")"

# Fixture tarballs: one top dir, like the upstream releases.
FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX/p/prometheus-x" "$FIX/g/grafana-x/bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX/p/prometheus-x/prometheus"
printf '#!/bin/sh\nexit 0\n' > "$FIX/g/grafana-x/bin/grafana"
chmod +x "$FIX/p/prometheus-x/prometheus" "$FIX/g/grafana-x/bin/grafana"
tar -czf "$FIX/prometheus.tar.gz" -C "$FIX/p" prometheus-x
tar -czf "$FIX/grafana.tar.gz" -C "$FIX/g" grafana-x

# setup <uname-s> <good-checksums:1|0> <health:1|0>
setup() {
    local case_dir="$TMP_ROOT/$RANDOM$RANDOM"
    BIN="$case_dir/bin"; HOME_DIR="$case_dir/home"; LOG="$case_dir/calls.log"
    mkdir -p "$BIN" "$HOME_DIR"; : > "$LOG"
    cat > "$BIN/uname" <<EOF
#!/bin/sh
case "\$1" in -m) echo x86_64 ;; *) echo $1 ;; esac
EOF
    cat > "$BIN/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$LOG"
case "\$2" in is-enabled) [ "\${STUB_ENABLED:-1}" = 1 ] ;; esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/bun"
    # curl: a download (-o <file> <url>) copies the fixture; a health probe (-w) answers 200 or 000
    cat > "$BIN/curl" <<EOF
#!/bin/sh
out=""; url=""; w=0
while [ \$# -gt 0 ]; do
    case "\$1" in -o) out="\$2"; shift ;; -w) w=1; shift ;; http*) url="\$1" ;; esac
    shift
done
echo "curl \$url" >> "$LOG"
if [ -n "\$out" ] && [ "\$out" != /dev/null ]; then
    case "\$url" in
        *prometheus*) cp "$FIX/prometheus.tar.gz" "\$out" ;;
        *grafana*) cp "$FIX/grafana.tar.gz" "\$out" ;;
        *) exit 22 ;;
    esac
    exit 0
fi
[ "$3" = 1 ] && printf 200 || printf 000
EOF
    # sha256sum: the pinned hash for a good fixture, a bogus one otherwise
    cat > "$BIN/sha256sum" <<EOF
#!/bin/sh
case "\$1" in
    *prometheus*) h="$PIN_PROM" ;;
    *) h="$PIN_GRAF" ;;
esac
[ "$2" = 1 ] || h=0000000000000000000000000000000000000000000000000000000000000000
echo "\$h  \$1"
EOF
    chmod +x "$BIN"/*
}

run() {
    OUT="$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME HOME="$HOME_DIR" PATH="$BIN:${RUN_PATH:-/usr/bin:/bin}" bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
}

DATA_REL=".local/share/himmel/observability"
UNIT_REL=".config/systemd/user"

echo "case 1: install writes pinned trees, config, three units; telemetry off; alerts to cadence-alert"
setup Linux 1 1
run install
assert_eq "install rc" 0 "$RC"
D="$HOME_DIR/$DATA_REL"
prom_unit="$(cat "$HOME_DIR/$UNIT_REL/himmel-observability-prometheus.service" 2>/dev/null)"
graf_unit="$(cat "$HOME_DIR/$UNIT_REL/himmel-observability-grafana.service" 2>/dev/null)"
hook_unit="$(cat "$HOME_DIR/$UNIT_REL/himmel-observability-grafana-alert-hook.service" 2>/dev/null)"
assert_contains "prometheus loopback" "--web.listen-address=127.0.0.1:9090" "$prom_unit"
assert_contains "prometheus time retention" "--storage.tsdb.retention.time=30d" "$prom_unit"
assert_contains "prometheus size retention" "--storage.tsdb.retention.size=5GB" "$prom_unit"
assert_contains "grafana unit runs the pinned binary" "bin/grafana\" server" "$graf_unit"
assert_contains "grafana admin password from a file, not argv" "GF_SECURITY_ADMIN_PASSWORD__FILE=$D/admin-password" "$graf_unit"
assert_contains "hook unit runs the receiver under bun" "scripts/observability/grafana-cadence-hook.ts" "$hook_unit"
ini="$(cat "$D/grafana.ini" 2>/dev/null)"
assert_contains "analytics reporting off" "reporting_enabled = false" "$ini"
assert_contains "update check off" "check_for_updates = false" "$ini"
assert_contains "plugin update check off" "check_for_plugin_updates = false" "$ini"
assert_contains "grafana loopback" "http_addr = 127.0.0.1" "$ini"
cp_yaml="$(cat "$D/grafana-provisioning/alerting/contact-points.yaml" 2>/dev/null)"
assert_contains "contact point is the cadence webhook" "url: http://127.0.0.1:9878/alert" "$cp_yaml"
assert_not_contains "no telegram contact point" "telegram" "$(grep -v '^#' "$D/grafana-provisioning/alerting/contact-points.yaml" 2>/dev/null)"
assert_contains "policies route to the cadence contact point" "receiver: himmel-cadence-alert" "$(cat "$D/grafana-provisioning/alerting/policies.yaml" 2>/dev/null)"
assert_not_contains "policies no longer name telegram" "himmel-telegram" "$(cat "$D/grafana-provisioning/alerting/policies.yaml" 2>/dev/null)"
assert_not_contains "linux prometheus.yml has no windows_exporter job" "windows_exporter" "$(cat "$D/prometheus.yml" 2>/dev/null)"
assert_contains "prometheus.yml keeps the flow-exporter job" "job_name: flow-exporter" "$(cat "$D/prometheus.yml" 2>/dev/null)"
assert_eq "dashboard copied" "yes" "$([ -f "$D/dashboards/himmel-health.json" ] && echo yes || echo no)"
assert_contains "dashboard provider points at the copy" "path: $D/dashboards" "$(cat "$D/grafana-provisioning/dashboards/himmel-dashboards.yaml" 2>/dev/null)"
assert_eq "admin password is 0600" "600" "$(stat -c %a "$D/admin-password" 2>/dev/null)"
calls="$(cat "$LOG")"
assert_contains "daemon-reload" "systemctl --user daemon-reload" "$calls"
assert_contains "enable all three" "systemctl --user enable himmel-observability-prometheus.service himmel-observability-grafana.service himmel-observability-grafana-alert-hook.service" "$calls"
assert_contains "restart all three" "systemctl --user restart himmel-observability-prometheus.service" "$calls"

echo "case 2: a checksum mismatch aborts before anything is installed"
setup Linux 0 1
run install
assert_eq "mismatch rc" 1 "$RC"
assert_contains "mismatch named" "sha256 mismatch for prometheus" "$OUT"
assert_eq "no unit written" "no" "$([ -e "$HOME_DIR/$UNIT_REL/himmel-observability-prometheus.service" ] && echo yes || echo no)"
assert_eq "no tree unpacked" "no" "$([ -e "$HOME_DIR/$DATA_REL/prometheus-3.15.0" ] && echo yes || echo no)"
assert_not_contains "nothing enabled" "enable" "$(cat "$LOG")"

echo "case 3: services that never answer fail the install"
setup Linux 1 0
run install
assert_eq "unhealthy rc" 1 "$RC"
assert_contains "journal hint" "journalctl --user" "$OUT"

echo "case 4: status reports each unit and endpoint; any FAIL is rc 1"
setup Linux 1 1
run install
run status
assert_eq "status rc when all up" 0 "$RC"
assert_contains "grafana health reported" "OK   health  grafana" "$OUT"
STUB_ENABLED=0 run status
assert_eq "status rc when units unregistered" 1 "$RC"
assert_contains "unregistered unit reported" "FAIL service  himmel-observability-grafana.service not registered" "$OUT"
setup Linux 1 0
run status
assert_eq "status rc when nothing answers" 1 "$RC"
assert_contains "dead endpoint reported" "FAIL health  prometheus" "$OUT"

echo "case 5: uninstall removes the units and the whole data dir; a second run is a no-op"
setup Linux 1 1
run install
run uninstall
assert_eq "uninstall rc" 0 "$RC"
assert_eq "units gone" "0" "$(find "$HOME_DIR/$UNIT_REL" -name 'himmel-observability-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "data dir gone" "no" "$([ -e "$HOME_DIR/$DATA_REL" ] && echo yes || echo no)"
assert_contains "units disabled --now" "systemctl --user disable --now himmel-observability-grafana.service" "$(cat "$LOG")"
run uninstall
assert_eq "second uninstall rc" 0 "$RC"

echo "case 6: macOS and an unknown subcommand are refused"
setup Darwin 1 1
run install
assert_eq "macOS rc" 2 "$RC"
assert_contains "macOS reason" "macOS is not supported yet" "$OUT"
setup Linux 1 1
run bogus
assert_eq "bad subcommand rc" 1 "$RC"

echo ""
echo "install-grafana: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
