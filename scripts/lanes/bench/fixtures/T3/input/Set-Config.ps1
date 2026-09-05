param(
    [string]$ConfigPath,
    [hashtable]$Values
)

function Set-Config {
    param([string]$Path, [hashtable]$Data)
    $json = $Data | ConvertTo-Json -Depth 5
    Set-Content -Path $Path -Value $json -Encoding UTF8
    Write-Host "Config written to $Path"
}

Set-Config -Path $ConfigPath -Data $Values
