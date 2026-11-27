$script:NspODataBaseUrl = $null
$script:NspODataApiKey = $null
$script:NspODataToken = $null
$script:NspODataTokenExpiry = [DateTimeOffset]::MinValue
$script:NspODataProgressEnabled = $false
$script:NspODataProgressPeriod = ""

function Write-NspODataProgress {
    param([Parameter(Mandatory = $true)][string] $Status)

    if ($script:NspODataProgressEnabled) {
        $description = if ($script:NspODataProgressPeriod) { "${script:NspODataProgressPeriod}: $Status" } else { $Status }
        Write-Progress -Activity "NoSpamProxy-Bericht" -Status $description
    }
}

function Write-NspReportProgress {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch] $Stopwatch
    )

    $elapsed = $Stopwatch.Elapsed
    $duration = "{0:00}:{1:00}" -f [Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
    Write-Progress -Id 42 -Activity "NoSpamProxy-Bericht | $Status | Laufzeit: $duration" -Status "In Bearbeitung"
}

function Get-NspODataReportDataWithProgress {
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $ApiKey,
        [Parameter(Mandatory = $true)][int] $Days,
        [Parameter(Mandatory = $true)][string] $ODataScriptPath,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch] $Stopwatch
    )

    if ($ProgressPreference -in @("SilentlyContinue", "Ignore")) {
        return Get-NspODataReportData -BaseUrl $BaseUrl -ApiKey $ApiKey -Days $Days
    }

    $worker = [PowerShell]::Create()
    $async = $null
    try {
        [void]$worker.AddScript({
            param($Path, $Url, $Key, $PeriodDays)
            $ErrorActionPreference = "Stop"
            $ProgressPreference = "Continue"
            . $Path
            $script:NspODataProgressEnabled = $true
            Get-NspODataReportData -BaseUrl $Url -ApiKey $Key -Days $PeriodDays
        }.ToString()).AddArgument($ODataScriptPath).AddArgument($BaseUrl).AddArgument($ApiKey).AddArgument($Days)
        $async = $worker.BeginInvoke()
        $nextProgress = 0
        $status = "OData-Abfrage wird vorbereitet"
        do {
            while ($nextProgress -lt $worker.Streams.Progress.Count) {
                $record = $worker.Streams.Progress[$nextProgress++]
                if ($record.Activity -eq "NoSpamProxy-Bericht" -and $record.RecordType -eq "Processing") {
                    $status = $record.StatusDescription
                }
            }
            Write-NspReportProgress -Status $status -Stopwatch $Stopwatch
            if (-not $async.IsCompleted) { [void]$async.AsyncWaitHandle.WaitOne(1000) }
        } while (-not $async.IsCompleted)

        $result = $worker.EndInvoke($async)
        if ($worker.HadErrors) { throw $worker.Streams.Error[0] }
        if ($result.Count -ne 1) { throw "OData report collection returned an unexpected number of results." }
        return $result[0]
    }
    finally {
        if ($null -ne $async -and -not $async.IsCompleted) { $worker.Stop() }
        $worker.Dispose()
    }
}

function Initialize-NspOData {
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $ApiKey
    )

    $parsedBaseUrl = $null
    if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsedBaseUrl) -or
        $parsedBaseUrl.Scheme -ne "https" -or $parsedBaseUrl.UserInfo -or
        $parsedBaseUrl.Query -or $parsedBaseUrl.Fragment) {
        throw "ODataBaseUrl must be an HTTPS URL without credentials, query, or fragment."
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "Set the NSP_API_KEY environment variable to use the NoSpamProxy OData API."
    }

    $script:NspODataBaseUrl = $BaseUrl.TrimEnd("/")
    $script:NspODataApiKey = $ApiKey
    $script:NspODataToken = $null
    $script:NspODataTokenExpiry = [DateTimeOffset]::MinValue
}

function Get-NspHttpStatusCode {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    try { return [int]$ErrorRecord.Exception.Response.StatusCode }
    catch { return 0 }
}

