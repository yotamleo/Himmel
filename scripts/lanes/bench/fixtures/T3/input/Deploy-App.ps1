param(
    [string]$Environment = "staging",
    [switch]$Force
)

function Deploy-App {
    param([string]$Env)
    Write-Host "Deploying to $Env..."
    if ($Force) {
        Write-Host "Force flag set, skipping confirmation."
    }
}

Deploy-App -Env $Environment
Write-Host "Deployment complete."
