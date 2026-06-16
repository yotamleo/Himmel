pip install pre-commit
pre-commit install
pre-commit install --hook-type pre-push
pre-commit install --hook-type commit-msg
Write-Host "Done. Run 'pre-commit run --all-files' to validate all hooks now."
