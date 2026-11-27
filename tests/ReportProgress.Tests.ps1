$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "ReportOData.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Write-Progress {
    param($Id, $Activity, $Status)
    $script:displayedActivity = $Activity
}
Write-NspReportProgress -Status "Aktueller Zeitraum: Sandbox-Analyse" -Stopwatch ([Diagnostics.Stopwatch]::StartNew())
Assert-True ($script:displayedActivity -match "Sandbox-Analyse.*Laufzeit: \d{2}:\d{2}") "Minimal progress views must show the step and elapsed time."
Remove-Item Function:\Write-Progress

$fixturePath = Join-Path $env:TEMP ("nsp-progress-test-" + [guid]::NewGuid().ToString("N") + ".ps1")
$fixture = @'
function Get-NspODataReportData {
    param($BaseUrl, $ApiKey, $Days, $ComparisonDays, [switch] $NoComparison)
    if ($ApiKey -eq "failure") { throw "fixture request failed" }
    Write-Progress -Activity "NoSpamProxy-Bericht" -Status "Aktueller Zeitraum: Sandbox-Analyse"
    Start-Sleep -Milliseconds 2300
    return [pscustomobject]@{ Days = $Days; ComparisonDays = $ComparisonDays; NoComparison = [bool]$NoComparison; Nested = @{ Value = 42 } }
}
'@

function Write-NspReportProgress {
    param($Status, $Stopwatch)
    $script:updates.Add([pscustomobject]@{ Status = $Status; Elapsed = $Stopwatch.Elapsed.TotalSeconds })
}

try {
    [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($true))
    $script:updates = [System.Collections.Generic.List[object]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $report = Get-NspODataReportDataWithProgress -BaseUrl "https://example.invalid" -ApiKey "fixture" `
        -Days 7 -ComparisonDays 14 -ODataScriptPath $fixturePath -Stopwatch $clock
    Assert-True ($report.Days -eq 7 -and $report.ComparisonDays -eq 14 -and -not $report.NoComparison -and $report.Nested.Value -eq 42) "Worker must forward the custom comparison and return the original report data."
    $stepUpdates = @($script:updates | Where-Object { $_.Status -eq "Aktueller Zeitraum: Sandbox-Analyse" })
    Assert-True ($stepUpdates.Count -ge 2) "A long-running request must refresh its current step."
    Assert-True (($stepUpdates[-1].Elapsed - $stepUpdates[0].Elapsed) -ge 1) "Elapsed time must advance while the request is running."
    $report = Get-NspODataReportDataWithProgress -BaseUrl "https://example.invalid" -ApiKey "fixture" `
        -Days 7 -NoComparison -ODataScriptPath $fixturePath -Stopwatch ([Diagnostics.Stopwatch]::StartNew())
    Assert-True ($report.NoComparison) "Worker must forward disabled comparison."

    $failed = $false
    try {
        Get-NspODataReportDataWithProgress -BaseUrl "https://example.invalid" -ApiKey "failure" `
            -Days 7 -ODataScriptPath $fixturePath -Stopwatch ([Diagnostics.Stopwatch]::StartNew()) | Out-Null
    }
    catch {
        if ($_.Exception.Message -like "*fixture request failed*") { $failed = $true }
        else { throw }
    }
    Assert-True $failed "Worker failures must be surfaced to the caller."

    function Get-NspODataReportData {
        param($BaseUrl, $ApiKey, $Days, $ComparisonDays, [switch] $NoComparison)
        return [pscustomobject]@{ Days = $Days; ComparisonDays = $ComparisonDays; NoComparison = [bool]$NoComparison }
    }
    $savedPreference = $ProgressPreference
    try {
        $ProgressPreference = "SilentlyContinue"
        $before = $script:updates.Count
        $report = Get-NspODataReportDataWithProgress -BaseUrl "https://example.invalid" -ApiKey "fixture" `
            -Days 3 -ComparisonDays 5 -ODataScriptPath "not-used" -Stopwatch ([Diagnostics.Stopwatch]::StartNew())
        Assert-True ($report.Days -eq 3 -and $report.ComparisonDays -eq 5 -and $script:updates.Count -eq $before) "Suppressed progress must forward the custom comparison without updates."
        $report = Get-NspODataReportDataWithProgress -BaseUrl "https://example.invalid" -ApiKey "fixture" `
            -Days 3 -NoComparison -ODataScriptPath "not-used" -Stopwatch ([Diagnostics.Stopwatch]::StartNew())
        Assert-True ($report.NoComparison) "Suppressed progress must forward disabled comparison."
    }
    finally { $ProgressPreference = $savedPreference }
}
finally {
    if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
}

Write-Host "Report progress tests passed."
