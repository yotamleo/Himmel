function New-Report {
    param(
        [string]$Title,
        [string[]]$Lines
    )
    $report = @()
    $report += "# $Title"
    $report += ""
    foreach ($line in $Lines) {
        $report += "- $line"
    }
    return $report -join "`n"
}

$result = New-Report -Title "Weekly Summary" -Lines @("Item one", "Item two")
Write-Output $result
