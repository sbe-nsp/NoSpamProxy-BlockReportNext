$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "ReportOData.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Initialize-NspOData {
    param($BaseUrl, $ApiKey)
    $script:initializations++
}

function Get-NspODataPeriodReportData {
    param($StartUtc, $EndUtc)
    return [pscustomobject]@{ StartUtc = $StartUtc; EndUtc = $EndUtc }
}

function Get-NspTopSpammers {
    param($StartUtc, $EndUtc)
    $script:topRange = [pscustomobject]@{ StartUtc = $StartUtc; EndUtc = $EndUtc }
    return @()
}

foreach ($testCase in @(
        @{ Expected = 14; UseDefault = $true },
        @{ Expected = 1; UseDefault = $false },
        @{ Expected = 7; UseDefault = $false },
        @{ Expected = 30; UseDefault = $false }
    )) {
    $script:initializations = 0
    $script:topRange = $null
    $arguments = @{ BaseUrl = "https://example.invalid"; ApiKey = "fixture" }
    if (-not $testCase.UseDefault) { $arguments.Days = $testCase.Expected }
    $before = [DateTime]::UtcNow.Date
    $report = Get-NspODataReportData @arguments
    $after = [DateTime]::UtcNow.Date
    $end = $report.Current.EndUtc
    $days = $testCase.Expected
    Assert-True ($end -eq $before -or $end -eq $after) "Current period must end at today's UTC midnight."
    Assert-True ($end.Kind -eq [DateTimeKind]::Utc) "Period boundaries must use UTC."
    Assert-True ($report.Current.StartUtc -eq $end.AddDays(-$days)) "Current period length is incorrect."
    Assert-True ($report.Comparison.EndUtc -eq $report.Current.StartUtc) "Periods must be adjacent."
    Assert-True ($report.Comparison.StartUtc -eq $report.Comparison.EndUtc.AddDays(-$days)) "Comparison period length is incorrect."
    Assert-True ($script:topRange.StartUtc -eq $report.Current.StartUtc -and $script:topRange.EndUtc -eq $end) "Recipient ranking must use the current period."
    Assert-True ($script:initializations -eq 1) "Valid requests must initialize the OData connection."
}

foreach ($invalid in @(0, -1)) {
    $rejected = $false
    try { Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days $invalid | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $_.FullyQualifiedErrorId -like "ParameterArgumentValidationError*" }
    Assert-True $rejected "Non-positive period lengths must be rejected."

    $rejected = $false
    try { & (Join-Path $root "Get-PermanentlyBlocked.ps1") -Help -Days $invalid | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $_.FullyQualifiedErrorId -like "ParameterArgumentValidationError*" }
    Assert-True $rejected "The public script must reject non-positive period lengths."
}

$script:initializations = 0
$rejected = $false
try { Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days ([int]::MaxValue) | Out-Null }
catch {
    if ($_.Exception.Message -like "*too large to calculate two valid UTC periods*") { $rejected = $true }
    else { throw }
}
Assert-True ($rejected -and $script:initializations -eq 0) "Out-of-range dates must fail before OData initialization."
Write-Host "Report period tests passed."