function Get-NspODataToken {
    if ($script:NspODataToken -and
        $script:NspODataTokenExpiry -gt [DateTimeOffset]::UtcNow.AddSeconds(60)) {
        return $script:NspODataToken
    }

    $loginUrl = $script:NspODataBaseUrl + "/api/identity-service/account/login/pat"
    try {
        $response = Invoke-WebRequest -Uri $loginUrl -Method Get `
            -Headers @{ Authorization = "Bearer $($script:NspODataApiKey)"; Accept = "application/json" } `
            -UseBasicParsing -TimeoutSec 30
    }
    catch {
        $statusCode = Get-NspHttpStatusCode $_
        if ($statusCode -eq 401) {
            throw "NoSpamProxy OData authentication failed (HTTP 401). Check the configured PAT."
        }
        if ($statusCode -eq 403) {
            throw "NoSpamProxy denied OData authentication (HTTP 403)."
        }
        if ($statusCode -gt 0) {
            throw "NoSpamProxy OData authentication failed (HTTP $statusCode)."
        }
        throw "NoSpamProxy OData authentication failed because the service could not be reached."
    }

    try { $login = $response.Content | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "NoSpamProxy OData authentication returned invalid JSON." }

    $token = [string](Get-NspODataProperty $login "token")
    if (-not $token) { $token = [string](Get-NspODataProperty $login "access_token") }
    if (-not $token) { throw "NoSpamProxy OData authentication response contained no token." }

    $script:NspODataToken = $token
    $script:NspODataTokenExpiry = [DateTimeOffset]::UtcNow.AddMinutes(55)
    return $script:NspODataToken
}

function Test-NspODataUrlOrigin {
    param([Parameter(Mandatory = $true)][string] $Url)

    $parsedUrl = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsedUrl)) {
        throw "OData returned an invalid pagination URL."
    }
    $baseUri = [System.Uri]$script:NspODataBaseUrl
    if ($parsedUrl.Scheme -ne "https" -or
        $parsedUrl.Host -ne $baseUri.Host -or
        $parsedUrl.Port -ne $baseUri.Port -or
        $parsedUrl.UserInfo) {
        throw "OData returned a pagination URL outside the configured HTTPS origin."
    }
    return $parsedUrl.AbsoluteUri
}

function Invoke-NspODataRequest {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [System.Collections.IDictionary] $Query
    )

    if ($Path -match "^https?://") {
        $url = Test-NspODataUrlOrigin $Path
    }
    else {
        if (-not $Path.StartsWith("/") -or $Path.StartsWith("//") -or $Path.Contains("://")) {
            throw "OData paths must be relative to the configured API origin."
        }
        $url = $script:NspODataBaseUrl + $Path
        if ($Query -and $Query.Count -gt 0) {
            $queryParts = [System.Collections.Generic.List[string]]::new()
            foreach ($key in $Query.Keys) {
                $encodedKey = [System.Uri]::EscapeDataString([string]$key)
                $encodedValue = [System.Uri]::EscapeDataString([string]$Query[$key])
                $queryParts.Add($encodedKey + "=" + $encodedValue)
            }
            $url += "?" + ($queryParts -join "&")
        }
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $token = Get-NspODataToken
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get `
                -Headers @{ Authorization = "Bearer $token"; Accept = "application/json" } `
                -UseBasicParsing -TimeoutSec 60
        }
        catch {
            $statusCode = Get-NspHttpStatusCode $_
            if ($statusCode -eq 401 -and $attempt -eq 0) {
                $script:NspODataToken = $null
                $script:NspODataTokenExpiry = [DateTimeOffset]::MinValue
                continue
            }
            if ($statusCode -eq 401) {
                throw "NoSpamProxy rejected the renewed OData token (HTTP 401)."
            }
            if ($statusCode -eq 403) {
                throw "NoSpamProxy denied access to OData resource '$Path' (HTTP 403)."
            }
            if ($statusCode -gt 0) {
                throw "OData request for '$Path' failed (HTTP $statusCode)."
            }
            if ($_.Exception -is [System.Management.Automation.PSInvalidOperationException] -or
                $_.Exception -is [System.ArgumentException]) {
                throw
            }
            throw "OData request for '$Path' failed because the service could not be reached."
        }
        try { return $response.Content | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "OData response for '$Path' contained invalid JSON." }
    }

    throw "NoSpamProxy OData request did not complete."
}

