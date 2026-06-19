#!/usr/bin/env bash
# Thin shim — kept for backward compatibility with machines whose
# .claude/settings.json hooks stanza still references this filename.
# All logic lives in block-backend-tier.sh (HIMMEL-400).
exec bash "$(dirname "$0")/block-backend-tier.sh" "$@"
