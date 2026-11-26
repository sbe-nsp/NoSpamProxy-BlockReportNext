<#
.SYNOPSIS
Erstellt einen OData-basierten NoSpamProxy-Bericht für zwei vollständige 14-Tage-Zeiträume.
.DESCRIPTION
Ruft alle Berichtsdaten ausschließlich lesend über die NoSpamProxy-OData-API ab. Mit -NoSend wird
der HTML-Bericht lokal gespeichert, ohne eine E-Mail zu versenden. Der PAT muss in NSP_API_KEY stehen.
Der Bericht vergleicht zwei vollständige 14-Tage-Zeiträume in UTC. Nicht belegbare Kennzahlen
werden als n/a angezeigt. Das eingebettete Logo erfordert keine separate Bilddatei.
.PARAMETER Help
Zeigt diese ausführliche Hilfe an, ohne einen Bericht zu erstellen oder die API aufzurufen.
.PARAMETER ReportType
Berichtsformat beim E-Mail-Versand: HTML, PDF oder Both (Standard). PDF benötigt Microsoft Edge;
ohne Edge oder bei einem PDF-Fehler wird HTML als Fallback verwendet.
.PARAMETER SMTPHosts
Ein oder mehrere SMTP-Relay-Hostnamen/IP-Adressen. Versand über TCP 25; die Beispielwerte ersetzen.
.PARAMETER ReportSender
Absenderadresse; die Beispieladresse ersetzen.
.PARAMETER ReportRecipients
Eine oder mehrere BCC-Empfänger; die Beispieladresse ersetzen.
.PARAMETER ReportSubject
E-Mail-Betreff. Standard: NoSpamProxy: Permanently blocked report.
.PARAMETER ODataBaseUrl
Erforderliche HTTPS-Basis-URL der eigenen NoSpamProxy-Service-API.
.PARAMETER NoSend
Erstellt den Bericht ohne SMTP-Versand.
.PARAMETER OutputPath
Zieldateipfad für den HTML-Bericht; bei -NoSend erforderlich und sonst nicht zulässig.
.EXAMPLE
.\Get-PermanentlyBlocked.ps1 -Help
Zeigt die Hilfe an. API-Schlüssel und SMTP-Konfiguration sind hierfür nicht erforderlich.
.EXAMPLE
$securePat = Read-Host 'NoSpamProxy PAT' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
try {
    $env:NSP_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    .\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -NoSend -OutputPath "$env:TEMP\report.html"
} finally {
    Remove-Item Env:\NSP_API_KEY -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
}
Erstellt einen HTML-Bericht ohne E-Mail-Versand; die PAT-Eingabe erfolgt verdeckt. Die Beispiel-URL
muss durch die eigene Service-API-Basis-URL ersetzt werden.
.EXAMPLE
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -SMTPHosts 'smtp-relay.example.local' -ReportSender 'nsp-report@example.local' -ReportRecipients 'admin@example.local'
Versendet den Bericht über einen konfigurierten SMTP-Relay. Der PAT muss bereits in NSP_API_KEY stehen.
.NOTES
Die Zeitfenster sind UTC, jeweils Start inklusiv und Ende exklusiv. SQL wird nicht verwendet.
#>
[CmdletBinding()]
param(
    [ValidateSet("HTML", "PDF", "Both")]
    [string] $ReportType = "Both",
    [string[]] $SMTPHosts = @("192.0.2.1", "192.0.2.2"),
    [string] $ReportSender = "admin@example.invalid",
    [string[]] $ReportRecipients = @("admin@example.invalid"),
    [string] $ReportSubject = "NoSpamProxy: Permanently blocked report",
    [string] $ODataBaseUrl,
    [switch] $NoSend,
    [string] $OutputPath,
    [switch] $Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    return
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$reportVersion = "1.5.1 (Build 20261126.4, 2026-11-26)"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web
. (Join-Path $PSScriptRoot "ReportOData.ps1")

function ConvertTo-NspHtml {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return "" }
    return [System.Web.HttpUtility]::HtmlEncode([string]$Value)
}

function Get-NspEmbeddedLogo {
    param([Parameter(Mandatory = $true)][string] $Template)

    $matches = [regex]::Matches($Template, 'data:image/png;base64,([A-Za-z0-9+/=]+)')
    if ($matches.Count -ne 1) { throw "The report template must contain exactly one embedded PNG logo." }
    try { $bytes = [Convert]::FromBase64String($matches[0].Groups[1].Value) }
    catch { throw "The embedded report logo is not valid base64." }
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($bytes.Length -lt $signature.Length) { throw "The embedded report logo is not a PNG image." }
    for ($i = 0; $i -lt $signature.Length; $i++) {
        if ($bytes[$i] -ne $signature[$i]) { throw "The embedded report logo is not a PNG image." }
    }
    return [pscustomobject]@{ DataUri = $matches[0].Value; Bytes = $bytes }
}

