#!/usr/bin/env bash
set -u
fail=0

# TC-010: runner script exists
if [ -f "run-tests.sh" ]; then echo "PASS TC-010 runner script exists"; else echo "FAIL TC-010 runner script exists"; fail=1; fi

# TC-010: tests directory exists
if [ -d "tests" ]; then echo "PASS TC-010 tests directory exists"; else echo "FAIL TC-010 tests directory exists"; fail=1; fi

# TC-012: word count
val="one two three"
count=$(printf '%s' "$val" | wc -w | tr -d ' ')
if [ "$count" -eq 3 ]; then echo "PASS TC-012 word count"; else echo "FAIL TC-012 word count"; fail=1; fi

exit "$fail"
