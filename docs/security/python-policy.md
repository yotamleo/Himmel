# Python dependency policy

Status: enforced via pre-commit (epic #8, task #30).

## Pinning policy

Python dependencies in this repo are pinned via **`uv.lock`** (preferred). If a
project must export a flat list, generate `requirements*.txt` with
`--generate-hashes` so every package line carries a `--hash=sha256:` pin.

- `uv` is the canonical Python tool. See https://docs.astral.sh/uv/.
- Every `pyproject.toml` must ship a committed sibling `uv.lock`.
- Hand-edited `requirements.txt` files are rejected — they bypass tamper
  detection. Regenerate them, do not patch them.

## Install command

Reproducible install for a `uv` project:

```bash
uv sync
```

For a hashed `requirements.txt`:

```bash
uv pip install --require-hashes -r requirements.txt
# or
pip install --require-hashes -r requirements.txt
```

## Enforcement

Two pre-commit hooks run locally:

| Hook id              | Script                                  | What it checks |
|----------------------|-----------------------------------------|----------------|
| `uv-lock-integrity`  | `scripts/hooks/check-uv-lock.sh`        | Every `pyproject.toml` has a tracked sibling `uv.lock`; `uv lock --check` reports no drift (soft-skipped if `uv` is not installed locally). |
| `pip-hashes`         | `scripts/hooks/check-pip-hashes.sh`     | Every package line in a staged `requirements*.txt` carries `--hash=sha256:`. |

To regenerate a hashed requirements file:

```bash
uv pip compile pyproject.toml -o requirements.txt --generate-hashes
# or
pip-compile --generate-hashes pyproject.toml -o requirements.txt
```

## Reference

- Task brief: HIMMEL-84 python-uv-lock-verify (tracked in the operator's private handover repo)
- Epic plan: HIMMEL-19 security-tooling (tracked in the operator's private handover repo)
