param(
    [string]$KeyPath,
    [string]$ValueName,
    [string]$Value
)

function Update-Registry {
    param([string]$Key, [string]$Name, [string]$Data)
    if (-not (Test-Path $Key)) {
        New-Item -Path $Key -Force | Out-Null
    }
    Set-ItemProperty -Path $Key -Name $Name -Value $Data
    Write-Host "Set $Name under $Key"
}

Update-Registry -Key $KeyPath -Name $ValueName -Data $Value
