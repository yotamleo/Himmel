#!/usr/bin/env bash
# resolve-powershell.sh — locate the preferred PowerShell executable at
# RUNTIME (HIMMEL-2126).
#
# WHY: Windows PowerShell 5.1 (powershell.exe) has a trap class pwsh
# (PowerShell 7) does not: it reads a BOM-less UTF-8 script as cp1252,
# mojibaking an em-dash into a phantom token that throws a ParserError at the
# WRONG line; it has its own reserved-variable quirks; and it strips
# jq-style quoting differently than pwsh does. Operator ruling (2026-08-26):
# ALWAYS invoke pwsh unless a named reason exists — 5.1 is a loud, named
# fallback only, never a silent default.
#
# Source this file, then call `resolve_powershell`:
#   ps="$(resolve_powershell)" || { echo "no PowerShell"; exit 1; }
# Prints the resolved executable on stdout + returns 0 on success. When pwsh
# is unavailable and Windows PowerShell is used instead, ALSO prints ONE
# warning line to stderr naming the trap class + HIMMEL-2126 — the fallback
# must never be silent. Returns 1 + empty stdout if no PowerShell interpreter
# resolves at all. bash 3.2-safe.
resolve_powershell() {
    local ps_pwsh
    for ps_pwsh in pwsh pwsh.exe; do
        if command -v "$ps_pwsh" >/dev/null 2>&1; then
            command -v "$ps_pwsh"
            return 0
        fi
    done
    local ps_fallback
    for ps_fallback in powershell.exe powershell; do
        if command -v "$ps_fallback" >/dev/null 2>&1; then
            echo "WARN: pwsh (PowerShell 7) not found; falling back to Windows PowerShell 5.1 ($ps_fallback) -- HIMMEL-2126: PS 5.1 misreads BOM-less UTF-8 as cp1252 (em-dash mojibake -> phantom-token ParserError at the WRONG line), has reserved-variable quirks, and strips jq-style quoting differently than pwsh. Install pwsh (PowerShell 7) to silence this." >&2
            command -v "$ps_fallback"
            return 0
        fi
    done
    return 1
}
