#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell (HIMMEL-441).
#
# Blocks container invocations that grant root-equivalent host access. Membership
# in the `docker` group is root-equivalent: a user/agent in it can start a
# container as root and bind-mount any host path WRITABLE, bypassing file
# permissions, block-read-secrets, AND block-edit-on-main. Motivating example
# (operator, 2026-06-20) — writes /etc as root with no sudo and no reader cmd:
#   docker run --rm --pull=never -v /etc:/host-etc:rw ubuntu:22.04 \
#     /usr/bin/install -m 0644 -o 0 -g 0 /host-etc/sddm.conf.bak /host-etc/sddm.conf
# The danger is the `-v /etc:…:rw` MOUNT (and privilege flags), not the command —
# so this guard is mount/flag-shaped, a SEPARATE concern from block-read-secrets
# (command-position + reader-list shaped). It therefore has its OWN bypass var.
#
# Detection model (docker|podman run|exec|create, plus `docker cp`):
#   * Bind-mount of a SECRET-BEARING host path → block in ANY mode (:ro or :rw):
#       /  /etc  /root  the docker socket  $HOME (itself)  $HOME dotdirs
#       (.ssh .aws .gnupg .kube .docker .config)  C:\Users\<user> (Windows home).
#     /home is NOT a blanket prefix — $HOME/Documents/proj is allowed.
#   * Bind-mount of a SYSTEM-INTEGRITY host path → block only when WRITABLE:
#       /usr /bin /sbin /lib /lib64 /boot /var /sys /proc /dev
#     (read-only mounts leak no secret — -v /etc/localtime:…:ro, -v /usr/share/
#     fonts:…:ro are common + legit; a small read-only allowlist under /etc is
#     carved out: localtime, timezone, resolv.conf, hosts, ssl/certs, ca-certs).
#   * Privilege flags: --privileged, --pid=host/--pid host, --user 0|root /
#     -u 0|0:* / -u0 / --user=0|root, --cap-add of a root-equivalent cap
#     (SYS_ADMIN SYS_PTRACE DAC_OVERRIDE DAC_READ_SEARCH ALL), --device of a host
#     BLOCK device (/dev/sd* nvme* vd* xvd* hd* loop* dm-* mapper/* disk/* md*),
#     --volumes-from.
#   * docker cp <hostpath> …  → block when a host-path arg is secret-bearing.
#
# Path is NORMALISED before matching: leading ~ and literal $HOME/${HOME} expand
# to $HOME; $PWD/${PWD} and relative paths are project-local (allowed); Windows
# `C:\…` backslashes → `/` and the drive colon is preserved when splitting
# `-v HOST:CTR[:opts]`; /./ , /../ , // and trailing / are collapsed.
#
# Accepted limitations (gate = common privesc shapes, not a determined attacker):
#   * docker exec into an ALREADY-privileged container (prior state, invisible).
#   * --volumes-from re-mounting another container's bind.
#   * Env-substituted host paths the hook cannot resolve ($SOMEVAR/etc).
#   * /proc/self/root and symlink-based host access.
#   * Rootless podman is not actually root-equivalent but is treated the same
#     (binary block; a 0/2-exit hook has no severity channel).
#   * A container COMMAND arg that literally equals a privesc flag (e.g.
#     `docker run img tool --privileged`) may false-positive — use the bypass.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: set DOCKER_PRIVESC_OK=1 in the shell that launched Claude Code (Claude
# cannot inject env vars into hooks). Session-sticky; restart to re-enable.
set -euo pipefail
# noglob: this hook does NO intentional filename expansion, and several token
# loops iterate UNQUOTED ($clause, $p, $ms) by design. Without -f a host path
# bearing a glob metachar (`-v /etc*:/h`) would be pathname-expanded against the
# hook's CWD, making the verdict non-deterministic AND letting the literal slip
# past the anchored classifier (fail-OPEN). -f + the glob fail-closed in
# classify_path together close that. case-pattern matching is unaffected by -f.
set -f

if ! command -v jq >/dev/null 2>&1; then
    echo "block-docker-privesc: jq not on PATH — refusing to evaluate; install jq or disable the hook" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Resolved $HOME (backslashes → slashes, trailing slash trimmed) for $HOME mounts.
HOME_RESOLVED="${HOME:-}"
HOME_RESOLVED="${HOME_RESOLVED//\\//}"
HOME_RESOLVED="${HOME_RESOLVED%/}"

strip_quotes() {
    local p="${1#\"}"; p="${p#\'}"; p="${p%\"}"; p="${p%\'}"
    printf '%s' "$p"
}

