#!/usr/bin/env bash
# fixture: only textual reference anywhere is this self header comment (no
# path prefix, so even the basename fallback would only self-match) - proves
# a Bash tool_use whose command has an embedded newline still counts this
# script as USED (the referencing path sits on the command's second line).
echo multiline-used
