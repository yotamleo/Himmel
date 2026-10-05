#!/usr/bin/env bash
# stub doctor for the bundle lint fixture: only the emit literals matter
emit OK C1-guardrail "ok"
case "${1:-}" in a) emit WARN C3-luna "dirty" ;; esac
