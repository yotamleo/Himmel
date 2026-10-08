#!/usr/bin/env bash
# bucket-gitleaks.sh — HIMMEL-4911. Leg-side pre-check of a handover-bucket file
# BEFORE it is written/committed: the luna vault's pre-commit runs gitleaks, and
# a generic-api-key false positive on prose stalls the vault's auto-commit for
# every session until someone notices. Usage:
#   bash scripts/handover/console-kit/bucket-gitleaks.sh [--config <toml>] <file>
# Prints ONE line: `GITLEAKS ok` (exit 0) or `GITLEAKS FINDING <rule>[,<rule>]`
# (exit 1; the rule ids only, never the matched text). Exit 2 = usage / file
# missing / gitleaks absent or unusable (the line says why). Config: --config,
# else the vault's .gitleaks.toml (vault-status.sh --path), else gitleaks' defaults.
# On a FINDING reword the prose (break the key=value shape) and re-run.
# bash 3.2-safe; no .ps1 twin (the console kit is Linux-only).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg=""
if [ "${1:-}" = "--config" ]; then cfg="${2:-}"; shift 2 2>/dev/null || shift; fi
file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then printf 'GITLEAKS error: no such file: %s\n' "$file"; exit 2; fi
command -v gitleaks >/dev/null 2>&1 || { printf 'GITLEAKS error: gitleaks not installed\n'; exit 2; }
if [ -z "$cfg" ]; then
    vault="$(bash "$HERE/vault-status.sh" --path 2>/dev/null)"
    [ -n "$vault" ] && [ -f "$vault/.gitleaks.toml" ] && cfg="$vault/.gitleaks.toml"
fi
report="$(mktemp "${TMPDIR:-/tmp}/bucket-gitleaks.XXXXXX")" || { printf 'GITLEAKS error: mktemp failed\n'; exit 2; }
trap 'rm -f "$report"' EXIT
gitleaks detect --no-git --no-banner --redact -f json -r "$report" ${cfg:+--config "$cfg"} --source "$file" >/dev/null 2>&1
rc=$?
case "$rc" in
    0) printf 'GITLEAKS ok\n'; exit 0 ;;
    1)
        rules="$(grep -o '"RuleID": *"[^"]*"' "$report" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | sort -u | paste -sd, -)"
        printf 'GITLEAKS FINDING %s\n' "${rules:-unknown}"
        exit 1 ;;
    *) printf 'GITLEAKS error: gitleaks exited %s\n' "$rc"; exit 2 ;;
esac
