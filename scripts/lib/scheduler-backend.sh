#!/usr/bin/env bash
# scheduler-backend.sh — detect + remediate the OS scheduler backend the
# auto-arm-on-cap watchdog relies on via arm-resume.sh (HIMMEL-594). Pure: no
# privileged commands, sourceable, bash-3.2-safe. The STATUS mirrors what
# arm-resume.sh actually selects so the verdict can never be a false-OK:
#   - windows: schtasks (always present)
#   - linux:   `at` when present (needs atd live), else crontab fallback
#   - macos:   crontab only (arm-resume skips `at` there — atrun unreliable)
# Consumed by himmel-doctor C9 + the ubuntu/macos installers. No `set -e`
# (sourced into callers with their own error posture).

scheduler_backend_os() {
    if [ -n "${SCHEDULER_BACKEND_OS:-}" ]; then printf '%s\n' "$SCHEDULER_BACKEND_OS"; return; fi
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*|MSYS*|CYGWIN*) echo windows ;;
        linux*|Linux*)                             echo linux ;;
        darwin*|Darwin*)                           echo macos ;;
        *)                                         echo unknown ;;
    esac
}

# _atd_live — rc 0 if the at daemon is running. Honors SCHEDULER_BACKEND_ATD_ACTIVE
# (1/0 test seam). Prober order: systemctl → pgrep → (absent) conservative FAIL.
_scheduler_atd_live() {
    case "${SCHEDULER_BACKEND_ATD_ACTIVE:-}" in 1) return 0 ;; 0) return 1 ;; esac
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet atd 2>/dev/null && return 0
        return 1
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x atd >/dev/null 2>&1 && return 0
        return 1
    fi
    return 1   # prober absent → conservative "not live" (no false-OK)
}

scheduler_backend_status() {
    case "$(scheduler_backend_os)" in
        windows) command -v schtasks >/dev/null 2>&1 && echo ok || echo missing ;;
        linux)
            if command -v at >/dev/null 2>&1; then
                if _scheduler_atd_live; then echo ok; else echo disabled; fi
            elif command -v crontab >/dev/null 2>&1; then echo ok-cron
            else echo missing; fi ;;
        macos)
            if command -v crontab >/dev/null 2>&1; then echo ok-cron; else echo missing; fi ;;
        *) echo missing ;;
    esac
}

scheduler_backend_remediation() {
    local os status; os="$(scheduler_backend_os)"; status="$(scheduler_backend_status)"
    case "$os" in
        windows) : ;;  # schtasks always present
        linux)
            case "$status" in
                disabled|missing) echo "sudo apt install -y at && sudo systemctl enable --now atd" ;;
                ok-cron)          echo "only crontab is available; for exact one-shot timing: sudo apt install -y at && sudo systemctl enable --now atd" ;;
            esac ;;
        macos)
            case "$status" in
                ok-cron)  echo "crontab is the expected macOS backend (ALPHA — please validate auto-arm fires and file an issue if not)" ;;
                missing)  echo "crontab not found — install/enable cron (ALPHA, please file an issue)" ;;
            esac ;;
    esac
}
