#!/usr/bin/env python3
"""
Build a cloud-init NoCloud seed ISO (volume id 'cidata') for a Linux-host
VirtualBox Ubuntu guest — the seed docs/setup/vms.md's "Linux host" section
describes. Adapted from a working one-off script.

Dependency: pycdlib (only needed to actually write the ISO — `--dry-run`
skips it). Install into the dedicated venv, since the system python is
externally-managed:

    python3 -m venv ~/.himmel/vm-venv
    ~/.himmel/vm-venv/bin/pip install pycdlib python-dotenv
    ~/.himmel/vm-venv/bin/python scripts/machine-setup/make-cloudinit-seed.py \\
        --password-hash '$6$...'

No plaintext password argv option exists — argv is visible in shell history
and `ps` on a multi-user box. Rely on the `ubuntu_vm_pass` fallback already in
the primary checkout's .env (nothing to type — `--user`/no flags is enough)
or `--password-file <path>`, or precompute a hash yourself and pass
`--password-hash`. Do NOT pass the plaintext as an inline env assignment
(`ubuntu_vm_pass=... python ...`) — that still lands it in shell history and
the process environment, the exact leak this design avoids; env support
exists only so the .env loader can feed it in-process. Never prints or logs
the plaintext password or the derived hash — `--dry-run` redacts the passwd
line in its printed user-data.

The generated user's password is for the VirtualBox console (and cloud-init
bring-up) only: `ssh_pwauth` stays off, so SSH accepts key auth alone unless
`--allow-password-ssh` is passed.

The written ISO embeds an offline-crackable password hash, so it's created
mode 0600 (not umask-default) rather than left group/world-readable.

Usage:
  python scripts/machine-setup/make-cloudinit-seed.py
      # (reads ubuntu_vm_pass from the primary checkout's .env)
  python scripts/machine-setup/make-cloudinit-seed.py --password-file secret.txt
  python scripts/machine-setup/make-cloudinit-seed.py --password-hash '$6$...'
  python scripts/machine-setup/make-cloudinit-seed.py --password-hash x --dry-run
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_HOSTNAME = "himmel-vm"
DEFAULT_INSTANCE_ID = "himmel-vm-001"
DEFAULT_OUT = "~/VirtualBox VMs/images/cidata.iso"
DEFAULT_PUBKEY = "~/.ssh/id_ed25519.pub"
PACKAGES = ["git", "jq", "curl", "rsync", "openssh-server"]
# A crypt(3) hash: "$<id>$[rounds=N$]<non-empty salt>$<non-empty hash>",
# e.g. $6$salt$hash or $6$rounds=5000$salt$hash. Empty salt/hash segments
# (e.g. a bare "$6$") are rejected — they're not a real hash.
_PASSWORD_HASH_RE = re.compile(r"^\$[0-9a-z]+(\$rounds=\d+)?\$[^\s$]+\$[^\s$]+$")
# A plausible OpenSSH public-key line: "<key-type> <base64-payload>[ comment]".
_PUBKEY_RE = re.compile(
    r"^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|"
    r"sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) "
    r"[A-Za-z0-9+/=]+( \S.*)?$"
)


def _env_path():
    """Path to the PRIMARY checkout's .env (mirrors scripts/lib/vmsdk.py's
    worktree-safe resolution — a worktree has no .env of its own)."""
    here = Path(__file__).resolve().parent
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=here, capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip():
            return (here / r.stdout.strip()).resolve().parent / ".env"
    except Exception:
        pass
    return here.parents[1] / ".env"


def _load_dotenv():
    try:
        from dotenv import load_dotenv
    except ImportError:
        sys.exit("Missing: pip install python-dotenv (or use ~/.himmel/vm-venv)")
    load_dotenv(_env_path())


def _read_password_file(path):
    p = Path(os.path.expanduser(path))
    try:
        text = p.read_text()
    except OSError as e:
        sys.exit(f"could not read --password-file {p}: {e}")
    # Strip exactly one trailing newline sequence (CRLF or LF) — not a
    # general rstrip, so a password that deliberately ends in a space
    # survives untouched.
    if text.endswith("\r\n"):
        text = text[:-2]
    elif text.endswith("\n"):
        text = text[:-1]
    return text


def _require_nonblank_password(plaintext, source_desc):
    """Refuse an empty/whitespace-only plaintext — hashing it would
    provision the NOPASSWD-sudo user with a blank console password.
    Exits 2 (a distinct, specific error) on a blank value."""
    if plaintext is None or plaintext.strip() == "":
        print(f"make-cloudinit-seed: {source_desc} is empty — refusing to "
              "provision a blank console password", file=sys.stderr)
        sys.exit(2)
    return plaintext


def _require_no_embedded_newlines(plaintext, source_desc):
    """A password with an embedded newline hashes differently through the
    openssl -stdin fallback (which only sees its first line) than through
    stdlib crypt (which hashes the whole string) — never an intended
    console password. Checked after the one trailing-newline strip, so
    only an INTERNAL newline trips this. Exits 2."""
    if "\n" in plaintext or "\r" in plaintext:
        print(f"make-cloudinit-seed: {source_desc} contains an embedded "
              "newline — refusing (a console password must be one line)",
              file=sys.stderr)
        sys.exit(2)
    return plaintext


def _validate_pubkey(pubkey_text, path):
    """Take the first non-empty line and require it to look like a real
    OpenSSH public key. An empty or malformed --pubkey would otherwise
    silently ship a guest nobody can reach via the default key-only path.
    Exits 2 (naming the path) on failure."""
    first_line = ""
    for line in pubkey_text.splitlines():
        if line.strip():
            first_line = line.strip()
            break
    if not first_line or not _PUBKEY_RE.match(first_line):
        print(f"make-cloudinit-seed: {path} does not contain a valid SSH "
              "public key (expected e.g. \"ssh-ed25519 AAAA... comment\")",
              file=sys.stderr)
        sys.exit(2)
    return first_line


def _scrubbed_env():
    """A copy of os.environ with anything credential-shaped removed —
    password/secret/token, and the *_API_KEY / *_CREDENTIAL / *_AUTH shapes
    a primary .env also carries. subprocess.run() inherits the full process
    environment by default — including ubuntu_vm_pass once the .env loader
    has put it there — so the openssl fallback below must not see any of it,
    even though the plaintext is only ever passed via stdin."""
    denylist = ("pass", "secret", "token", "key", "credential", "auth")
    return {
        k: v for k, v in os.environ.items()
        if k != "ubuntu_vm_pass" and not any(d in k.lower() for d in denylist)
    }


def _hash_password(password):
    """Derive a sha512-crypt hash for a plain password. Never prints it."""
    try:
        import crypt
    except ImportError:
        crypt = None
    if crypt is not None:
        print("make-cloudinit-seed: hashing password via stdlib crypt (sha512-crypt)",
              file=sys.stderr)
        return crypt.crypt(password, crypt.mksalt(crypt.METHOD_SHA512))
    print("make-cloudinit-seed: stdlib crypt is unavailable (removed in Python "
          "3.13+) — falling back to `openssl passwd -6`", file=sys.stderr)
    try:
        r = subprocess.run(
            ["openssl", "passwd", "-6", "-stdin"],
            input=password, capture_output=True, text=True, timeout=10,
            env=_scrubbed_env(),
        )
    except FileNotFoundError:
        sys.exit("Missing: neither stdlib crypt nor `openssl` on PATH — "
                  "pass --password-hash instead")
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("openssl passwd -6 failed to produce a password hash")
    return r.stdout.strip()


def _validate_password_hash(h):
    """Reject anything that isn't a plain crypt(3) hash shape before it gets
    embedded in the seed — whitespace or quote characters would otherwise
    need to survive raw interpolation. Exits 2 (not 1) on a bad shape."""
    if not _PASSWORD_HASH_RE.match(h) or '"' in h or "'" in h:
        print("make-cloudinit-seed: --password-hash does not look like a crypt(3) "
              "hash (expected \"$<id>$...\" with no whitespace or quotes)",
              file=sys.stderr)
        sys.exit(2)
    return h


def build_user_data(user, password_hash, pubkey, hostname, instance_id,
                     redact=False, allow_password_ssh=False):
    passwd_field = "***REDACTED***" if redact else password_hash
    # user/hostname/pubkey/passwd are operator- or file-supplied scalars; run
    # them through json.dumps (a JSON string is a valid YAML double-quoted
    # scalar) so a stray colon/quote/newline can't restructure the document.
    return f"""#cloud-config
