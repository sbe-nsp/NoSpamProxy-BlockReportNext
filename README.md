# NoSpamProxy BlockReport Next

**Ein kompakter PowerShell-Analysebericht für NoSpamProxy.** Alle Daten werden lesend über die OData-Service-API abgerufen – ohne SQL-Zugriff.

<p align="center">
  <strong>NSP-dark (Standard)</strong><br>
  <img src="https://raw.githubusercontent.com/sbe-nsp/NoSpamProxy-BlockReportNext/v0.4.1/docs/report-preview-nsp-dark.png" alt="NSP-dark: Vorschau des NoSpamProxy-Analyseberichts" width="876">
  <br>
  <strong>NSP-light</strong><br>
  <img src="https://raw.githubusercontent.com/sbe-nsp/NoSpamProxy-BlockReportNext/v0.4.1/docs/report-preview-nsp-light.png" alt="NSP-light: Vorschau des NoSpamProxy-Analyseberichts" width="876">
  <br>
  <strong>NSP-Classic</strong><br>
  <img src="https://raw.githubusercontent.com/sbe-nsp/NoSpamProxy-BlockReportNext/v0.4.1/docs/report-preview-nsp-classic.png" alt="NSP-Classic: Vorschau des NoSpamProxy-Analyseberichts" width="876">
  <br>
  <sub>Alle Berichtsvorschauen enthalten ausschließlich fiktive Beispieldaten.</sub>
</p>

<p align="center">
  <a href="https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/tag/v0.4.1">Release 0.4.1</a> ·
  <a href="#api-zugang-erstellen">API-Zugang erstellen</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#aufruf">Aufruf</a> ·
  <a href="#wöchentliche-ausführung-mit-der-aufgabenplanung">Aufgabenplanung</a>
</p>

## API-Zugang erstellen

Der Bericht benötigt einen NoSpamProxy-API-Schlüssel, auch Personal Access Token (PAT) genannt, mit genau zwei Leserechten:

- `read:messageTracking` für die Nachrichtentracking-Daten einschließlich URL Safeguard.
- `read:ownedDomains` für die eigenen Domains und die Auswertung interner Empfänger.

`manage`-Rechte sind für den Bericht nicht erforderlich. Zum **Erstellen** des Schlüssels benötigst du ein NoSpamProxy-Benutzerkonto, das API-Schlüssel erstellen darf.

### 1. PowerShell öffnen

Melde dich an einem NoSpamProxy-System an, auf dem das NoSpamProxy-PowerShell-Modul installiert und eingerichtet ist. Öffne über das Windows-Startmenü **Windows PowerShell**. Gib die folgenden Befehle in diesem Fenster ein und bestätige jeden Befehl mit **Enter**. Das Fenster während der Einrichtung geöffnet lassen.

### 2. NoSpamProxy-Modul laden

```powershell
Import-Module NoSpamProxy
```

Wird das Modul nicht gefunden, muss es zuerst auf diesem System verfügbar gemacht werden; wende dich dazu an die NoSpamProxy-Administration.

### 3. Mit NoSpamProxy verbinden

```powershell
Connect-Nsp -Credential (Get-Credential)
```

Im Anmeldefenster den Benutzernamen und das Passwort des NoSpamProxy-Kontos eingeben und bestätigen. Wenn die Verbindung wegen eines nicht vertrauenswürdigen Serverzertifikats fehlschlägt, kann in einer Testumgebung alternativ folgender Befehl verwendet werden:

```powershell
Connect-Nsp -IgnoreServerCertificateErrors -Credential (Get-Credential)
```

Der Schalter überspringt die Zertifikatsprüfung; für produktive Umgebungen sollte stattdessen ein vertrauenswürdiges Zertifikat verwendet werden.

### 4. API-Schlüssel erstellen und bereitstellen

Nach erfolgreicher Anmeldung diesen Befehl ausführen:

```powershell
$reportKey = New-NspApiKey -Name "NoSpamProxy-BlockReport" -Permissions "read:messageTracking","read:ownedDomains"
```

Der Name muss für dein Benutzerkonto eindeutig sein. Falls bereits ein Schlüssel mit diesem Namen existiert, wähle einen anderen Namen. Der Tokenwert wird nur bei der Erstellung zurückgegeben. Um den API-Schlüssel als Text auszugeben und beispielsweise für die Aufgabenplanung zu übernehmen, führe im selben Fenster aus:

