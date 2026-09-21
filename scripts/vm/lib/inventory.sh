#!/usr/bin/env bash
# inventory.sh <label> — checksummed machine inventory (HIMMEL-3324). Runs ON the guest.
# Writes /tmp/inv-<label>/{home.meta,home.sha,etc.sha,sys.meta,tmp.meta,pkgs.txt,sizes.txt,procs.txt}.
# Content hashes, not mtimes: the diff is over what a file IS, not when it was touched.
#
# STRICTLY READ-ONLY. A first version ran the agent CLI's plugin listing, `npm ls -g`
# and `bun pm ls -g`, and each of those CREATED state (~/.claude, ~/.claude.json,
# ~/.npm/_logs, ~/.bun/install/global) on the pristine machine — the inventory was
# contaminating the thing it measures. This one reads files and never runs a tool.
#
# Exit status: 2 for a bad label; 1 when a REQUIRED collection (1-4: home.meta, home.sha,
# etc.sha, sys.meta) or the MANIFEST write/readback failed — each is named on stderr and the
# rest are still collected; else 0.
# The probes 5-8 (/tmp, packages, sizes, processes) are deliberately fail-open: /tmp churns
# under the walk and the tools the others call may be absent.
set -u
export LC_ALL=C
label=${1:?label}
# The label becomes a path component that is removed recursively: refuse anything that could
# leave /tmp/inv-* BEFORE the path is built (HIMMEL-3348).
case $label in
    *[!A-Za-z0-9._-]*) echo "inventory.sh: invalid label '$label' (allowed: [A-Za-z0-9._-])" >&2; exit 2 ;;
esac
out=/tmp/inv-$label
rm -rf "$out"; mkdir -p "$out"
bad=0
need() { echo "inventory.sh: required collection failed: $1" >&2; bad=1; }

# 1. Every path under $HOME: type, octal mode, size, path, symlink target.
( set -o pipefail; find "$HOME" -xdev -mindepth 1 -printf '%y\t%m\t%s\t%p\t%l\n' | sort >"$out/home.meta" ) || need home.meta
# 2. sha256 of every regular file under $HOME.
( set -o pipefail; find "$HOME" -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum >"$out/home.sha" 2>"$out/home.sha.err" ) || need home.sha
# 3. /etc content hashes (sudo, NOPASSWD on the guest).
# shellcheck disable=SC2024  # the redirect targets $out (guest user's own dir), not a root file
( set -o pipefail; sudo find /etc -xdev -type f -print0 | sort -z | sudo xargs -0 -r sha256sum >"$out/etc.sha" 2>"$out/etc.sha.err" ) || need etc.sha
# 4. Non-HOME paths an install could plausibly touch: metadata. A directory that is absent is
#    normal; one that is present and cannot be listed is a failed collection.
(
  set -o pipefail
  {
    rc=0
    for d in /usr/local /opt /var/spool/cron /var/spool/at /etc/cron.d /etc/systemd /usr/lib/systemd/user /var/lib/systemd/linger; do
      [ -e "$d" ] || continue
      sudo find "$d" -xdev -mindepth 0 -printf '%y\t%m\t%s\t%p\t%l\n' 2>/dev/null || rc=1
    done
    exit "$rc"
  } | sort >"$out/sys.meta"
) || need sys.meta
# 5. /tmp (excluding the inventory dirs and roundtrip logs themselves).
find /tmp -xdev -mindepth 1 -not -path '/tmp/inv-*' -not -path '/tmp/rt-*' -printf '%y\t%m\t%s\t%p\t%l\n' 2>/dev/null | sort >"$out/tmp.meta"
# 6. Packages, schedulers, tool locations — read-only.
{
  echo "## dpkg"; dpkg-query -W -f='${Package} ${Version}\n' | sort
  echo "## global node_modules"; ls -1 /usr/lib/node_modules /usr/local/lib/node_modules 2>&1
  echo "## user crontab"; cat /var/spool/cron/crontabs/"$(id -un)" 2>&1
  echo "## at queue"; sudo ls -1 /var/spool/at /var/spool/cron/atjobs 2>&1
  echo "## user units"; ls -1 "$HOME/.config/systemd/user" 2>&1
  echo "## git global config"; cat "$HOME/.gitconfig" 2>&1
  echo "## PATH lookups"
  for c in claude codex qmd himmelctl jira pre-commit uv gh gitleaks shellcheck; do
    for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin "$HOME/.local/bin" "$HOME/.bun/bin"; do
      [ -e "$d/$c" ] && echo "$c -> $d/$c"
    done
  done
} >"$out/pkgs.txt" 2>&1
# 7. Sizes (KiB) of the paths the ticket names, then top-level HOME.
{
  for p in "$HOME/.claude" "$HOME/.claude.json" "$HOME/.codex" "$HOME/.local" "$HOME/.cache" "$HOME/.config" "$HOME/.bun" "$HOME/.npm" "$HOME/himmel" "$HOME/himmel-trial" "$HOME/.local/bin" "$HOME/.cache/qmd" "$HOME/.local/share"; do
    [ -e "$p" ] && du -sk "$p" 2>/dev/null
  done
  echo "## top-level HOME"; du -sk "$HOME"/.[!.]* "$HOME"/* 2>/dev/null | sort -k2
  echo "## df"; df -k /
} >"$out/sizes.txt"
# 8. Processes owned by the login user (own plumbing filtered out).
# shellcheck disable=SC2009  # need args + ppid columns pgrep does not give
ps -u "$(id -un)" -o pid,ppid,args --no-headers 2>/dev/null | grep -v -E ' ps -u|inventory\.sh|sshd|bash -lc|sort -k3|grep -v' | sort -k3 >"$out/procs.txt"
# 9. Manifest.
( cd "$out" && wc -l home.meta home.sha etc.sha sys.meta tmp.meta pkgs.txt sizes.txt procs.txt && sha256sum home.meta home.sha etc.sha sys.meta tmp.meta pkgs.txt sizes.txt procs.txt ) >"$out/MANIFEST" || need MANIFEST
cat "$out/MANIFEST" || need MANIFEST
exit "$bad"
