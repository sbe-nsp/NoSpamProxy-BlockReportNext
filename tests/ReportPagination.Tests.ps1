$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "ReportOData.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$script:mode = "large"
$script:requests = 0
$script:consumed = 0
$script:totalRows = 100513
function Invoke-NspODataRequest {
    param($Path, $Query)
    $script:requests++
    switch ($script:mode) {
        "large" {
            $skip = [long]$Query["`$skip"]
            if ($script:requests -gt 1 -and $script:consumed -ne $skip) {
                throw "The previous page was not consumed before requesting the next page."
            }
            $remaining = $script:totalRows - $skip
            $size = [int][Math]::Min(500, $remaining)
            $values = @(for ($i = 0; $i -lt $size; $i++) { $skip + $i })
            return [pscustomobject]@{ value = $values }
        }
        "nextlink" {
            switch ($script:requests) {
                1 { return [pscustomobject]@{ value = @(1); "@odata.nextLink" = "/page2" } }
                2 { return [pscustomobject]@{ value = @(2); "@odata.nextLink" = "/page3" } }
                3 { return [pscustomobject]@{ value = @(3) } }
                default { throw "Unexpected request." }
            }
        }
        "cycle" {
            $link = if ($script:requests -eq 2) { "/page-b" } else { "/page-a" }
            return [pscustomobject]@{ value = @($script:requests); "@odata.nextLink" = $link }
        }
        "repeated-group" {
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ Name = "filter"; Scl = 1; MessageTrackSummary = @{ MailId = "a" } },
                [pscustomobject]@{ Name = "filter"; Scl = 1; MessageTrackSummary = @{ MailId = "b" } }
            ) }
        }
        "repeated-id" {
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ Id = 1; Name = "same" },
                [pscustomobject]@{ Id = 2; Name = "same" }
            ) }
        }
        "distinct-id" {
            $skip = [int]$Query["`$skip"]
            if ($skip -ge 4) { return [pscustomobject]@{ value = @() } }
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ Id = $skip + 1; Name = "same" },
                [pscustomobject]@{ Id = $skip + 2; Name = "same" }
            ) }
        }
        "report" {
            if ($Path -eq "/api/message-tracking/Actions") {
                if ($Query["`$apply"] -match "with countdistinct as UniqueCount") {
                    $count = if ($script:inconsistentActions) { 6 } else { 2 }
                    return [pscustomobject]@{ value = @(
                        [pscustomobject]@{ Name = "malwareScan"; Decision = "RejectPermanent"; n = $count; UniqueCount = 1 }
                    ) }
                }
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ Name = "malwareScan"; Decision = "RejectPermanent"; n = 5 },
                    [pscustomobject]@{ Name = "other"; Decision = "RejectPermanent"; n = 4 }
                ) }
            }
            if ($Path -eq "/api/message-tracking/Filters") {
                if ($Query["`$apply"] -notmatch "groupby\(\(Name,Scl\)," -or $Query["`$apply"] -match "MailId") {
                    throw "Filter events must be aggregated without per-message rows."
                }
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ Name = "filter"; Scl = 1; n = 100000 },
                    [pscustomobject]@{ Name = "filter"; Scl = 2; n = 2 },
                    [pscustomobject]@{ Name = "filter"; Scl = $null; n = 3 }
                ) }
            }
            if ($Path -eq "/api/message-tracking/MessageTrackSummaries" -and $Query["`$apply"] -match "groupby\(\(MailId\)") {
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ MailId = "mail-a"; n = 2 },
                    [pscustomobject]@{ MailId = $null; n = 3 }
                ) }
            }
            return [pscustomobject]@{ value = @() }
        }
        default { throw "Unexpected test mode." }
    }
}

Get-NspODataItems -Path "/large" | ForEach-Object {
    Assert-True ($_ -eq $script:consumed) "A paginated result was missing or duplicated."
    $script:consumed++
}
Assert-True ($script:consumed -eq 100513 -and $script:requests -eq 202) "More than 200 full pages must be processed completely."

