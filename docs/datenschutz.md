# Datenschutzerklärung — Fieldworksdiary

**Stand:** 2026-05-13

Diese Erklärung beschreibt, welche Daten die App „Fieldworksdiary"
verarbeitet, zu welchem Zweck, auf welcher Rechtsgrundlage und wie
lange. Sie ergänzt — nicht ersetzt — die Datenschutzerklärung auf der
Web-Präsenz des Verantwortlichen.

## 1. Verantwortlicher

Verantwortlich im Sinne der DSGVO (Art. 4 Nr. 7) ist:

> *(Diese Felder vor dem App-Store-Submit ausfüllen.)*
>
> Name, Adresse
> E-Mail-Kontakt
> Optional: Telefon

## 2. Hosting & Datenfluss

Das Backend („Server") läuft als selbst betriebene PocketBase-Instanz
in einem privaten Netzwerk (Docker-Host). Die App spricht das Backend
ausschließlich über HTTPS / TLS an. Es gibt **keine** Cloud-Anbieter,
keine Drittanbieter-Analytics, kein Tracking, keine Werbung.

Datenflüsse:

- App ↔ Backend (Docker-Maschine): alle App-Daten (Aufsammlungen, Fundorte,
  Exkursionen, Kontoinformationen).
- App ↔ Apple: Sign-In-with-Apple-Authentifizierungs-Token, falls
  diese Login-Methode gewählt wurde. Apple erfährt nicht, was die App
  speichert oder wie sie benutzt wird.
- Backend ↔ Reverse-Geocoding & MTB-Lookup-Dienste (selbst gehostet
  auf dem Docker-Host): Koordinaten zur Anreicherung mit Verwaltungseinheiten
  und MTB-Quadranten. Antworten werden 7 Tage serverseitig gecacht.

## 3. Verarbeitete Daten

### 3.1 Kontodaten
- E-Mail-Adresse
- Passwort (nur als bcrypt-Hash gespeichert)
- Anzeigename, Kürzel
- Apple-User-Identifier (bei Sign-in-with-Apple), nicht jedoch die
  reale Apple-ID
- Authentifizierungs-Token (App-seitig im iOS-Schlüsselbund;
  serverseitig nur als signiertes JWT für die Sitzungsdauer)

### 3.2 Inhaltsdaten
- Geo-Koordinaten der Aufsammlungen (Dezimalgrad)
- Zeitstempel, Genauigkeit, Höhe
- Provisorische und endgültige Aufsammlungs-Codes
- Frei eingegebene Texte (Fundortnamen, Notizen, Sammler-Initialen)
- Permit-PDFs, falls hochgeladen
- Determinationsergebnisse, falls erfasst

### 3.3 Abgeleitete Daten
- Aus den Koordinaten serverseitig ermittelte
  Verwaltungseinheiten (Land, Region, Ort) und MTB-Quadranten
- Astronomische Berechnungen (Sonnen-/Mondzeiten) pro Exkursionstag

Es werden **keine** Werbe-Identifier (IDFA), keine Geräte-Fingerprints,
keine Standortdaten außerhalb expliziter Sample-Erfassung verarbeitet.

## 4. Zweck der Verarbeitung

- Bereitstellung der App-Kernfunktion: lokale Erfassung, Synchronisation
  und Verwaltung wissenschaftlicher Aufsammlungen.
- Anreicherung der Daten zur Etikettierung und Auswertung.
- Authentifizierung und Trennung der Daten verschiedener Nutzer.

## 5. Rechtsgrundlage

- Art. 6 Abs. 1 lit. b DSGVO — Erfüllung des Nutzungsvertrags
  („App nutzen können").
- Art. 6 Abs. 1 lit. f DSGVO — berechtigtes Interesse an einer
  zuverlässigen Anreicherung und Datenintegrität (Reverse-Geocoding,
  MTB-Lookup).

## 6. Speicherdauer

- Kontodaten: bis zur Account-Löschung.
- Inhaltsdaten: bis zur Account-Löschung; einzelne Datensätze können
  jederzeit in der App entfernt werden.
- Authentifizierungs-Token: bis zur Abmeldung.
- Geocache-Antworten (serverseitig): 7 Tage rollierend.
- Backup-Dumps des PocketBase-Datenbestands: bis zu 30 Tage auf der
  NAS, danach automatisches Rotieren.

## 7. Empfänger

Es findet **keine** Datenweitergabe an Dritte statt. Apple erhält
ausschließlich die für Sign-in-with-Apple notwendigen Auth-Datenflüsse.

## 8. Betroffenenrechte

Nutzer haben das Recht auf

- Auskunft (Art. 15 DSGVO)
- Berichtigung (Art. 16 DSGVO)
- Löschung (Art. 17 DSGVO) — vollständig in der App umsetzbar via
  „Einstellungen → Konto → Account löschen"
- Datenübertragbarkeit (Art. 20 DSGVO) — in der App über
  „Einstellungen → Daten → Daten exportieren" als ZIP-Archiv
  (`data.json` plus PDFs)
- Widerspruch (Art. 21 DSGVO)
- Beschwerde bei einer Aufsichtsbehörde (Art. 77 DSGVO)

Anfragen bitte an die unter §1 genannte Kontaktadresse.

## 9. Sicherheit

- Datenübertragung ausschließlich verschlüsselt (TLS 1.2+).
- Passwort serverseitig als bcrypt-Hash.
- Authentifizierungs-Token im iOS-Schlüsselbund mit
  `kSecAttrAccessibleAfterFirstUnlock`.
- Datentrennung auf Datenbankebene über `owner`-Filter
  (PocketBase-Rules `owner = @request.auth.id`).

## 10. Änderungen

Diese Erklärung kann angepasst werden, wenn sich die Verarbeitungs-
zwecke oder die technische Architektur ändern. Die jeweils aktuelle
Version ist in der App und auf der Web-Präsenz des Verantwortlichen
abrufbar.
