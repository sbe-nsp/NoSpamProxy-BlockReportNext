# NoSpamProxy BlockReport Next

**Ein kompakter PowerShell-Analysebericht für NoSpamProxy.** Alle Daten werden lesend über die OData-Service-API abgerufen – ohne SQL-Zugriff.

<p align="center">
  <img src="https://raw.githubusercontent.com/sbe-nsp/NoSpamProxy-BlockReportNext/v0.1.0/docs/report-preview.png" alt="Vorschau des NoSpamProxy-Analyseberichts" width="876">
  <br>
  <sub>Berichtsvorschau mit fiktiven Beispieldaten.</sub>
</p>

<p align="center">
  <a href="https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/tag/v0.1.0">Release 0.1.0</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#aufruf">Aufruf</a>
</p>

## Berichtsumfang

Der Bericht vergleicht dieselben neun Bereiche in zwei vollständigen, nicht überlappenden 14-Tage-Zeiträumen:

1. Verarbeitete Nachrichtentracks und Zustellstatus
2. Blockierungsgründe, Filterereignisse und Engine-Aktionen
3. ContentFiltering-Ereignisse und Anhang-Quarantäne
4. MalwareScan-Operationen und bestätigte Malware-Funde
5. Sandbox-Analyse
6. URL Safeguard
7. 32GUARDS Recall
8. DeepFile Analyzer
9. Häufigste MIME-Typen und Status der zugehörigen Nachricht

Zusätzlich enthält der Bericht weiterhin eine Top-10-Liste interner Empfänger dauerhaft oder temporär blockierter Nachrichten. Wo die API eine periodische Kennzahl nicht belegt, zeigt der Report `n/a` und erklärt die Einschränkung. Erfolgreich abgefragte Nullwerte werden als `0` dargestellt. Prozentänderungen bei einem Vergleichswert von null sind nicht berechenbar und erscheinen als `n/a`.

Differenzen zwischen Anteilen werden als Prozentpunkte (`PP`) ausgewiesen; die Spalte „Änderung“ zeigt die relative Veränderung. Die Blockierungsgründe `LoopDetected` und `None` werden nicht als Zeilen angezeigt, zählen aber weiterhin zum Nenner der Anteile. Filtertreffer werden kompakt als Ereignisse mit positiver Bewertung gezeigt; sie belegen für sich keine ursächliche Blockierung.

Die Zeitfilter sind UTC: aktueller Zeitraum `[heute-14 Tage, heute)`, Vergleichszeitraum `[heute-28 Tage, heute-14 Tage)`. Start ist inklusiv, Ende exklusiv.

## Voraussetzungen

- Windows und PowerShell 5.1 oder neuer.
- HTTPS-Zugriff auf die NoSpamProxy-Service-API und die eigene Basis-URL.
- Ein PAT mit Leserechten auf die benötigten Tracking- und Konfigurationsentitäten.
- Für PDF-Ausgabe: Microsoft Edge. Ohne Edge wird beim Versand HTML als Fallback verwendet.
- Für den Versand: erreichbarer SMTP-Relay auf Port 25, gültiger Absender und Empfänger.
- `template.html` und `ReportOData.ps1` im selben Verzeichnis wie `Get-PermanentlyBlocked.ps1`.
- Das NoSpamProxy-Logo ist in `template.html` eingebettet; eine separate Bilddatei ist nicht erforderlich.

## Installation

Das [Anwenderpaket](https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/download/v0.1.0/NoSpamProxy-BlockReportNext-v0.1.0-build20261126.5.zip) herunterladen und entpacken. Es enthält nur `Get-PermanentlyBlocked.ps1`, `ReportOData.ps1`, `template.html` und diese README.

Alternativ den `master`-Branch klonen:

```powershell
git clone --branch master https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext.git
Set-Location .\NoSpamProxy-BlockReportNext
```

Die Dateien im Projektverzeichnis zusammen belassen. Danach den PAT wie unten beschrieben bereitstellen und den Bericht zunächst mit `-NoSend` prüfen. Für den GitHub-Zugriff sind entsprechende Repository-Berechtigungen nötig.

## Zugangsdaten

Der PAT wird ausschließlich aus der Prozess-Umgebungsvariable `NSP_API_KEY` gelesen. Lege ihn nicht in Skriptdateien, Aufgabenargumenten, PowerShell-History, Logs oder Git ab. Für geplante Ausführungen sollte ein geschützter Secret Store den Wert zur Laufzeit in die Umgebung des Prozesses laden.

Für einen interaktiven Test kann der PAT verdeckt abgefragt werden:

```powershell
$odataBaseUrl = Read-Host 'HTTPS-Basis-URL der eigenen NoSpamProxy-Service-API'
$securePat = Read-Host 'NoSpamProxy PAT' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
try {
    $env:NSP_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    .\Get-PermanentlyBlocked.ps1 -ODataBaseUrl $odataBaseUrl -NoSend -OutputPath "$env:TEMP\NoSpamProxy-Report.html"
}
finally {
    Remove-Item Env:\NSP_API_KEY -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
}
```

