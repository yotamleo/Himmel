#!/usr/bin/env bash
# scripts/caller.sh - fixture: non-test caller referencing bar-wired.sh and
# the wired-agent.md agent (neither call actually runs; this is fixture text
# for git-grep classification, not executable wiring).
echo "would call: scripts/bar-wired.sh and .claude/agents/wired-agent.md"
