<#
.SYNOPSIS
Erstellt einen OData-basierten NoSpamProxy-Bericht für zwei gleich lange Zeiträume.
.DESCRIPTION
Ruft alle Berichtsdaten ausschließlich lesend über die NoSpamProxy-OData-API ab. Mit -NoSend wird
der HTML-Bericht lokal gespeichert, ohne eine E-Mail zu versenden. Der PAT muss in NSP_API_KEY stehen.
Der Bericht vergleicht zwei vollständige, gleich lange Zeiträume in UTC. Standard sind 14 Tage
pro Zeitraum; -Days legt die Länge fest. Der aktuelle UTC-Tag ist nicht enthalten.
Nicht belegbare Kennzahlen werden als - angezeigt. MIME-Details sind im HTML aufklappbar und im PDF geöffnet.
Das eingebettete Logo erfordert keine separate Bilddatei.
.PARAMETER Help
Zeigt diese ausführliche Hilfe an, ohne einen Bericht zu erstellen oder die API aufzurufen.
.PARAMETER ReportType
Berichtsformat beim E-Mail-Versand: HTML, PDF oder Both (Standard). PDF benötigt Microsoft Edge;
ohne Edge oder bei einem PDF-Fehler wird HTML als Fallback verwendet.
.PARAMETER Template
Gestaltung des Berichts: NSP-dark (Standard), NSP-light oder NSP-Classic.
.PARAMETER SMTPHosts
Ein oder mehrere SMTP-Relay-Hostnamen/IP-Adressen. Versand über TCP 25; die Beispielwerte ersetzen.
.PARAMETER ReportSender
Absenderadresse; die Beispieladresse ersetzen.
.PARAMETER ReportRecipients
Eine oder mehrere BCC-Empfänger; die Beispieladresse ersetzen.
.PARAMETER ReportSubject
E-Mail-Betreff. Standard: NoSpamProxy: Permanently blocked report.
.PARAMETER ODataBaseUrl
Erforderliche HTTPS-Basis-URL der eigenen NoSpamProxy Web App und Service-API.
.PARAMETER NoSend
Erstellt den Bericht ohne SMTP-Versand.
.PARAMETER OutputPath
Zieldateipfad für den HTML-Bericht; bei -NoSend erforderlich und sonst nicht zulässig.
.PARAMETER Days
Anzahl vollständiger UTC-Tage pro Zeitraum. Standard: 14. Der Vergleichszeitraum ist ebenso lang
und schließt direkt an den aktuellen Zeitraum an. Der heutige UTC-Tag ist ausgeschlossen.
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
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -Days 7 -NoSend -OutputPath "$env:TEMP\report.html"
Vergleicht die letzten sieben vollständigen UTC-Tage mit den sieben Tagen davor.
.EXAMPLE
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -Template NSP-light -NoSend -OutputPath "$env:TEMP\report.html"
Erstellt den Bericht mit der hellen Vorlage.
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
    [ValidateSet("NSP-dark", "NSP-light", "NSP-Classic")]
    [string] $Template = "NSP-dark",
    [string[]] $SMTPHosts = @("192.0.2.1", "192.0.2.2"),
    [string] $ReportSender = "admin@example.invalid",
    [string[]] $ReportRecipients = @("admin@example.invalid"),
    [string] $ReportSubject = "NoSpamProxy: Permanently blocked report",
    [string] $ODataBaseUrl,
    [switch] $NoSend,
    [string] $OutputPath,
    [switch] $Help,
    [ValidateRange(1, 2147483647)]
    [int] $Days = 14
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    return
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$reportVersion = "0.4.2 (Build 20261127.5, 2026-11-27)"
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

function New-NspReportMailMessage {
    param(
        [Parameter(Mandatory = $true)][string] $Sender,
        [Parameter(Mandatory = $true)][string[]] $Recipients,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Subject,
        [Parameter(Mandatory = $true)][string] $CurrentRange,
        [Parameter(Mandatory = $true)][string] $HtmlPath,
        [Parameter(Mandatory = $true)][string] $PdfPath,
        [Parameter(Mandatory = $true)][ValidateSet("HTML", "PDF", "Both")][string] $ReportType,
        [Parameter(Mandatory = $true)][bool] $PdfReady
    )

    $message = New-Object System.Net.Mail.MailMessage
    try {
        $message.From = $Sender
        foreach ($recipient in $Recipients) { $message.Bcc.Add($recipient) }
        $message.Subject = $Subject
        $message.BodyEncoding = [Text.Encoding]::UTF8
        $message.Body = "NoSpamProxy Analysebericht im Anhang für den Zeitraum $CurrentRange."
        $message.IsBodyHtml = $false

        $sendHtml = ($ReportType -eq "HTML") -or ($ReportType -eq "Both") -or (($ReportType -eq "PDF") -and -not $PdfReady)
        if ($sendHtml) {
            $htmlAttachment = New-Object System.Net.Mail.Attachment($HtmlPath)
            $htmlAttachment.ContentType.MediaType = "text/html"
            $htmlAttachment.Name = "NoSpamProxy-Report.html"
            $message.Attachments.Add($htmlAttachment)
        }
        if ($PdfReady -and $ReportType -in @("PDF", "Both")) {
            $pdfAttachment = New-Object System.Net.Mail.Attachment($PdfPath)
            $pdfAttachment.ContentType.MediaType = "application/pdf"
            $pdfAttachment.Name = "NoSpamProxy-Report.pdf"
            $message.Attachments.Add($pdfAttachment)
        }
        return $message
    }
    catch {
        $message.Dispose()
        throw
    }
}

