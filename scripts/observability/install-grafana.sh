#!/usr/bin/env bash
# install-grafana.sh — run Prometheus + Grafana as systemd USER units on Linux,
# provisioned with the himmel-health dashboard (HIMMEL-4289).
#
# WHY: the dashboard engine is Grafana + Prometheus (operator ruling 2026-10-05).
# install-stack.sh runs only the flow exporter; this is the opt-in tier above it
# (HIMMEL-4280 spec §3). Nothing here needs root and nothing is a distro package:
# both servers are the UPSTREAM release tarballs, pinned by version and sha256,
# unpacked under one machine-local directory.
#
#   install-grafana.sh [install|status|uninstall]     (default: install)
#
# Layout (everything under $DATA, so uninstall is one directory):
#   $DATA/prometheus-<ver>/   $DATA/grafana-<ver>/    the pinned upstream trees
#   $DATA/prometheus.yml      the repo copy minus the Windows-only exporter job
#   $DATA/alerts.rules.yml    the repo copy
#   $DATA/grafana.ini         telemetry/analytics/update checks OFF, loopback only
#   $DATA/grafana-provisioning/  the repo provisioning, with the contact point
#                             rendered to the cadence-alert webhook
#   $DATA/dashboards/         dashboards/ copied from the repo
# Units (~/.config/systemd/user): himmel-observability-prometheus,
# himmel-observability-grafana, himmel-observability-grafana-alert-hook.
#
# Alerts: Grafana's one contact point is a webhook to grafana-cadence-hook.ts,
# which calls scripts/luna/cadence-alert.sh — one dedupe path, one log. The
# Windows Telegram contact point (GRAFANA_TELEGRAM_*) is not used here.
#
# macOS is not supported yet (launchd packaging): HIMMEL-4406.
#
# ponytail: the pins below are bumped by hand, upgrade path: a pin-bump check in
# himmel-doctor once a second pinned upstream binary exists.
set -uo pipefail

PROM_VER="3.15.0"
GRAF_VER="13.2.3"
# sha256 of the upstream tarballs (prometheus: the release's sha256sums.txt;
# grafana: dl.grafana.com's <tarball>.sha256). A mismatch aborts the install.
PROM_SHA_AMD64="2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0"
PROM_SHA_ARM64="f1f90ec08e849d494ca66c611470afc50192f0355f1a61c33f2cbde02d067823"
GRAF_SHA_AMD64="6107ad27016296aac38e0d7ffa8753ab540b5541ad27e94790f771289d733235"
GRAF_SHA_ARM64="a2a41b960ba4c25e83140484e48813730d3c81891a128439a2a9d2df6eb3840e"

HOST="127.0.0.1"
PROM_PORT=9090
GRAF_PORT=3000
HOOK_PORT=9878
PROM_UNIT="himmel-observability-prometheus.service"
GRAF_UNIT="himmel-observability-grafana.service"
HOOK_UNIT="himmel-observability-grafana-alert-hook.service"
UNITS="$PROM_UNIT $GRAF_UNIT $HOOK_UNIT"
CONTACT_POINT="himmel-cadence-alert"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/himmel/observability"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

die() { echo "install-grafana: $*" >&2; exit "${2:-1}"; }

case "$(uname -s 2>/dev/null)" in
    Linux) ;;
    Darwin) die "macOS is not supported yet (launchd packaging): HIMMEL-4406" 2 ;;
    MINGW*|MSYS*|CYGWIN*) die "Windows shells use install-stack.ps1" 2 ;;
    *) die "unsupported platform: $(uname -s 2>/dev/null)" 2 ;;
esac

# Primary checkout, never a worktree: a worktree is prunable and would leave the
# hook unit pointing at a deleted path (same rule as install-stack.sh).
resolve_root() {
    local common
    if common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$common" ]; then
        (cd "$(dirname "$common")" 2>/dev/null && pwd) && return 0
    fi
    (cd "$SCRIPT_DIR/../.." && pwd)
}

find_bun() {
    if command -v bun 2>/dev/null; then return 0; fi
    [ -x "$HOME/.bun/bin/bun" ] && echo "$HOME/.bun/bin/bun"
}

# systemd expands % specifiers in unit values, even inside quotes (HIMMEL-4342)
unit_escape() { printf '%s' "$1" | sed -e 's/%/%%/g'; }

case "$(uname -m 2>/dev/null)" in
    x86_64|amd64) ARCH=amd64; PROM_SHA="$PROM_SHA_AMD64"; GRAF_SHA="$GRAF_SHA_AMD64" ;;
    aarch64|arm64) ARCH=arm64; PROM_SHA="$PROM_SHA_ARM64"; GRAF_SHA="$GRAF_SHA_ARM64" ;;
    *) die "unsupported architecture: $(uname -m 2>/dev/null)" 2 ;;
