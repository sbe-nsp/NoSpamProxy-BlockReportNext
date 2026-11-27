$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Web
. (Join-Path $root "ReportOData.ps1")
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root "Get-PermanentlyBlocked.ps1"), [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { throw "Report script contains parser errors." }
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-TestPeriod {
    $analysis = [pscustomobject]@{
        OperationCount = 0; ConfirmedTrackCount = 0; ConfirmedOperationCount = 0
        ConfirmedFileCount = 0; InconclusiveOperationCount = 0; StatusCounts = @{}; FileStatusCounts = @{}
    }
    return [pscustomobject]@{
        MessageTotal = 0; StatusCounts = @{}; RejectReasonCounts = @{}
        ActionCounts = @{}; ActionUniqueMessages = @{}; ActionUnattributedEvents = @{}
        FilterCounts = @{}; QuarantineCounts = @{ True = 0; False = 0; Null = 0 }; OperationCounts = @{}
        MalwareRejectEvidence = [pscustomobject]@{
            RejectActionEventCount = 0; RejectedMessageCount = 0; RejectedTrackCount = 0
            InfectedPartCount = 0; MatchingOperationCount = 0; EvidenceComplete = $true
        }
        SandboxEvidence = $analysis; DeepFileEvidence = $analysis
        UrlVisitCounts = @{ True = 0 }; ObservedUrls = @{ Total = 0; Malicious = 0 }; RecalledMessages = 0
        AttachmentCounts = @{}; TotalAttachments = 0
    }
}

$current = New-TestPeriod
$previous = New-TestPeriod
$current.StatusCounts = @{
    DeliveryPending = 1; DispatcherError = 2; PartialSuccess = 3; PermanentlyBlocked = 20
    PutOnHold = 4; Success = 50; Suppressed = 5; TemporarilyBlocked = 10; FutureStatus = 6; DuplicateDrop = 7
}
$previous.StatusCounts = @{ PermanentlyBlocked = 10; TemporarilyBlocked = 10 }
$current.RejectReasonCounts = @{ Policy = 15; SpamOrVirus = 15; FutureReason = 1 }
$previous.RejectReasonCounts = @{ Policy = 5; SpamOrVirus = 10 }
$current.ActionCounts = @{
    "OutbreakDetection|RejectPermanent" = 7; "OutbreakDetection|RejectTemporarily" = 8
    "validateSignatureAndDecrypt|RejectPermanent" = 9; "malwareScan|RejectPermanent" = 10
    "fraudDetection|RejectPermanent" = 11; "greylisting|RejectTemporarily" = 12
    "ContentFiltering|RejectTemporarily" = 13; "ContentFiltering|RejectPermanent" = 14
    "FutureAction|RejectPermanent" = 15
}
foreach ($name in @("OutbreakDetectionFilter", "realtimeBlocklist", "reputation", "surblFilter", "bitdefenderFilter")) {
    $current.FilterCounts[$name] = @{ PositiveScl = 2 }
}
$current.QuarantineCounts = @{ True = 3; False = 4; Null = 5 }
$current.MalwareRejectEvidence.RejectActionEventCount = 12
$current.MalwareRejectEvidence.RejectedMessageCount = 12
$current.MalwareRejectEvidence.RejectedTrackCount = 12
$current.MalwareRejectEvidence.InfectedPartCount = 12
$previous.MalwareRejectEvidence.RejectActionEventCount = 4
$previous.MalwareRejectEvidence.RejectedMessageCount = 4
$previous.MalwareRejectEvidence.RejectedTrackCount = 4
$previous.MalwareRejectEvidence.InfectedPartCount = 4
$current.DeepFileEvidence.OperationCount = 6
$current.DeepFileEvidence.ConfirmedTrackCount = 2
$current.AttachmentCounts = @{
    "application/pdf" = @{ Total = 3; Status = @{ Success = 2; PermanentlyBlocked = 1 }; Quarantined = 1 }
    "text/<script>" = @{ Total = 1; Status = @{ TemporarilyBlocked = 1 }; Quarantined = 0 }
}
$current.TotalAttachments = 4
$previous.AttachmentCounts = @{ "application/pdf" = @{ Total = 2; Status = @{ Success = 2 }; Quarantined = 0 } }
$previous.TotalAttachments = 2

$data = [pscustomobject]@{ Current = $current; Comparison = $previous; TopSpammers = @() }
$current.MessageTotal = 150
$previous.MessageTotal = 100
$cards = New-NspKpiCards $data
Assert-True ($cards.Contains('Nachrichtentracks aktuell</span><small>Vergleichszeitraum: 100<br>Veränderung: +50 (+50,00%)</small>')) "Message KPI must show the current change against its comparison."
Assert-True ($cards.Contains('Dauerhaft blockiert</span><small>Vergleichszeitraum: 10<br>Veränderung: +10 (+100,00%)</small>')) "Permanent KPI must compare permanent counts."
Assert-True ($cards.Contains('Temporär blockiert</span><small>Vergleichszeitraum: 10<br>Veränderung: 0 (0,00%)</small>')) "Temporary KPI must show unchanged counts."
Assert-True ($cards.Contains('Blockierungen gesamt</span><small>Vergleichszeitraum: 20<br>Veränderung: +10 (+50,00%)</small>')) "Total block KPI must compare combined counts."
Assert-True ((Format-NspKpiComparison 20 30) -eq 'Vergleichszeitraum: 30<br>Veränderung: -10 (-33,33%)') "Decreases must have a minus sign."
Assert-True ((Format-NspKpiComparison 5 0) -eq 'Vergleichszeitraum: 0<br>Veränderung: +5 (-)') "A zero baseline must not produce a percentage."
Assert-True ((Format-NspKpiComparison $null 5) -eq 'Vergleichszeitraum: 5<br>Veränderung: -') "An unavailable value must not produce a change."
$raw = New-NspReportContent $data
$content = [Net.WebUtility]::HtmlDecode($raw)
foreach ($label in @(
        "Zustellfehler", "Teilweise zugestellt", "Permanent abgewiesen",
        "Zurückgestellt", "Erfolgreich zugestellt", "Zustellung unterdrückt (Duplikate, etc)", "Temporär abgewiesen",
        "Richtlinien / Vorgaben (Policy)", "Spam- oder Malware-Verdacht (SpamOrVirus)",
        "32Guards / RejectPermanent – Ereignisse", "32Guards / RejectTemporarily – Ereignisse",
        "Signatur / Entschlüsselungsfehler", "Malware Prüfung", "CxO Prüfung", "Greylisting",
        "Temporär abgewiesen wegen Inhaltsfilterung", "Inhaltsfilter - Permanent abgewiesen",
        "Inhaltsfilter - Temporär abgewiesen", "Anhänge in Quarantäne",
        "32Guards", "Realtime Blocklist", "Reputationsfilter", "SURBL Filter", "CSA / AV Engine",
        "E-Mails abgewiesen wegen Malware", "Zurückgerufene Nachrichten durch 32Guards Recall",
        "DeepFile-Analysevorgänge", "Nachrichtentracks mit einem Befund", "FutureStatus", "FutureReason"
    )) {
    Assert-True ($content.Contains("<td>$label</td>")) "Expected row missing: $label"
}
foreach ($label in @(
        "Gesamt verarbeitete Nachrichtentracks", "Anhänge: IsQuarantined=false",
        "Anhänge: IsQuarantined=null", "Unklare Analysevorgänge", "<td>DuplicateDrop</td>",
        "Zustellung ausstehend", "<td>DeliveryPending</td>"
    )) {
    Assert-True (-not $content.Contains($label)) "Unexpected row: $label"
}
Assert-True ($content.Contains("<td>FutureAction / RejectPermanent – Ereignisse</td>")) "Unknown action labels must remain visible."
Assert-True ($content -match "32Guards / RejectPermanent – Ereignisse</td><td class='num'>7</td><td class='num'>0</td>") "Translated actions must retain their counts."
Assert-True ($content -match "E-Mails abgewiesen wegen Malware</td><td class='num'>12</td><td class='num'>4</td>") "Grouped malware message counts must retain their values."
Assert-True ($content -match "DeepFile-Analysevorgänge</td><td class='num'>6</td>") "DeepFile operations must not be relabeled as file counts."
Assert-True ($content -match "Nachrichtentracks mit einem Befund</td><td class='num'>2</td>") "DeepFile findings must remain track counts."
Assert-True ($content -match "Richtlinien / Vorgaben \(Policy\) – Anteil an blockierten Nachrichten</td><td class='num'>50,00%</td><td class='num'>25,00%</td><td class='num'>100,00%</td><td class='num'>100,00%</td>") "Block reason share differences must show relative percent change."
Assert-True (-not $content.Contains("n/a")) "Missing values must be displayed as a dash throughout the report."

$rows = [System.Text.StringBuilder]::new()
Add-NspPercentTableRow $rows "Other percentage" 30 20
Assert-True ($rows.ToString() -match "<td class='num'>10,00 PP</td><td class='num'>50,00%</td>") "Other percentage differences must remain in percentage points."
$rows.Clear() | Out-Null
Add-NspPercentTableRow $rows "Zero comparison" 30 0 -RelativeDifference
Assert-True ($rows.ToString() -match "<td class='num'>30,00%</td><td class='num'>0,00%</td><td class='num'>-</td><td class='num'>-</td>") "A relative difference from zero must be unavailable."
$rows.Clear() | Out-Null
Add-NspCountTableRow $rows "Missing count" $null 0
Assert-True ($rows.ToString() -match "<td class='num'>-</td><td class='num'>0</td><td class='num'>-</td><td class='num'>-</td>") "Missing counts must not be confused with zero."

$sandbox = [regex]::Match($content, "(?s)<h2>5\. Sandbox-Analyse</h2>.*?</section>").Value
Assert-True ([regex]::Matches($sandbox, "<tr><td>").Count -eq 2) "Sandbox must show two metrics."
Assert-True ($sandbox.Contains("Sind Tracking-Details gelöscht")) "Sandbox results must explain the effect of deleted tracking details."
$mime = [regex]::Match($raw, "(?s)<h2>9\. Häufigste MIME-Typen.*?</section>").Value
Assert-True ([regex]::Matches($mime, "<details class='mime-details'>").Count -eq 2) "MIME types must have independent collapsed details."
Assert-True (-not ($mime -match "<details[^>]*\sopen")) "MIME details must initially be closed."
Assert-True ($mime.Contains("text/&lt;script&gt;") -and -not $mime.Contains("text/<script>")) "MIME labels must be HTML encoded."
Assert-True ($mime.Contains("Aktuell: 3") -and $mime.Contains("Vergleich: 2")) "Collapsed MIME summaries must show both counts."
Assert-True ($mime.Contains("Status der Nachricht: Erfolgreich zugestellt")) "MIME details must use translated status labels."

$previous.MalwareRejectEvidence.InfectedPartCount = 2
$different = [Net.WebUtility]::HtmlDecode((New-NspReportContent $data))
Assert-True ($different.Contains("<td>infizierte Mailteile</td>")) "Different malware measures must not be hidden."
$current.MalwareRejectEvidence.EvidenceComplete = $false
$incomplete = [Net.WebUtility]::HtmlDecode((New-NspReportContent $data))
Assert-True ($incomplete -match "infizierte Mailteile</td><td class='num'>-</td>") "Incomplete malware evidence must be displayed as a dash."

$current.AttachmentCounts = @{}
$previous.AttachmentCounts = @{}
$empty = New-NspReportContent $data
Assert-True ($empty.Contains("Keine Anhangsdaten in diesem Zeitraum.")) "An empty MIME list must be explained."
Assert-True (-not $empty.Contains("<details class='mime-details'>")) "An empty MIME list must not contain details."
Write-Host "Report presentation tests passed."
