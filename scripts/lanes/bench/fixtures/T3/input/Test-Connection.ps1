param([string]$ComputerName = "localhost")

function Test-ConnectionSafe {
    param([string]$Target)
    $result = Test-Connection -ComputerName $Target -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($result) {
        Write-Host "$Target is reachable"
    } else {
        Write-Host "$Target is unreachable"
    }
}

Test-ConnectionSafe -Target $ComputerName