function Format-NspCount {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return "-" }
    return ([long]$Value).ToString("N0", [Globalization.CultureInfo]::GetCultureInfo("de-DE"))
}

function Format-NspPercent {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return "-" }
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
        [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspCount $Current)$Unit</td><td class='num'>$(Format-NspCount $Previous)$Unit</td><td class='num'>-</td><td class='num'>-</td></tr>")
        return
    }

    $currentValue = [double]$Current
    $previousValue = [double]$Previous
    $delta = $currentValue - $previousValue
    $change = if ($previousValue -eq 0) { "-" } else { Format-NspPercent (($delta / $previousValue) * 100) }
    $deltaText = if ($delta -gt 0) { "+" + (Format-NspCount $delta) } else { Format-NspCount $delta }
    $deltaText += $Unit
    [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspCount $Current)$Unit</td><td class='num'>$(Format-NspCount $Previous)$Unit</td><td class='num'>$deltaText</td><td class='num'>$change</td></tr>")
}

function Add-NspPercentTableRow {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder,
        [Parameter(Mandatory = $true)][string] $Label,
        [AllowNull()] $Current,
        [AllowNull()] $Previous,
        [switch] $RelativeDifference
    )

    $safeLabel = ConvertTo-NspHtml $Label
    if ($null -eq $Current -or $null -eq $Previous) {
        [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspPercent $Current)</td><td class='num'>$(Format-NspPercent $Previous)</td><td class='num'>-</td><td class='num'>-</td></tr>")
        return
    }

    $delta = [double]$Current - [double]$Previous
    $change = if ([double]$Previous -eq 0) { "-" } else { Format-NspPercent (($delta / [double]$Previous) * 100) }
    $deltaText = if ($RelativeDifference) { $change } else { (Format-NspPercent $delta).Replace("%", " PP") }
    [void]$Builder.AppendLine("<tr><td>$safeLabel</td><td class='num'>$(Format-NspPercent $Current)</td><td class='num'>$(Format-NspPercent $Previous)</td><td class='num'>$deltaText</td><td class='num'>$change</td></tr>")
}

function Add-NspPanel {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $TableRows,
        [string] $Footnote = "",
        [string] $Id = ""
    )

    $safeTitle = ConvertTo-NspHtml $Title
    $idAttribute = if ($Id) { " id='$(ConvertTo-NspHtml $Id)'" } else { "" }
    [void]$Builder.AppendLine("<section class='panel'$idAttribute><h2>$safeTitle</h2><div class='table-wrap'><table><thead><tr><th>Messwert</th><th class='num'>Aktuell</th><th class='num'>Vergleich</th><th class='num'>Differenz</th><th class='num'>Änderung</th></tr></thead><tbody>$TableRows</tbody></table></div>")
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

function Format-NspKpiChange {
    param([AllowNull()] $Current, [AllowNull()] $Previous)

    if ($null -eq $Current -or $null -eq $Previous) {
        return "-"
    }

    $delta = [long]$Current - [long]$Previous
    $deltaText = Format-NspCount $delta
    if ($delta -gt 0) { $deltaText = "+$deltaText" }
    $percentText = if ([long]$Previous -eq 0) { "-" } else {
        $formatted = Format-NspPercent (([double]$delta / [double]$Previous) * 100)
        if ($delta -gt 0) { "+$formatted" } else { $formatted }
    }
    return "$deltaText ($percentText)"
}

