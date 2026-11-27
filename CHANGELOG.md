## [0.3.0] - Build 20261127.2 - 2026-11-27

### Neu
- `-Days` legt die Anzahl vollständiger UTC-Tage für den aktuellen und den unmittelbar vorhergehenden Vergleichszeitraum fest; ohne Angabe bleiben es jeweils 14 Tage.
- Die vier Kennzahlen im Berichtskopf zeigen den Vergleichszeitraum sowie die absolute und relative Veränderung mit Vorzeichen.

### Überarbeitet
- „Zustellung ausstehend“ ist in der Nachrichtenübersicht ausgeblendet; fehlende oder nicht berechenbare Werte erscheinen als `-`.
- Prozentanteile bei den Blockierungsgründen zeigen in den Spalten „Differenz“ und „Änderung“ die relative Veränderung in Prozent.
- Die Sandbox-Auswertung weist auf möglicherweise gelöschte Tracking-Details und dadurch fehlende Funde hin.
- Die Dokumentation erklärt die Web-App-Adresse für `-ODataBaseUrl`; die Berichtsvorschau zeigt fiktive Daten im aktuellen Design.

## [0.2.0] - Build 20261127.1 - 2026-11-27

### Neu
- MIME-Typen im HTML-Bericht einzeln auf- und zuklappbar; die Details sind zunächst geschlossen und im PDF geöffnet.
- Aktualisierte Berichtsvorschau mit ausschließlich fiktiven Beispieldaten.

### Überarbeitet
- Verständlichere Status-, Engine-, Filter-, Malware- und Recall-Bezeichnungen sowie eine Erläuterung der API-Blockierungsgründe.
- Einheitliche Schriftfarbe für die Kennzahlen im Berichtskopf; doppelte Gesamtzahl und nicht benötigte Quarantäne- und Sandbox-Zeilen entfernt.
- DeepFile-Werte bleiben fachlich korrekt als Analysevorgänge und Nachrichtentracks bezeichnet.
- API-Zugang und wöchentliche Ausführung über die Windows-Aufgabenplanung sind in der README beschrieben.

## [0.1.0] - Build 20261126.5 - 2026-11-26

### Neu
- Erste Veröffentlichung von NoSpamProxy BlockReport Next mit neun OData-basierten Analysebereichen und einem Vergleich zweier vollständiger 14-Tage-Zeiträume.
- Kompakte Übersicht über Nachrichten, Blockierungen, Filter- und Engine-Ereignisse, Malware, Sandbox, URL Safeguard und Anhänge.
- HTML-Bericht mit eingebettetem Logo und Versionsanzeige; optionaler PDF- und SMTP-Versand sowie `-NoSend` zur lokalen Prüfung.
- Die eigene HTTPS-Basis-URL ist mit `-ODataBaseUrl` anzugeben; der PAT wird über `NSP_API_KEY` bereitgestellt.
- Die Projektvorschau enthält ausschließlich fiktive Beispieldaten.
- Das Anwenderpaket und die automatisch erzeugten Quellarchive enthalten die drei benötigten Reportdateien und die README.

### Dokumentation aktualisiert - 2026-11-26
- Schritt-für-Schritt-Anleitung zum Erstellen eines API-Schlüssels mit den benötigten Leserechten und zur Ausgabe des Tokenwerts ergänzt.
- Einrichtung einer wöchentlichen Windows-Aufgabe mit geschützter Schlüsseldatei und SMTP-Versand beschrieben.
- Das Anwenderpaket enthält die aktualisierte README; die automatisch erzeugten Quellarchive zeigen weiterhin den ursprünglichen Release-Tag.
