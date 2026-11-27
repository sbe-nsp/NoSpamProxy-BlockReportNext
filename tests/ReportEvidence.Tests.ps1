$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "ReportOData.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$script:end = [DateTime]::UtcNow.Date
$script:start = $script:end.AddDays(-1)
$script:mode = "analysis"
$script:consumed = 0
$script:checkStreaming = $false

function New-OperationRow {
    param([string] $TrackId, [string] $Type, [string] $Data, [DateTime] $Created = $script:start)
    return [pscustomobject]@{
        MessageTrackId = $TrackId
        Created = $Created.ToString("o")
        Operation = [pscustomobject]@{ Type = $Type; Data = $Data }
    }
}

function Get-NspODataItems {
    param($Path, $PageSize, $Query)
    if ($Path -ne "/api/message-tracking/MessageOperations" -or $PageSize -ne 500) {
        throw "Operation records must use 500-row pages."
    }
    if ($script:mode -eq "invalid-time") {
        New-OperationRow "one" "SandboxAnalysis" '{}' $script:end
        return
    }
    if ($script:mode -eq "invalid-type") {
        New-OperationRow "one" "Other" '{}'
        return
    }
    if ($script:mode -eq "invalid-json") {
        New-OperationRow "one" "SandboxAnalysis" 'not json'
        return
    }
    if ($script:mode -eq "many-malware") {
        $script:malwareRequests++
        if ($Query["`$filter"] -notmatch "^MessageTrackId in \(([^)]+)\)") { throw "Missing malware ID batch." }
        foreach ($id in $Matches[1].Split(",")) {
            New-OperationRow $id "MalwareScan" '{"infectedMailParts":[]}'
        }
        return
    }
    if ($script:mode -eq "malware") {
        New-OperationRow "111" "MalwareScan" '{"infectedMailParts":[{},{}]}'
        New-OperationRow "222" "MalwareScan" '{}'
        return
    }
    if ($script:mode -eq "wrong-malware-id") {
        New-OperationRow "999" "MalwareScan" '{"infectedMailParts":[]}'
        return
    }

    $type = if ($Query["`$filter"] -match "SandboxAnalysis") { "SandboxAnalysis" } else { "DeepFileAnalysis" }
    if ($type -eq "SandboxAnalysis") {
        New-OperationRow "one" $type '{"sandboxAnalysisStatus":"NoMalwareFound","executionStatus":"Completed","sandboxAnalysisResults":[{"status":"Clean"}]}'
        if ($script:checkStreaming -and $script:consumed -ne 1) { throw "Operation records were buffered before processing." }
        New-OperationRow "ONE" $type '{"sandboxAnalysisStatus":"Found","executionStatus":"Completed","sandboxAnalysisResults":[{"status":"Infected"}]}'
        New-OperationRow "two" $type '{"sandboxAnalysisStatus":"Unknown","sandboxAnalysisResults":[{"status":"Unknown"}]}'
    }
    else {
        New-OperationRow "track-a" $type '{"deepFileAnalysisStatus":"NoMalwareFound","results":[]}'
        New-OperationRow "track-a" $type '{"deepFileAnalysisStatus":"Found","results":[{"status":"Infected"},{"status":"Infected"}]}'
    }
}

function Get-NspODataApplyRows {
    param($Path, $Apply, $OrderBy)
    if ($script:mode -eq "many-malware") {
        foreach ($id in 1..201) {
            [pscustomobject]@{ MessageTrackId = [string]$id; MessageTrackSummary = @{ MailId = "mail-$id" }; n = 1 }
        }
        return
    }
    [pscustomobject]@{ MessageTrackId = "111"; MessageTrackSummary = @{ MailId = "mail-a" }; n = 2 }
    [pscustomobject]@{ MessageTrackId = "222"; MessageTrackSummary = @{ MailId = $null }; n = 1 }
    [pscustomobject]@{ MessageTrackId = "333"; MessageTrackSummary = @{ MailId = "mail-a" }; n = 1 }
}