function New-NspKpiCards {
    param(
        [Parameter(Mandatory = $true)] $ReportData,
        [ValidateSet("NSP-dark", "NSP-light", "NSP-Classic")][string] $Design = "NSP-dark"
    )

    $current = $ReportData.Current
    $previous = $ReportData.Comparison
    $currentBlocked = Get-NspPeriodBlockTotal $current
    $previousBlocked = Get-NspPeriodBlockTotal $previous
    $currentPermanent = Get-NspDictionaryCount $current.StatusCounts "PermanentlyBlocked"
    $previousPermanent = Get-NspDictionaryCount $previous.StatusCounts "PermanentlyBlocked"
    $currentTemporary = Get-NspDictionaryCount $current.StatusCounts "TemporarilyBlocked"
    $previousTemporary = Get-NspDictionaryCount $previous.StatusCounts "TemporarilyBlocked"

    $metrics = @(
        @{ Label = "Nachrichtentracks"; Mark = "▤"; Current = $current.MessageTotal; Previous = $previous.MessageTotal },
        @{ Label = "Dauerhaft blockiert"; Mark = "◇"; Current = $currentPermanent; Previous = $previousPermanent },
        @{ Label = "Temporär blockiert"; Mark = "◷"; Current = $currentTemporary; Previous = $previousTemporary },
        @{ Label = "Blockierungen gesamt"; Mark = "◈"; Current = $currentBlocked; Previous = $previousBlocked }
    )
    $cards = [Text.StringBuilder]::new()
    if ($Design -eq "NSP-Classic") {
        [void]$cards.AppendLine('<table class="metrics" role="presentation"><tr>')
    }
    else {
        [void]$cards.AppendLine("<section class='metrics' aria-label='Kennzahlen'>")
    }
    foreach ($metric in $metrics) {
        $value = Format-NspCount $metric.Current
        $previousValue = Format-NspCount $metric.Previous
        $change = Format-NspKpiChange $metric.Current $metric.Previous
        if ($Design -eq "NSP-Classic") {
            $label = if ($metric.Label -eq "Nachrichtentracks") { "Nachrichtentracks aktuell" } else { $metric.Label }
            [void]$cards.AppendLine("<td class='metric'><span class='value'>$value</span><span class='label'>$label</span><small>Vergleichszeitraum: $previousValue<br>Veränderung: $change</small></td>")
        }
        elseif ($Design -eq "NSP-light") {
            [void]$cards.AppendLine("<article class='metric'><div class='metric-top'><span class='metric-title'>$($metric.Label)</span><span class='metric-mark' aria-hidden='true'>$($metric.Mark)</span></div><div class='metric-value'>$value</div><div class='metric-bottom'><div><small>Vergleichszeitraum</small><strong>$previousValue</strong></div><span class='change'>$change</span></div></article>")
        }
        else {
            [void]$cards.AppendLine("<article class='metric'><div class='metric-label'>$($metric.Label)</div><div class='metric-value'>$value</div><div class='metric-foot'><div><small>Vergleichszeitraum</small><strong>$previousValue</strong></div><span class='delta'>$change</span></div></article>")
        }
    }
    if ($Design -eq "NSP-Classic") { [void]$cards.AppendLine("</tr></table>") }
    else { [void]$cards.AppendLine("</section>") }
    return $cards.ToString()
}

function Format-NspChartWidth {
    param([AllowNull()] $Percent)
    if ($null -eq $Percent) { return "0" }
    return ([Math]::Max(0, [Math]::Min(100, [double]$Percent))).ToString("0.####", [Globalization.CultureInfo]::InvariantCulture)
}