function New-NspInlineLogoView {
    param(
        [Parameter(Mandatory = $true)][string] $Html,
        [Parameter(Mandatory = $true)][byte[]] $LogoBytes
    )

    $htmlView = [Net.Mail.AlternateView]::CreateAlternateViewFromString($Html, [Text.Encoding]::UTF8, "text/html")
    $logoStream = [IO.MemoryStream]::new($LogoBytes)
    $logoResource = [Net.Mail.LinkedResource]::new($logoStream, "image/png")
    $logoResource.ContentId = "nsp-report-logo"
    $logoResource.TransferEncoding = [Net.Mime.TransferEncoding]::Base64
    $htmlView.LinkedResources.Add($logoResource)
    return $htmlView
}

function Format-NspCount {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return "n/a" }
    return ([long]$Value).ToString("N0", [Globalization.CultureInfo]::GetCultureInfo("de-DE"))
}

function Format-NspPercent {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return "n/a" }
    return ([double]$Value).ToString("N2", [Globalization.CultureInfo]::GetCultureInfo("de-DE")) + "%"
}

function Get-NspDictionaryCount {
    param(
        [AllowNull()] $Dictionary,
        [Parameter(Mandatory = $true)][string] $Key
    )
    if ($null -eq $Dictionary -or -not $Dictionary.Contains($Key)) { return [long]0 }
    return [long]$Dictionary[$Key]
}

function Add-NspCountTableRow {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder,
        [Parameter(Mandatory = $true)][string] $Label,
        [AllowNull()] $Current,
        [AllowNull()] $Previous,
        [string] $Unit = ""
    )

    $safeLabel = ConvertTo-NspHtml $Label
    if ($null -eq $Current -or $null -eq $Previous) {
        [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspCount $Current)$Unit</td><td class='num'>$(Format-NspCount $Previous)$Unit</td><td class='num'>n/a</td><td class='num'>n/a</td></tr>")
        return
    }

    $currentValue = [double]$Current
    $previousValue = [double]$Previous
    $delta = $currentValue - $previousValue
    $change = if ($previousValue -eq 0) { "n/a" } else { Format-NspPercent (($delta / $previousValue) * 100) }
    $deltaText = if ($delta -gt 0) { "+" + (Format-NspCount $delta) } else { Format-NspCount $delta }
    $deltaText += $Unit
    [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspCount $Current)$Unit</td><td class='num'>$(Format-NspCount $Previous)$Unit</td><td class='num'>$deltaText</td><td class='num'>$change</td></tr>")
}

function Add-NspPercentTableRow {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder,
        [Parameter(Mandatory = $true)][string] $Label,
        [AllowNull()] $Current,
        [AllowNull()] $Previous
    )

    $safeLabel = ConvertTo-NspHtml $Label
    if ($null -eq $Current -or $null -eq $Previous) {
        [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspPercent $Current)</td><td class='num'>$(Format-NspPercent $Previous)</td><td class='num'>n/a</td><td class='num'>n/a</td></tr>")
        return
    }

    $delta = [double]$Current - [double]$Previous
    $change = if ([double]$Previous -eq 0) { "n/a" } else { Format-NspPercent (($delta / [double]$Previous) * 100) }
    $deltaText = (Format-NspPercent $delta).Replace("%", " PP")
    [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspPercent $Current)</td><td class='num'>$(Format-NspPercent $Previous)</td><td class='num'>$deltaText</td><td class='num'>$change</td></tr>")
}

function Add-NspPanel {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $TableRows,
        [string] $Footnote = ""
    )

    $safeTitle = ConvertTo-NspHtml $Title
    [void]$Builder.AppendLine("<section class='panel'><h2>$safeTitle</h2><div class='table-wrap'><table><thead><tr><th>Messwert</th><th class='num'>Aktuell</th><th class='num'>Vergleich</th><th class='num'>Differenz</th><th class='num'>Änderung</th></tr></thead><tbody>$TableRows</tbody></table></div>")
    if ($Footnote) { [void]$Builder.AppendLine("<p class='footnote'>$(ConvertTo-NspHtml $Footnote)</p>") }
    [void]$Builder.AppendLine("</section>")
}

function Get-NspActionTotal {
    param(
        [Parameter(Mandatory = $true)] $Period,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Decision
    )
    $total = [long]0
    foreach ($key in $Period.ActionCounts.Keys) {
        $parts = $key.Split("|")
        if ($parts.Count -ge 2 -and $parts[0] -eq $Name -and $parts[1] -eq $Decision) {
            $total += [long]$Period.ActionCounts[$key]
        }
    }
    return $total
}

function Get-NspActionUniqueMessageCount {
    param(
        [Parameter(Mandatory = $true)] $Period,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Decision
    )
    $key = "$Name|$Decision"
    return Get-NspDictionaryCount $Period.ActionUniqueMessages $key
}

function Get-NspPeriodBlockTotal {
    param([Parameter(Mandatory = $true)] $Period)
    return (Get-NspDictionaryCount $Period.StatusCounts "PermanentlyBlocked") +
        (Get-NspDictionaryCount $Period.StatusCounts "TemporarilyBlocked")
}

function Get-NspPeriodRejectReasonShare {
    param(
        [Parameter(Mandatory = $true)] $Period,
        [Parameter(Mandatory = $true)][string] $Reason
    )
    $blocked = Get-NspPeriodBlockTotal $Period
    if ($blocked -eq 0) { return $null }
    return ([double](Get-NspDictionaryCount $Period.RejectReasonCounts $Reason) / $blocked) * 100
}

