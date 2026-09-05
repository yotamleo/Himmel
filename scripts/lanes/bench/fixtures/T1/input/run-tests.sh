#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$DIR/strcheck.sh" ]; then
    . "$DIR/strcheck.sh"
fi

for f in "$DIR"/*.sh; do
    case "$f" in
        "$DIR/run-tests.sh") continue ;;
        "$DIR/strcheck.sh") continue ;;
    esac
    . "$f"
done

fail=0
total=0

check() {
    local fn="$1" arg="$2" expect="$3" got
    total=$((total+1))
    "$fn" "$arg"
    got=$?
    if [ "$got" -ne "$expect" ]; then
        echo "FAIL: $fn '$arg' expected=$expect got=$got" >&2
        fail=$((fail+1))
    fi
}

check cfgval_01 "prod-web-01" 0
check cfgval_01 "staging-web-01" 1
check cfgval_02 "fatal error occurred" 0
check cfgval_02 "all good here" 1
check cfgval_03 "v2.3.1" 0
check cfgval_03 "latest" 1
check cfgval_04 "feature disabled" 0
check cfgval_04 "feature enabled" 1
check cfgval_05 "# a comment" 0
check cfgval_05 "not a comment" 1
check cfgval_06 "true" 0
check cfgval_06 "false" 1
check cfgval_07 "deny all" 0
check cfgval_07 "allow all" 1
check cfgval_08 "ssh-rsa AAAA" 0
check cfgval_08 "ecdsa-sha2 AAAA" 1
check cfgval_09 "release.tar.gz" 0
check cfgval_09 "release.zip" 1
check cfgval_10 "https://example.com" 0
check cfgval_10 "http://example.com" 1
check cfgval_11 "status: pending" 0
check cfgval_11 "status: done" 1
check cfgval_12 "feature/foo" 0
check cfgval_12 "bugfix/foo" 1
check cfgval_13 "commit msg skip-ci" 0
check cfgval_13 "commit msg normal" 1
check cfgval_14 "critical failure" 0
check cfgval_14 "minor issue" 1
check envchk_01 "10.0.0.5" 0
check envchk_01 "192.168.1.5" 1
check envchk_02 "tag: latest" 0
check envchk_02 "tag: v1" 1
check envchk_03 "status draft" 0
check envchk_03 "status final" 1
check envchk_04 "archived=true" 0
check envchk_04 "status: active" 1
check envchk_05 "INFO: starting" 0
check envchk_05 "DEBUG: starting" 1
check envchk_06 "request timeout" 0
check envchk_06 "request ok" 1
check envchk_07 "prod-web-01" 0
check envchk_07 "staging-web-01" 1
check envchk_08 "fatal error occurred" 0
check envchk_08 "all good here" 1
check envchk_09 "v2.3.1" 0
check envchk_09 "latest" 1
check envchk_10 "feature disabled" 0
check envchk_10 "feature enabled" 1
check envchk_11 "# a comment" 0
check envchk_11 "not a comment" 1
check envchk_12 "true" 0
check envchk_12 "false" 1
check envchk_13 "deny all" 0
check envchk_13 "allow all" 1
check envchk_14 "ssh-rsa AAAA" 0
check envchk_14 "ecdsa-sha2 AAAA" 1
check argparse_01 "release.tar.gz" 0
check argparse_01 "release.zip" 1
check argparse_02 "https://example.com" 0
check argparse_02 "http://example.com" 1
check argparse_03 "status: pending" 0
check argparse_03 "status: done" 1
check argparse_04 "feature/foo" 0
check argparse_04 "bugfix/foo" 1
check argparse_05 "commit msg skip-ci" 0
check argparse_05 "commit msg normal" 1
check argparse_06 "critical failure" 0
check argparse_06 "minor issue" 1
check argparse_07 "10.0.0.5" 0
check argparse_07 "192.168.1.5" 1
check argparse_08 "tag: latest" 0
check argparse_08 "tag: v1" 1
check argparse_09 "status draft" 0
check argparse_09 "status final" 1
check argparse_10 "archived=true" 0
check argparse_10 "status: active" 1
check argparse_11 "INFO: starting" 0
check argparse_11 "DEBUG: starting" 1
check argparse_12 "request timeout" 0
check argparse_12 "request ok" 1
check argparse_13 "prod-web-01" 0
check argparse_13 "staging-web-01" 1
check argparse_14 "fatal error occurred" 0
check argparse_14 "all good here" 1
check netguard_01 "v2.3.1" 0
check netguard_01 "latest" 1
check netguard_02 "feature disabled" 0
check netguard_02 "feature enabled" 1
check netguard_03 "# a comment" 0
check netguard_03 "not a comment" 1
check netguard_04 "true" 0
check netguard_04 "false" 1
check netguard_05 "deny all" 0
check netguard_05 "allow all" 1
check netguard_06 "ssh-rsa AAAA" 0
check netguard_06 "ecdsa-sha2 AAAA" 1
check netguard_07 "release.tar.gz" 0
check netguard_07 "release.zip" 1
check netguard_08 "https://example.com" 0
check netguard_08 "http://example.com" 1
check netguard_09 "status: pending" 0
check netguard_09 "status: done" 1
check netguard_10 "feature/foo" 0
check netguard_10 "bugfix/foo" 1
check netguard_11 "commit msg skip-ci" 0
check netguard_11 "commit msg normal" 1
check netguard_12 "critical failure" 0
check netguard_12 "minor issue" 1
check netguard_13 "10.0.0.5" 0
check netguard_13 "192.168.1.5" 1
check netguard_14 "tag: latest" 0
check netguard_14 "tag: v1" 1
check logfilt_01 "status draft" 0
check logfilt_01 "status final" 1
check logfilt_02 "archived=true" 0
check logfilt_02 "status: active" 1
check logfilt_03 "INFO: starting" 0
check logfilt_03 "DEBUG: starting" 1
check logfilt_04 "request timeout" 0
check logfilt_04 "request ok" 1
check logfilt_05 "prod-web-01" 0
check logfilt_05 "staging-web-01" 1
check logfilt_06 "fatal error occurred" 0
check logfilt_06 "all good here" 1
check logfilt_07 "v2.3.1" 0
check logfilt_07 "latest" 1
check logfilt_08 "feature disabled" 0
check logfilt_08 "feature enabled" 1
check logfilt_09 "# a comment" 0
check logfilt_09 "not a comment" 1
check logfilt_10 "true" 0
check logfilt_10 "false" 1
check logfilt_11 "deny all" 0
check logfilt_11 "allow all" 1
check logfilt_12 "ssh-rsa AAAA" 0
check logfilt_12 "ecdsa-sha2 AAAA" 1
check logfilt_13 "release.tar.gz" 0
check logfilt_13 "release.zip" 1
check logfilt_14 "https://example.com" 0
check logfilt_14 "http://example.com" 1
check statemach_01 "status: pending" 0
check statemach_01 "status: done" 1
check statemach_02 "feature/foo" 0
check statemach_02 "bugfix/foo" 1
check statemach_03 "commit msg skip-ci" 0
check statemach_03 "commit msg normal" 1
check statemach_04 "critical failure" 0
check statemach_04 "minor issue" 1
check statemach_05 "10.0.0.5" 0
check statemach_05 "192.168.1.5" 1
check statemach_06 "tag: latest" 0
check statemach_06 "tag: v1" 1
check statemach_07 "status draft" 0
check statemach_07 "status final" 1
check statemach_08 "archived=true" 0
check statemach_08 "status: active" 1
check statemach_09 "INFO: starting" 0
check statemach_09 "DEBUG: starting" 1
check statemach_10 "request timeout" 0
check statemach_10 "request ok" 1
check statemach_11 "prod-web-01" 0
check statemach_11 "staging-web-01" 1
check statemach_12 "fatal error occurred" 0
check statemach_12 "all good here" 1
check statemach_13 "v2.3.1" 0
check statemach_13 "latest" 1
check secscan_01 "feature disabled" 0
check secscan_01 "feature enabled" 1
check secscan_02 "# a comment" 0
check secscan_02 "not a comment" 1
check secscan_03 "true" 0
check secscan_03 "false" 1
check secscan_04 "deny all" 0
check secscan_04 "allow all" 1
check secscan_05 "ssh-rsa AAAA" 0
check secscan_05 "ecdsa-sha2 AAAA" 1
check secscan_06 "release.tar.gz" 0
check secscan_06 "release.zip" 1
check secscan_07 "https://example.com" 0
check secscan_07 "http://example.com" 1
check secscan_08 "status: pending" 0
check secscan_08 "status: done" 1
check secscan_09 "feature/foo" 0
check secscan_09 "bugfix/foo" 1
check secscan_10 "commit msg skip-ci" 0
check secscan_10 "commit msg normal" 1
check secscan_11 "critical failure" 0
check secscan_11 "minor issue" 1
check secscan_12 "10.0.0.5" 0
check secscan_12 "192.168.1.5" 1
check secscan_13 "tag: latest" 0
check secscan_13 "tag: v1" 1
check permchk_01 "status draft" 0
check permchk_01 "status final" 1
check permchk_02 "archived=true" 0
check permchk_02 "status: active" 1
check permchk_03 "INFO: starting" 0
check permchk_03 "DEBUG: starting" 1
check permchk_04 "request timeout" 0
check permchk_04 "request ok" 1
check permchk_05 "prod-web-01" 0
check permchk_05 "staging-web-01" 1
check permchk_06 "fatal error occurred" 0
check permchk_06 "all good here" 1
check permchk_07 "v2.3.1" 0
check permchk_07 "latest" 1
check permchk_08 "feature disabled" 0
check permchk_08 "feature enabled" 1
check permchk_09 "# a comment" 0
check permchk_09 "not a comment" 1
check permchk_10 "true" 0
check permchk_10 "false" 1
check permchk_11 "deny all" 0
check permchk_11 "allow all" 1
check permchk_12 "ssh-rsa AAAA" 0
check permchk_12 "ecdsa-sha2 AAAA" 1
check permchk_13 "release.tar.gz" 0
check permchk_13 "release.zip" 1
check relgate_01 "https://example.com" 0
check relgate_01 "http://example.com" 1
check relgate_02 "status: pending" 0
check relgate_02 "status: done" 1
check relgate_03 "feature/foo" 0
check relgate_03 "bugfix/foo" 1
check relgate_04 "commit msg skip-ci" 0
check relgate_04 "commit msg normal" 1
check relgate_05 "critical failure" 0
check relgate_05 "minor issue" 1
check relgate_06 "10.0.0.5" 0
check relgate_06 "192.168.1.5" 1
check relgate_07 "tag: latest" 0
check relgate_07 "tag: v1" 1
check relgate_08 "status draft" 0
check relgate_08 "status final" 1
check relgate_09 "archived=true" 0
check relgate_09 "status: active" 1
check relgate_10 "INFO: starting" 0
check relgate_10 "DEBUG: starting" 1
check relgate_11 "request timeout" 0
check relgate_11 "request ok" 1
check relgate_12 "prod-web-01" 0
check relgate_12 "staging-web-01" 1
check relgate_13 "fatal error occurred" 0
check relgate_13 "all good here" 1
check ffchk_01 "v2.3.1" 0
check ffchk_01 "latest" 1
check ffchk_02 "feature disabled" 0
check ffchk_02 "feature enabled" 1
check ffchk_03 "# a comment" 0
check ffchk_03 "not a comment" 1
check ffchk_04 "true" 0
check ffchk_04 "false" 1
check ffchk_05 "deny all" 0
check ffchk_05 "allow all" 1
check ffchk_06 "ssh-rsa AAAA" 0
check ffchk_06 "ecdsa-sha2 AAAA" 1
check ffchk_07 "release.tar.gz" 0
check ffchk_07 "release.zip" 1
check ffchk_08 "https://example.com" 0
check ffchk_08 "http://example.com" 1
check ffchk_09 "status: pending" 0
check ffchk_09 "status: done" 1
check ffchk_10 "feature/foo" 0
check ffchk_10 "bugfix/foo" 1
check ffchk_11 "commit msg skip-ci" 0
check ffchk_11 "commit msg normal" 1
check ffchk_12 "critical failure" 0
check ffchk_12 "minor issue" 1
check ffchk_13 "10.0.0.5" 0
check ffchk_13 "192.168.1.5" 1
check pathsan_01 "tag: latest" 0
check pathsan_01 "tag: v1" 1
check pathsan_02 "status draft" 0
check pathsan_02 "status final" 1
check pathsan_03 "archived=true" 0
check pathsan_03 "status: active" 1
check pathsan_04 "INFO: starting" 0
check pathsan_04 "DEBUG: starting" 1
check pathsan_05 "request timeout" 0
check pathsan_05 "request ok" 1
check pathsan_06 "prod-web-01" 0
check pathsan_06 "staging-web-01" 1
check pathsan_07 "fatal error occurred" 0
check pathsan_07 "all good here" 1
check pathsan_08 "v2.3.1" 0
check pathsan_08 "latest" 1
check pathsan_09 "feature disabled" 0
check pathsan_09 "feature enabled" 1
check pathsan_10 "# a comment" 0
check pathsan_10 "not a comment" 1
check pathsan_11 "true" 0
check pathsan_11 "false" 1
check pathsan_12 "deny all" 0
check pathsan_12 "allow all" 1
check pathsan_13 "ssh-rsa AAAA" 0
check pathsan_13 "ecdsa-sha2 AAAA" 1
check inputguard_01 "release.tar.gz" 0
check inputguard_01 "release.zip" 1
check inputguard_02 "https://example.com" 0
check inputguard_02 "http://example.com" 1
check inputguard_03 "status: pending" 0
check inputguard_03 "status: done" 1
check inputguard_04 "feature/foo" 0
check inputguard_04 "bugfix/foo" 1
check inputguard_05 "commit msg skip-ci" 0
check inputguard_05 "commit msg normal" 1
check inputguard_06 "critical failure" 0
check inputguard_06 "minor issue" 1
check inputguard_07 "10.0.0.5" 0
check inputguard_07 "192.168.1.5" 1
check inputguard_08 "tag: latest" 0
check inputguard_08 "tag: v1" 1
check inputguard_09 "status draft" 0
check inputguard_09 "status final" 1
check inputguard_10 "archived=true" 0
check inputguard_10 "status: active" 1
check inputguard_11 "INFO: starting" 0
check inputguard_11 "DEBUG: starting" 1
check inputguard_12 "request timeout" 0
check inputguard_12 "request ok" 1
check inputguard_13 "prod-web-01" 0
check inputguard_13 "staging-web-01" 1
check cistatus_01 "fatal error occurred" 0
check cistatus_01 "all good here" 1
check cistatus_02 "v2.3.1" 0
check cistatus_02 "latest" 1
check cistatus_03 "feature disabled" 0
check cistatus_03 "feature enabled" 1
check cistatus_04 "# a comment" 0
check cistatus_04 "not a comment" 1
check cistatus_05 "true" 0
check cistatus_05 "false" 1
check cistatus_06 "deny all" 0
check cistatus_06 "allow all" 1
check cistatus_07 "ssh-rsa AAAA" 0
check cistatus_07 "ecdsa-sha2 AAAA" 1
check cistatus_08 "release.tar.gz" 0
check cistatus_08 "release.zip" 1
check cistatus_09 "https://example.com" 0
check cistatus_09 "http://example.com" 1
check cistatus_10 "status: pending" 0
check cistatus_10 "status: done" 1
check cistatus_11 "feature/foo" 0
check cistatus_11 "bugfix/foo" 1
check cistatus_12 "commit msg skip-ci" 0
check cistatus_12 "commit msg normal" 1
check cistatus_13 "critical failure" 0
check cistatus_13 "minor issue" 1
check pkgfilt_01 "10.0.0.5" 0
check pkgfilt_01 "192.168.1.5" 1
check pkgfilt_02 "tag: latest" 0
check pkgfilt_02 "tag: v1" 1
check pkgfilt_03 "status draft" 0
check pkgfilt_03 "status final" 1
check pkgfilt_04 "archived=true" 0
check pkgfilt_04 "status: active" 1
check pkgfilt_05 "INFO: starting" 0
check pkgfilt_05 "DEBUG: starting" 1
check pkgfilt_06 "request timeout" 0
check pkgfilt_06 "request ok" 1
check pkgfilt_07 "prod-web-01" 0
check pkgfilt_07 "staging-web-01" 1
check pkgfilt_08 "fatal error occurred" 0
check pkgfilt_08 "all good here" 1
check pkgfilt_09 "v2.3.1" 0
check pkgfilt_09 "latest" 1
check pkgfilt_10 "feature disabled" 0
check pkgfilt_10 "feature enabled" 1
check pkgfilt_11 "# a comment" 0
check pkgfilt_11 "not a comment" 1
check pkgfilt_12 "true" 0
check pkgfilt_12 "false" 1
check pkgfilt_13 "deny all" 0
check pkgfilt_13 "allow all" 1
check hostmatch_01 "ssh-rsa AAAA" 0
check hostmatch_01 "ecdsa-sha2 AAAA" 1
check hostmatch_02 "release.tar.gz" 0
check hostmatch_02 "release.zip" 1
check hostmatch_03 "https://example.com" 0
check hostmatch_03 "http://example.com" 1
check hostmatch_04 "status: pending" 0
check hostmatch_04 "status: done" 1
check hostmatch_05 "feature/foo" 0
check hostmatch_05 "bugfix/foo" 1
check hostmatch_06 "commit msg skip-ci" 0
check hostmatch_06 "commit msg normal" 1
check hostmatch_07 "critical failure" 0
check hostmatch_07 "minor issue" 1
check hostmatch_08 "10.0.0.5" 0
check hostmatch_08 "192.168.1.5" 1
check hostmatch_09 "tag: latest" 0
check hostmatch_09 "tag: v1" 1
check hostmatch_10 "status draft" 0
check hostmatch_10 "status final" 1
check hostmatch_11 "archived=true" 0
check hostmatch_11 "status: active" 1
check hostmatch_12 "INFO: starting" 0
check hostmatch_12 "DEBUG: starting" 1
check hostmatch_13 "request timeout" 0
check hostmatch_13 "request ok" 1

echo "ran $total checks, $fail failed"
[ "$fail" -eq 0 ]
