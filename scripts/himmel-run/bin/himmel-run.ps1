#!/usr/bin/env pwsh
$Dir = Split-Path -Parent $PSScriptRoot
& node (Join-Path $Dir 'dist/index.js') @args
exit $LASTEXITCODE
