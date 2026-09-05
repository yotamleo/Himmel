function Get-Status {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warning "Service $ServiceName not found."
        return
    }
    [PSCustomObject]@{
        Name   = $svc.Name
        Status = $svc.Status
    }
}

Get-Status -ServiceName "Spooler"
