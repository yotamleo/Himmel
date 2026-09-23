#!/usr/bin/env bash
# scripts/out-of-window.sh - fixture: no static reference anywhere; a Bash
# tool_use in the out-of-window transcript fixture calls it BEFORE --since,
# proving the USED scan is windowed and does not leak an out-of-window call
# into the static DEAD verdict.
echo out-of-window