## Aufruf

Die ausführliche Hilfe lässt sich ohne API-Schlüssel oder Berichtserstellung anzeigen:

```powershell
.\Get-PermanentlyBlocked.ps1 -Help
# Alternativ:
Get-Help .\Get-PermanentlyBlocked.ps1 -Full
```

HTML-Bericht erstellen, ohne eine E-Mail zu senden:

```powershell
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -NoSend -OutputPath 'C:\Reports\NoSpamProxy-Report.html'
```

HTML und PDF per SMTP versenden:

```powershell
.\Get-PermanentlyBlocked.ps1 `
  -ODataBaseUrl 'https://nospamproxy.example.com' `
  -SMTPHosts 'smtp-relay.example.local' `
  -ReportSender 'nsp-report@example.local' `
  -ReportRecipients 'admin@example.local' `
  -ReportType Both
```

Ersetze `https://nospamproxy.example.com` in den Beispielen durch die HTTPS-Basis-URL deiner NoSpamProxy-Service-API. Die Empfänger werden als BCC eingetragen. Beim Versand muss mindestens ein SMTP-Relay und ein Empfänger angegeben werden. Die voreingestellten Beispielwerte sind nicht produktiv verwendbar.

## Parameter

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-ReportType` | `Both` | `HTML`, `PDF` oder `Both`; steuert die E-Mail-Anhänge. |
| `-SMTPHosts` | Beispieladressen | SMTP-Relays, der Reihe nach versucht. |
| `-ReportSender` | Beispieladresse | Absenderadresse. |
| `-ReportRecipients` | Beispieladresse | BCC-Empfänger. |
| `-ReportSubject` | `NoSpamProxy: Permanently blocked report` | E-Mail-Betreff. |
| `-ODataBaseUrl` | erforderlich | HTTPS-Basis-URL der eigenen Service-API; für `-Help` nicht erforderlich. |
| `-NoSend` | aus | Bericht ohne SMTP-Versand erstellen. |
| `-OutputPath` | nicht gesetzt | Zieldatei für HTML; nur zusammen mit `-NoSend` zulässig und dann erforderlich. |
| `-Help` | aus | Zeigt die ausführliche Hilfe ohne API-Aufruf oder E-Mail-Versand. |

Für geplante Ausführungen müssen die eigene OData-Basis-URL und die SMTP-Parameter angegeben sowie `NSP_API_KEY` im Prozess der geplanten Ausführung sicher bereitgestellt werden; eine temporär in einer interaktiven PowerShell gesetzte Variable reicht dafür nicht aus.

## Grenzen der API-Daten

- Aktionen und Filter werden als Ereignisse gezählt; eindeutige `MailId`-Werte werden getrennt ausgewiesen. Diese Werte sind nicht additiv als Nachrichtensumme zu interpretieren.
- Die Attachment-Entität enthält `MimeType`, `IsQuarantined` und die verknüpfte Nachricht, aber keinen anhangspezifischen ContentFiltering-Entscheid. Temporär und permanent abgelehnte Anhänge sind daher `n/a`, nicht eine aus Nachrichtenereignissen abgeleitete Zahl.
- `IsQuarantined=null` bleibt ein eigener, nicht gemeldeter Zustand und wird nicht als `false` behandelt.
- Gesehene und als bösartig markierte URLs werden anhand ihres Hashes in Nachrichten des jeweiligen Zeitraums eindeutig gezählt. Fehlt ein URL-Hash, erscheinen diese Zahlen als `n/a`. Klicks mit bösartiger Bewertung werden separat anhand von `UrlVisits.VisitedOn` gezählt und müssen nicht zu den im selben Zeitraum gesehenen URLs gehören.
- Ein `Scl`-Wert oder ein Filtername allein belegt keine 32GUARDS-Zuordnung. Recall wird stattdessen anhand eindeutiger `MailId`-Werte mit `WasRecalled=true` gezählt.
- MalwareScan-Operationen, Analyseergebnisse und tatsächliche Malware-Funde sind getrennte Größen. Malware-Kennzahlen mit identischen Werten in beiden Zeiträumen werden mit ihren jeweiligen Bezeichnungen in einer Zeile zusammengefasst. Sandbox-Funde erfordern einen expliziten `Infected`-Ergebnisstatus; unklare Vorgänge werden separat gezeigt.

## Sicherheit und Datenschutz

Die API wird ausschließlich mit GET-Abfragen verwendet. API-Antworten und Empfängeradressen werden nicht in Logs oder Testdokumentation geschrieben. Report-Dateien für E-Mail und PDF liegen temporär im Benutzer-Tempverzeichnis und werden nach Abschluss entfernt; `-NoSend` schreibt nur die ausdrücklich angegebene HTML-Ausgabe dauerhaft.

## Version

Die Skriptversion einschließlich Build und Datum ist im Berichtskopf sichtbar und wird in `Get-PermanentlyBlocked.ps1` gepflegt. Die Patchnotes stehen auf der [Release-Seite](https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/tag/v0.1.0).
