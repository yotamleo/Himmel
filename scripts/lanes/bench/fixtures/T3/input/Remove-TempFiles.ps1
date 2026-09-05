param([string]$Path = $env:TEMP)

function Remove-TempFiles {
    param([string]$TargetPath)
    Get-ChildItem -Path $TargetPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Remove-TempFiles -TargetPath $Path
Write-Host "Cleanup finished for $Path"
