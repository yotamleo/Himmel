#!/usr/bin/env bash
set -u
fail=0

# TC-001: two plus two
if [ $((2 + 2)) -eq 4 ]; then echo "PASS TC-001 two plus two"; else echo "FAIL TC-001 two plus two"; fail=1; fi

# TC-002: ten minus three
if [ $((10 - 3)) -eq 7 ]; then echo "PASS TC-002 ten minus three"; else echo "FAIL TC-002 ten minus three"; fail=1; fi

# TC-002: three times three
if [ $((3 * 3)) -eq 9 ]; then echo "PASS TC-002 three times three"; else echo "FAIL TC-002 three times three"; fail=1; fi

# TC-005: twenty divided by four
if [ $((20 / 4)) -eq 5 ]; then echo "PASS TC-005 twenty divided by four"; else echo "FAIL TC-005 twenty divided by four"; fail=1; fi

exit "$fail"
