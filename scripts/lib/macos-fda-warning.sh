#!/usr/bin/env bash
# macos-fda-warning.sh — Full Disk Access arm-time warning for macOS cron
# cadences (HIMMEL-3075, himmel#771).
#
# WHY: on modern macOS, /usr/sbin/cron itself needs Full Disk Access (TCC)
# before ANY cron-fired job can read inside a protected folder (~/Documents,
# ~/Desktop, ~/Downloads, iCloud Drive). arm/status/disarm all SUCCEED
# regardless — the adopter (himmel#771, macOS 26) verified with a probe
# crontab entry that the identical `ls` fails under cron and succeeds from an
# interactive terminal. Every vault leg then fails on every fire with
# "Operation not permitted" and nothing at arm time says so.
#
# cron's TCC grant state cannot be probed synchronously from an interactive
# shell — no API answers "does cron have FDA" without a live disk read, and
# the adopter already established that. So this is a warning at arm time, not
# a check: `himmel-doctor` is the reader-side half, probing a leg's first-fire
# log for "Operation not permitted" (HIMMEL-3075).
#
# Callers gate this ENTIRELY on their own PLATFORM var (set by each script's
# own platform-detect block) so the non-Darwin path never even calls in here —
# that is the provable control the ticket asks for.
#
# Sourced, not executed. bash 3.2-safe; no side effects.
#
# Platform guard (gitbash-only): pure POSIX bash 3.2+, works fine under Git
# Bash on Windows too — it never runs there in practice because every caller
# gates the call on its own PLATFORM var being "macos" (see above).

# True (rc=0) if $1 sits inside a folder TCC protects on macOS.
macos_fda_protected_path() {
    local target="$1" home="${HOME:-}"
    [ -n "$target" ] && [ -n "$home" ] || return 1
    case "$target" in
        "$home/Documents"|"$home/Documents"/*) return 0 ;;
        "$home/Desktop"|"$home/Desktop"/*) return 0 ;;
        "$home/Downloads"|"$home/Downloads"/*) return 0 ;;
        "$home/Library/Mobile Documents"|"$home/Library/Mobile Documents"/*) return 0 ;;
    esac
    return 1
}

# Prints the FDA warning, naming every protected path among "$@". Call with
# NO arguments when the caller has no fixed target to check (e.g. qmd-cadence
# reindexes whatever collections qmd itself is configured with, a path this
# script never sees) — that prints the same warning without a Targets: list
# rather than guessing at a path. No-op unless PLATFORM=macos.
macos_fda_warn_if_needed() {
    [ "${PLATFORM:-}" = "macos" ] || return 0
    local targets=""
    if [ "$#" -gt 0 ]; then
        local target
        for target in "$@"; do
            macos_fda_protected_path "$target" || continue
            targets="$targets  - $target
"
        done
        [ -n "$targets" ] || return 0
    fi
    cat <<EOF

  ⚠ Full Disk Access required (HIMMEL-3075, himmel#771):
${targets}  /usr/sbin/cron itself needs Full Disk Access, or every fire of this
  cadence fails with "Operation not permitted" — silently, with nothing at
  arm time or in the scheduler saying so. This is not this cadence's own
  target — it's cron's own TCC grant, checked once per station.
  Grant it: System Settings -> Privacy & Security -> Full Disk Access ->
  add /usr/sbin/cron.
  cron's TCC grant state cannot be probed from here — 'himmel-doctor' checks
  a leg's first-fire log for "Operation not permitted" instead of a live probe.
EOF
}
