# shellcheck shell=sh
# pty-run.sh -- run a command under a pty with its stdin held OPEN (HIMMEL-2534).
#
# Sourced by the `at` job body arm-resume.sh writes, which /bin/sh executes at
# fire time: POSIX sh only, no %q, no arrays, no [[ ]].
#
# WHY: atd runs a job with stdin=/dev/null and no tty. A claude launched that
# way exits at the first idle cross-session message (five fleet legs lost
# 2026-09-05). `script` alone is not enough: measured, `script -qefc CMD
# /dev/null </dev/null` hands CMD a tty but forwards the EOF at once, so
# CMD reads EOF immediately. Holding the fifo below open read-write (nothing
# ever writes to it) gives script a stdin that never EOFs, so the session is
# genuinely interactive and idles until a message arrives.
#
#   _himmel_pty_run <cmd> [args...]     rc = <cmd>'s exit status
#
# Both `script` dialects: util-linux (`-qefc STRING FILE`, -e = child's rc) and
# BSD/macOS (`-q FILE cmd args...`). The command string is handed to the inner
# `sh -c` through the environment, never spliced into the outer command line,
# so the user's login shell ($SHELL, e.g. fish) never re-parses the prompt.
#
# A host with no script(1)/mkfifo (Windows Git-Bash, minimal images) falls back
# to the pre-fix bare launch and says so on stderr -- a leg that cannot be
# messaged while idle is worse than none only if nobody is told.
#
# HIMMEL_PTY_SCRIPT_CMD overrides the script binary (test seam, same idiom as
# SCHTASKS_CMD).

# _himmel_pty_sq <word>: print <word> single-quoted for a POSIX sh re-parse.
_himmel_pty_sq() {
    _hp_s=$1
    _hp_o=
    _hp_q="'"
    _hp_esc="'\\''"
    while :; do
        case $_hp_s in
            *"$_hp_q"*)
                _hp_pre=${_hp_s%%"$_hp_q"*}
                _hp_o=$_hp_o$_hp_pre$_hp_esc
                _hp_s=${_hp_s#*"$_hp_q"}
                ;;
            *) break ;;
        esac
    done
    printf "'%s%s'" "$_hp_o" "$_hp_s"
}

# Subshell body: the fifo fd and the exported command string stay private to
# one launch.
_himmel_pty_run() (
    _hp_script=${HIMMEL_PTY_SCRIPT_CMD:-script}
    _hp_f=
    if command -v "$_hp_script" >/dev/null 2>&1 \
        && _hp_f=$(mktemp -u "${TMPDIR:-/tmp}/himmel-pty.XXXXXX" 2>/dev/null) \
        && mkfifo "$_hp_f" 2>/dev/null; then
        :
    else
        echo "WARN pty-run: script(1)/mkfifo unavailable -- launching $1 WITHOUT a pty; an idle cross-session message will end this session (HIMMEL-2534)" >&2
        command "$@"
        exit $?
    fi
    exec 3<>"$_hp_f" || exit 1
    rm -f "$_hp_f"
    # A pty made for a non-tty stdin is 0x0, which a TUI can lay itself out
    # against; give it a sane size. Dropped from the environment before exec so
    # the prompt does not sit in claude's /proc environ.
    _hp_cmd="unset HIMMEL_PTY_CMD; stty rows 50 cols 200 2>/dev/null; exec"
    for _hp_a in "$@"; do
        _hp_cmd="$_hp_cmd $(_himmel_pty_sq "$_hp_a")"
    done
    case ${TERM:-dumb} in
        dumb) TERM=xterm-256color; export TERM ;;
    esac
    HIMMEL_PTY_CMD=$_hp_cmd
    export HIMMEL_PTY_CMD
    # script's own stdout is the pty's output copy (a full TUI paint stream);
    # atd would mail it, so send it nowhere. stderr stays for script's errors.
    # Captured, not piped into `grep -q`: no producer to SIGPIPE under a caller's
    # pipefail, and the case works in the POSIX sh the at body runs under.
    _hp_ver=$("$_hp_script" --version 2>&1)
    case $_hp_ver in
        *util-linux*)
            # shellcheck disable=SC2016  # $HIMMEL_PTY_CMD is meant to expand in the inner shell
            "$_hp_script" -qefc 'sh -c "$HIMMEL_PTY_CMD"' /dev/null <&3 3<&- >/dev/null
            ;;
        *)
            "$_hp_script" -q /dev/null sh -c "$HIMMEL_PTY_CMD" <&3 3<&- >/dev/null
            ;;
    esac
)
