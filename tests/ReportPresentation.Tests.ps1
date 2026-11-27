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

$templateParameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Template" })[0]
Assert-True ($templateParameter.DefaultValue.SafeGetValue() -eq "NSP-dark") "NSP-dark must be the default template."
$invalidTemplateRejected = $false
try { & (Join-Path $root "Get-PermanentlyBlocked.ps1") -Help -Template "unknown" | Out-Null }
catch [System.Management.Automation.ParameterBindingException] { $invalidTemplateRejected = $true }
Assert-True $invalidTemplateRejected "An unknown template must be rejected before the report runs."
foreach ($design in @("NSP-dark", "NSP-light", "NSP-Classic")) {
    $templateFile = if ($design -eq "NSP-Classic") { "template.html" } else { "template-" + $design.ToLowerInvariant() + ".html" }
    $templatePath = Join-Path $root $templateFile
    $templateHtml = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    foreach ($placeholder in @("{{CURRENT_RANGE}}", "{{PREVIOUS_RANGE}}", "{{KPI_CARDS}}", "{{REPORT_CONTENT}}", "{{GENERATED_AT}}", "{{REPORT_VERSION}}")) {
        Assert-True ($templateHtml.Contains($placeholder)) "$design is missing $placeholder."
    }
    if ($design -ne "NSP-Classic") { Assert-True ($templateHtml.Contains("{{OVERVIEW}}")) "$design is missing the overview." }
    Assert-True ($null -ne (Get-NspEmbeddedLogo $templateHtml)) "$design must contain the embedded logo."
}