function New-NspOverview {
    param(
        [Parameter(Mandatory = $true)] $ReportData,
        [ValidateSet("NSP-dark", "NSP-light")][string] $Design = "NSP-dark"
    )

    $current = $ReportData.Current
    $previous = $ReportData.Comparison
    $blocked = Get-NspPeriodBlockTotal $current
    $blockShare = if ($current.MessageTotal -gt 0) { ([double]$blocked / $current.MessageTotal) * 100 } else { $null }
    $reasons = @(
        @{ Key = "Policy"; Label = "Richtlinien / Vorgaben (Policy)" },
        @{ Key = "SpamOrVirus"; Label = "Spam- oder Malware-Verdacht (SpamOrVirus)" }
    )
    $reasonHtml = [Text.StringBuilder]::new()
    foreach ($reason in $reasons) {
        $share = Get-NspPeriodRejectReasonShare $current $reason.Key
        $shareText = Format-NspPercent $share
        $width = Format-NspChartWidth $share
        $currentCount = Format-NspCount (Get-NspDictionaryCount $current.RejectReasonCounts $reason.Key)
        $previousCount = Format-NspCount (Get-NspDictionaryCount $previous.RejectReasonCounts $reason.Key)
        if ($Design -eq "NSP-light") {
            [void]$reasonHtml.AppendLine("<div class='reason'><div class='reason-line'><strong>$($reason.Label)</strong><b>$shareText</b></div><div class='track'><span style='width:$width%'></span></div><div class='reason-foot'><span>$currentCount aktuell</span><span>$previousCount im Vergleichszeitraum</span></div></div>")
        }
        else {
            [void]$reasonHtml.AppendLine("<div class='reason-head'><strong>$($reason.Label)</strong><span>$shareText</span></div><div class='bar'><span style='width:$width%'></span></div><div class='reason-foot'><span>$currentCount aktuell</span><span>$previousCount im Vergleichszeitraum</span></div>")
        }
    }
    $blockedText = Format-NspCount $blocked
    $note = "Die Anteile beziehen sich auf alle dauerhaft und temporär blockierten Nachrichtentracks, einschließlich ausgeblendeter Gründe. Policy ist ein API-Ablehnungsgrund; SpamOrVirus allein bestätigt keinen Malware-Fund."
    if ($Design -eq "NSP-light") {
        return "<section class='card'><div class='card-head'><div><h3>Blockierungsgründe</h3><p class='desc'>Anteil an $blockedText blockierten Nachrichtentracks</p></div><span class='pill'>Verteilung</span></div>$reasonHtml<div class='insight'>$note</div></section>"
    }

    $shareText = Format-NspPercent $blockShare
    $width = Format-NspChartWidth $blockShare
    $remaining = Format-NspCount ($current.MessageTotal - $blocked)
    $total = Format-NspCount $current.MessageTotal
    return @"
<div class="grid">
  <section class="panel"><div class="panel-head"><div><h3>Verteilung der Nachrichtentracks</h3><p class="desc">Blockierungen im Verhältnis zur Gesamtzahl</p></div></div>
    <div class="distribution"><div class="ring" style="background:conic-gradient(var(--amber) 0 $width%,#31515a $width% 100%)" aria-label="$shareText der Nachrichtentracks sind blockiert"><div><strong>$shareText</strong><small>BLOCKIERT</small></div></div>
      <div class="legend"><div class="legend-row"><span class="legend-label"><i class="dot"></i>Blockierungen gesamt</span><strong>$blockedText</strong></div><div class="legend-row"><span class="legend-label"><i class="dot blue"></i>Übrige Nachrichtentracks</span><strong>$remaining</strong></div><div class="legend-row"><span class="legend-label">Nachrichtentracks gesamt</span><strong>$total</strong></div></div>
    </div><p class="notice">Die übrigen Nachrichtentracks umfassen mehrere Status und sind nicht gleichbedeutend mit erfolgreich zugestellten Nachrichten.</p></section>
  <section class="panel"><div class="panel-head"><div><h3>Blockierungsgründe</h3><p class="desc">Anteil an $blockedText blockierten Nachrichtentracks</p></div></div>$reasonHtml<p class="rule-note">$note</p></section>
</div>
"@
}

