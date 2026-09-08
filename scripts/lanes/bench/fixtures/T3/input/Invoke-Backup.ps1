param(
    [string]$Source,
    [string]$Destination
)

function Invoke-Backup {
    param([string]$From, [string]$To)
    if (-not (Test-Path $From)) {
        throw "Source path does not exist: $From"
    }
    Copy-Item -Path $From -Destination $To -Recurse -Force
    Write-Host "Backup complete: $From -> $To"
}

Invoke-Backup -From $Source -To $Destination