$mailFixtureRoot = Join-Path $env:TEMP ("nsp-mail-test-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $mailFixtureRoot | Out-Null
    $htmlPath = Join-Path $mailFixtureRoot "report.html"
    $pdfPath = Join-Path $mailFixtureRoot "report.pdf"
    [IO.File]::WriteAllText($htmlPath, "<html>fixture</html>")
    [IO.File]::WriteAllText($pdfPath, "PDF fixture")
    $range = "2026-11-13 bis einschließlich 2026-11-26 (UTC)"
    foreach ($case in @(
            @{ Type = "HTML"; Ready = $false; Expected = @("NoSpamProxy-Report.html") },
            @{ Type = "PDF"; Ready = $true; Expected = @("NoSpamProxy-Report.pdf") },
            @{ Type = "Both"; Ready = $true; Expected = @("NoSpamProxy-Report.html", "NoSpamProxy-Report.pdf") },
            @{ Type = "PDF"; Ready = $false; Expected = @("NoSpamProxy-Report.html") },
            @{ Type = "Both"; Ready = $false; Expected = @("NoSpamProxy-Report.html") }
        )) {
        $message = New-NspReportMailMessage -Sender "sender@example.invalid" -Recipients @("recipient@example.invalid") `
            -Subject "Fixture" -CurrentRange $range -HtmlPath $htmlPath -PdfPath $pdfPath `
            -ReportType $case.Type -PdfReady $case.Ready
        try {
            Assert-True (-not $message.IsBodyHtml -and $message.AlternateViews.Count -eq 0) "Every report email must use only a plain-text body."
            Assert-True ($message.Body -eq "NoSpamProxy Analysebericht im Anhang für den Zeitraum $range.") "The email body must show the requested current period."
            $names = @($message.Attachments | ForEach-Object { $_.Name })
            Assert-True (($names -join ",") -eq ($case.Expected -join ",")) "Report attachments must remain correct for $($case.Type)."
            if ($case.Type -eq "Both" -and $case.Ready) {
                $client = [Net.Mail.SmtpClient]::new()
                try {
                    $client.DeliveryMethod = [Net.Mail.SmtpDeliveryMethod]::SpecifiedPickupDirectory
                    $client.PickupDirectoryLocation = $mailFixtureRoot
                    $client.Send($message)
                }
                finally { $client.Dispose() }
                $eml = @(Get-ChildItem -LiteralPath $mailFixtureRoot -Filter "*.eml")
                Assert-True ($eml.Count -eq 1) "MIME test message must be created."
                $mime = [IO.File]::ReadAllText($eml[0].FullName)
                Assert-True (([regex]::Matches($mime, '(?im)^Content-Type:\s*text/plain\b')).Count -eq 1) "MIME output must have one plain-text body."
                Assert-True (([regex]::Matches($mime, '(?im)^Content-Type:\s*text/html\b')).Count -eq 1) "MIME output must not have an HTML body in addition to the HTML attachment."
                Assert-True ($mime -notmatch '(?im)^Content-Type:\s*multipart/(alternative|related)\b') "MIME output must not contain HTML or inline-logo alternatives."
            }
        }
        finally { $message.Dispose() }
    }
}
finally {
    if (Test-Path -LiteralPath $mailFixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $mailFixtureRoot -Recurse -Force
    }
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
foreach ($design in @("NSP-dark", "NSP-light")) {
    $cards = New-NspKpiCards $data -Design $design
    $metrics = @([regex]::Matches($cards, "(?s)<article class='metric'>.*?</article>") | ForEach-Object { $_.Value })
    Assert-True ($metrics.Count -eq 4) "$design must show four metrics."
    Assert-True ($metrics[0].Contains("Nachrichtentracks") -and $metrics[0].Contains("+50 (+50,00%)")) "Message KPI must show its comparison change."
    Assert-True ($metrics[1].Contains("Dauerhaft blockiert") -and $metrics[1].Contains("+10 (+100,00%)")) "Permanent KPI must compare permanent counts."
    Assert-True ($metrics[2].Contains("Temporär blockiert") -and $metrics[2].Contains("0 (0,00%)")) "Temporary KPI must show unchanged counts."
    Assert-True ($metrics[3].Contains("Blockierungen gesamt") -and $metrics[3].Contains("+10 (+50,00%)")) "Total block KPI must compare combined counts."
    $overview = New-NspOverview $data -Design $design
    Assert-True ($overview.Contains("50,00%") -and $overview.Contains("15 aktuell") -and $overview.Contains("5 im Vergleichszeitraum")) "$design must show accurate reason shares and counts."
    $zeroData = [pscustomobject]@{ Current = (New-TestPeriod); Comparison = (New-TestPeriod) }
    $zeroOverview = New-NspOverview $zeroData -Design $design
    Assert-True ($zeroOverview.Contains("width:0%") -and -not $zeroOverview.Contains("NaN")) "$design must handle a zero denominator."
    if ($design -eq "NSP-dark") {
        Assert-True ($overview.Contains("20,00%") -and $overview.Contains(">120</strong>")) "Dark distribution must use total and blocked tracks."
    }
}
$classicCards = New-NspKpiCards $data -Design "NSP-Classic"
$classicMetrics = @([regex]::Matches($classicCards, "(?s)<td class='metric'>.*?</td>") | ForEach-Object { $_.Value })
Assert-True ($classicCards.Contains('<table class="metrics" role="presentation">') -and $classicMetrics.Count -eq 4) "Classic must preserve the original table-based KPI layout."
Assert-True ($classicMetrics[0].Contains("Nachrichtentracks aktuell") -and $classicMetrics[0].Contains("Vergleichszeitraum: 100<br>Veränderung: +50 (+50,00%)")) "Classic must show message KPI and its comparison."
Assert-True ($classicMetrics[1].Contains("Dauerhaft blockiert") -and $classicMetrics[1].Contains("Veränderung: +10 (+100,00%)")) "Classic must retain permanent block comparisons."
Assert-True ($classicMetrics[2].Contains("Temporär blockiert") -and $classicMetrics[2].Contains("Veränderung: 0 (0,00%)")) "Classic must retain unchanged comparisons."
Assert-True ($classicMetrics[3].Contains("Blockierungen gesamt") -and $classicMetrics[3].Contains("Veränderung: +10 (+50,00%)")) "Classic must retain combined block comparisons."
Assert-True ((Format-NspKpiChange 20 30) -eq '-10 (-33,33%)') "Decreases must have a minus sign."
Assert-True ((Format-NspKpiChange 5 0) -eq '+5 (-)') "A zero baseline must not produce a percentage."
Assert-True ((Format-NspKpiChange $null 5) -eq '-') "An unavailable value must not produce a change."

$current | Add-Member -NotePropertyName StartUtc -NotePropertyValue ([DateTime]::Parse("2026-11-13T00:00:00Z").ToUniversalTime())
$current | Add-Member -NotePropertyName EndUtc -NotePropertyValue ([DateTime]::Parse("2026-11-27T00:00:00Z").ToUniversalTime())
$previous | Add-Member -NotePropertyName StartUtc -NotePropertyValue ([DateTime]::Parse("2026-10-30T00:00:00Z").ToUniversalTime())
$previous | Add-Member -NotePropertyName EndUtc -NotePropertyValue ([DateTime]::Parse("2026-11-13T00:00:00Z").ToUniversalTime())
$data | Add-Member -NotePropertyName GeneratedAtUtc -NotePropertyValue ([DateTime]::Parse("2026-11-27T01:00:00Z").ToUniversalTime())
$entryFixtureRoot = Join-Path $env:TEMP ("nsp-entry-test-" + [guid]::NewGuid().ToString("N"))
$savedKey = $env:NSP_API_KEY
try {
    New-Item -ItemType Directory -Path $entryFixtureRoot | Out-Null
    foreach ($file in @("Get-PermanentlyBlocked.ps1", "template.html", "template-nsp-dark.html", "template-nsp-light.html")) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $entryFixtureRoot $file)
    }
    $stub = @'