function Get-NspODataItems {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [System.Collections.IDictionary] $Query,
        [ValidateRange(1, 500)][int] $PageSize = 500
    )

    $skip = [long]0
    $nextLink = $null
    $seenNextLinks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenPageBoundaries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $groupKeys = @()
    $hasGroupBy = $Query -and $Query["`$apply"] -match "groupby\(\(([^)]+)\)"
    if ($hasGroupBy -and $Query["`$orderby"]) {
        $keys = @($Matches[1].Split(",") | ForEach-Object { $_.Trim() })
        $orderKeys = @(([string]$Query["`$orderby"]).Split(",") | ForEach-Object { $_.Trim() })
        if ($keys.Count -eq $orderKeys.Count -and -not (Compare-Object $keys $orderKeys)) {
            $groupKeys = $keys
        }
    }
    $checkEntityId = $Query -and -not $hasGroupBy -and $Query["`$orderby"] -match "(^|,)\s*Id(?:\s+(?:asc|desc))?\s*(,|$)"

    while ($true) {
        if ($nextLink) {
            $page = Invoke-NspODataRequest -Path $nextLink
        }
        else {
            $pageQuery = @{}
            if ($Query) {
                foreach ($key in $Query.Keys) { $pageQuery[$key] = $Query[$key] }
            }
            $pageQuery["`$top"] = $PageSize
            $pageQuery["`$skip"] = $skip
            $page = Invoke-NspODataRequest -Path $Path -Query $pageQuery
        }

        if ($null -eq $page -or $null -eq $page.PSObject.Properties["value"]) {
            throw "OData response for '$Path' did not contain a value collection."
        }
        $pageItems = @($page.value)
        $boundaryKeys = $groupKeys
        if ($pageItems.Count -gt 0 -and $checkEntityId -and
            $null -ne (Get-NspODataProperty $pageItems[0] "Id") -and
            $null -ne (Get-NspODataProperty $pageItems[-1] "Id")) {
            $boundaryKeys = @("Id")
        }
        if ($pageItems.Count -gt 0 -and $boundaryKeys.Count -gt 0) {
            $first = [object[]]::new($boundaryKeys.Count)
            $last = [object[]]::new($boundaryKeys.Count)
            for ($i = 0; $i -lt $boundaryKeys.Count; $i++) {
                $first[$i] = Get-NspODataPathValue $pageItems[0] $boundaryKeys[$i]
                $last[$i] = Get-NspODataPathValue $pageItems[-1] $boundaryKeys[$i]
            }
            $boundary = ConvertTo-Json -InputObject ([ordered]@{ First = $first; Last = $last }) -Compress -Depth 10
            if (-not $seenPageBoundaries.Add($boundary)) {
                throw "OData pagination for '$Path' repeated a page of ordered results."
            }
        }
        foreach ($item in $pageItems) { Write-Output $item }
        $skip += $pageItems.Count

        $nextLink = [string](Get-NspODataProperty $page "@odata.nextLink")
        if ($nextLink) {
            if (-not $seenNextLinks.Add($nextLink)) {
                throw "OData pagination for '$Path' repeated a next link."
            }
            continue
        }

        if ($pageItems.Count -lt $PageSize) { return }
    }
}

function Get-NspODataApplyRows {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Apply,
        [Parameter(Mandatory = $true)][string] $OrderBy
    )

    return Get-NspODataItems -Path $Path -Query @{ "`$apply" = $Apply; "`$orderby" = $OrderBy }
}

function Get-NspSingleAggregateCount {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Apply
    )

    $rows = @(Get-NspODataItems -Path $Path -Query @{ "`$apply" = $Apply })
    if ($rows.Count -eq 0) { return [long]0 }
    if ($rows.Count -ne 1) { throw "OData aggregate for '$Path' returned more than one row." }
    return Get-NspAggregateCount $rows[0]
}

function Get-NspObservedUrlCounts {
    param(
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $from = ConvertTo-NspODataDate $StartUtc
    $to = ConvertTo-NspODataDate $EndUtc
    $filter = "MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to"
    $path = "/api/message-tracking/MessageUrlSummaries"
    $missing = Get-NspSingleAggregateCount $path "filter($filter and (Sha256Hash eq null or Sha256Hash eq ''))/aggregate(`$count as n)"
    if ($missing -gt 0) {
        return [pscustomobject]@{ Total = $null; Malicious = $null }
    }

    $total = Get-NspSingleAggregateCount $path "filter($filter)/aggregate(Sha256Hash with countdistinct as n)"
    $malicious = Get-NspSingleAggregateCount $path "filter($filter and IsMalicious eq true)/aggregate(Sha256Hash with countdistinct as n)"
    return [pscustomobject]@{ Total = $total; Malicious = $malicious }
}

function Get-NspODataProperty {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            $value = $InputObject[$Name]
            if ($value -is [System.Array]) { return ,$value }
            return $value
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { return ,$property.Value }
    return $property.Value
}

function Get-NspODataPathValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $value = $InputObject
    foreach ($part in $Path.Split("/")) {
        $value = Get-NspODataProperty -InputObject $value -Name $part
    }
    return $value
}

function Get-NspAggregateCount {
    param([Parameter(Mandatory = $true)] $Row)

    $value = Get-NspODataProperty $Row "n"
    if ($null -eq $value) {
        throw "OData aggregate row did not contain the required numeric count field n."
    }
    $count = [long]0
    if ($value -is [string]) {
        if (-not [long]::TryParse($value, [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$count)) {
            throw "OData aggregate field n was not an integer."
        }
    }
    else {
        try { $count = [long]$value }
        catch { throw "OData aggregate field n was not an integer." }
    }
    if ($count -lt 0) { throw "OData aggregate field n was negative." }
    return $count
}

function Add-NspCount {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Counts,
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $true)][long] $Value
    )

    if (-not $Counts.Contains($Key)) { $Counts[$Key] = [long]0 }
    $Counts[$Key] += $Value
}

