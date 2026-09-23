#!/usr/bin/env bash
# scripts/precedence-test.sh - fixture: referenced from BOTH a test file and
# docs/readme.md, never from non-test code; proves TEST-ONLY beats DOC-ONLY.
echo precedence