# Collapse /./ , /../ , // and trailing / on an absolute (or drive-rooted) path.
# bash 3.2-safe: a component stack delimited by '/', no external tools.
collapse_path() {
    local p="$1" prefix="" comp stack=""
    case "$p" in
        [A-Za-z]:/*) prefix="${p%%:*}:"; p="${p#*:}" ;;
    esac
    local oldIFS="$IFS"; IFS='/'
    for comp in $p; do
        case "$comp" in
            ''|.) ;;
            ..) stack="${stack%/*}" ;;
            *) stack="$stack/$comp" ;;
        esac
    done
    IFS="$oldIFS"
    [ -z "$stack" ] && stack="/"
    printf '%s%s' "$prefix" "$stack"
}

# Normalise a raw host-path token → canonical form, or __PROJECTLOCAL__ for a
# relative / $PWD path (always allowed).
normalise_path() {
    local p
    p=$(strip_quotes "$1")
    p="${p//\\//}"
    # Match the LITERAL ~ / $HOME / $PWD strings in the input token; the hook does
    # its own expansion, so shellcheck's "tilde/expr does not expand" notes are
    # intentional here.
    # shellcheck disable=SC2088,SC2016
    case "$p" in
        '~')          p="$HOME_RESOLVED" ;;
        '~/'*)        p="$HOME_RESOLVED/${p#\~/}" ;;
        '$HOME')      p="$HOME_RESOLVED" ;;
        '$HOME/'*)    p="$HOME_RESOLVED/${p#\$HOME/}" ;;
        '${HOME}')    p="$HOME_RESOLVED" ;;
        '${HOME}/'*)  p="$HOME_RESOLVED/${p#\$\{HOME\}/}" ;;
        '$PWD'|'$PWD/'*|'${PWD}'|'${PWD}/'*) printf '%s' "__PROJECTLOCAL__"; return ;;
    esac
    case "$p" in
        /*) ;;
        [A-Za-z]:/*) ;;
        *) printf '%s' "__PROJECTLOCAL__"; return ;;
    esac
    collapse_path "$p"
}

# classify_path <normalised-path> <ro|rw> → 0 = block, 1 = allow.
classify_path() {
    local p="$1" mode="$2"
    # Unresolved glob metachar in a host path → fail-CLOSED. The shell expands
    # `-v /etc*:/h` to `/etc` before docker sees it, but the hook sees the literal
    # `/etc*`, which no anchored pattern below matches — so block any host path
    # still bearing * ? [ rather than wave the expansion through.
    case "$p" in *'*'*|*'?'*|*'['*) return 0 ;; esac
    # docker socket — root-equivalent, any mode.
    case "$p" in */docker.sock) return 0 ;; esac
    # Read-only safe config files under /etc — common + legit container mounts.
    if [ "$mode" = "ro" ]; then
        case "$p" in
            /etc/localtime|/etc/timezone|/etc/resolv.conf|/etc/hosts|/etc/ssl/certs|/etc/ssl/certs/*|/etc/ca-certificates|/etc/ca-certificates/*) return 1 ;;
        esac
    fi
    # Secret-bearing — block in ANY mode.
    case "$p" in
        /) return 0 ;;
        /etc|/etc/*) return 0 ;;
        /root|/root/*) return 0 ;;
    esac
    if [ -n "$HOME_RESOLVED" ]; then
        [ "$p" = "$HOME_RESOLVED" ] && return 0
        case "$p" in
            "$HOME_RESOLVED"/.ssh|"$HOME_RESOLVED"/.ssh/*|\
            "$HOME_RESOLVED"/.aws|"$HOME_RESOLVED"/.aws/*|\
            "$HOME_RESOLVED"/.gnupg|"$HOME_RESOLVED"/.gnupg/*|\
            "$HOME_RESOLVED"/.kube|"$HOME_RESOLVED"/.kube/*|\
            "$HOME_RESOLVED"/.docker|"$HOME_RESOLVED"/.docker/*|\
            "$HOME_RESOLVED"/.config|"$HOME_RESOLVED"/.config/*) return 0 ;;
        esac
    fi
    # Windows home tree: <drive>:/Users/<name> (bare = home root; dotdirs under it).
    case "$p" in
        [A-Za-z]:/[Uu]sers/*)
            local rest="${p#*:/[Uu]sers/}"
            case "$rest" in
                */*) ;;            # deeper than home root → fall through
                *) return 0 ;;     # exactly <drive>:/Users/<name> → block
            esac
            case "$rest" in
                */.ssh|*/.ssh/*|*/.aws|*/.aws/*|*/.gnupg|*/.gnupg/*|*/.kube|*/.kube/*|*/.docker|*/.docker/*|*/.config|*/.config/*) return 0 ;;
            esac
            ;;
    esac
    # System-integrity — block only when WRITABLE.
    case "$p" in
        /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/boot|/boot/*|/var|/var/*|/sys|/sys/*|/proc|/proc/*|/dev|/dev/*)
            [ "$mode" = "rw" ] && return 0
            return 1 ;;
    esac
    return 1
}

# host_is_path <token> → 0 if the -v/--mount HOST side is a path (vs a named
# volume like "data" → allowed).
host_is_path() {
    case "$1" in
        /*|'~'*|'$'*|[A-Za-z]:[\\/]*) return 0 ;;
        './'*|'../'*|.) return 0 ;;
    esac
    return 1
}

# parse a `-v HOST:CTR[:opts]` spec → sets HOST + MODE.
HOST=""; MODE="rw"
parse_v_spec() {
    local spec; spec=$(strip_quotes "$1")
    HOST=""; MODE="rw"
    local tail="" f2rest="" opts=""
    case "$spec" in
        [A-Za-z]:[\\/]*)
            local drive="${spec%%:*}"; tail="${spec#*:}"
            HOST="${drive}:${tail%%:*}"
            case "$tail" in *:*) f2rest="${tail#*:}" ;; esac
            ;;
        *)
            HOST="${spec%%:*}"
            case "$spec" in *:*) f2rest="${spec#*:}" ;; esac
            ;;
    esac
    case "$f2rest" in *:*) opts="${f2rest#*:}" ;; esac
    case ",$opts," in *,ro,*|*,readonly,*) MODE="ro" ;; esac
}

# check a `-v` value → 0 block / 1 allow.
check_v() {
    parse_v_spec "$1"
    [ -z "$HOST" ] && return 1
    host_is_path "$HOST" || return 1
    local norm; norm=$(normalise_path "$HOST")
    [ "$norm" = "__PROJECTLOCAL__" ] && return 1
    classify_path "$norm" "$MODE"
}

# check a `--mount type=bind,source=…,…` value → 0 block / 1 allow.
check_mount() {
    local ms; ms=$(strip_quotes "$1")
    local src="" mode="rw" kv
    local oldIFS="$IFS"; IFS=','
    for kv in $ms; do
        case "$kv" in
            source=*) src="${kv#source=}" ;;
            src=*)    src="${kv#src=}" ;;
            readonly|readonly=true|ro) mode="ro" ;;
        esac
    done
    IFS="$oldIFS"
    [ -z "$src" ] && return 1
    host_is_path "$src" || return 1
    local norm; norm=$(normalise_path "$src")
    [ "$norm" = "__PROJECTLOCAL__" ] && return 1
    classify_path "$norm" "$mode"
}

is_root_user() {
    case "$1" in
        0|root|0:*|root:*) return 0 ;;
    esac
    return 1
}

is_dangerous_cap() {
    local c; c=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    c="${c#CAP_}"
    case "$c" in
        SYS_ADMIN|SYS_PTRACE|DAC_OVERRIDE|DAC_READ_SEARCH|ALL) return 0 ;;
    esac
    return 1
}

is_block_device() {
    local p; p=$(strip_quotes "$1")
    p="${p//\\//}"
    case "$p" in
        /dev/sd*|/dev/nvme*|/dev/vd*|/dev/xvd*|/dev/hd*|/dev/loop*|/dev/dm-*|/dev/mapper/*|/dev/disk/*|/dev/md*) return 0 ;;
    esac
    return 1
}

# scan a `docker cp` clause: block if a host-path arg is secret-bearing.
scan_cp() {
    local clause="$1" tok seensub=0
    for tok in $clause; do
        tok=$(strip_quotes "$tok")
        if [ "$seensub" = "0" ]; then
            [ "$tok" = "cp" ] && seensub=1
            continue
        fi
        case "$tok" in -*) continue ;; esac
        # container refs are <name|id>:<path>; host paths start with /,~,.,$ or drive.
        if host_is_path "$tok"; then
            local norm; norm=$(normalise_path "$tok")
            [ "$norm" = "__PROJECTLOCAL__" ] && continue
            # secret-bearing (any mode) is the cp concern; mode=ro probes the
            # read direction (cp host→container reads the host path).
            classify_path "$norm" "ro" && return 0
        fi
    done
    return 1
}

# scan a docker/podman run|exec|create clause → 0 block / 1 allow.
scan_docker_clause() {
    local clause="$1" tok cmdtok="" sub="" expectsub=0 skipval=0
    for tok in $clause; do
        # Strip surrounding quotes so a quoted flag TOKEN (`docker run "-v"
        # /etc:/h`, `"--privileged"`) cannot dodge the case match below.
        tok=$(strip_quotes "$tok")
        if [ "$expectsub" = "0" ]; then
            # Skip ALL leading tokens until the docker/podman binary — wrappers
            # AND their flags/values (sudo -E …, sudo -u root …, nice -n 5 …,
            # timeout 10 …, env -i …). A bare wrapper-only skip let `sudo -E
            # docker run -v /etc:…:rw` through (the flag became the command);
            # skip-until-docker closes that. ${tok##*/} strips a leading path so
            # /usr/bin/docker still matches.
            case "${tok##*/}" in
                docker|podman) cmdtok="$tok"; expectsub=1 ;;
            esac
            continue
        fi
        # Past the docker token: the subcommand is the first non-flag token,
        # skipping global flags and the VALUE of value-taking global flags
        # (docker -H tcp://… run, docker --context foo run).
        if [ "$skipval" = "1" ]; then skipval=0; continue; fi
        case "$tok" in
            -H|--host|--context|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey)
                skipval=1 ;;
            -*) ;;
            *) sub="$tok"; break ;;
        esac
    done
    [ -z "$cmdtok" ] && return 1
    case "$sub" in
        cp) scan_cp "$clause"; return $? ;;
        run|exec|create) ;;
        *) return 1 ;;
    esac

    local pending="" seensub=0
    for tok in $clause; do
        tok=$(strip_quotes "$tok")
        if [ "$seensub" = "0" ]; then
            [ "$tok" = "$sub" ] && seensub=1
            continue
        fi
        if [ -n "$pending" ]; then
            case "$pending" in
                v)      check_v "$tok" && return 0 ;;
                mount)  check_mount "$tok" && return 0 ;;
                user)   is_root_user "$tok" && return 0 ;;
                cap)    is_dangerous_cap "$tok" && return 0 ;;
                device) is_block_device "$tok" && return 0 ;;
                pid)    [ "$tok" = "host" ] && return 0 ;;
            esac
            pending=""
            continue
        fi
        case "$tok" in
            -v|--volume)        pending=v ;;
            -v*)                check_v "${tok#-v}" && return 0 ;;
            --volume=*)         check_v "${tok#--volume=}" && return 0 ;;
            --mount)            pending=mount ;;
            --mount=*)          check_mount "${tok#--mount=}" && return 0 ;;
            --privileged)       return 0 ;;
            --pid=host)         return 0 ;;
            --pid)              pending=pid ;;
            --user)             pending=user ;;
            --user=*)           is_root_user "${tok#--user=}" && return 0 ;;
            -u)                 pending=user ;;
            -u*)                is_root_user "${tok#-u}" && return 0 ;;
            --cap-add)          pending=cap ;;
            --cap-add=*)        is_dangerous_cap "${tok#--cap-add=}" && return 0 ;;
            --device)           pending=device ;;
            --device=*)         is_block_device "${tok#--device=}" && return 0 ;;
            --volumes-from|--volumes-from=*) return 0 ;;
        esac
    done
    return 1
}

# Split into clauses at shell separators (mount specs contain none of these).
normalized=$(printf '%s' "$cmd" | sed -e 's/[;|&()`]/\
/g')

block=0
while IFS= read -r clause; do
    [ -z "$clause" ] && continue
    if scan_docker_clause "$clause"; then block=1; fi
done <<EOF
$normalized
EOF

if [ "$block" = "1" ]; then
    [ "${DOCKER_PRIVESC_OK:-0}" = "1" ] && exit 0
    echo "⛔ block-docker-privesc: refusing $tool command — root-equivalent container access" >&2
    echo "    $cmd" >&2
    echo "" >&2
    echo "A docker/podman bind-mount of a sensitive host path or a privilege flag was" >&2
    echo "detected (docker-group access is root-equivalent). To bypass intentionally," >&2
    echo "set DOCKER_PRIVESC_OK=1 in the shell that launched Claude Code:" >&2
    echo "    DOCKER_PRIVESC_OK=1 claude" >&2
    echo "Session-sticky. Restart Claude without it to re-enable the guard." >&2
    exit 2
fi

exit 0