$script:requests = 0
$script:consumed = 0
$script:totalRows = 100000
Get-NspODataItems -Path "/large" | ForEach-Object { $script:consumed++ }
Assert-True ($script:consumed -eq 100000 -and $script:requests -eq 201) "Exactly 200 full pages must be followed by an empty page."

$script:mode = "nextlink"
$script:requests = 0
$results = @(Get-NspODataItems -Path "/nextlink" -PageSize 2)
Assert-True (($results -join ",") -eq "1,2,3") "A short page with a next link must not end pagination."

$script:mode = "cycle"
$script:requests = 0
$failed = $false
try { Get-NspODataItems -Path "/cycle" -PageSize 2 | Out-Null }
catch {
    if ($_.Exception.Message -like "*repeated a next link*") { $failed = $true }
    else { throw }
}
Assert-True ($failed -and $script:requests -eq 3) "A multi-link pagination cycle must fail explicitly."

$script:mode = "repeated-group"
$script:requests = 0
$failed = $false
try {
    Get-NspODataItems -Path "/groups" -PageSize 2 -Query @{
        "`$apply" = "groupby((Name,Scl,MessageTrackSummary/MailId),aggregate(`$count as n))"
        "`$orderby" = "Name,Scl,MessageTrackSummary/MailId"
    } | Out-Null
}
catch {
    if ($_.Exception.Message -like "*repeated a page of ordered results*") { $failed = $true }
    else { throw }
}
Assert-True ($failed -and $script:requests -eq 2) "An ignored skip on grouped results must fail explicitly."

$script:mode = "repeated-id"
$script:requests = 0
$failed = $false
try { Get-NspODataItems -Path "/entities" -PageSize 2 -Query @{ "`$orderby" = "Name,Id" } | Out-Null }
catch {
    if ($_.Exception.Message -like "*repeated a page of ordered results*") { $failed = $true }
    else { throw }
}
Assert-True ($failed -and $script:requests -eq 2) "An ignored skip on ID-ordered entities must fail explicitly."

$script:mode = "distinct-id"
$script:requests = 0
$results = @(Get-NspODataItems -Path "/entities" -PageSize 2 -Query @{ "`$orderby" = "Name,Id" })
Assert-True ($results.Count -eq 4 -and $script:requests -eq 3) "Different entities with identical names must not be mistaken for repeated pages."

function Get-NspMalwareRejectEvidence { param($StartUtc, $EndUtc) return @{} }
function Get-NspAnalysisEvidence { param($OperationType, $StartUtc, $EndUtc) return @{} }
function Get-NspObservedUrlCounts { param($StartUtc, $EndUtc) return @{} }

$script:mode = "report"
$script:requests = 0
$script:inconsistentActions = $false
$end = [DateTime]::UtcNow.Date
$report = Get-NspODataPeriodReportData -StartUtc $end.AddDays(-1) -EndUtc $end
$filter = $report.FilterCounts["filter"]
Assert-True ($filter.Total -eq 100005 -and $filter.PositiveScl -eq 100002 -and $filter.Scl["(null)"] -eq 3) "Aggregated filter event counts must preserve their meaning."
Assert-True ($report.ActionCounts["malwareScan|RejectPermanent"] -eq 5 -and $report.ActionUniqueMessages["malwareScan|RejectPermanent"] -eq 1 -and $report.ActionUnattributedEvents["malwareScan|RejectPermanent"] -eq 3 -and $report.ActionUnattributedEvents["other|RejectPermanent"] -eq 4) "Aggregated action counts must preserve their meaning."
Assert-True ($report.RecalledMessages -eq 1 -and $report.UnattributedRecallCount -eq 1) "Streamed recall groups must preserve unique and unattributed counts."

$script:inconsistentActions = $true
$failed = $false
try { Get-NspODataPeriodReportData -StartUtc $end.AddDays(-1) -EndUtc $end | Out-Null }
catch {
    if ($_.Exception.Message -like "*inconsistent action aggregates*") { $failed = $true }
    else { throw }
}
Assert-True $failed "Inconsistent aggregate results must fail instead of producing incorrect counts."
Write-Host "Report pagination tests passed."
