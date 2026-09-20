#!/usr/bin/env bash
# record-launch.sh <session> <mode> <source> <autocompact> (HIMMEL-3299)
#
# Writes a console's durable launch-context row. console.sh puts this in front
# of the `claude` command it prints, so the row is written by the command the
# operator PASTES, immediately before claude starts -- never when the line is
# only printed. A console started from that line is the one launch path with no
# launcher (headed-arm.sh and arm-resume.sh write their own row), and a row
# written at print time would be a record for a console nobody started: the
# same fabricated-data defect as a test fixture, but under a real session name
# and so indistinguishable from a true row.
#
# The row is the one console_context_write_record writes for the arm paths, so
# the reader (sc_launch_context) sees a single shape. Best-effort: a row that
# cannot be written is said on stderr and the exit is still 0, because the next
# thing in the pasted line is the console itself and it must start regardless
# (the reader then says `unknown`, never a proxy).
#
# ponytail: the row exists once this runs, which is before claude has
# authenticated and opened its session -- a claude that fails after that leaves
# a row for a console that never came up. Writing from inside the started
# session (a SessionStart hook) would close it; it cannot know the mode the
# launch line carried without re-deriving it, so it is not done here.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/console-context.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/console-context.sh"

if [ "$#" -ne 4 ]; then
    echo "record-launch: usage: record-launch.sh <session> <mode> <source> <autocompact>" >&2
    exit 0
fi

if ! console_context_write_record "$1" "$2" "$3" "$4"; then
    echo "record-launch: WARN launch record NOT written under ${CONSOLE_CONTEXT_RECORD_DIR:-<no cache dir>} (this console's launch context will read as unknown)" >&2
fi
exit 0