```powershell
Write-Output $reportKey.Token
```

Kopiere den angezeigten Schlüssel direkt in einen geschützten Secret Store. Nach dem Schließen des Fensters kann der Tokenwert nicht erneut über NoSpamProxy abgerufen werden; bei Verlust muss ein neuer Schlüssel erstellt werden. Die [Anleitung zur Aufgabenplanung](#wöchentliche-ausführung-mit-der-aufgabenplanung) zeigt, wie ein gespeicherter Schlüssel für eine wöchentliche Ausführung bereitgestellt wird.

Den Schlüssel für den Bericht in **demselben PowerShell-Fenster** bereitstellen:

```powershell
$env:NSP_API_KEY = $reportKey.Token
```

Die Variable gilt nur für dieses PowerShell-Fenster. Nach dem Schließen muss der Schlüssel für einen erneuten Aufruf wieder bereitgestellt werden. Wie ein bereits vorhandener Schlüssel eingegeben wird, steht unter [Zugangsdaten](#zugangsdaten).

### 5. Bericht ausprobieren

Das [Anwenderpaket installieren](#installation), falls noch nicht geschehen. Im selben PowerShell-Fenster in das entpackte Verzeichnis wechseln. Den Beispielpfad durch den tatsächlichen Pfad ersetzen:

```powershell
Set-Location 'C:\Pfad\zum\NoSpamProxy-BlockReport'
```

Für `-ODataBaseUrl` die HTTPS-Basisadresse der bereits eingerichteten NoSpamProxy Web App verwenden: dieselbe Adresse, mit der du die Web App im Browser aufrufst, gegebenenfalls einschließlich Port. Gib nur die Basisadresse ohne nachfolgenden Seiten- oder API-Pfad an.

Die eigene HTTPS-Basis-URL eingeben und den Bericht ohne E-Mail-Versand erstellen:

```powershell
$odataBaseUrl = Read-Host 'HTTPS-Basis-URL der eigenen NoSpamProxy-Service-API'
$outputPath = Join-Path $env:TEMP ("NoSpamProxy-Report-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl $odataBaseUrl -NoSend -ReportType HTML -OutputPath $outputPath
```

Während der Erstellung zeigt PowerShell den aktuellen Arbeitsschritt und die verstrichene Laufzeit an. Auch bei einer längeren OData-Abfrage läuft die Zeitanzeige weiter; eine Prozent- oder Restzeitprognose wird nicht vorgetäuscht. Die Anzeige lässt sich bei Bedarf mit `$ProgressPreference = 'SilentlyContinue'` ausblenden.

Nach erfolgreichem Abschluss zeigt PowerShell den Speicherort der HTML-Datei an. Mit diesem Befehl lässt sich der Bericht im Browser öffnen:

```powershell
Start-Process $outputPath
```

## Berichtsumfang

Der Bericht vergleicht dieselben neun Bereiche in zwei vollständigen, nicht überlappenden und gleich langen Zeiträumen. Standard sind 14 Tage pro Zeitraum; mit `-Days` ist die Länge einstellbar:

1. Verarbeitete Nachrichtentracks und Zustellstatus
2. Blockierungsgründe, Filterereignisse und Engine-Aktionen
3. ContentFiltering-Ereignisse und Anhang-Quarantäne
4. MalwareScan-Operationen und bestätigte Malware-Funde
5. Sandbox-Analyse
6. URL Safeguard
7. 32GUARDS Recall
8. 32Guards DeepFile Analyzer
9. Häufigste MIME-Typen und Status der zugehörigen Nachricht

Zusätzlich enthält der Bericht weiterhin eine Top-10-Liste interner Empfänger dauerhaft oder temporär blockierter Nachrichten. Wo die API eine periodische Kennzahl nicht belegt, zeigt der Report `-` und erklärt die Einschränkung. Erfolgreich abgefragte Nullwerte werden als `0` dargestellt. Prozentänderungen bei einem Vergleichswert von null sind nicht berechenbar und erscheinen als `-`.

Die vier Kennzahlen im Berichtskopf zeigen neben dem Vergleichswert die absolute und prozentuale Veränderung des aktuellen Zeitraums gegenüber dem Vergleichszeitraum. Ein Plus bedeutet einen Anstieg, ein Minus einen Rückgang.

Für die Gestaltung stehen `NSP-dark` (Standard), `NSP-light` und `NSP-Classic` (die bisherige Vorlage) zur Wahl. Mit `-Template NSP-light` oder `-Template NSP-Classic` wird die jeweilige Vorlage für die HTML- und PDF-Berichte verwendet. Die E-Mail selbst enthält nur einen Klartext mit dem aktuellen Berichtszeitraum; die Berichte werden angehängt.

Bei den Anteilen im Bereich „Blockierungsgründe“ zeigen „Differenz“ und „Änderung“ die relative Veränderung in Prozent. In anderen Bereichen werden Differenzen zwischen Anteilen als Prozentpunkte (`PP`) ausgewiesen; „Änderung“ zeigt dort die relative Veränderung. Die Blockierungsgründe `LoopDetected` und `None` werden nicht als Zeilen angezeigt, zählen aber weiterhin zum Nenner der Anteile. Filtertreffer werden kompakt als Ereignisse mit positiver Bewertung gezeigt; sie belegen für sich keine ursächliche Blockierung.

`Policy` ist ein API-Ablehnungsgrund, der als „Richtlinie / Vorgabe“ übersetzt wird. Der Wert allein nennt weder die konkrete Regel noch die auslösende Aktion; diese lassen sich im Nachrichtentracking prüfen. `SpamOrVirus` allein belegt keinen bestätigten Malware-Fund.

Die MIME-Typen lassen sich im HTML-Bericht einzeln aufklappen und sind zunächst geschlossen. Im PDF sind ihre Details vollständig geöffnet; die Darstellung in E-Mail-Programmen hängt von deren Unterstützung für aufklappbare Bereiche ab.

Die Zeitfilter sind UTC. Bei `-Days 7` umfasst der aktuelle Zeitraum die letzten sieben vollständigen UTC-Tage; der Vergleich umfasst die unmittelbar davorliegenden sieben Tage. Der heutige UTC-Tag ist ausgeschlossen. Allgemein gilt: aktuell `[heute-Days, heute)`, Vergleich `[heute-2×Days, heute-Days)`; Start ist inklusiv, Ende exklusiv.

OData-Ergebnisse werden ohne feste Seitenzahlbegrenzung abgerufen. Filter- und Aktionsdaten werden seitenweise ausgewertet; bei großen Datenmengen können Laufzeit und Speicherbedarf trotzdem deutlich steigen. Wiederholte Fortsetzungslinks oder erkennbare wiederholte Seiten führen zu einem Fehler statt zu einem unvollständigen Bericht.

## Voraussetzungen

- Windows und PowerShell 5.1 oder neuer.
- In der getesteten Umgebung lieferte die `OwnedDomains`-Abfrage unter PowerShell 7 HTTP 404; mit Windows PowerShell 5.1 funktionierte sie. Bei diesem Fehler Windows PowerShell 5.1 verwenden.
- HTTPS-Zugriff auf die NoSpamProxy-Service-API und die eigene Basis-URL.
- Ein PAT mit `read:messageTracking` und `read:ownedDomains`.
- Für PDF-Ausgabe: Microsoft Edge. Ohne Edge wird beim Versand HTML als Fallback verwendet.
- Für den Versand: erreichbarer SMTP-Relay auf Port 25, gültiger Absender und Empfänger.
- `template-nsp-dark.html`, `template-nsp-light.html`, `template.html` und `ReportOData.ps1` im selben Verzeichnis wie `Get-PermanentlyBlocked.ps1`.
- Das NoSpamProxy-Logo ist in alle Vorlagen eingebettet; eine separate Bilddatei ist nicht erforderlich.

## Installation

Das [Anwenderpaket 0.4.1](https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/download/v0.4.1/NoSpamProxy-BlockReportNext-v0.4.1-build20261127.4.zip) herunterladen und entpacken. Es enthält die zwei PowerShell-Dateien, alle drei HTML-Vorlagen und die README.

Alternativ den `master`-Branch klonen:

```powershell
git clone --branch master https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext.git
Set-Location .\NoSpamProxy-BlockReportNext
```

Die Dateien im Projektverzeichnis zusammen belassen. Danach den PAT wie unter [API-Zugang erstellen](#api-zugang-erstellen) beschrieben bereitstellen und den Bericht zunächst mit `-NoSend` prüfen.

## Zugangsdaten

Der PAT wird ausschließlich aus der Prozess-Umgebungsvariable `NSP_API_KEY` gelesen. Lege ihn nicht in Skriptdateien, Aufgabenargumenten, PowerShell-History, Logs oder Git ab. Für geplante Ausführungen sollte ein geschützter Secret Store den Wert zur Laufzeit in die Umgebung des Prozesses laden.

Wenn bereits ein PAT vorhanden ist, kann er für einen interaktiven Test verdeckt abgefragt werden:

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

Für sieben Tage und die sieben Tage davor:

```powershell
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -Days 7 -NoSend -OutputPath 'C:\Reports\NoSpamProxy-Report.html'
```

Die helle oder klassische Vorlage auswählen:

```powershell
.\Get-PermanentlyBlocked.ps1 -ODataBaseUrl 'https://nospamproxy.example.com' -Template NSP-light -NoSend -OutputPath 'C:\Reports\NoSpamProxy-Report.html'
# Alternativ: -Template NSP-Classic
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

Ersetze `https://nospamproxy.example.com` in den Beispielen durch die HTTPS-Basisadresse deiner NoSpamProxy Web App, mit der du sie im Browser öffnest. Die Empfänger werden als BCC eingetragen. Beim Versand muss mindestens ein SMTP-Relay und ein Empfänger angegeben werden. Die voreingestellten Beispielwerte sind nicht produktiv verwendbar.

## Wöchentliche Ausführung mit der Aufgabenplanung

Dieses Beispiel versendet den Bericht einmal pro Woche per SMTP. Ohne `-Days` vergleicht der Bericht weiterhin zwei vollständige 14-Tage-Zeiträume; der wöchentliche Zeitplan allein ändert diese Zeiträume nicht. Für einen Wochenvergleich kann im Startskript beispielsweise `-ReportType Both -Days 7` angegeben werden.

### 1. Voraussetzungen vorbereiten

Entpacke das Anwenderpaket auf dem Windows-Computer, der den Bericht ausführen soll, beispielsweise nach `C:\Reports\NoSpamProxy-BlockReport`. Die beiden PowerShell-Dateien und alle drei Vorlagen müssen zusammen in diesem Verzeichnis bleiben. Der Computer benötigt Zugriff auf die eigene NoSpamProxy-Service-API und das SMTP-Relay.

Falls Windows die heruntergeladenen Skripte aufgrund ihrer Internet-Herkunft blockiert, kannst du sie nach Prüfung des Pakets entsperren. Passe die Pfade bei Bedarf an:

```powershell
Unblock-File -Path 'C:\Reports\NoSpamProxy-BlockReport\Get-PermanentlyBlocked.ps1','C:\Reports\NoSpamProxy-BlockReport\ReportOData.ps1'
```

Wähle ein Windows-Konto für die Aufgabe. Dieses Konto benötigt Zugriff auf das Reportverzeichnis, die API und das SMTP-Relay. Die folgenden Schritte zum Speichern des Schlüssels müssen **auf demselben Computer und unter demselben Windows-Konto** ausgeführt werden, unter dem später die Aufgabe läuft. Das Benutzerprofil des Kontos muss beim Ausführen verfügbar sein.

### 2. API-Schlüssel für das Aufgabenkonto speichern

Melde dich als das gewählte Aufgabenkonto an und öffne **Windows PowerShell**. Mit `whoami` kannst du prüfen, welches Windows-Konto das Fenster ausführt. Falls noch kein Schlüssel vorhanden ist, erstelle ihn wie unter [API-Zugang erstellen](#api-zugang-erstellen) beschrieben.

Erstelle ein Verzeichnis für die geschützte Schlüsseldatei. Dieses Beispiel verwendet `C:\ProgramData\NoSpamProxy-BlockReport`; passe den Pfad bei Bedarf an und stelle sicher, dass das Aufgabenkonto dort schreiben darf.

```powershell
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\NoSpamProxy-BlockReport' | Out-Null
```

Gib anschließend den zuvor ausgegebenen API-Schlüssel ein. Die Eingabe wird nicht angezeigt:

```powershell
$securePat = Read-Host 'NoSpamProxy API-Schlüssel' -AsSecureString
$securePat | Export-Clixml -LiteralPath 'C:\ProgramData\NoSpamProxy-BlockReport\api-key.xml'
```

Windows verschlüsselt den gespeicherten Wert für dieses Benutzerkonto auf diesem Computer. Ein anderes Konto oder ein anderer Computer kann diese Datei nicht verwenden; dort muss der Schlüssel unter dem jeweiligen Aufgabenkonto erneut gespeichert werden. Begrenze den Zugriff auf das Verzeichnis auf das Aufgabenkonto und die zuständigen Administratoren. Bei einem neuen oder abgelaufenen API-Schlüssel die Datei auf dieselbe Weise unter dem Aufgabenkonto erneut erstellen.

### 3. Startskript anlegen

Öffne Editor, kopiere den folgenden Inhalt hinein und speichere ihn als `C:\Reports\NoSpamProxy-BlockReport\Start-BlockReport.ps1`. Im Speicherdialog **Alle Dateien** als Dateityp auswählen, damit keine zusätzliche Endung `.txt` angehängt wird.

Ersetze die Beispielpfade, die HTTPS-Basis-URL, das SMTP-Relay sowie Absender und Empfänger durch deine eigenen Werte. Der Pfad zu `api-key.xml` muss mit Schritt 2 übereinstimmen.

```powershell
$ErrorActionPreference = 'Stop'
$securePat = Import-Clixml -LiteralPath 'C:\ProgramData\NoSpamProxy-BlockReport\api-key.xml'
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
try {
    $env:NSP_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    & 'C:\Reports\NoSpamProxy-BlockReport\Get-PermanentlyBlocked.ps1' `
        -ODataBaseUrl 'https://nospamproxy.example.com' `
        -SMTPHosts 'smtp-relay.example.local' `
        -ReportSender 'nsp-report@example.local' `
        -ReportRecipients 'admin@example.local' `
        -ReportType Both
}
finally {
    Remove-Item Env:\NSP_API_KEY -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
}
```

Der Schlüssel steht nur während des Startskripts in der Prozessumgebung. Das Startskript selbst und die Aufgabenargumente enthalten keinen Tokenwert.

### 4. Wöchentliche Aufgabe erstellen

1. Öffne im Windows-Startmenü **Aufgabenplanung** und wähle rechts **Aufgabe erstellen**.
2. Vergib auf **Allgemein** einen Namen, z. B. `NoSpamProxy BlockReport`. Wähle über **Benutzer oder Gruppe ändern** das Windows-Konto aus Schritt 2. Für einen unbeaufsichtigten Lauf wähle **Unabhängig von der Benutzeranmeldung ausführen** und speichere die Anmeldeinformationen, wenn Windows danach fragt.
3. Öffne **Trigger**, klicke auf **Neu**, wähle **Wöchentlich** und lege Wochentag und Uhrzeit fest. Bestätige mit **OK**.
4. Öffne **Aktionen**, klicke auf **Neu** und wähle **Programm starten**:
   - **Programm/Skript:** `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
   - **Argumente hinzufügen:** `-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Reports\NoSpamProxy-BlockReport\Start-BlockReport.ps1"`
   - Ersetze den Pfad zum Startskript, falls du es anders gespeichert hast.
5. Überprüfe unter **Bedingungen**, ob die Einstellungen für den Computer passen, und speichere die Aufgabe mit **OK**.

Die Ausführung von PowerShell-Skripten muss durch die Richtlinien des Computers erlaubt sein. Bei einer Sperre durch Gruppenrichtlinien oder fehlendem Recht **Anmelden als Stapelverarbeitungsauftrag** hilft die Windows-Administration.

### 5. Aufgabe prüfen

Wähle die Aufgabe in der Aufgabenplanungsbibliothek aus und klicke auf **Ausführen**. Dieser Probelauf versendet den Bericht bereits per E-Mail. Prüfe anschließend **Ergebnis der letzten Ausführung**: `0x0` bedeutet, dass der PowerShell-Prozess erfolgreich beendet wurde. Kontrolliere zusätzlich den Posteingang. Bei Fehlern helfen der Aufgabenverlauf und ein manueller Aufruf des Startskripts unter dem Aufgabenkonto.

```powershell
& 'C:\Reports\NoSpamProxy-BlockReport\Start-BlockReport.ps1'
```

## Parameter

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-ReportType` | `Both` | `HTML`, `PDF` oder `Both`; steuert die E-Mail-Anhänge. |
| `-Template` | `NSP-dark` | Berichtsgestaltung: `NSP-dark`, `NSP-light` oder `NSP-Classic`. |
| `-SMTPHosts` | Beispieladressen | SMTP-Relays, der Reihe nach versucht. |
| `-ReportSender` | Beispieladresse | Absenderadresse. |
| `-ReportRecipients` | Beispieladresse | BCC-Empfänger. |
| `-ReportSubject` | `NoSpamProxy: Permanently blocked report` | E-Mail-Betreff. |
| `-ODataBaseUrl` | erforderlich | HTTPS-Basisadresse der eigenen NoSpamProxy Web App und Service-API; für `-Help` nicht erforderlich. |
| `-Days` | `14` | Anzahl vollständiger UTC-Tage pro Zeitraum; mindestens `1`. Der Vergleich umfasst die direkt davorliegenden Tage. |
| `-NoSend` | aus | Bericht ohne SMTP-Versand erstellen. |
| `-OutputPath` | nicht gesetzt | Zieldatei für HTML; nur zusammen mit `-NoSend` zulässig und dann erforderlich. |
| `-Help` | aus | Zeigt die ausführliche Hilfe ohne API-Aufruf oder E-Mail-Versand. |

Für geplante Ausführungen müssen die eigene OData-Basis-URL und die SMTP-Parameter angegeben sowie `NSP_API_KEY` im Prozess der geplanten Ausführung sicher bereitgestellt werden; eine temporär in einer interaktiven PowerShell gesetzte Variable reicht dafür nicht aus. Ein vollständiges Beispiel steht unter [Wöchentliche Ausführung mit der Aufgabenplanung](#wöchentliche-ausführung-mit-der-aufgabenplanung).

## Grenzen der API-Daten

- Aktionen und Filter werden als Ereignisse gezählt; eindeutige `MailId`-Werte werden getrennt ausgewiesen. Diese Werte sind nicht additiv als Nachrichtensumme zu interpretieren.
- Die Attachment-Entität enthält `MimeType`, `IsQuarantined` und die verknüpfte Nachricht, aber keinen anhangspezifischen ContentFiltering-Entscheid. Temporär und permanent abgelehnte Anhänge sind daher `-`, nicht eine aus Nachrichtenereignissen abgeleitete Zahl.
- `IsQuarantined=null` bleibt ein eigener, nicht gemeldeter Zustand und wird nicht als `false` behandelt.
- Gesehene und als bösartig markierte URLs werden anhand ihres Hashes in Nachrichten des jeweiligen Zeitraums eindeutig gezählt. Fehlt ein URL-Hash, erscheinen diese Zahlen als `-`. Klicks mit bösartiger Bewertung werden separat anhand von `UrlVisits.VisitedOn` gezählt und müssen nicht zu den im selben Zeitraum gesehenen URLs gehören.
- Ein `Scl`-Wert oder ein Filtername allein belegt keine 32GUARDS-Zuordnung. Recall wird stattdessen anhand eindeutiger `MailId`-Werte mit `WasRecalled=true` gezählt.
- MalwareScan-Operationen, Analyseergebnisse und tatsächliche Malware-Funde sind getrennte Größen. Malware-Kennzahlen mit identischen Werten in beiden Zeiträumen können in einer Zeile zusammengefasst werden. Sandbox-Funde erfordern einen expliziten `Infected`-Ergebnisstatus; unbekannte Ergebnisse zählen nicht als bestätigter Fund.
- Werden Nachrichtentracking-Details nach Ablauf der Aufbewahrungsfrist gelöscht, fehlen die zugehörigen Analysevorgänge im Bericht. Eine `0` bei bestätigten Sandbox-Funden bedeutet daher nicht, dass im gesamten Zeitraum keine Funde aufgetreten sind.
- DeepFile-Analysevorgänge sind keine Dateizählung; bestätigte Nachrichtentracks sind nicht zwingend eindeutige E-Mails.

## Sicherheit und Datenschutz

Die API wird ausschließlich mit GET-Abfragen verwendet. API-Antworten und Empfängeradressen werden nicht in Logs oder Testdokumentation geschrieben. Report-Dateien für E-Mail und PDF liegen temporär im Benutzer-Tempverzeichnis und werden nach Abschluss entfernt; `-NoSend` schreibt nur die ausdrücklich angegebene HTML-Ausgabe dauerhaft.

## Version

Aktuelle Version: **0.4.1, Build 20261127.4 vom 27.11.2026**. Die Skriptversion ist im Bericht sichtbar und wird in `Get-PermanentlyBlocked.ps1` gepflegt. Die Patchnotes stehen auf der [Release-Seite](https://github.com/sbe-nsp/NoSpamProxy-BlockReportNext/releases/tag/v0.4.1).