hostname: {json.dumps(hostname)}
manage_etc_hosts: true
ssh_pwauth: {"true" if allow_password_ssh else "false"}
users:
  - name: {json.dumps(user)}
    shell: /bin/bash
    lock_passwd: false
    passwd: {json.dumps(passwd_field)}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [sudo, adm]
    ssh_authorized_keys:
      - {json.dumps(pubkey)}
package_update: true
packages: [{", ".join(PACKAGES)}]
runcmd:
  - [ systemctl, enable, --now, ssh ]
  - [ systemctl, mask, sleep.target, suspend.target, hibernate.target, hybrid-sleep.target ]
final_message: {json.dumps(f"{hostname} cloud-init done after $UPTIME s")}
"""


def build_meta_data(hostname, instance_id):
    return f"instance-id: {json.dumps(instance_id)}\nlocal-hostname: {json.dumps(hostname)}\n"


def _open_private(path):
    """Create/truncate path and guarantee it ends up mode 0600, whether it
    was just created or already existed with looser permissions. The
    os.open() mode argument only applies at creation time — it has no
    effect on a pre-existing file — so an unconditional fchmod is required
    to actually cover that case. Returns the open fd; caller closes it.
    On native Windows Python (no os.fchmod), falls back to a path-based
    chmod, since POSIX mode bits there are advisory anyway (NTFS ACLs
    govern). A pre-existing symlink at the path is refused (O_NOFOLLOW ->
    OSError ELOOP) rather than followed, so the mode guard can never be
    redirected at another file."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags, 0o600)
    if hasattr(os, "fchmod"):
        os.fchmod(fd, 0o600)
    else:
        # native Windows Python has no fchmod; POSIX mode bits are advisory
        # there anyway (NTFS ACLs govern), so path-based chmod is the best
        # available equivalent.
        os.chmod(str(path), 0o600)
    return fd


