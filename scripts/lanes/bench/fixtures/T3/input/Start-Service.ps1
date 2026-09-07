param([string]$Name)

function Start-ServiceSafe {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warning "Service $ServiceName not found."
        return
    }
    if ($svc.Status -ne "Running") {
        Start-Service -Name $ServiceName
        Write-Host "Started $ServiceName"
    } else {
        Write-Host "$ServiceName already running"
    }
}

Start-ServiceSafe -ServiceName $Name