$script:checkStreaming = $true
Get-NspOperationRecords -OperationType "SandboxAnalysis" -StartUtc $script:start -EndUtc $script:end | ForEach-Object { $script:consumed++ }
Assert-True ($script:consumed -eq 3) "Operation records must be validated and delivered as they arrive."
$script:checkStreaming = $false

$sandbox = Get-NspAnalysisEvidence -OperationType "SandboxAnalysis" -StartUtc $script:start -EndUtc $script:end
Assert-True ($sandbox.OperationCount -eq 3 -and $sandbox.UniqueTrackCount -eq 2) "Sandbox operation and case-insensitive unique track counts must be preserved."
Assert-True ($sandbox.ConfirmedOperationCount -eq 1 -and $sandbox.ConfirmedTrackCount -eq 1 -and $sandbox.ConfirmedFileCount -eq 1 -and $sandbox.InconclusiveOperationCount -eq 1) "Sandbox findings and inconclusive results must be preserved."
Assert-True ($sandbox.StatusCounts["NoMalwareFound"] -eq 1 -and $sandbox.FileStatusCounts["Infected"] -eq 1 -and $sandbox.ExecutionStatusCounts["Completed"] -eq 2) "Sandbox status counts must be preserved."

$deep = Get-NspAnalysisEvidence -OperationType "DeepFileAnalysis" -StartUtc $script:start -EndUtc $script:end
Assert-True ($deep.OperationCount -eq 2 -and $deep.UniqueTrackCount -eq 1 -and $deep.ConfirmedOperationCount -eq 1 -and $deep.ConfirmedFileCount -eq 2 -and $deep.InconclusiveOperationCount -eq 0) "DeepFile counts must be preserved."

$script:mode = "malware"
$malware = Get-NspMalwareRejectEvidence -StartUtc $script:start -EndUtc $script:end
Assert-True ($malware.RejectActionEventCount -eq 4 -and $malware.RejectedTrackCount -eq 3 -and $malware.RejectedMessageCount -eq 1 -and $malware.UnattributedActionCount -eq 1) "Malware reject event and unique ID counts must be preserved."
Assert-True ($malware.MatchingOperationCount -eq 2 -and $malware.InfectedPartCount -eq 2 -and $malware.UnverifiedOperationCount -eq 2 -and -not $malware.EvidenceComplete) "Incomplete malware evidence must remain visible."

$script:mode = "many-malware"
$script:malwareRequests = 0
$many = Get-NspMalwareRejectEvidence -StartUtc $script:start -EndUtc $script:end
Assert-True ($many.RejectedTrackCount -eq 201 -and $many.MatchingOperationCount -eq 201 -and $many.EvidenceComplete -and $script:malwareRequests -eq 2) "Unsorted malware IDs must be processed completely across batches."

$script:mode = "wrong-malware-id"
$failed = $false
try { Get-NspMalwareRejectEvidence -StartUtc $script:start -EndUtc $script:end | Out-Null }
catch {
    if ($_.Exception.Message -like "*did not match the requested message IDs*") { $failed = $true }
    else { throw }
}
Assert-True $failed "Malware operations outside the requested ID batch must still fail explicitly."

foreach ($test in @(
        @{ Mode = "invalid-time"; Error = "*out-of-period Created timestamp*" },
        @{ Mode = "invalid-type"; Error = "*did not honor the requested operation type filter*" },
        @{ Mode = "invalid-json"; Error = "*contained invalid JSON*" }
    )) {
    $script:mode = $test.Mode
    $failed = $false
    try { Get-NspAnalysisEvidence -OperationType "SandboxAnalysis" -StartUtc $script:start -EndUtc $script:end | Out-Null }
    catch {
        if ($_.Exception.Message -like $test.Error) { $failed = $true }
        else { throw }
    }
    Assert-True $failed "Invalid streamed evidence must still fail explicitly."
}
Write-Host "Report evidence tests passed."
