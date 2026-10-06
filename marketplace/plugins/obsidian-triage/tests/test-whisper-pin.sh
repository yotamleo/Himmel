#!/usr/bin/env bash
# HIMMEL-4675: faster-whisper + av are pinned to a pair that decodes, both media
# rungs install exactly that pair, and whisper-probe.py catches the av.open
# `metadata_errors` mismatch (av 19 dropped the kwarg faster-whisper 1.2.1 passes).
# Hermetic: fake av / faster_whisper modules, no install, no network.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools="$here/../tools"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/whisper-pin.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }

req="$tools/requirements-whisper.txt"
if grep -qE '^faster-whisper==[0-9.]+ ' "$req" 2>/dev/null; then ok "faster-whisper pinned with =="; else no "faster-whisper pinned with =="; fi
if grep -qE '^av==[0-9.]+ ' "$req" 2>/dev/null; then ok "av pinned with =="; else no "av pinned with =="; fi
if grep -qE '^ +--hash=sha256:' "$req" 2>/dev/null; then ok "closure carries hashes"; else no "closure carries hashes"; fi

# Both rungs hand uv the requirements file, never a bare `--with faster-whisper`.
cat > "$tmp/cmd.py" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path
tools = Path(sys.argv[1])
seen = {}
def fake_run(cmd, **kw):
    seen["cmd"] = cmd
    return subprocess.CompletedProcess(cmd, 0, "text\n", "")
for name in ("ig-media-fetch.py", "x-media-fetch.py"):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_")[:-3], tools / name)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.shutil.which = lambda _n: "/usr/bin/uv"
    mod.subprocess.run = fake_run
    mod.whisper_transcribe(Path(sys.argv[2]) / "a.wav", "base")
    cmd = seen["cmd"]
    i = cmd.index("--with-requirements") if "--with-requirements" in cmd else -1
    good = i >= 0 and Path(cmd[i + 1]) == tools / "requirements-whisper.txt" and "faster-whisper" not in cmd
    print(("OK " if good else "BAD ") + name + " " + " ".join(cmd[:8]))
PY
out=$(python3 "$tmp/cmd.py" "$tools" "$tmp" 2>&1 || true)
for n in ig-media-fetch.py x-media-fetch.py; do
    if grep -q "^OK $n" <<< "$out"; then ok "$n installs the pinned pair"; else no "$n installs the pinned pair"; printf '%s\n' "$out"; fi
done

# whisper-probe against a fake av that has dropped metadata_errors, then one that has it.
mk_fakes() { # $1 dir, $2 = "drop" | "keep"
    mkdir -p "$1/faster_whisper"
    if [ "$2" = drop ]; then
        printf '__version__ = "19.0.1"\ndef open(path, mode="r", **kw):\n    if "metadata_errors" in kw:\n        raise TypeError("open() got an unexpected keyword argument metadata_errors")\n    return path\n' > "$1/av.py"
    else
        printf '__version__ = "18.0.0"\ndef open(path, mode="r", **kw):\n    return path\n' > "$1/av.py"
    fi
    printf '__version__ = "1.2.1"\nimport av\ndef decode_audio(p):\n    av.open(p, mode="r", metadata_errors="ignore")\n    return [0.0] * 3200\n' > "$1/faster_whisper/__init__.py"
}
mk_fakes "$tmp/drop" drop
mk_fakes "$tmp/keep" keep
rc=0; out=$(PYTHONPATH="$tmp/drop" python3 "$tools/whisper-probe.py" 2>&1) || rc=$?
if [ "$rc" = 1 ] && grep -q "metadata_errors" <<< "$out"; then ok "probe fails on the metadata_errors mismatch"; else no "probe fails on the metadata_errors mismatch (rc=$rc: $out)"; fi
rc=0; out=$(PYTHONPATH="$tmp/keep" python3 "$tools/whisper-probe.py" 2>&1) || rc=$?
if [ "$rc" = 0 ] && grep -q "whisper-probe: ok faster-whisper=1.2.1 av=18.0.0" <<< "$out"; then ok "probe passes on a compatible pair"; else no "probe passes on a compatible pair (rc=$rc: $out)"; fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