function New-NspReportContent {
    param([Parameter(Mandatory = $true)] $ReportData)

    $current = $ReportData.Current
    $previous = $ReportData.Comparison
    $content = [System.Text.StringBuilder]::new()

    $statusRows = [System.Text.StringBuilder]::new()
    $statusLabels = @{
        DispatcherError = "Zustellfehler"
        PartialSuccess = "Teilweise zugestellt"
        PermanentlyBlocked = "Permanent abgewiesen"
        PutOnHold = "Zurückgestellt"
        Success = "Erfolgreich zugestellt"
        Suppressed = "Zustellung unterdrückt (Duplikate, etc)"
        TemporarilyBlocked = "Temporär abgewiesen"
    }
    $allStatuses = @("Success", "PermanentlyBlocked", "TemporarilyBlocked", "DispatcherError", "PartialSuccess", "Suppressed", "PutOnHold")
    $allStatuses += @($current.StatusCounts.Keys) + @($previous.StatusCounts.Keys)
    $allStatuses = @($allStatuses | Where-Object { $_ -and $_ -notin @("DuplicateDrop", "DeliveryPending") } | Sort-Object -Unique)
    foreach ($status in $allStatuses) {
        $statusLabel = if ($statusLabels.ContainsKey($status)) { $statusLabels[$status] } else { $status }
        Add-NspCountTableRow $statusRows $statusLabel `
            (Get-NspDictionaryCount $current.StatusCounts $status) `
            (Get-NspDictionaryCount $previous.StatusCounts $status)
    }
    Add-NspPanel -Id "status" $content "Nachrichtenübersicht" $statusRows.ToString() `
        "Die Statuswerte basieren auf Nachrichtentracks. Die Gesamtzahl im Berichtskopf enthält auch nicht separat angezeigte Statuswerte."

    $reasonRows = [System.Text.StringBuilder]::new()
    $reasonLabels = @{ Policy = "Richtlinien / Vorgaben (Policy)"; SpamOrVirus = "Spam- oder Malware-Verdacht (SpamOrVirus)" }
    $reasons = @("Policy", "SpamOrVirus") +
        @($current.RejectReasonCounts.Keys) + @($previous.RejectReasonCounts.Keys)
    $reasons = @($reasons | Where-Object { $_ -and $_ -notin @("LoopDetected", "None") } | Sort-Object -Unique)
    foreach ($reason in $reasons) {
        $reasonLabel = if ($reasonLabels.ContainsKey($reason)) { $reasonLabels[$reason] } else { $reason }
        Add-NspCountTableRow $reasonRows $reasonLabel `
            (Get-NspDictionaryCount $current.RejectReasonCounts $reason) `
            (Get-NspDictionaryCount $previous.RejectReasonCounts $reason)
        Add-NspPercentTableRow $reasonRows "$reasonLabel – Anteil an blockierten Nachrichten" `
            (Get-NspPeriodRejectReasonShare $current $reason) `
            (Get-NspPeriodRejectReasonShare $previous $reason) -RelativeDifference
    }
    Add-NspPanel -Id "reasons" $content "Blockierungsgründe" $reasonRows.ToString() `
        "Policy ist ein von der API gemeldeter Ablehnungsgrund (Richtlinie / Vorgabe). Welche Regel oder Aktion die Ablehnung ausgelöst hat, muss im Nachrichtentracking geprüft werden. SpamOrVirus bezeichnet die API-Kategorie für Spam oder Malware und belegt allein keinen bestätigten Malware-Fund. Die Anteile beziehen sich auf alle dauerhaft und temporär blockierten Nachrichtentracks, einschließlich ausgeblendeter Gründe. Bei Anteilen zeigen Differenz und Änderung die relative Veränderung in Prozent."

    $filterRows = [System.Text.StringBuilder]::new()
    $filterLabels = @{
        OutbreakDetectionFilter = "32Guards"
        realtimeBlocklist = "Realtime Blocklist"
        reputation = "Reputationsfilter"
        surblFilter = "SURBL Filter"
    }
    $filterNames = @("realtimeBlocklist", "OutbreakDetectionFilter", "bitdefenderFilter", "reputation", "wordFilter", "surblFilter", "csaWhitelist")
    $filterNames += @($current.FilterCounts.Keys) + @($previous.FilterCounts.Keys)
    $filterNames = @($filterNames | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($name in $filterNames) {
        $currentBucket = $current.FilterCounts[$name]
        $previousBucket = $previous.FilterCounts[$name]
        $currentPositiveScl = if ($currentBucket) { $currentBucket.PositiveScl } else { [long]0 }
        $previousPositiveScl = if ($previousBucket) { $previousBucket.PositiveScl } else { [long]0 }
        if ($currentPositiveScl -gt 0 -or $previousPositiveScl -gt 0) {
            $displayName = if ($filterLabels.ContainsKey($name)) { $filterLabels[$name] } else { $name -replace "(?i)bitdefender(?:filter)?", "CSA / AV Engine" }
            Add-NspCountTableRow $filterRows $displayName $currentPositiveScl $previousPositiveScl
        }
    }
    if ($filterRows.Length -eq 0) {
        [void]$filterRows.AppendLine("<tr><td colspan='5'>Keine Filtertreffer in beiden Zeiträumen.</td></tr>")
    }
    $engineRows = [System.Text.StringBuilder]::new()
    $actionLabels = @{
        "OutbreakDetection|RejectPermanent" = "32Guards / RejectPermanent – Ereignisse"
        "OutbreakDetection|RejectTemporarily" = "32Guards / RejectTemporarily – Ereignisse"
        "validateSignatureAndDecrypt|RejectPermanent" = "Signatur / Entschlüsselungsfehler"
        "malwareScan|RejectPermanent" = "Malware Prüfung"
        "fraudDetection|RejectPermanent" = "CxO Prüfung"
        "greylisting|RejectTemporarily" = "Greylisting"
        "ContentFiltering|RejectTemporarily" = "Temporär abgewiesen wegen Inhaltsfilterung"
    }
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
        $actionKey = "$name|$decision"
        $actionLabel = if ($actionLabels.ContainsKey($actionKey)) { $actionLabels[$actionKey] } else { "$name / $decision – Ereignisse" }
        Add-NspCountTableRow $engineRows $actionLabel `
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
    Add-NspPanel -Id "engine" $content "Engine-Aktionen" $engineRows.ToString() `
        "Ereignisse und, soweit angezeigt, eindeutige MailIds sind unterschiedliche Zählweisen. Eine Nachricht kann mehrere Filter- und Aktionsereignisse erzeugen. Der Reputationsfilter ist nicht automatisch 32Guards zuzuordnen."

    $contentActionRows = [System.Text.StringBuilder]::new()
    foreach ($decision in @("RejectPermanent", "RejectTemporarily")) {
        $label = if ($decision -eq "RejectPermanent") { "Inhaltsfilter - Permanent abgewiesen" } else { "Inhaltsfilter - Temporär abgewiesen" }
        Add-NspCountTableRow $contentActionRows $label `
            (Get-NspActionTotal $current "ContentFiltering" $decision) `
            (Get-NspActionTotal $previous "ContentFiltering" $decision)
    }
    Add-NspCountTableRow $contentActionRows "Temporär abgelehnte Anhänge" $null $null
    Add-NspCountTableRow $contentActionRows "Permanent abgelehnte Anhänge" $null $null
    Add-NspCountTableRow $contentActionRows "Abgelehnte Anhänge insgesamt" $null $null
    Add-NspCountTableRow $contentActionRows "Anhänge in Quarantäne" $current.QuarantineCounts.True $previous.QuarantineCounts.True
    Add-NspPanel -Id "content" $content "ContentFiltering und Anhang-Quarantäne" $contentActionRows.ToString() `
        "Die Inhaltsfilter-Werte zählen Ereignisse auf Nachrichtenebene und keine eindeutigen Anhänge. Die API weist Anhängen keinen ContentFiltering-Entscheidungsstatus zu."
    Add-NspPanel -Id "filter" $content "Filtertreffer bei dauerhaft blockierten Nachrichten" $filterRows.ToString() `
        "Gezählt werden Filterereignisse mit positiver Bewertung. Mehrere Ereignisse können dieselbe Nachricht betreffen; ein Filtertreffer allein belegt nicht, dass dieser Filter die Blockierung verursacht hat."

    $malwareRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $malwareRows "Malware Prüfung" `
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
        $label = if ($labels.Contains("abgewiesene Nachrichten")) { "E-Mails abgewiesen wegen Malware" } else { $labels -join " / " }
        Add-NspCountTableRow $malwareRows $label $measure.Current $measure.Previous
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
    Add-NspPanel -Id "malware" $content "MalwareScan" $malwareRows.ToString() `
        "Die abgewiesenen E-Mails werden anhand eindeutiger MailIds gezählt. RejectPermanent-Aktionen werden anhand von MessageTrackId mit MalwareScan-Operationen korreliert. Bei unvollständiger Zuordnung werden infizierte Mailteile und Fundrate als - angezeigt. Gleiche Werte in beiden Zeiträumen können gemeinsam dargestellt werden; dies belegt keine Eins-zu-eins-Zuordnung der Messgrößen."

    $sandboxRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $sandboxRows "Analysevorgänge" $current.SandboxEvidence.OperationCount $previous.SandboxEvidence.OperationCount
    Add-NspCountTableRow $sandboxRows "Analysevorgänge mit bestätigtem Fund" $current.SandboxEvidence.ConfirmedOperationCount $previous.SandboxEvidence.ConfirmedOperationCount
    Add-NspPanel -Id "sandbox" $content "Sandbox-Analyse" $sandboxRows.ToString() `
        "Ein bestätigter Fund erfordert den expliziten Ergebnisstatus Infected. Eine Ablehnung oder ein unbekanntes Ergebnis allein belegt keinen Malware-Fund. Sind Tracking-Details gelöscht, fehlen diese Vorgänge; ein Wert von 0 belegt daher keine vollständige Abwesenheit von Funden."

    $urlRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $urlRows "Unterschiedliche gesehene URLs" $current.ObservedUrls.Total $previous.ObservedUrls.Total
    Add-NspCountTableRow $urlRows "Unterschiedliche als bösartig markierte URLs" $current.ObservedUrls.Malicious $previous.ObservedUrls.Malicious
    Add-NspCountTableRow $urlRows "Klicks mit bösartiger Bewertung" $current.UrlVisitCounts.True $previous.UrlVisitCounts.True
    Add-NspPanel -Id "urls" $content "URL Safeguard" $urlRows.ToString() `
        "URLs werden anhand ihres Hashes einmal pro Zeitraum gezählt; die Zuordnung zum Zeitraum erfolgt über das Sendedatum der Nachricht. Bösartige URLs basieren auf der aktuellen API-Bewertung. Klicks zählen Besuchsereignisse mit bösartiger Bewertung anhand des Besuchszeitpunkts und müssen nicht zu den im selben Zeitraum gesehenen URLs gehören. Fehlende URL-Hashes ergeben -."

    $recallRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $recallRows "Zurückgerufene Nachrichten durch 32Guards Recall" $current.RecalledMessages $previous.RecalledMessages
    Add-NspPanel -Id "recall" $content "Zurückgerufene Nachrichten" $recallRows.ToString() `
        "Zählung basiert auf MessageTrackSummaries.WasRecalled=true und eindeutigen MailId-Werten. Einträge ohne MailId werden nicht als eindeutige Nachrichten gezählt."

    $deepRows = [System.Text.StringBuilder]::new()
    Add-NspCountTableRow $deepRows "DeepFile-Analysevorgänge" $current.DeepFileEvidence.OperationCount $previous.DeepFileEvidence.OperationCount
    Add-NspCountTableRow $deepRows "Nachrichtentracks mit einem Befund" $current.DeepFileEvidence.ConfirmedTrackCount $previous.DeepFileEvidence.ConfirmedTrackCount
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
    Add-NspPanel -Id "deepfile" $content "32Guards DeepFile Analyzer" $deepRows.ToString() `
        "Als bestätigter Fund zählt ausschließlich ein expliziter Infected-Status auf Ergebnisebene. Übersprungene oder unbekannte Ergebnisse werden nicht als malwarefrei gezählt."

    $mimeRows = [System.Text.StringBuilder]::new()
    $mimeDetails = [System.Text.StringBuilder]::new()
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
            $detailRows = [System.Text.StringBuilder]::new()
            Add-NspCountTableRow $detailRows "Anhänge" $currentCount $previousCount
            $currentShare = if ($current.TotalAttachments -gt 0) { ([double]$currentCount / $current.TotalAttachments) * 100 } else { $null }
            $previousShare = if ($previous.TotalAttachments -gt 0 -and $previousBucket) { ([double]$previousCount / $previous.TotalAttachments) * 100 } elseif ($previous.TotalAttachments -gt 0) { 0 } else { $null }
            Add-NspPercentTableRow $detailRows "Anteil an allen Anhängen" $currentShare $previousShare
            foreach ($status in @("Success", "TemporarilyBlocked", "PermanentlyBlocked")) {
                $currentStatusCounts = if ($currentBucket) { $currentBucket.Status } else { $null }
                $previousStatusCounts = if ($previousBucket) { $previousBucket.Status } else { $null }
                $currentStatus = Get-NspDictionaryCount $currentStatusCounts $status
                $previousStatus = Get-NspDictionaryCount $previousStatusCounts $status
                Add-NspCountTableRow $detailRows "Status der Nachricht: $($statusLabels[$status])" $currentStatus $previousStatus
            }
            $currentQuarantined = if ($currentBucket) { [long]$currentBucket.Quarantined } else { [long]0 }
            $previousQuarantined = if ($previousBucket) { [long]$previousBucket.Quarantined } else { [long]0 }
            Add-NspCountTableRow $detailRows "Anhänge in Quarantäne" $currentQuarantined $previousQuarantined
            $safeMime = ConvertTo-NspHtml $mime
            [void]$mimeDetails.AppendLine("<details class='mime-details'><summary>$safeMime <span class='mime-counts'>Aktuell: $(Format-NspCount $currentCount) · Vergleich: $(Format-NspCount $previousCount)</span></summary><div class='table-wrap'><table><thead><tr><th>Detail</th><th class='num'>Aktuell</th><th class='num'>Vergleich</th><th class='num'>Differenz</th><th class='num'>Änderung</th></tr></thead><tbody>$($detailRows.ToString())</tbody></table></div></details>")
        }
    }
    $mimeHtml = "<section class='panel' id='mime'><h2>Häufigste MIME-Typen der Anhänge</h2><div class='table-wrap'><table><thead><tr><th>Messwert</th><th class='num'>Aktuell</th><th class='num'>Vergleich</th><th class='num'>Differenz</th><th class='num'>Änderung</th></tr></thead><tbody>$($mimeRows.ToString())</tbody></table></div>$($mimeDetails.ToString())<p class='footnote'>Die zehn häufigsten MIME-Typen werden nach aktuellem Zeitraum sortiert; bei leerem aktuellem Zeitraum nach dem Vergleichszeitraum. Statuswerte beziehen sich auf die verknüpfte Nachricht, nicht auf eine anhangspezifische ContentFiltering-Entscheidung. Differenzen von Anteilen sind in Prozentpunkten (PP) angegeben.</p></section>"
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
$templateFile = switch ($Template) {
    "NSP-light" { "template-nsp-light.html" }
    "NSP-Classic" { "template.html" }
    "NSP-dark" { "template-nsp-dark.html" }
}
$templatePath = Join-Path $PSScriptRoot $templateFile
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Required HTML template not found: $templateFile" }