esac
PROM_DIR="$DATA/prometheus-$PROM_VER"
GRAF_DIR="$DATA/grafana-$GRAF_VER"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.linux-$ARCH.tar.gz"
GRAF_URL="https://dl.grafana.com/oss/release/grafana-$GRAF_VER.linux-$ARCH.tar.gz"

# fetch_tree <name> <url> <sha256> <dest-dir> <binary-relpath>
# Download, verify against the pin, unpack with the tarball's top directory
# stripped. A tree that already has its binary is left alone (idempotent).
fetch_tree() {
    local name="$1" url="$2" sha="$3" dest="$4" bin="$5" tarball got
    [ -x "$dest/$bin" ] && return 0
    mkdir -p "$DATA/dl" || die "cannot create $DATA/dl"
    tarball="$DATA/dl/$name.tar.gz"
    curl -fsSL --retry 2 --max-time 600 -o "$tarball" "$url" || { rm -f "$tarball"; die "download failed: $url"; }
    got="$(sha256sum "$tarball" | cut -d' ' -f1)"
    if [ "$got" != "$sha" ]; then
        rm -f "$tarball"
        die "sha256 mismatch for $name (expected $sha, got $got); nothing was installed"
    fi
    rm -rf "$dest"; mkdir -p "$dest" || die "cannot create $dest"
    tar -xzf "$tarball" -C "$dest" --strip-components=1 || { rm -rf "$dest"; die "cannot unpack $tarball"; }
    rm -f "$tarball"
    [ -x "$dest/$bin" ] || die "$name unpacked without $bin"
}

