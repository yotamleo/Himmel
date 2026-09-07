#!/usr/bin/env bash
set -u
fail=0

# TC-005: uppercase conversion
val=$(printf '%s' "abc" | tr 'a-z' 'A-Z')
if [ "$val" = "ABC" ]; then echo "PASS TC-005 uppercase conversion"; else echo "FAIL TC-005 uppercase conversion"; fail=1; fi

# TC-006: string length
val="hello"
if [ "${#val}" -eq 5 ]; then echo "PASS TC-006 string length"; else echo "FAIL TC-006 string length"; fail=1; fi

# TC-009: string concatenation
val="foo""bar"
if [ "$val" = "foobar" ]; then echo "PASS TC-009 string concatenation"; else echo "FAIL TC-009 string concatenation"; fail=1; fi

exit "$fail"
