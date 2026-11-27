$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "ReportOData.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$script:rows = [System.Collections.Generic.List[object]]::new()
$script:requests = 0
$script:repeatPage = $false
function Invoke-NspODataRequest {
    param($Path, $Query)
    if ($Path -eq "/odata/v4/OwnedDomains") {
        return [pscustomobject]@{ value = @([pscustomobject]@{ Name = "example.invalid"; Id = 1 }) }
    }
    if ($Path -ne "/api/message-tracking/MessageAddresses" -or $Query["`$orderby"] -notin @("n desc,Address", "Address")) {
        throw "Unexpected ranking request."
    }
    $script:requests++
    $orderedRows = if ($Query["`$orderby"] -eq "Address") {
        @($script:rows | Sort-Object -Property Address)
    }
    else {
        @($script:rows)
    }
    $skip = if ($script:repeatPage) { 0 } else { [int]$Query["`$skip"] }
    $size = [int]$Query["`$top"]
    $values = @(
        for ($i = $skip; $i -lt [Math]::Min($skip + $size, $orderedRows.Count); $i++) {
            $orderedRows[$i]
        }
    )
    return [pscustomobject]@{ value = $values }
}

function Add-RankRow {
    param([string] $Address, [long] $Count)
    $script:rows.Add([pscustomobject]@{ Address = $Address; n = $Count })
}

function Assert-Ranking {
    param([string] $Message)
    $end = [DateTime]::UtcNow.Date
    $expected = @(
        $script:rows | Sort-Object -Property Address | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Address) } |
            ForEach-Object { [pscustomobject]@{ Address = $_.Address; Count = [long]$_.n } } |
            Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Address"; Ascending = $true } |
            Select-Object -First 10
    )
    $actual = @(Get-NspTopSpammers -StartUtc $end.AddDays(-1) -EndUtc $end)
    Assert-True ($expected.Count -eq $actual.Count) "$Message returned $($actual.Count) entries; expected $($expected.Count)."
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-True ($expected[$i].Address -ceq $actual[$i].Address -and $expected[$i].Count -eq $actual[$i].Count) "$Message changed the recipient ranking."
    }
}

Assert-Ranking "An empty ranking"
$script:rows.Clear()
$script:requests = 0
Add-RankRow " " 1000
foreach ($i in 1..4) { Add-RankRow ("person-{0}@example.invalid" -f $i) (100 - $i) }
Assert-Ranking "A short ranking"

$script:rows.Clear()
$script:requests = 0
foreach ($i in 1..9) { Add-RankRow ("high-{0}@example.invalid" -f $i) (1000 - $i) }
foreach ($i in 600..1) { Add-RankRow ("tie-{0:D4}@example.invalid" -f $i) 100 }
foreach ($i in 1..1000) { Add-RankRow ("low-{0:D4}@example.invalid" -f $i) 1 }
Assert-Ranking "A ranking with ties across pages"
Assert-True ($script:requests -eq 2) "Ranking must read all cutoff ties but stop before lower-count pages."

$script:rows.Clear()
$script:requests = 0
foreach ($i in 1100..1) { Add-RankRow ("tie-{0:D4}@example.invalid" -f $i) 1 }
Assert-Ranking "An entirely tied ranking"
Assert-True ($script:requests -eq 3) "All tied pages must be considered."

$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach ($cultureName in @("en-US", "tr-TR")) {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
        $script:rows.Clear()
        $script:requests = 0
        foreach ($name in @("aa", "AA", "ab", "aB", "ac", "ad", "ae", "af", "ag", "ah", "ai", "aj", "i", "I", ([string][char]0x0131), ([string][char]0x0130))) {
            Add-RankRow "$name@example.invalid" 1
        }
        Assert-Ranking "A culture-sensitive ranking with case-equivalent addresses"
        Assert-True ($script:requests -eq 2) "Case-equivalent address keys must use the original full sort."
    }
}
finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
}

$script:rows.Clear()
Add-RankRow "first@example.invalid" 1
Add-RankRow "second@example.invalid" 2
$script:requests = 0
$failed = $false
$end = [DateTime]::UtcNow.Date
try { Get-NspTopSpammers -StartUtc $end.AddDays(-1) -EndUtc $end | Out-Null }
catch {
    if ($_.Exception.Message -like "*out of count order*") { $failed = $true }
    else { throw }
}
Assert-True $failed "A server that ignores count ordering must fail explicitly."

$script:rows.Clear()
foreach ($i in 1100..1) { Add-RankRow ("tie-{0:D4}@example.invalid" -f $i) 1 }
$script:requests = 0
$script:repeatPage = $true
$failed = $false
$end = [DateTime]::UtcNow.Date
try { Get-NspTopSpammers -StartUtc $end.AddDays(-1) -EndUtc $end | Out-Null }
catch {
    if ($_.Exception.Message -like "*repeated a page of ordered results*") { $failed = $true }
    else { throw }
}
Assert-True ($failed -and $script:requests -eq 2) "Repeated ranking pages must fail instead of looping."
Write-Host "Report ranking tests passed."