function ConvertTo-NspODataDate {
    param([Parameter(Mandatory = $true)][DateTime] $Date)
    return $Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NspOperationRecords {
    param(
        [Parameter(Mandatory = $true)][string] $OperationType,
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $from = ConvertTo-NspODataDate $StartUtc
    $to = ConvertTo-NspODataDate $EndUtc
    $filter = "Operation/Type eq '$OperationType' and Created ge $from and Created lt $to"
    $rows = Get-NspODataItems -Path "/api/message-tracking/MessageOperations" -PageSize 100 `
        -Query @{
            "`$filter" = $filter
            "`$expand" = "Operation"
            "`$orderby" = "Created desc,Id desc"
        }

    foreach ($row in $rows) {
        $operation = Get-NspODataProperty $row "Operation"
        if ((Get-NspODataProperty $operation "Type") -ne $OperationType) {
            throw "MessageOperations did not honor the requested operation type filter."
        }
        $createdValue = Get-NspODataProperty $row "Created"
        $createdUtc = [DateTime]::MinValue
        $parsed = [DateTime]::TryParse([string]$createdValue, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$createdUtc)
        if (-not $parsed -or $createdUtc -lt $StartUtc -or $createdUtc -ge $EndUtc) {
            throw "MessageOperations returned an invalid or out-of-period Created timestamp."
        }
    }
    return $rows
}

function ConvertFrom-NspOperationData {
    param([Parameter(Mandatory = $true)] $Operation)

    $data = Get-NspODataProperty $Operation "Data"
    if (-not ($data -is [string]) -or [string]::IsNullOrWhiteSpace($data)) {
        throw "NoSpamProxy operation evidence did not contain JSON Data."
    }
    try { $parsed = $data | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "NoSpamProxy operation evidence contained invalid JSON." }
    if ($null -eq $parsed -or $parsed -is [System.Array]) {
        throw "NoSpamProxy operation evidence JSON was not an object."
    }
    return $parsed
}

function Get-NspAnalysisEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $OperationType,
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $rows = @(Get-NspOperationRecords -OperationType $OperationType -StartUtc $StartUtc -EndUtc $EndUtc)
    $statusCounts = @{}
    $fileStatusCounts = @{}
    $executionStatusCounts = @{}
    $confirmedTrackIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $confirmedOperationCount = 0
    $confirmedFileCount = 0
    $inconclusiveOperationCount = 0

    foreach ($row in $rows) {
        $trackId = [string](Get-NspODataProperty $row "MessageTrackId")
        if (-not $trackId) { throw "MessageOperations omitted MessageTrackId." }
        $operation = Get-NspODataProperty $row "Operation"
        $data = ConvertFrom-NspOperationData $operation
        $rootStatusName = if ($OperationType -eq "SandboxAnalysis") { "sandboxAnalysisStatus" } else { "deepFileAnalysisStatus" }
        $rootStatus = [string](Get-NspODataProperty $data $rootStatusName)
        if ($rootStatus) { Add-NspCount $statusCounts $rootStatus 1 }

        $executionStatus = [string](Get-NspODataProperty $data "executionStatus")
        if ($executionStatus) { Add-NspCount $executionStatusCounts $executionStatus 1 }

        $isConfirmed = $false
        $hasKnownOutcome = $false
        if ($OperationType -eq "SandboxAnalysis") {
            if ($rootStatus -eq "NoMalwareFound") {
                $hasKnownOutcome = $true
            }
            $results = Get-NspODataProperty $data "sandboxAnalysisResults"
            foreach ($result in @($results)) {
                if ($null -eq $result) { continue }
                $fileStatus = [string](Get-NspODataProperty $result "status")
                if ($fileStatus) { Add-NspCount $fileStatusCounts $fileStatus 1 }
                if (-not $fileStatus -or $fileStatus -eq "Unknown") { $hasKnownOutcome = $false }
                if ($fileStatus -eq "Infected") {
                    $isConfirmed = $true
                    $confirmedFileCount++
                }
            }
        }
        else {
            if ($rootStatus -eq "NoMalwareFound") { $hasKnownOutcome = $true }
            $results = Get-NspODataProperty $data "results"
            foreach ($result in @($results)) {
                $fileStatus = [string](Get-NspODataProperty $result "status")
                if ($fileStatus) { Add-NspCount $fileStatusCounts $fileStatus 1 }
                if ($fileStatus -eq "Infected") {
                    $isConfirmed = $true
                    $confirmedFileCount++
                }
            }
        }

        if ($isConfirmed) { $hasKnownOutcome = $true }
        if (-not $hasKnownOutcome) { $inconclusiveOperationCount++ }
        if ($isConfirmed) {
            [void]$confirmedTrackIds.Add($trackId)
            $confirmedOperationCount++
        }
    }

    return [pscustomobject]@{
        OperationType = $OperationType
        OperationCount = [long]$rows.Count
        UniqueTrackCount = [long](@($rows | ForEach-Object { [string](Get-NspODataProperty $_ "MessageTrackId") } | Sort-Object -Unique).Count)
        ConfirmedOperationCount = [long]$confirmedOperationCount
        ConfirmedTrackCount = [long]$confirmedTrackIds.Count
        ConfirmedFileCount = [long]$confirmedFileCount
        InconclusiveOperationCount = [long]$inconclusiveOperationCount
        StatusCounts = $statusCounts
        FileStatusCounts = $fileStatusCounts
        ExecutionStatusCounts = $executionStatusCounts
    }
}

