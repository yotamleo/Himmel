#!/usr/bin/env bash
# scripts/doc-and-code.sh - fixture: mentioned by full path in docs/readme.md
# (a non-self hit) AND called only by basename from a sibling script that
# never spells the "scripts/" prefix (codex-2 unmasking fix: the full-path
# doc hit must not suppress the basename search that would otherwise
# surface the real code caller).
echo doc-and-code