def write_iso(out_path, user_data, meta_data):
    import pycdlib  # deferred: only needed to actually write the ISO

    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
    for name, body in (("user-data", user_data), ("meta-data", meta_data)):
        data = body.encode()
        iso.add_fp(io.BytesIO(data), len(data), f"/{name.upper().replace('-', '_')}.;1",
                   rr_name=name, joliet_path=f"/{name}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # The ISO embeds an offline-crackable password hash — create it 0600
    # (not umask-default) before pycdlib opens and fills it, so the file is
    # never briefly world/group-readable, and never stays loose if the
    # path already existed. The write goes through that same descriptor, so
    # there is no pathname reopen (and no symlink-swap window) between the
    # mode guard and the write.
    fd = _open_private(out_path)
    with os.fdopen(fd, "wb") as fp:
        iso.write_fp(fp)
    iso.close()


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--user", default=None,
                    help="guest username (default: $ubuntu_vm_user, else the "
                         "primary checkout's .env)")
    pw = p.add_mutually_exclusive_group()
    pw.add_argument("--password-hash", help="a pre-computed crypt(3) hash, used as-is")
    pw.add_argument("--password-file",
                     help="path to a file holding the plaintext password (one "
                          "trailing newline stripped); hashed in-process, never "
                          "printed. Neither flag given: falls back to "
                          "$ubuntu_vm_pass (env, else the primary checkout's .env)")
    p.add_argument("--pubkey", default=DEFAULT_PUBKEY,
                    help=f"SSH public key file to embed (default: {DEFAULT_PUBKEY})")
    p.add_argument("--out", default=DEFAULT_OUT,
                    help=f"seed ISO path to write (default: {DEFAULT_OUT!r})")
    p.add_argument("--hostname", default=DEFAULT_HOSTNAME)
    p.add_argument("--instance-id", default=DEFAULT_INSTANCE_ID)
    p.add_argument("--allow-password-ssh", action="store_true",
                    help="also enable SSH password auth (ssh_pwauth). Off by "
                         "default — the password is for the VirtualBox console "
                         "only; SSH stays key-only via --pubkey")
    p.add_argument("--dry-run", action="store_true",
                    help="print the user-data (passwd line redacted) instead of "
                         "writing the ISO")
    return p.parse_args(argv)


def resolve_password_hash(args):
    if args.password_hash is not None:
        # Explicitly given (even "") — validate rather than silently
        # falling through to the file/env source below.
        return _validate_password_hash(args.password_hash)
    if args.password_file:
        source_desc = f"--password-file {args.password_file}"
        plaintext = _read_password_file(args.password_file)
        _require_nonblank_password(plaintext, source_desc)
    else:
        # None = not set anywhere ("no password source", below); "" (or
        # whitespace-only) = a source WAS found but is blank — a distinct
        # error via _require_nonblank_password, not silently accepted.
        source_desc = "ubuntu_vm_pass"
        plaintext = os.environ.get("ubuntu_vm_pass")
        if plaintext is None:
            _load_dotenv()
            plaintext = os.environ.get("ubuntu_vm_pass")
        if plaintext is None:
            sys.exit("no password source: pass --password-hash, --password-file, "
                      "or set ubuntu_vm_pass (env or .env)")
        _require_nonblank_password(plaintext, source_desc)
    _require_no_embedded_newlines(plaintext, source_desc)
    return _validate_password_hash(_hash_password(plaintext))


def main(argv=None):
    args = parse_args(argv)

    user = args.user or os.environ.get("ubuntu_vm_user")
    if not user:
        _load_dotenv()
        user = os.environ.get("ubuntu_vm_user")
    if not user:
        sys.exit("--user not given and ubuntu_vm_user is not set (env or .env)")

    pubkey_path = Path(os.path.expanduser(args.pubkey))
    try:
        pubkey_text = pubkey_path.read_text()
    except OSError as e:
        sys.exit(f"could not read pubkey {pubkey_path}: {e}")
    pubkey = _validate_pubkey(pubkey_text, pubkey_path)

    password_hash = resolve_password_hash(args)

    if args.dry_run:
        print(build_user_data(user, password_hash, pubkey, args.hostname,
                               args.instance_id, redact=True,
                               allow_password_ssh=args.allow_password_ssh), end="")
        return

    user_data = build_user_data(user, password_hash, pubkey, args.hostname,
                                 args.instance_id,
                                 allow_password_ssh=args.allow_password_ssh)
    meta_data = build_meta_data(args.hostname, args.instance_id)
    out_path = Path(os.path.expanduser(args.out))
    write_iso(out_path, user_data, meta_data)
    print(f"seed written: {out_path} ({out_path.stat().st_size} bytes) user={user}")


if __name__ == "__main__":
    main()
