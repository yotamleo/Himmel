#!/usr/bin/env bash
# accept-common.sh - shared helpers for the hidden acceptance tests (HIMMEL-4090).
# Sourced by tasks/<id>/accept.sh. Each check prints `ok <name>` or
# `FAIL <name>`; accept_done prints `accept: <passed>/<total>` and exits 0 only
# when every check passed. The runner records that line verbatim.

A_PASS=0
A_TOTAL=0

accept_ok() { # $1 = name; $2.. = command that must succeed
  local name="$1"; shift
  A_TOTAL=$((A_TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    A_PASS=$((A_PASS + 1)); echo "ok $name"
  else
    echo "FAIL $name"
  fi
}

accept_eq() { # $1 = name; $2 = expected; $3 = actual
  A_TOTAL=$((A_TOTAL + 1))
  if [ "$2" = "$3" ]; then
    A_PASS=$((A_PASS + 1)); echo "ok $1"
  else
    echo "FAIL $1 (want '$2', got '$3')"
  fi
}

accept_rc() { # $1 = name; $2 = expected exit code; $3.. = command
  local name="$1" want="$2" rc
  shift 2
  "$@" >/dev/null 2>&1; rc=$?
  accept_eq "$name" "$want" "$rc"
}

accept_done() {
  echo "accept: $A_PASS/$A_TOTAL"
  [ "$A_TOTAL" -gt 0 ] && [ "$A_PASS" -eq "$A_TOTAL" ]
}