function New-NspReportContent {
    param([Parameter(Mandatory = $true)] $ReportData)

    $current = $ReportData.Current
    $previous = $ReportData.Comparison
    $content = [System.Text.StringBuilder]::new()

    $statusRows = [System.Text.StringBuilder]::new()
    $allStatuses = @("Success", "PermanentlyBlocked", "TemporarilyBlocked", "DispatcherError", "DeliveryPending", "PartialSuccess", "Suppressed", "PutOnHold")
    $allStatuses += @($current.StatusCounts.Keys) + @($previous.StatusCounts.Keys)
    $allStatuses = @($allStatuses | Where-Object { $_ -and $_ -ne "DuplicateDrop" } | Sort-Object -Unique)
    foreach ($status in $allStatuses) {
        Add-NspCountTableRow $statusRows $status `
            (Get-NspDictionaryCount $current.StatusCounts $status) `
            (Get-NspDictionaryCount $previous.StatusCounts $status)
    }
    Add-NspCountTableRow $statusRows "Gesamt verarbeitete Nachrichtentracks" $current.MessageTotal $previous.MessageTotal
    Add-NspPanel $content "1. Nachrichtenübersicht" $statusRows.ToString() `
        "Statuswerte werden direkt aus MessageTrackSummaries übernommen. Die Gesamtzahl enthält jeden Nachrichtentrack genau einmal, einschließlich nicht separat angezeigter Statuswerte."

    $reasonRows = [System.Text.StringBuilder]::new()
    $reasons = @("Policy", "SpamOrVirus") +
        @($current.RejectReasonCounts.Keys) + @($previous.RejectReasonCounts.Keys)
    $reasons = @($reasons | Where-Object { $_ -and $_ -notin @("LoopDetected", "None") } | Sort-Object -Unique)
    foreach ($reason in $reasons) {
        Add-NspCountTableRow $reasonRows $reason `
            (Get-NspDictionaryCount $current.RejectReasonCounts $reason) `
            (Get-NspDictionaryCount $previous.RejectReasonCounts $reason)
        Add-NspPercentTableRow $reasonRows "$reason – Anteil an blockierten Nachrichten" `
            (Get-NspPeriodRejectReasonShare $current $reason) `
            (Get-NspPeriodRejectReasonShare $previous $reason)
    }
    Add-NspPanel $content "2. Blockierungsgründe" $reasonRows.ToString() `
        "Die Anteile verwenden alle dauerhaft und temporär blockierten Nachrichtentracks als Nenner, einschließlich der ausgeblendeten Gründe LoopDetected und None. Differenzen von Anteilen sind in Prozentpunkten (PP) angegeben."

    $filterRows = [System.Text.StringBuilder]::new()
    $filterNames = @("realtimeBlocklist", "OutbreakDetectionFilter", "bitdefenderFilter", "reputation", "wordFilter", "surblFilter", "csaWhitelist")
    $filterNames += @($current.FilterCounts.Keys) + @($previous.FilterCounts.Keys)
    $filterNames = @($filterNames | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($name in $filterNames) {
        $currentBucket = $current.FilterCounts[$name]
        $previousBucket = $previous.FilterCounts[$name]
        $currentPositiveScl = if ($currentBucket) { $currentBucket.PositiveScl } else { [long]0 }
        $previousPositiveScl = if ($previousBucket) { $previousBucket.PositiveScl } else { [long]0 }
        if ($currentPositiveScl -gt 0 -or $previousPositiveScl -gt 0) {
            $displayName = $name -replace "(?i)bitdefender(?:filter)?", "CSA / AV Engine"
            Add-NspCountTableRow $filterRows $displayName $currentPositiveScl $previousPositiveScl
        }
    }
    if ($filterRows.Length -eq 0) {
        [void]$filterRows.AppendLine("<tr><td colspan='5'>Keine Filtertreffer in beiden Zeiträumen.</td></tr>")
    }
    $engineRows = [System.Text.StringBuilder]::new()
    $engineActions = @(
        @{ Name = "OutbreakDetection"; Decision = "RejectPermanent" },
        @{ Name = "OutbreakDetection"; Decision = "RejectTemporarily" },
        @{ Name = "validateSignatureAndDecrypt"; Decision = "RejectPermanent" },
        @{ Name = "malwareScan"; Decision = "RejectPermanent" },
        @{ Name = "fraudDetection"; Decision = "RejectPermanent" },
        @{ Name = "greylisting"; Decision = "RejectTemporarily" },
        @{ Name = "ContentFiltering"; Decision = "RejectTemporarily" }
    )
    $knownActionKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($engineAction in $engineActions) {
        [void]$knownActionKeys.Add("$($engineAction.Name)|$($engineAction.Decision)")
    }
    $observedActionKeys = @(@($current.ActionCounts.Keys) + @($previous.ActionCounts.Keys) | Sort-Object -Unique)
    foreach ($key in $observedActionKeys) {
        if (-not $knownActionKeys.Contains([string]$key)) {
            $parts = [string]$key -split "\|", 2
            if ($parts.Count -eq 2) {
                $engineActions += @{ Name = $parts[0]; Decision = $parts[1] }
                [void]$knownActionKeys.Add([string]$key)
            }
        }
    }
    foreach ($engineAction in $engineActions) {
        $name = $engineAction.Name
        $decision = $engineAction.Decision
        Add-NspCountTableRow $engineRows "$name / $decision – Ereignisse" `
            (Get-NspActionTotal $current $name $decision) `
            (Get-NspActionTotal $previous $name $decision)
        $showDetails = "$name|$decision" -notin @(
                "OutbreakDetection|RejectPermanent", "OutbreakDetection|RejectTemporarily",
                "validateSignatureAndDecrypt|RejectPermanent", "malwareScan|RejectPermanent",
                "fraudDetection|RejectPermanent", "greylisting|RejectTemporarily",
                "ContentFiltering|RejectTemporarily"
            )
        if ($showDetails) {
            Add-NspCountTableRow $engineRows "$name / $decision – eindeutige MailIds" `
                (Get-NspActionUniqueMessageCount $current $name $decision) `
                (Get-NspActionUniqueMessageCount $previous $name $decision)
            $key = "$name|$decision"
            Add-NspCountTableRow $engineRows "$name / $decision – Ereignisse ohne MailId" `
                (Get-NspDictionaryCount $current.ActionUnattributedEvents $key) `
                (Get-NspDictionaryCount $previous.ActionUnattributedEvents $key)
        }
    }
    Add-NspPanel $content "Engine-Aktionen" $engineRows.ToString() `
        "Ereignisse und, soweit angezeigt, eindeutige MailIds sind unterschiedliche Zählweisen. Eine Nachricht kann mehrere Filter- und Aktionsereignisse erzeugen. Der Filter reputation belegt keine 32GUARDS-Zuordnung."

    $contentActionRows = [System.Text.StringBuilder]::new()
    foreach ($decision in @("RejectPermanent", "RejectTemporarily")) {
        Add-NspCountTableRow $contentActionRows "ContentFiltering / $decision – Ereignisse" `
            (Get-NspActionTotal $current "ContentFiltering" $decision) `
            (Get-NspActionTotal $previous "ContentFiltering" $decision)
    }
    Add-NspCountTableRow $contentActionRows "Temporär abgelehnte Anhänge" $null $null
    Add-NspCountTableRow $contentActionRows "Permanent abgelehnte Anhänge" $null $null
    Add-NspCountTableRow $contentActionRows "Abgelehnte Anhänge insgesamt" $null $null
    Add-NspCountTableRow $contentActionRows "Anhänge: IsQuarantined=true" $current.QuarantineCounts.True $previous.QuarantineCounts.True
    Add-NspCountTableRow $contentActionRows "Anhänge: IsQuarantined=false" $current.QuarantineCounts.False $previous.QuarantineCounts.False
    Add-NspCountTableRow $contentActionRows "Anhänge: IsQuarantined=null / nicht gemeldet" $current.QuarantineCounts.Null $previous.QuarantineCounts.Null
    Add-NspPanel $content "3. ContentFiltering und Anhang-Quarantäne" $contentActionRows.ToString() `
        "Actions sind Ereignisse auf Nachrichtenebene und keine eindeutigen Anhangszähler. Die API weist Anhängen keinen ContentFiltering-Entscheidungsstatus zu. null wird nicht als false interpretiert."
    Add-NspPanel $content "Filtertreffer bei dauerhaft blockierten Nachrichten" $filterRows.ToString() `
        "Gezählt werden Filterereignisse mit positiver Bewertung. Mehrere Ereignisse können dieselbe Nachricht betreffen; ein Filtertreffer allein belegt nicht, dass dieser Filter die Blockierung verursacht hat."

    $malwareRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $malwareRows "MalwareScan-Operationen" `
        (Get-NspDictionaryCount $current.OperationCounts "MalwareScan") `
        (Get-NspDictionaryCount $previous.OperationCounts "MalwareScan")
    $currentInfectedParts = if ($current.MalwareRejectEvidence.EvidenceComplete) { $current.MalwareRejectEvidence.InfectedPartCount } else { $null }
    $previousInfectedParts = if ($previous.MalwareRejectEvidence.EvidenceComplete) { $previous.MalwareRejectEvidence.InfectedPartCount } else { $null }
    $malwareMeasures = @(
        @{ Label = "Ablehnungsaktionen"; Current = $current.MalwareRejectEvidence.RejectActionEventCount; Previous = $previous.MalwareRejectEvidence.RejectActionEventCount },
        @{ Label = "abgewiesene Nachrichten"; Current = $current.MalwareRejectEvidence.RejectedMessageCount; Previous = $previous.MalwareRejectEvidence.RejectedMessageCount },
        @{ Label = "Nachrichtentracks"; Current = $current.MalwareRejectEvidence.RejectedTrackCount; Previous = $previous.MalwareRejectEvidence.RejectedTrackCount },
        @{ Label = "infizierte Mailteile"; Current = $currentInfectedParts; Previous = $previousInfectedParts }
    )
    $usedMeasures = [bool[]]::new($malwareMeasures.Count)
    for ($i = 0; $i -lt $malwareMeasures.Count; $i++) {
        if ($usedMeasures[$i]) { continue }
        $measure = $malwareMeasures[$i]
        $labels = [System.Collections.Generic.List[string]]::new()
        $labels.Add($measure.Label)
        if ($null -ne $measure.Current -and $null -ne $measure.Previous) {
            for ($j = $i + 1; $j -lt $malwareMeasures.Count; $j++) {
                $candidate = $malwareMeasures[$j]
                if (-not $usedMeasures[$j] -and $null -ne $candidate.Current -and $null -ne $candidate.Previous -and
                    $measure.Current -eq $candidate.Current -and $measure.Previous -eq $candidate.Previous) {
                    $labels.Add($candidate.Label)
                    $usedMeasures[$j] = $true
                }
            }
        }
        Add-NspCountTableRow $malwareRows ($labels -join " / ") $measure.Current $measure.Previous
    }
    $currentScans = Get-NspDictionaryCount $current.OperationCounts "MalwareScan"
    $previousScans = Get-NspDictionaryCount $previous.OperationCounts "MalwareScan"
    $currentMalwareRate = if ($currentScans -gt 0 -and $current.MalwareRejectEvidence.EvidenceComplete) {
        ([double]$current.MalwareRejectEvidence.MatchingOperationCount / $currentScans) * 100
    } else { $null }
    $previousMalwareRate = if ($previousScans -gt 0 -and $previous.MalwareRejectEvidence.EvidenceComplete) {
        ([double]$previous.MalwareRejectEvidence.MatchingOperationCount / $previousScans) * 100
    } else { $null }
    Add-NspPercentTableRow $malwareRows "Fundrate (zugeordnete RejectPermanent-Scans / alle MalwareScan-Operationen)" $currentMalwareRate $previousMalwareRate
    Add-NspPanel $content "4. MalwareScan" $malwareRows.ToString() `
        "RejectPermanent-Aktionen werden anhand von MessageTrackId mit MalwareScan-Operationen korreliert. Bei unvollständiger Zuordnung werden infizierte Mailteile und Fundrate als n/a angezeigt. Gleiche Werte in beiden Zeiträumen werden gemeinsam dargestellt; die genannten Messgrößen bleiben unterschiedlich und belegen keine Eins-zu-eins-Zuordnung."

    $sandboxRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $sandboxRows "Analysevorgänge" $current.SandboxEvidence.OperationCount $previous.SandboxEvidence.OperationCount
    Add-NspCountTableRow $sandboxRows "Analysevorgänge mit bestätigtem Fund" $current.SandboxEvidence.ConfirmedOperationCount $previous.SandboxEvidence.ConfirmedOperationCount
    Add-NspCountTableRow $sandboxRows "Unklare Analysevorgänge" $current.SandboxEvidence.InconclusiveOperationCount $previous.SandboxEvidence.InconclusiveOperationCount
    Add-NspPanel $content "5. Sandbox-Analyse" $sandboxRows.ToString() `
        "Ein bestätigter Fund erfordert den expliziten Ergebnisstatus Infected. Eine Ablehnung oder ein unbekanntes Ergebnis allein belegt keinen Malware-Fund; unklare Vorgänge werden separat gezeigt."

    $urlRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $urlRows "Unterschiedliche gesehene URLs" $current.ObservedUrls.Total $previous.ObservedUrls.Total
    Add-NspCountTableRow $urlRows "Unterschiedliche als bösartig markierte URLs" $current.ObservedUrls.Malicious $previous.ObservedUrls.Malicious
    Add-NspCountTableRow $urlRows "Klicks mit bösartiger Bewertung" $current.UrlVisitCounts.True $previous.UrlVisitCounts.True
    Add-NspPanel $content "6. URL Safeguard" $urlRows.ToString() `
        "URLs werden anhand ihres Hashes einmal pro Zeitraum gezählt; die Zuordnung zum Zeitraum erfolgt über das Sendedatum der Nachricht. Bösartige URLs basieren auf der aktuellen API-Bewertung. Klicks zählen Besuchsereignisse mit bösartiger Bewertung anhand des Besuchszeitpunkts und müssen nicht zu den im selben Zeitraum gesehenen URLs gehören. Fehlende URL-Hashes ergeben n/a."

    $recallRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $recallRows "Eindeutige zurückgerufene Nachrichten (WasRecalled=true)" $current.RecalledMessages $previous.RecalledMessages
    Add-NspPanel $content "7. Zurückgerufene Nachrichten" $recallRows.ToString() `
        "Zählung basiert auf MessageTrackSummaries.WasRecalled=true und eindeutigen MailId-Werten. Einträge ohne MailId werden nicht als eindeutige Nachrichten gezählt."

    $deepRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $deepRows "DeepFileAnalysis-Operationen" $current.DeepFileEvidence.OperationCount $previous.DeepFileEvidence.OperationCount
    Add-NspCountTableRow $deepRows "Nachrichtentracks mit bestätigtem Fund" $current.DeepFileEvidence.ConfirmedTrackCount $previous.DeepFileEvidence.ConfirmedTrackCount
    Add-NspCountTableRow $deepRows "Operationen mit bestätigtem Fund" $current.DeepFileEvidence.ConfirmedOperationCount $previous.DeepFileEvidence.ConfirmedOperationCount
    Add-NspCountTableRow $deepRows "Analyseergebnisse mit Status Infected" $current.DeepFileEvidence.ConfirmedFileCount $previous.DeepFileEvidence.ConfirmedFileCount
    Add-NspCountTableRow $deepRows "Unvollständige / nicht eindeutige Ergebnisse" $current.DeepFileEvidence.InconclusiveOperationCount $previous.DeepFileEvidence.InconclusiveOperationCount
    $deepStatuses = @(@($current.DeepFileEvidence.StatusCounts.Keys) + @($previous.DeepFileEvidence.StatusCounts.Keys) | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($status in $deepStatuses) {
        Add-NspCountTableRow $deepRows "DeepFile-Status: $status" `
            (Get-NspDictionaryCount $current.DeepFileEvidence.StatusCounts $status) `
            (Get-NspDictionaryCount $previous.DeepFileEvidence.StatusCounts $status)
    }
    $deepResultStatuses = @(@($current.DeepFileEvidence.FileStatusCounts.Keys) + @($previous.DeepFileEvidence.FileStatusCounts.Keys) | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($status in $deepResultStatuses) {
        Add-NspCountTableRow $deepRows "DeepFile-Ergebnisstatus: $status" `
            (Get-NspDictionaryCount $current.DeepFileEvidence.FileStatusCounts $status) `
            (Get-NspDictionaryCount $previous.DeepFileEvidence.FileStatusCounts $status)
    }
    Add-NspPanel $content "8. DeepFile-Analyse" $deepRows.ToString() `
        "Als bestätigter Fund zählt ausschließlich ein expliziter Infected-Status auf Ergebnisebene. Übersprungene oder unbekannte Ergebnisse werden nicht als malwarefrei gezählt."

    $mimeRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $mimeRows "Alle Anhänge" $current.TotalAttachments $previous.TotalAttachments
    $mimeRankingSource = if ($current.AttachmentCounts.Count -gt 0) { $current.AttachmentCounts } else { $previous.AttachmentCounts }
    $topMimeTypes = @($mimeRankingSource.GetEnumerator() |
        Sort-Object -Property @{ Expression = { [long]$_.Value.Total }; Descending = $true }, @{ Expression = { [string]$_.Key }; Ascending = $true } |
        Select-Object -First 10)
    if ($topMimeTypes.Count -eq 0) {
        [void]$mimeRows.AppendLine("<tr><td colspan='5'>Keine Anhangsdaten in diesem Zeitraum.</td></tr>")
    }
    else {
        foreach ($entry in $topMimeTypes) {
            $mime = [string]$entry.Key
            $currentBucket = $current.AttachmentCounts[$mime]
            $previousBucket = $previous.AttachmentCounts[$mime]
            $currentCount = if ($currentBucket) { [long]$currentBucket.Total } else { [long]0 }
            $previousCount = if ($previousBucket) { [long]$previousBucket.Total } else { [long]0 }
            [void]$mimeRows.AppendLine("<tr class='section'><td colspan='5'>$(ConvertTo-NspHtml $mime)</td></tr>")
            Add-NspCountTableRow $mimeRows "Anhänge" $currentCount $previousCount
            $currentShare = if ($current.TotalAttachments -gt 0) { ([double]$currentCount / $current.TotalAttachments) * 100 } else { $null }
            $previousShare = if ($previous.TotalAttachments -gt 0 -and $previousBucket) { ([double]$previousCount / $previous.TotalAttachments) * 100 } elseif ($previous.TotalAttachments -gt 0) { 0 } else { $null }
            Add-NspPercentTableRow $mimeRows "Anteil an allen Anhängen" $currentShare $previousShare
            foreach ($status in @("Success", "TemporarilyBlocked", "PermanentlyBlocked")) {
                $currentStatusCounts = if ($currentBucket) { $currentBucket.Status } else { $null }
                $previousStatusCounts = if ($previousBucket) { $previousBucket.Status } else { $null }
                $currentStatus = Get-NspDictionaryCount $currentStatusCounts $status
                $previousStatus = Get-NspDictionaryCount $previousStatusCounts $status
                Add-NspCountTableRow $mimeRows "Status der Nachricht: $status" $currentStatus $previousStatus
            }
            $currentQuarantined = if ($currentBucket) { [long]$currentBucket.Quarantined } else { [long]0 }
            $previousQuarantined = if ($previousBucket) { [long]$previousBucket.Quarantined } else { [long]0 }
            Add-NspCountTableRow $mimeRows "Quarantänisiert (IsQuarantined=true)" $currentQuarantined $previousQuarantined
        }
    }
    $mimeHtml = "<section class='panel'><h2>9. Häufigste MIME-Typen der Anhänge</h2><div class='table-wrap'><table><thead><tr><th>MIME-Typ / Detail</th><th class='num'>Aktuell</th><th class='num'>Vergleich</th><th class='num'>Differenz</th><th class='num'>Änderung</th></tr></thead><tbody>$($mimeRows.ToString())</tbody></table></div><p class='footnote'>Die zehn häufigsten MIME-Typen werden nach aktuellem Zeitraum sortiert; bei leerem aktuellem Zeitraum nach dem Vergleichszeitraum. Statuswerte beziehen sich auf die verknüpfte Nachricht, nicht auf eine anhangspezifische ContentFiltering-Entscheidung. Differenzen von Anteilen sind in Prozentpunkten (PP) angegeben.</p></section>"
    [void]$content.AppendLine($mimeHtml)

    $recipientRows = [System.Text.StringBuilder]::new()
    if ($ReportData.TopSpammers.Count -eq 0) {
        [void]$recipientRows.AppendLine("<tr><td colspan='2'>Keine passenden Empfänger im aktuellen Zeitraum.</td></tr>")
    }
    else {
        foreach ($recipient in $ReportData.TopSpammers) {
            [void]$recipientRows.AppendLine("<tr><td>$(ConvertTo-NspHtml $recipient.Address)</td><td class='num'>$(Format-NspCount $recipient.Count)</td></tr>")
        }
    }
    [void]$content.AppendLine("<section class='panel'><h2>Häufigste Empfänger blockierter Nachrichten</h2><div class='table-wrap'><table><thead><tr><th>Empfängeradresse (Owned Domain)</th><th class='num'>Adresseinträge</th></tr></thead><tbody>$($recipientRows.ToString())</tbody></table></div><p class='footnote'>Aktueller Zeitraum; Empfängeradresseinträge dauerhaft oder temporär blockierter Nachrichten unter den konfigurierten Owned Domains.</p></section>")

    return $content.ToString()
}

function Get-NspEdgePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Test-NspPdfReady {
    param([Parameter(Mandatory = $true)][string] $FilePath)
    $elapsedMs = 0
    $lastSize = -1
    $stableMs = 0
    while ($elapsedMs -lt 60000) {
        if (Test-Path -LiteralPath $FilePath) {
            $size = (Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue).Length
            if ($null -ne $size -and $size -ge 1000) {
                if ($size -eq $lastSize) {
                    $stableMs += 250
                    if ($stableMs -ge 1000) { return $true }
                }
                else {
                    $stableMs = 0
                    $lastSize = $size
                }
            }
        }
        Start-Sleep -Milliseconds 250
        $elapsedMs += 250
    }
    return $false
}

if ($NoSend -and -not $OutputPath) {
throw "-NoSend requires -OutputPath so the generated HTML report is preserved."
}
if ($OutputPath -and -not $NoSend) {
    throw "-OutputPath may only be used together with -NoSend."
}
if ([string]::IsNullOrWhiteSpace($ODataBaseUrl)) {
    throw "Specify -ODataBaseUrl with the HTTPS base URL of your NoSpamProxy service."
}
if (-not $NoSend -and ($SMTPHosts.Count -eq 0 -or $ReportRecipients.Count -eq 0)) {
    throw "SMTPHosts and ReportRecipients must contain at least one value when sending a report."
}
if (-not $env:NSP_API_KEY) {
    throw "Set the NSP_API_KEY environment variable to the NoSpamProxy PAT before running the report."
}

$temporaryRoot = Join-Path $env:TEMP ("nsp-report-" + [guid]::NewGuid().ToString("N"))
$htmlPath = Join-Path $temporaryRoot "report.html"
$pdfPath = Join-Path $temporaryRoot "report.pdf"
$pdfProfile = Join-Path $temporaryRoot "edge-profile"
$mailMessage = $null
$smtpClient = $null

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Write-Host "Reading NoSpamProxy report data through OData..."
    $reportData = Get-NspODataReportData -BaseUrl $ODataBaseUrl -ApiKey $env:NSP_API_KEY
    $currentStart = $reportData.Current.StartUtc.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $currentEnd = $reportData.Current.EndUtc.AddDays(-1).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $previousStart = $reportData.Comparison.StartUtc.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $previousEnd = $reportData.Comparison.EndUtc.AddDays(-1).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)

    $currentBlocked = Get-NspPeriodBlockTotal $reportData.Current
    $previousBlocked = Get-NspPeriodBlockTotal $reportData.Comparison
    $currentPermanent = Get-NspDictionaryCount $reportData.Current.StatusCounts "PermanentlyBlocked"
    $previousPermanent = Get-NspDictionaryCount $reportData.Comparison.StatusCounts "PermanentlyBlocked"
    $currentTemporary = Get-NspDictionaryCount $reportData.Current.StatusCounts "TemporarilyBlocked"
    $previousTemporary = Get-NspDictionaryCount $reportData.Comparison.StatusCounts "TemporarilyBlocked"

    $kpis = @"
