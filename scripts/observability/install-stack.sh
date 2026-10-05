#!/usr/bin/env bash
# install-stack.sh — run the HIMMEL-922 flow exporter as a user service on
# Linux (systemd --user) and macOS (launchd agent) (HIMMEL-4288).
#
# WHY: the flow exporter (scripts/observability/flow-exporter.ts) only helps if
# it is up when the operator looks; a hand-started `bun run` dies with the
# terminal. A user-level service restarts it on failure and at login, with no
# root and no repo-owned daemon state.
#
#   install-stack.sh [install|status|uninstall]     (default: install)
#
# Scope: the EXPORTER ONLY. Prometheus + Grafana are a separate opt-in tier
# (HIMMEL-4280 spec §3, HIMMEL-2333 option (a)) and are not installed here.
# Windows uses install-stack.ps1.
#
# The unit/plist points at the PRIMARY checkout (via git-common-dir, as
# doctor-cadence.sh does), never a worktree: a worktree is prunable and would
# leave the service pointing at a deleted path.
#
#   Linux : ~/.config/systemd/user/himmel-flow-exporter.service
#   macOS : ~/Library/LaunchAgents/himmel-flow-exporter.plist
#
# ponytail: flow-exporter.ts serves no /healthz route yet, so a /healthz 404
# falls back to /metrics, upgrade path: once flow-exporter.ts answers /healthz
# (HIMMEL-4288 ask, deferred), drop the /metrics fallback in probe().
set -uo pipefail

NAME="himmel-flow-exporter"
UNIT="$NAME.service"
HOST="127.0.0.1"
PORT=9877
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/Library/Logs/$NAME.log"
PLIST="$HOME/Library/LaunchAgents/$NAME.plist"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UID_N="$(id -u)"

die() { echo "install-stack: $*" >&2; exit "${2:-1}"; }

case "$(uname -s 2>/dev/null)" in
    Linux) PLATFORM=linux ;;
    Darwin) PLATFORM=macos ;;
    MINGW*|MSYS*|CYGWIN*) die "Windows shells use install-stack.ps1 (scripts/observability/install-stack.ps1)" 2 ;;
    *) die "unsupported platform: $(uname -s 2>/dev/null)" 2 ;;
esac

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

# sed, not ${s//x/&y}: bash 5.2 patsub_replacement treats a bare & in the replacement as the match
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# systemd expands % specifiers in unit values, even inside quotes (HIMMEL-4342)
unit_escape() { printf '%s' "$1" | sed -e 's/%/%%/g'; }

# probe: one pass over /healthz, then /metrics if /healthz is a 404.
# Sets HEALTH_URL to the URL that answered 200.
probe() {
    local code path
    HEALTH_URL=""
    for path in /healthz /metrics; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOST:$PORT$path")"
        if [ "$code" = 200 ]; then HEALTH_URL="http://$HOST:$PORT$path"; return 0; fi
        [ "$code" = 404 ] || return 1
    done
    return 1
}

wait_healthy() {
    for _ in $(seq 1 15); do
        if probe; then echo "flow exporter healthy: $HEALTH_URL"; return 0; fi
        sleep 1
    done
    if [ "$PLATFORM" = linux ]; then
        die "flow exporter not healthy after 15s; see: journalctl --user -u $NAME"
    fi
    die "flow exporter not healthy after 15s; see: $LOG_FILE"
}

write_unit() {
    mkdir -p "$UNIT_DIR" || die "cannot create $UNIT_DIR"
    cat > "$UNIT_DIR/$UNIT" <<EOF || die "cannot write $UNIT_DIR/$UNIT"
[Unit]
Description=himmel flow exporter (HIMMEL-922)

[Service]
Type=simple
WorkingDirectory=$(unit_escape "$ROOT")
ExecStart="$(unit_escape "$BUN")" run "$(unit_escape "$ROOT")/scripts/observability/flow-exporter.ts"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

write_plist() {
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")" || die "cannot create LaunchAgents/Logs dirs"
    cat > "$PLIST" <<EOF || die "cannot write $PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$BUN")</string>
        <string>run</string>
        <string>$(xml_escape "$ROOT")/scripts/observability/flow-exporter.ts</string>
    </array>
    <key>WorkingDirectory</key><string>$(xml_escape "$ROOT")</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_FILE")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
EOF
}

cmd_install() {
    ROOT="$(resolve_root)"
    BUN="$(find_bun)" || true
    [ -n "$BUN" ] || die "bun not found on PATH or at ~/.bun/bin/bun"
    if [ "$PLATFORM" = linux ]; then
        write_unit
        systemctl --user daemon-reload || die "systemctl daemon-reload failed"
        systemctl --user enable "$UNIT" || die "systemctl enable failed"
        systemctl --user restart "$UNIT" || die "systemctl restart failed"
    else
        write_plist
        launchctl bootout "gui/$UID_N/$NAME" >/dev/null 2>&1 || true   # not loaded yet is fine
        launchctl bootstrap "gui/$UID_N" "$PLIST" || die "launchctl bootstrap failed"
        launchctl enable "gui/$UID_N/$NAME" || die "launchctl enable failed"
    fi
    wait_healthy
}

cmd_status() {
    local bad=0 out svc_ok=1
    if [ "$PLATFORM" = linux ]; then
        systemctl --user is-enabled "$UNIT" >/dev/null 2>&1 || svc_ok=0
    else
        launchctl print "gui/$UID_N/$NAME" >/dev/null 2>&1 || svc_ok=0
    fi
    if [ "$svc_ok" = 1 ]; then echo "OK   service  $NAME registered"
    else echo "FAIL service  $NAME not registered"; bad=1; fi
    if probe; then echo "OK   health  $HEALTH_URL"
    else echo "FAIL health  no 200 from http://$HOST:$PORT/healthz or /metrics"; bad=1; fi
    out="$(bash "$SCRIPT_DIR/../doctor-cadence.sh" status 2>&1)"
    if grep -q '^ARMED' <<< "$out"; then echo "OK   doctor-cadence  armed"
    else echo "FAIL doctor-cadence  not armed (bash scripts/doctor-cadence.sh arm)"; bad=1; fi
    return "$bad"
}

cmd_uninstall() {
    if [ "$PLATFORM" = linux ]; then
        # nothing installed = nothing to stop; a registered unit that will not stop is an error
        if [ -f "$UNIT_DIR/$UNIT" ]; then
            systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || die "systemctl disable --now failed; unit file left in place"
        fi
        rm -f "$UNIT_DIR/$UNIT" || die "cannot remove $UNIT_DIR/$UNIT"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    else
        if launchctl print "gui/$UID_N/$NAME" >/dev/null 2>&1; then
            launchctl bootout "gui/$UID_N/$NAME" >/dev/null 2>&1 || die "launchctl bootout failed; plist left in place"
        fi
        rm -f "$PLIST" || die "cannot remove $PLIST"
    fi
    echo "$NAME uninstalled"
}

case "${1:-install}" in
    install) cmd_install ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) die "usage: install-stack.sh [install|status|uninstall]" 1 ;;
esac