$temporaryRoot = Join-Path $env:TEMP ("nsp-report-" + [guid]::NewGuid().ToString("N"))
$htmlPath = Join-Path $temporaryRoot "report.html"
$pdfPath = Join-Path $temporaryRoot "report.pdf"
$pdfProfile = Join-Path $temporaryRoot "edge-profile"
$mailMessage = $null
$smtpClient = $null
$progressClock = [Diagnostics.Stopwatch]::StartNew()

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Write-Host "Reading NoSpamProxy report data through OData..."
    $reportData = Get-NspODataReportDataWithProgress -BaseUrl $ODataBaseUrl -ApiKey $env:NSP_API_KEY -Days $Days `
        -ODataScriptPath (Join-Path $PSScriptRoot "ReportOData.ps1") -Stopwatch $progressClock
    Write-NspReportProgress -Status "HTML-Bericht erstellen" -Stopwatch $progressClock
    $currentStart = $reportData.Current.StartUtc.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $currentEnd = $reportData.Current.EndUtc.AddDays(-1).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $previousStart = $reportData.Comparison.StartUtc.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $previousEnd = $reportData.Comparison.EndUtc.AddDays(-1).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)

    $kpis = New-NspKpiCards $reportData -Design $Template
    $overview = if ($Template -ne "NSP-Classic") { New-NspOverview $reportData -Design $Template } else { "" }
    $templateHtml = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    [void](Get-NspEmbeddedLogo $templateHtml)

    $currentRange = "$currentStart bis einschließlich $currentEnd (UTC)"
    $previousRange = "$previousStart bis einschließlich $previousEnd (UTC)"
    $templateHtml = $templateHtml.Replace("{{CURRENT_RANGE}}", (ConvertTo-NspHtml $currentRange))
    $templateHtml = $templateHtml.Replace("{{PREVIOUS_RANGE}}", (ConvertTo-NspHtml $previousRange))
    $templateHtml = $templateHtml.Replace("{{GENERATED_AT}}", (ConvertTo-NspHtml $reportData.GeneratedAtUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)))
    $templateHtml = $templateHtml.Replace("{{KPI_CARDS}}", $kpis)
    $templateHtml = $templateHtml.Replace("{{OVERVIEW}}", $overview)
    $templateHtml = $templateHtml.Replace("{{REPORT_VERSION}}", (ConvertTo-NspHtml $reportVersion))
    $templateHtml = $templateHtml.Replace("{{REPORT_CONTENT}}", (New-NspReportContent $reportData))
    [IO.File]::WriteAllText($htmlPath, $templateHtml, [Text.UTF8Encoding]::new($false))

    $edgePath = Get-NspEdgePath
    $pdfReady = $false
    if ($ReportType -in @("PDF", "Both")) {
        Write-NspReportProgress -Status "PDF-Bericht erstellen" -Stopwatch $progressClock
        if (-not $edgePath) {
            Write-Warning "Microsoft Edge not found; PDF output is unavailable and HTML will be used as fallback."
        }
        else {
            $pdfHtmlPath = Join-Path $temporaryRoot "report-print.html"
            $pdfHtml = $templateHtml.Replace("<details class='mime-details'>", "<details class='mime-details' open>")
            [IO.File]::WriteAllText($pdfHtmlPath, $pdfHtml, [Text.UTF8Encoding]::new($false))
            & $edgePath --headless --disable-gpu --no-first-run --no-default-browser-check "--user-data-dir=$pdfProfile" --no-pdf-header-footer --disable-print-preview --kiosk-printing "--print-to-pdf=$pdfPath" ([Uri]::new($pdfHtmlPath).AbsoluteUri) | Out-Null
            $pdfReady = ($LASTEXITCODE -eq 0) -and (Test-NspPdfReady -FilePath $pdfPath)
            if (-not $pdfReady) { Write-Warning "PDF rendering did not complete successfully; HTML will be used as fallback." }
        }
    }

    if ($NoSend) {
        Write-NspReportProgress -Status "HTML-Bericht speichern" -Stopwatch $progressClock
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

    Write-NspReportProgress -Status "E-Mail vorbereiten" -Stopwatch $progressClock
    $mailMessage = New-NspReportMailMessage -Sender $ReportSender -Recipients $ReportRecipients `
        -Subject $ReportSubject -CurrentRange $currentRange -HtmlPath $htmlPath -PdfPath $pdfPath `
        -ReportType $ReportType -PdfReady $pdfReady

    $lastSmtpError = $null
    Write-NspReportProgress -Status "E-Mail versenden" -Stopwatch $progressClock
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
    Write-Progress -Id 42 -Activity "NoSpamProxy-Bericht" -Completed
    if ($null -ne $mailMessage) { $mailMessage.Dispose() }
    if ($null -ne $smtpClient) { $smtpClient.Dispose() }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
