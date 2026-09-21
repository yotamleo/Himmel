#!/usr/bin/env bash
# inventory.sh <label> — checksummed machine inventory (HIMMEL-3324). Runs ON the guest.
# Writes /tmp/inv-<label>/{home.meta,home.sha,etc.sha,sys.meta,tmp.meta,pkgs.txt,sizes.txt,procs.txt}.
# Content hashes, not mtimes: the diff is over what a file IS, not when it was touched.
#
# STRICTLY READ-ONLY. A first version ran the agent CLI's plugin listing, `npm ls -g`
# and `bun pm ls -g`, and each of those CREATED state (~/.claude, ~/.claude.json,
# ~/.npm/_logs, ~/.bun/install/global) on the pristine machine — the inventory was
# contaminating the thing it measures. This one reads files and never runs a tool.
set -u
export LC_ALL=C
label=${1:?label}
out=/tmp/inv-$label
rm -rf "$out"; mkdir -p "$out"

# 1. Every path under $HOME: type, octal mode, size, path, symlink target.
find "$HOME" -xdev -mindepth 1 -printf '%y\t%m\t%s\t%p\t%l\n' | sort >"$out/home.meta"
# 2. sha256 of every regular file under $HOME.
find "$HOME" -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum >"$out/home.sha" 2>"$out/home.sha.err"
# 3. /etc content hashes (sudo, NOPASSWD on the guest).
# shellcheck disable=SC2024  # the redirect targets $out (guest user's own dir), not a root file
sudo find /etc -xdev -type f -print0 | sort -z | sudo xargs -0 -r sha256sum >"$out/etc.sha" 2>"$out/etc.sha.err"
# 4. Non-HOME paths an install could plausibly touch: metadata.
{
  for d in /usr/local /opt /var/spool/cron /var/spool/at /etc/cron.d /etc/systemd /usr/lib/systemd/user /var/lib/systemd/linger; do
    [ -e "$d" ] && sudo find "$d" -xdev -mindepth 0 -printf '%y\t%m\t%s\t%p\t%l\n'
  done
} 2>/dev/null | sort >"$out/sys.meta"
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
( cd "$out" && wc -l home.meta home.sha etc.sha sys.meta tmp.meta pkgs.txt sizes.txt procs.txt && sha256sum home.meta home.sha etc.sha sys.meta tmp.meta pkgs.txt sizes.txt procs.txt ) >"$out/MANIFEST"
cat "$out/MANIFEST"