function Get-NspMalwareRejectEvidence {
    param(
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $from = ConvertTo-NspODataDate $StartUtc
    $to = ConvertTo-NspODataDate $EndUtc
    $filter = "Name eq 'malwareScan' and Decision eq 'RejectPermanent' and MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to"
    $actionApply = "filter($filter)/groupby((MessageTrackId,MessageTrackSummary/MailId),aggregate(`$count as n))"
    $actions = @(Get-NspODataApplyRows "/api/message-tracking/Actions" $actionApply "MessageTrackId,MessageTrackSummary/MailId")
    $trackIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $mailIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actionEventCount = [long]0
    $unattributedActionCount = [long]0
    foreach ($row in $actions) {
        $actionEventCount += Get-NspAggregateCount $row
        $trackId = [string](Get-NspODataProperty $row "MessageTrackId")
        if (-not $trackId) { throw "MalwareScan RejectPermanent action omitted MessageTrackId." }
        [void]$trackIds.Add($trackId)
        $mailId = [string](Get-NspODataPathValue $row "MessageTrackSummary/MailId")
        if ($mailId) { [void]$mailIds.Add($mailId) }
        else { $unattributedActionCount++ }
    }
    $messageIds = @($trackIds | Sort-Object)
    $infectedPartCount = [long]0
    $matchingOperationCount = [long]0
    $unverifiedOperationCount = [long]0
    $matchedMessageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    for ($start = 0; $start -lt $messageIds.Count; $start += 200) {
        $length = [Math]::Min(200, $messageIds.Count - $start)
        $chunk = [string[]]$messageIds[$start..($start + $length - 1)]
        $filterIds = "MessageTrackId in (" + ($chunk -join ",") + ") and Operation/Type eq 'MalwareScan' and Created ge $from and Created lt $to"
        $operations = @(Get-NspODataItems -Path "/api/message-tracking/MessageOperations" -PageSize 100 `
            -Query @{ "`$filter" = $filterIds; "`$expand" = "Operation"; "`$orderby" = "Id" })

        foreach ($row in $operations) {
            $trackId = [string](Get-NspODataProperty $row "MessageTrackId")
            $operation = Get-NspODataProperty $row "Operation"
            if ((Get-NspODataProperty $operation "Type") -ne "MalwareScan" -or $trackId -notin $chunk) {
                throw "MalwareScan operation evidence did not match the requested message IDs."
            }
            [void]$matchedMessageIds.Add($trackId)
            $matchingOperationCount++
            $data = ConvertFrom-NspOperationData $operation
            $infectedParts = Get-NspODataProperty $data "infectedMailParts"
            if ($infectedParts -is [System.Array]) {
                $infectedPartCount += $infectedParts.Count
            }
            else {
                $unverifiedOperationCount++
            }
        }
    }

    $missingMessages = $messageIds.Count - $matchedMessageIds.Count
    return [pscustomobject]@{
        RejectActionEventCount = $actionEventCount
        RejectedMessageCount = [long]$mailIds.Count
        RejectedTrackCount = [long]$trackIds.Count
        MatchingOperationCount = $matchingOperationCount
        InfectedPartCount = $infectedPartCount
        UnattributedActionCount = [long]$unattributedActionCount
        EvidenceComplete = ($missingMessages -eq 0 -and $unverifiedOperationCount -eq 0 -and $unattributedActionCount -eq 0)
        UnverifiedOperationCount = [long]($unverifiedOperationCount + $missingMessages)
    }
}

function Get-NspTopSpammers {
    param(
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $domains = @(Get-NspODataItems -Path "/odata/v4/OwnedDomains" -Query @{ "`$select" = "Name,Id"; "`$orderby" = "Name,Id" })
    $domainConditions = [System.Collections.Generic.List[string]]::new()
    foreach ($domain in $domains) {
        $name = [string](Get-NspODataProperty $domain "Name")
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $escapedName = $name.Trim().Replace("'", "''")
            $domainConditions.Add("endswith(tolower(Address),'@$escapedName')")
        }
    }
    if ($domainConditions.Count -eq 0) { return @() }

    $from = ConvertTo-NspODataDate $StartUtc
    $to = ConvertTo-NspODataDate $EndUtc
    $apply = "filter(MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to and (MessageTrackSummary/Status eq 'PermanentlyBlocked' or MessageTrackSummary/Status eq 'TemporarilyBlocked') and AddressType eq 'Recipient' and (" + ($domainConditions -join " or ") + "))/groupby((Address),aggregate(`$count as n))"
    $addressRows = @(Get-NspODataApplyRows "/api/message-tracking/MessageAddresses" $apply "Address")
    $result = foreach ($row in $addressRows) {
        $address = [string](Get-NspODataProperty $row "Address")
        if (-not [string]::IsNullOrWhiteSpace($address)) {
            [pscustomobject]@{ Address = $address; Count = Get-NspAggregateCount $row }
        }
    }
    return @($result | Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Address"; Ascending = $true } |
        Select-Object -First 10)
}

function Get-NspODataPeriodReportData {
    param(
        [Parameter(Mandatory = $true)][DateTime] $StartUtc,
        [Parameter(Mandatory = $true)][DateTime] $EndUtc
    )

    $from = ConvertTo-NspODataDate $StartUtc
    $to = ConvertTo-NspODataDate $EndUtc
    $summaryApply = "filter(Sent ge $from and Sent lt $to)/groupby((Status,RejectReason,WasReceivedFromRelayServer,WasRecalled),aggregate(`$count as n))"
    $actionTargets = @(
        "(Name eq 'OutbreakDetection' and Decision eq 'RejectPermanent')",
        "(Name eq 'OutbreakDetection' and Decision eq 'RejectTemporarily')",
        "(Name eq 'validateSignatureAndDecrypt' and Decision eq 'RejectPermanent')",
        "(Name eq 'malwareScan' and Decision eq 'RejectPermanent')",
        "(Name eq 'fraudDetection' and Decision eq 'RejectPermanent')",
        "(Name eq 'greylisting' and Decision eq 'RejectTemporarily')",
        "(Name eq 'ContentFiltering' and Decision eq 'RejectPermanent')",
        "(Name eq 'ContentFiltering' and Decision eq 'RejectTemporarily')"
    ) -join " or "
    $actionApply = "filter(MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to and ($actionTargets))/groupby((Name,Decision,MessageTrackSummary/MailId),aggregate(`$count as n))"
    $filterApply = "filter(MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to and MessageTrackSummary/Status eq 'PermanentlyBlocked')/groupby((Name,Scl,MessageTrackSummary/MailId),aggregate(`$count as n))"
    $attachmentApply = "filter(MessageTrackSummary/Sent ge $from and MessageTrackSummary/Sent lt $to)/groupby((MimeType,MessageTrackSummary/Status,IsQuarantined),aggregate(`$count as n))"
    $operationApply = "filter(Created ge $from and Created lt $to)/groupby((Operation/Type),aggregate(`$count as n))"
    $visitApply = "filter(VisitedOn ge $from and VisitedOn lt $to)/groupby((IsMalicious),aggregate(`$count as n))"

    $recallApply = "filter(Sent ge $from and Sent lt $to and WasRecalled eq true)/groupby((MailId),aggregate(`$count as n))"

    Write-NspODataProgress "Nachrichten und Blockierungsgründe"
    $summaryRows = @(Get-NspODataApplyRows "/api/message-tracking/MessageTrackSummaries" $summaryApply "Status,RejectReason,WasReceivedFromRelayServer,WasRecalled")

    $actions = @{}
    $actionUniqueMessages = @{}
    $actionUnattributedEvents = @{}
    Write-NspODataProgress "Prüfaktionen"
    Get-NspODataApplyRows "/api/message-tracking/Actions" $actionApply "Name,Decision,MessageTrackSummary/MailId" | ForEach-Object {
        $row = $_
        $name = [string](Get-NspODataProperty $row "Name")
        $decision = [string](Get-NspODataProperty $row "Decision")
        if (-not $name) { $name = "(unknown action)" }
        if (-not $decision) { $decision = "(unknown decision)" }
        $mailId = [string](Get-NspODataPathValue $row "MessageTrackSummary/MailId")
        $key = "$name|$decision"
        $eventCount = Get-NspAggregateCount $row
        Add-NspCount $actions $key $eventCount
        if ($mailId) { Add-NspCount $actionUniqueMessages $key 1 }
        else { Add-NspCount $actionUnattributedEvents $key $eventCount }
    }

    $filters = @{}
    Write-NspODataProgress "Filtertreffer"
    Get-NspODataApplyRows "/api/message-tracking/Filters" $filterApply "Name,Scl,MessageTrackSummary/MailId" | ForEach-Object {
        $row = $_
        $name = [string](Get-NspODataProperty $row "Name")
        if (-not $name) { $name = "(unknown filter)" }
        $scl = [string](Get-NspODataProperty $row "Scl")
        if ($null -eq (Get-NspODataProperty $row "Scl")) { $scl = "(null)" }
        if (-not $filters.ContainsKey($name)) {
            $filters[$name] = @{
                Total = [long]0
                UnattributedEvents = [long]0
                PositiveScl = [long]0
                Scl = @{}
                MessageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                PositiveMessageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            }
        }
        $count = Get-NspAggregateCount $row
        $filters[$name].Total += $count
        Add-NspCount $filters[$name].Scl $scl $count
        $mailId = [string](Get-NspODataPathValue $row "MessageTrackSummary/MailId")
        if ($mailId) { [void]$filters[$name].MessageIds.Add($mailId) }
        else { $filters[$name].UnattributedEvents += $count }
        $sclNumber = 0.0
        if ([double]::TryParse($scl, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$sclNumber) -and $sclNumber -gt 0) {
            $filters[$name].PositiveScl += $count
            if ($mailId) { [void]$filters[$name].PositiveMessageIds.Add($mailId) }
        }
    }
    foreach ($name in @($filters.Keys)) {
        $filters[$name].UniqueMessages = [long]$filters[$name].MessageIds.Count
        $filters[$name].UniquePositiveMessages = [long]$filters[$name].PositiveMessageIds.Count
    }

    Write-NspODataProgress "Anhänge"
    $attachmentRows = @(Get-NspODataApplyRows "/api/message-tracking/Attachments" $attachmentApply "MimeType,MessageTrackSummary/Status,IsQuarantined")
    Write-NspODataProgress "Analyseoperationen"
    $operationRows = @(Get-NspODataApplyRows "/api/message-tracking/MessageOperations" $operationApply "Operation/Type")
    Write-NspODataProgress "URL-Aufrufe"
    $visitRows = @(Get-NspODataApplyRows "/api/message-tracking/UrlVisits" $visitApply "IsMalicious")
    Write-NspODataProgress "Zurückgerufene Nachrichten"
    $recallRows = @(Get-NspODataApplyRows "/api/message-tracking/MessageTrackSummaries" $recallApply "MailId")

    Write-NspODataProgress "Ergebnisse auswerten"
    $statusCounts = @{}
    $reasonCounts = @{}
    $directionCounts = @{}
    $recalledCount = [long]0
    $unattributedRecallCount = [long]0
    $messageTotal = [long]0
    foreach ($row in $summaryRows) {
        $count = Get-NspAggregateCount $row
        $status = [string](Get-NspODataProperty $row "Status")
        if (-not $status) { $status = "(unknown status)" }
        $reason = [string](Get-NspODataProperty $row "RejectReason")
        if (-not $reason) { $reason = "(unspecified)" }
        $direction = [string](Get-NspODataProperty $row "WasReceivedFromRelayServer")
        if (-not $direction) { $direction = "(unspecified)" }
        Add-NspCount $statusCounts $status $count
        Add-NspCount $directionCounts $direction $count
        $messageTotal += $count
        if ($status -in @("PermanentlyBlocked", "TemporarilyBlocked")) {
            Add-NspCount $reasonCounts $reason $count
        }
    }
    foreach ($row in $recallRows) {
        if ([string](Get-NspODataPathValue $row "MailId")) { $recalledCount++ }
        else { $unattributedRecallCount++ }
    }

    $attachments = @{}
    $quarantineCounts = @{ True = [long]0; False = [long]0; Null = [long]0 }
    $totalAttachmentCount = [long]0
    foreach ($row in $attachmentRows) {
        $mimeType = [string](Get-NspODataProperty $row "MimeType")
        if ([string]::IsNullOrWhiteSpace($mimeType)) { $mimeType = "(unknown MIME type)" }
        $status = [string](Get-NspODataPathValue $row "MessageTrackSummary/Status")
        if (-not $status) { $status = "(unknown message status)" }
        $count = Get-NspAggregateCount $row
        if (-not $attachments.ContainsKey($mimeType)) {
            $attachments[$mimeType] = @{ Total = [long]0; Status = @{}; Quarantined = [long]0 }
        }
        $attachments[$mimeType].Total += $count
        Add-NspCount $attachments[$mimeType].Status $status $count
        $totalAttachmentCount += $count
        $isQuarantined = Get-NspODataProperty $row "IsQuarantined"
        if ($null -eq $isQuarantined) {
            $quarantineCounts.Null += $count
        }
        elseif ($isQuarantined -eq $true) {
            $quarantineCounts.True += $count
            $attachments[$mimeType].Quarantined += $count
        }
        else {
            $quarantineCounts.False += $count
        }
    }

    $operationCounts = @{}
    foreach ($row in $operationRows) {
        $type = [string](Get-NspODataPathValue $row "Operation/Type")
        if (-not $type) { $type = "(unknown operation type)" }
        Add-NspCount $operationCounts $type (Get-NspAggregateCount $row)
    }

    $visitCounts = @{ True = [long]0; False = [long]0; Null = [long]0 }
    foreach ($row in $visitRows) {
        $key = [string](Get-NspODataProperty $row "IsMalicious")
        if ($key -eq "True") { $visitCounts.True += Get-NspAggregateCount $row }
        elseif ($key -eq "False") { $visitCounts.False += Get-NspAggregateCount $row }
        else { $visitCounts.Null += Get-NspAggregateCount $row }
    }

    Write-NspODataProgress "Malware-Analyse"
    $malwareEvidence = Get-NspMalwareRejectEvidence -StartUtc $StartUtc -EndUtc $EndUtc
    Write-NspODataProgress "Sandbox-Analyse"
    $sandboxEvidence = Get-NspAnalysisEvidence -OperationType "SandboxAnalysis" -StartUtc $StartUtc -EndUtc $EndUtc
    Write-NspODataProgress "DeepFile-Analyse"
    $deepFileEvidence = Get-NspAnalysisEvidence -OperationType "DeepFileAnalysis" -StartUtc $StartUtc -EndUtc $EndUtc
    Write-NspODataProgress "Erkannte URLs"
    $observedUrls = Get-NspObservedUrlCounts -StartUtc $StartUtc -EndUtc $EndUtc

    return [pscustomobject]@{
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        MessageTotal = $messageTotal
        StatusCounts = $statusCounts
        RejectReasonCounts = $reasonCounts
        DirectionCounts = $directionCounts
        RecalledMessages = $recalledCount
        UnattributedRecallCount = $unattributedRecallCount
        ActionCounts = $actions
        ActionUniqueMessages = $actionUniqueMessages
        ActionUnattributedEvents = $actionUnattributedEvents
        FilterCounts = $filters
        AttachmentCounts = $attachments
        TotalAttachments = $totalAttachmentCount
        QuarantineCounts = $quarantineCounts
        OperationCounts = $operationCounts
        MalwareRejectEvidence = $malwareEvidence
        SandboxEvidence = $sandboxEvidence
        DeepFileEvidence = $deepFileEvidence
        ObservedUrls = $observedUrls
        UrlVisitCounts = $visitCounts
    }
}

function Get-NspODataReportData {
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $ApiKey,
        [ValidateRange(1, 2147483647)][int] $Days = 14
    )

    $todayUtc = [DateTime]::UtcNow.Date
    $maxDays = [int][Math]::Floor(($todayUtc - [DateTime]::MinValue).TotalDays / 2)
    if ($Days -gt $maxDays) { throw "The -Days value is too large to calculate two valid UTC periods." }
    $currentStart = $todayUtc.AddDays(-$Days)
    $comparisonStart = $currentStart.AddDays(-$Days)
    Write-NspODataProgress "Verbindung vorbereiten"
    Initialize-NspOData -BaseUrl $BaseUrl -ApiKey $ApiKey
    $script:NspODataProgressPeriod = "Aktueller Zeitraum"
    $current = Get-NspODataPeriodReportData -StartUtc $currentStart -EndUtc $todayUtc
    $script:NspODataProgressPeriod = "Vergleichszeitraum"
    $comparison = Get-NspODataPeriodReportData -StartUtc $comparisonStart -EndUtc $currentStart
    $script:NspODataProgressPeriod = "Aktueller Zeitraum"
    Write-NspODataProgress "Empfänger-Rangliste"
    $topSpammers = @(Get-NspTopSpammers -StartUtc $currentStart -EndUtc $todayUtc)

    return [pscustomobject]@{
        GeneratedAtUtc = [DateTime]::UtcNow
        Current = $current
        Comparison = $comparison
        TopSpammers = $topSpammers
    }
}