<table class="metrics" role="presentation"><tr>
  <td class="metric"><span class="value">$(Format-NspCount $reportData.Current.MessageTotal)</span><span class="label">Nachrichtentracks aktuell</span><small>Vergleich: $(Format-NspCount $reportData.Comparison.MessageTotal)</small></td>
  <td class="metric blocked"><span class="value">$(Format-NspCount $currentPermanent)</span><span class="label">Dauerhaft blockiert</span><small>Vergleich: $(Format-NspCount $previousPermanent)</small></td>
  <td class="metric"><span class="value">$(Format-NspCount $currentTemporary)</span><span class="label">Temporär blockiert</span><small>Vergleich: $(Format-NspCount $previousTemporary)</small></td>
  <td class="metric"><span class="value">$(Format-NspCount $currentBlocked)</span><span class="label">Blockierungen gesamt</span><small>Vergleich: $(Format-NspCount $previousBlocked)</small></td>
</tr></table>
"@

    $templatePath = Join-Path $PSScriptRoot "template.html"
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Required HTML template not found: template.html" }
    $template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $embeddedLogo = Get-NspEmbeddedLogo $template

    $currentRange = "$currentStart bis einschließlich $currentEnd (UTC)"
    $previousRange = "$previousStart bis einschließlich $previousEnd (UTC)"
    $template = $template.Replace("{{CURRENT_RANGE}}", (ConvertTo-NspHtml $currentRange))
    $template = $template.Replace("{{PREVIOUS_RANGE}}", (ConvertTo-NspHtml $previousRange))
    $template = $template.Replace("{{GENERATED_AT}}", (ConvertTo-NspHtml $reportData.GeneratedAtUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)))
    $template = $template.Replace("{{KPI_CARDS}}", $kpis)
    $template = $template.Replace("{{REPORT_VERSION}}", (ConvertTo-NspHtml $reportVersion))
    $template = $template.Replace("{{REPORT_CONTENT}}", (New-NspReportContent $reportData))
    [IO.File]::WriteAllText($htmlPath, $template, [Text.UTF8Encoding]::new($false))

    $edgePath = Get-NspEdgePath
    $pdfReady = $false
    if ($ReportType -in @("PDF", "Both")) {
        if (-not $edgePath) {
            Write-Warning "Microsoft Edge not found; PDF output is unavailable and HTML will be used as fallback."
        }
        else {
            & $edgePath --headless --disable-gpu --no-first-run --no-default-browser-check "--user-data-dir=$pdfProfile" --no-pdf-header-footer --disable-print-preview --kiosk-printing "--print-to-pdf=$pdfPath" ([Uri]::new($htmlPath).AbsoluteUri) | Out-Null
            $pdfReady = ($LASTEXITCODE -eq 0) -and (Test-NspPdfReady -FilePath $pdfPath)
            if (-not $pdfReady) { Write-Warning "PDF rendering did not complete successfully; HTML will be used as fallback." }
        }
    }

    if ($NoSend) {
        if ($OutputPath) {
            $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
            $outputDirectory = Split-Path -Parent $fullOutputPath
            if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
                New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
            }
            Copy-Item -LiteralPath $htmlPath -Destination $fullOutputPath -Force
            Write-Host "HTML report saved to $fullOutputPath"
        }
        else {
            Write-Host "HTML report generated; no email was sent. Use -OutputPath to save a copy."
        }
        return
    }

    $emailHtml = $template.Replace($embeddedLogo.DataUri, "cid:nsp-report-logo")

    $mailMessage = New-Object System.Net.Mail.MailMessage
    $mailMessage.From = $ReportSender
    foreach ($recipient in $ReportRecipients) { $mailMessage.Bcc.Add($recipient) }
    $mailMessage.Subject = $ReportSubject
    $mailMessage.BodyEncoding = [Text.Encoding]::UTF8

    $sendHtml = ($ReportType -eq "HTML") -or ($ReportType -eq "Both") -or (($ReportType -eq "PDF") -and -not $pdfReady)
    if ($sendHtml) {
        $htmlAttachment = New-Object System.Net.Mail.Attachment($htmlPath)
        $htmlAttachment.ContentType.MediaType = "text/html"
        $htmlAttachment.Name = "NoSpamProxy-Report.html"
        $mailMessage.Attachments.Add($htmlAttachment)
    }
    if ($pdfReady -and $ReportType -in @("PDF", "Both")) {
        $pdfAttachment = New-Object System.Net.Mail.Attachment($pdfPath)
        $pdfAttachment.ContentType.MediaType = "application/pdf"
        $pdfAttachment.Name = "NoSpamProxy-Report.pdf"
        $mailMessage.Attachments.Add($pdfAttachment)
    }

    if ($ReportType -eq "PDF" -and $pdfReady) {
        $mailMessage.Body = "Der NoSpamProxy-Bericht ist als PDF angehängt."
        $mailMessage.IsBodyHtml = $false
    }
    else {
        $mailMessage.Body = $emailHtml
        $mailMessage.IsBodyHtml = $true
        $htmlView = New-NspInlineLogoView $emailHtml $embeddedLogo.Bytes
        $mailMessage.AlternateViews.Add($htmlView)
    }

    $lastSmtpError = $null
    foreach ($smtpHost in $SMTPHosts) {
        $smtpClient = New-Object Net.Mail.SmtpClient($smtpHost, 25)
        try {
            $smtpClient.Send($mailMessage)
            Write-Host "Report sent successfully via configured SMTP relay."
            $lastSmtpError = $null
            break
        }
        catch {
            $lastSmtpError = $_
            Write-Warning "SMTP relay '$smtpHost' failed; trying the next configured relay."
        }
        finally {
            $smtpClient.Dispose()
            $smtpClient = $null
        }
    }
    if ($lastSmtpError) {
        throw "Report delivery failed on all configured SMTP relays. Last error: $($lastSmtpError.Exception.Message)"
    }
}
finally {
    if ($null -ne $mailMessage) { $mailMessage.Dispose() }
    if ($null -ne $smtpClient) { $smtpClient.Dispose() }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
