#!/usr/bin/env bash
# mutate-provenance.sh — HIMMEL-3787 S2a wet-run helper. Overwrites the
# project's himmel-installed adopter-scripts unit (proj/scripts/worktree.sh)
# with a third value, the way an operator would by hand after install: the
# real-install mirror of test-uninstall-provenance.sh's RED58/RED59. Runs ON
# the guest, from scripts/vm/provenance-roundtrip.sh, between inventory-B and
# uninstall.
#
# Refuses (rc 2, writing nothing) unless HIMMEL_RT_GUEST=1, or when the target
# file does not already exist (there is nothing to mutate).
set -u
export LC_ALL=C

[ "${HIMMEL_RT_GUEST:-}" = 1 ] || { echo "mutate-provenance.sh: refusing: guest-only (set HIMMEL_RT_GUEST=1 on the guest)" >&2; exit 2; }

TARGET="$HOME/proj/scripts/worktree.sh"
[ -f "$TARGET" ] || { echo "mutate-provenance.sh: refusing: $TARGET does not exist (nothing to mutate)" >&2; exit 2; }

printf '#!/bin/sh\necho "OPERATOR-EDITED-AFTER-INSTALL"\n' >"$TARGET"
echo "mutate-provenance.sh: $TARGET overwritten with an operator-edited value"