function Get-NspODataReportDataWithProgress {
    param($BaseUrl, $ApiKey, $Days, $ODataScriptPath, $Stopwatch)
    if ($global:NspFixtureFail) { throw "fixture request failed" }
    return $global:NspFixtureReport
}
function Write-NspReportProgress { param($Status, $Stopwatch) }
'@
    [IO.File]::WriteAllText((Join-Path $entryFixtureRoot "ReportOData.ps1"), $stub, [Text.UTF8Encoding]::new($true))
    function Write-Progress {
        param($Id, $Activity, [switch] $Completed)
        if ($Id -eq 42 -and $Completed) { $global:NspFixtureCompleted++ }
    }
    $global:NspFixtureReport = $data
    $global:NspFixtureFail = $false
    $env:NSP_API_KEY = "fixture"
    foreach ($design in @("NSP-dark", "NSP-light", "NSP-Classic")) {
        $global:NspFixtureCompleted = 0
        $output = Join-Path $entryFixtureRoot "$design.html"
        $arguments = @{ ODataBaseUrl = "https://example.invalid"; NoSend = $true; ReportType = "HTML"; OutputPath = $output }
        if ($design -ne "NSP-dark") { $arguments.Template = $design }
        & (Join-Path $entryFixtureRoot "Get-PermanentlyBlocked.ps1") @arguments
        $html = [IO.File]::ReadAllText($output)
        Assert-True ($global:NspFixtureCompleted -eq 1) "$design must complete the progress indicator after NoSend."
        Assert-True (-not $html.Contains("{{") -and $html.Contains("Sandbox-Analyse")) "$design must render a complete report."
        if ($design -eq "NSP-Classic") {
            Assert-True ($html.Contains('<table class="metrics" role="presentation">')) "Classic selection must use the original layout."
        }
        else {
            Assert-True ($html.Contains($design)) "$design selection must use the matching template."
        }
    }
    $global:NspFixtureFail = $true
    $global:NspFixtureCompleted = 0
    $failed = $false
    try {
        & (Join-Path $entryFixtureRoot "Get-PermanentlyBlocked.ps1") -ODataBaseUrl "https://example.invalid" `
            -NoSend -ReportType HTML -OutputPath (Join-Path $entryFixtureRoot "failure.html")
    }
    catch {
        if ($_.Exception.Message -like "*fixture request failed*") { $failed = $true }
        else { throw }
    }
    Assert-True ($failed -and $global:NspFixtureCompleted -eq 1) "Failed report generation must complete the progress indicator and surface the error."
}
finally {
    Remove-Item Function:\Write-Progress -ErrorAction SilentlyContinue
    Remove-Variable NspFixtureReport, NspFixtureFail, NspFixtureCompleted -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $savedKey) { Remove-Item Env:\NSP_API_KEY -ErrorAction SilentlyContinue }
    else { $env:NSP_API_KEY = $savedKey }
    if (Test-Path -LiteralPath $entryFixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $entryFixtureRoot -Recurse -Force
    }
}

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
Assert-True (-not ($content -match "<h2>[1-9]\. ")) "Report panel headings must not be numbered."
foreach ($id in @("status", "reasons", "filter", "malware", "sandbox", "urls", "recall", "deepfile", "mime")) {
    Assert-True ($raw.Contains("id='$id'")) "Missing navigation target: $id"
}

$rows = [System.Text.StringBuilder]::new()
Add-NspPercentTableRow $rows "Other percentage" 30 20
Assert-True ($rows.ToString() -match "<td class='num'>10,00 PP</td><td class='num'>50,00%</td>") "Other percentage differences must remain in percentage points."
$rows.Clear() | Out-Null
Add-NspPercentTableRow $rows "Zero comparison" 30 0 -RelativeDifference
Assert-True ($rows.ToString() -match "<td class='num'>30,00%</td><td class='num'>0,00%</td><td class='num'>-</td><td class='num'>-</td>") "A relative difference from zero must be unavailable."
$rows.Clear() | Out-Null
Add-NspCountTableRow $rows "Missing count" $null 0
Assert-True ($rows.ToString() -match "<td class='num'>-</td><td class='num'>0</td><td class='num'>-</td><td class='num'>-</td>") "Missing counts must not be confused with zero."

$sandbox = [regex]::Match($content, "(?s)<h2>Sandbox-Analyse</h2>.*?</section>").Value
Assert-True ([regex]::Matches($sandbox, "<tr><td>").Count -eq 2) "Sandbox must show two metrics."
Assert-True ($sandbox.Contains("Sind Tracking-Details gelöscht")) "Sandbox results must explain the effect of deleted tracking details."
$mime = [regex]::Match($raw, "(?s)<h2>Häufigste MIME-Typen.*?</section>").Value
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
