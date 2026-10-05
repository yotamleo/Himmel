#!/usr/bin/env bash
# plan-index-launch.sh <out> <cmd...> -- the detached wrapper tick.sh runs (HIMMEL-4051) for a
# plan-index --refresh. Takes <out>/.launch first so an overlapping tick's duplicate exits
# before it can clobber the live refresh's .run.log/.last-fail/.last-run (HIMMEL-4059: its own
# file so the test drives the production wrapper, and a single-quoted trap that reads "$o" only
# when it fires).
o=$1; shift
mkdir "$o/.launch" 2>/dev/null || exit 0
trap 'rmdir "$o/.launch"' EXIT
if "$@" >"$o/.run.log" 2>&1; then
    rc=0; rm -f "$o/.last-fail"
else
    rc=$?; tail -n 1 "$o/.run.log" >"$o/.last-fail"
fi
echo "$rc" >"$o/.last-run"
