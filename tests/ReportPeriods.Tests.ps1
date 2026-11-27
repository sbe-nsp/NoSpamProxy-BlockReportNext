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
    $script:periodCalls++
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
    $script:periodCalls = 0
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
    Assert-True ($script:periodCalls -eq 2) "Default reports must query both periods."
}

$script:periodCalls = 0
$report = Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days 7 -ComparisonDays 14
Assert-True ($report.Comparison.EndUtc -eq $report.Current.StartUtc -and
    $report.Comparison.StartUtc -eq $report.Current.StartUtc.AddDays(-14)) "Custom comparison must span the requested adjacent days."
Assert-True ($script:periodCalls -eq 2) "Custom comparison must query both periods."

$script:periodCalls = 0
$report = Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days 7 -NoComparison
Assert-True ($null -eq $report.Comparison -and $script:periodCalls -eq 1) "Disabled comparison must not query a comparison period."
Assert-True ($script:topRange.StartUtc -eq $report.Current.StartUtc) "Ranking must still use the current period."

foreach ($invalid in @(0, -1)) {
    $rejected = $false
    try { Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days $invalid | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $_.FullyQualifiedErrorId -like "ParameterArgumentValidationError*" }
    Assert-True $rejected "Non-positive period lengths must be rejected."

    $rejected = $false
    try { & (Join-Path $root "Get-PermanentlyBlocked.ps1") -Help -Days $invalid | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $_.FullyQualifiedErrorId -like "ParameterArgumentValidationError*" }
    Assert-True $rejected "The public script must reject non-positive period lengths."
    $rejected = $false
    try { & (Join-Path $root "Get-PermanentlyBlocked.ps1") -Help -ComparisonDays $invalid | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $true }
    Assert-True $rejected "The public script must reject non-positive comparison lengths."
}

foreach ($arguments in @(
        @{ Days = [int]::MaxValue },
        @{ Days = 1; ComparisonDays = [int]::MaxValue },
        @{ Days = [int]::MaxValue; NoComparison = $true }
    )) {
    $script:initializations = 0
    $rejected = $false
    try { Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" @arguments | Out-Null }
    catch {
        if ($_.Exception.Message -like "*too large to calculate valid UTC periods*") { $rejected = $true }
        else { throw }
    }
    Assert-True ($rejected -and $script:initializations -eq 0) "Out-of-range dates must fail before OData initialization."
}

$available = [int]([DateTime]::UtcNow.Date - [DateTime]::MinValue).TotalDays
$report = Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -Days $available -NoComparison
Assert-True ($report.Current.StartUtc -eq [DateTime]::MinValue) "Without comparison the entire valid date range must be available."
foreach ($public in @($false, $true)) {
    $script:initializations = 0
    $rejected = $false
    try {
        if ($public) { & (Join-Path $root "Get-PermanentlyBlocked.ps1") -Help -NoComparison -ComparisonDays 2 | Out-Null }
        else { Get-NspODataReportData -BaseUrl "https://example.invalid" -ApiKey "fixture" -NoComparison -ComparisonDays 2 | Out-Null }
    }
    catch {
        if ($_.Exception.Message -like "*cannot be combined*") { $rejected = $true } else { throw }
    }
    Assert-True ($rejected -and $script:initializations -eq 0) "Conflicting options must fail before initialization."
}
Write-Host "Report period tests passed."
