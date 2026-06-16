#!/usr/bin/env bash
set -e

if command -v python3 &>/dev/null; then
  PYTHON=python3
elif command -v python &>/dev/null; then
  PYTHON=python
else
  echo "ERROR: python/python3 not found. Install Python 3.8+ first." >&2
  exit 1
fi

echo "==> Installing pre-commit..."
$PYTHON -m pip install pre-commit --quiet

echo "==> Installing git hooks..."
$PYTHON -m pre_commit install
$PYTHON -m pre_commit install --hook-type pre-push
$PYTHON -m pre_commit install --hook-type commit-msg

echo "==> Done. Run '$PYTHON -m pre_commit run --all-files' to validate all hooks now."
