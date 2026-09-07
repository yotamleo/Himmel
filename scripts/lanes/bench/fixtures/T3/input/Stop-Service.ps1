param([string]$Name)

function Stop-ServiceSafe {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warning "Service $ServiceName not found."
        return
    }
    if ($svc.Status -eq "Running") {
        Stop-Service -Name $ServiceName -Force
        Write-Host "Stopped $ServiceName"
    } else {
        Write-Host "$ServiceName already stopped"
    }
}

Stop-ServiceSafe -ServiceName $Name
