#!/usr/bin/env bash
# GREEN: file-level exemption marker with a reason.
# git-env-ok: read-only status check against a trusted, non-configurable path
set -euo pipefail
git -C "$1" rev-parse --git-common-dir
