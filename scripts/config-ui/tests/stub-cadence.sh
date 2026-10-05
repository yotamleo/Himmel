#!/usr/bin/env bash
# Test seam HIMMEL_REPORT_CADENCE_ROOT: copied to each cadence script path.
# Records its argv to $STUB_ARGV; a real arm/disarm flips a marker in
# $STUB_STATE that stub-recorder.js reports back as the row's state.
name="$(basename "$0" .sh)"
echo "$name.sh $*" >> "$STUB_ARGV"
echo "plan: $name $* ${STUB_LEAK:-}"
echo "err: $name ${STUB_LEAK:-}" >&2
if [ "${2:-}" != "--dry-run" ]; then
  if [ -n "${STUB_HANG:-}" ]; then
    sleep 30 &
    echo "$!" > "$STUB_STATE/grandchild"
    sleep 30
  fi
  [ -n "${STUB_SLOW:-}" ] && sleep 1
  # STUB_RUN_SLEEP (seconds): a real run that outlasts Bun's 10 s idle default (HIMMEL-4369).
  [ -n "${STUB_RUN_SLEEP:-}" ] && sleep "$STUB_RUN_SLEEP"
  case "$1" in
    arm) : > "$STUB_STATE/$name" ;;
    disarm) rm -f "$STUB_STATE/$name" ;;
  esac
fi
exit "${STUB_RC:-0}"