render_config() {
    local src="$SCRIPT_DIR" prov="$DATA/grafana-provisioning"
    mkdir -p "$DATA/data/prometheus" "$DATA/data/grafana" "$DATA/plugins" "$DATA/dashboards" "$prov/alerting" "$prov/datasources" "$prov/dashboards" "$prov/plugins" \
        || die "cannot create $DATA subdirectories"

    # The Windows-only exporter job is the last stanza; on Linux its target never
    # exists, so `up == 0` would alert forever.
    sed -e '/^  - job_name: windows_exporter/,$d' "$src/prometheus.yml" > "$DATA/prometheus.yml" || die "cannot write prometheus.yml"
    grep -q windows_exporter "$DATA/prometheus.yml" && die "prometheus.yml still names windows_exporter; its job is no longer the last stanza"
    cp "$src/alerts.rules.yml" "$DATA/alerts.rules.yml" || die "cannot copy alerts.rules.yml"

    cp "$src/dashboards/"*.json "$DATA/dashboards/" || die "cannot copy dashboards"
    sed -e "s|@HIMMEL_DASHBOARDS_DIR@|$DATA/dashboards|" "$src/provisioning/dashboards/himmel-dashboards.yaml.tmpl" \
        > "$prov/dashboards/himmel-dashboards.yaml" || die "cannot render the dashboard provider"
    cp "$src/provisioning/datasources/prometheus.yaml" "$prov/datasources/" || die "cannot copy the datasource"
    cp "$src/provisioning/alerting/rules.yaml" "$prov/alerting/" || die "cannot copy alert rules"
    sed -e "s/himmel-telegram/$CONTACT_POINT/g" "$src/provisioning/alerting/policies.yaml" > "$prov/alerting/policies.yaml" || die "cannot render policies"
    grep -q himmel-telegram "$prov/alerting/policies.yaml" && die "policies still route to himmel-telegram"
    cat > "$prov/alerting/contact-points.yaml" <<EOF || die "cannot write the contact point"
# Rendered by install-grafana.sh (HIMMEL-4289): alerts go to cadence-alert.sh through
# grafana-cadence-hook.ts, never to Telegram directly.
apiVersion: 1

contactPoints:
  - orgId: 1
    name: $CONTACT_POINT
    receivers:
      - uid: himmel_cadence_alert_receiver
        type: webhook
        settings:
          url: http://$HOST:$HOOK_PORT/alert
          httpMethod: POST
EOF

    cat > "$DATA/grafana.ini" <<EOF || die "cannot write grafana.ini"
; Rendered by install-grafana.sh (HIMMEL-4289). Loopback only; telemetry off.
[paths]
data = $DATA/data/grafana
logs = $DATA/data/grafana/log
plugins = $DATA/plugins
provisioning = $prov

[server]
http_addr = $HOST
http_port = $GRAF_PORT

[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
feedback_links_enabled = false

[news]
news_feed_enabled = false

[snapshots]
external_enabled = false

[security]
disable_gravatar = true

[users]
allow_sign_up = false

[auth.anonymous]
enabled = true
org_role = Viewer

[log]
mode = console
EOF

    if [ ! -s "$DATA/admin-password" ]; then
        (umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$DATA/admin-password") || die "cannot write the admin password"
    fi
}

write_units() {
    local root="$1" bun="$2"
    mkdir -p "$UNIT_DIR" || die "cannot create $UNIT_DIR"
    cat > "$UNIT_DIR/$PROM_UNIT" <<EOF || die "cannot write $PROM_UNIT"
[Unit]
Description=himmel Prometheus (HIMMEL-4289)

[Service]
Type=simple
ExecStart="$(unit_escape "$PROM_DIR")/prometheus" --config.file="$(unit_escape "$DATA")/prometheus.yml" --storage.tsdb.path="$(unit_escape "$DATA")/data/prometheus" --web.listen-address=$HOST:$PROM_PORT --storage.tsdb.retention.time=30d --storage.tsdb.retention.size=5GB
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    cat > "$UNIT_DIR/$GRAF_UNIT" <<EOF || die "cannot write $GRAF_UNIT"
[Unit]
Description=himmel Grafana (HIMMEL-4289)
After=$PROM_UNIT

[Service]
Type=simple
WorkingDirectory=$(unit_escape "$GRAF_DIR")
Environment=GF_SECURITY_ADMIN_PASSWORD__FILE=$(unit_escape "$DATA")/admin-password
ExecStart="$(unit_escape "$GRAF_DIR")/bin/grafana" server --homepath="$(unit_escape "$GRAF_DIR")" --config="$(unit_escape "$DATA")/grafana.ini"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    cat > "$UNIT_DIR/$HOOK_UNIT" <<EOF || die "cannot write $HOOK_UNIT"
[Unit]
Description=himmel Grafana alert hook to cadence-alert (HIMMEL-4289)

[Service]
Type=simple
WorkingDirectory=$(unit_escape "$root")
Environment=HIMMEL_GRAFANA_HOOK_PORT=$HOOK_PORT
ExecStart="$(unit_escape "$bun")" run "$(unit_escape "$root")/scripts/observability/grafana-cadence-hook.ts"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# code <url>: the HTTP status, 000 when nothing answers
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1"; }

wait_healthy() {
    for _ in $(seq 1 60); do
        if [ "$(code "http://$HOST:$PROM_PORT/-/healthy")" = 200 ] \
            && [ "$(code "http://$HOST:$GRAF_PORT/api/health")" = 200 ] \
            && [ "$(code "http://$HOST:$HOOK_PORT/healthz")" = 200 ]; then
            echo "prometheus, grafana and the alert hook are healthy"
            return 0
        fi
        sleep 1
    done
    die "stack not healthy after 60s; see: journalctl --user -u ${PROM_UNIT%.service} -u ${GRAF_UNIT%.service} -u ${HOOK_UNIT%.service}"
}

cmd_install() {
    local root bun
    for t in curl tar sha256sum systemctl; do command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH"; done
    root="$(resolve_root)"
    bun="$(find_bun)" || true
    [ -n "$bun" ] || die "bun not found on PATH or at ~/.bun/bin/bun"
    mkdir -p "$DATA" || die "cannot create $DATA"
    fetch_tree prometheus "$PROM_URL" "$PROM_SHA" "$PROM_DIR" prometheus
    fetch_tree grafana "$GRAF_URL" "$GRAF_SHA" "$GRAF_DIR" bin/grafana
    render_config
    write_units "$root" "$bun"
    systemctl --user daemon-reload || die "systemctl daemon-reload failed"
    # shellcheck disable=SC2086  # $UNITS is a fixed word list
    systemctl --user enable $UNITS || die "systemctl enable failed"
    # shellcheck disable=SC2086
    systemctl --user restart $UNITS || die "systemctl restart failed"
    wait_healthy
}

cmd_status() {
    local bad=0 u name port path
    for u in $UNITS; do
        if systemctl --user is-enabled "$u" >/dev/null 2>&1; then echo "OK   service  $u registered"
        else echo "FAIL service  $u not registered"; bad=1; fi
    done
    while read -r name port path; do
        if [ "$(code "http://$HOST:$port$path")" = 200 ]; then echo "OK   health  $name http://$HOST:$port$path"
        else echo "FAIL health  $name no 200 from http://$HOST:$port$path"; bad=1; fi
    done <<EOF
prometheus $PROM_PORT /-/healthy
grafana $GRAF_PORT /api/health
alert-hook $HOOK_PORT /healthz
EOF
    return "$bad"
}

cmd_uninstall() {
    local u
    for u in $UNITS; do
        # nothing installed = nothing to stop; a registered unit that will not stop is an error
        if [ -f "$UNIT_DIR/$u" ]; then
            systemctl --user disable --now "$u" >/dev/null 2>&1 || die "systemctl disable --now $u failed; unit file left in place"
        fi
        rm -f "$UNIT_DIR/$u" || die "cannot remove $UNIT_DIR/$u"
    done
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    case "$DATA" in
        */himmel/observability) rm -rf "$DATA" || die "cannot remove $DATA" ;;
        *) die "refusing to remove an unexpected data dir: $DATA" ;;
    esac
    echo "himmel observability (prometheus + grafana + alert hook) uninstalled"
}

case "${1:-install}" in
    install) cmd_install ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) die "usage: install-grafana.sh [install|status|uninstall]" 1 ;;
esac
