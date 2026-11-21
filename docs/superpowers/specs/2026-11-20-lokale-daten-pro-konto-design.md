# Lokale Daten pro Konto

Stand: 2026-11-20. Status: von Jo entschieden, umgesetzt in PR „fix(ios): lokale Daten pro Konto“.

## Anlass

Auf einem Gerät lagen Proben von Konto A. Die App startete abgemeldet, dann
meldete sich Konto B an. Die App lud die Proben von A unter dem Konto von B
hoch. Ursache: Die App merkte sich nur im Arbeitsspeicher, wem die lokalen
Daten gehören, und es gab nur eine lokale Datenbank für alle.

Zweites Problem: Abmelden löschte alle lokalen Daten sofort, auch Proben und
Fotos, die noch nicht hochgeladen waren.

## Jos Vorgaben

- Wer abgemeldet ist, soll die Daten auf seinem Gerät weiter lokal
  exportieren und später importieren können (Absicherung).
- Ansonsten holt und synchronisiert die App immer die Daten des aktuellen
  Kontos.
- Daten verschiedener Konten werden pro Konto getrennt aufbewahrt.
- Lokaler Export und Import kommen als eigener PR mit eigenem Design.

## Lösung

- **Eine Datenbank pro Konto:** `Application Support/accounts/<Konto-ID>/legulus.sqlite`.
  Die Dienste eines Kontos (Stores, Sync, Hydratoren) bilden einen
  `AccountGraph`; `AppContainer` hält genau den des angemeldeten Kontos.
- **Abmelden löscht nichts.** Der Graph des Kontos wird angehalten, die
  Daten bleiben in seiner Datenbank und sind nach der nächsten Anmeldung
  wieder da, samt Ungesendetem.
- **Anderes Konto, andere Datenbank.** Meldet sich B an, öffnet die App die
  Datenbank von B (anfangs leer) und holt dessen Daten vom Server.
- **Token an das Konto gebunden:** Die Dienste eines Graphen bekommen das
  Sitzungs-Token nur, solange es zu ihrem Konto gehört (`AccountBoundAuth`,
  liest die Nutzer-ID aus dem Token). Arbeit, die nach einem Kontowechsel
  noch läuft, kann so weder unter fremdem Token senden noch fremde Daten in
  die eigene Datenbank holen.
- **Bisherige Datenbank:** Die eine Datenbank früherer Versionen wird beim
  ersten Anmelden auf die Konten aufgeteilt, deren Proben darin liegen
  (Spalte `user_id`). Jedes Konto bekommt eine Kopie mit seinen eigenen
  Proben, deren Fotos, Features und Outbox-Einträgen. Das Konto mit den
  meisten Proben behält zusätzlich, was sich nicht zuordnen lässt (Proben
  ohne Nutzer, zwischengespeicherte Exkursionen und Fundorte, übrige
  Outbox-Einträge). Ohne Proben ist die Datei ein Cache und geht an das
  angemeldete Konto. Kopiert wird über SQLites Backup unter einem
  Zwischennamen und mit einer Umbenennung veröffentlicht; die alte Datei
  wird erst entfernt, wenn alle Konten versorgt sind. Hat ein Konto schon
  eine Datenbank, bleibt die alte Datei unangetastet liegen.
- **Abgemeldet** arbeitet die App auf einer leeren Datenbank im Speicher.

## Bewusst so

- **Fotos** bleiben im gemeinsamen Ordner `Documents/photos/<Sample-ID>/`.
  Die IDs sind zufällig, und nur die Datenbank des Besitzers verweist auf
  die Dateien.
- **Wartende GPS-Fixes** einer Probe verfallen beim Abmelden. Die Probe
  bleibt dann ohne Koordinate, bis man sie von Hand setzt.
- **Aufteilung:** Noch nicht hochgeladene, selbst angelegte Fundorte des
  kleineren Kontos gehen bei der Aufteilung verloren, weil sie sich in der
  alten Datenbank keinem Konto zuordnen lassen.
- Lässt sich die Datenbank eines Kontos nicht öffnen, der Speicherort nicht
  ermitteln oder die Aufteilung der alten Datenbank für das Konto nicht
  abschließen (z.B. voller Speicher), beendet sich die App, statt im
  Speicher oder mit einer leeren Datenbank weiterzuarbeiten. Die Daten
  bleiben dabei in der alten Datei.
- Von Hand eingegebene Orte sind privat und bleiben bei der Aufteilung beim
  jeweiligen Besitzer; gemeinsame Orte des Backends stehen in jeder Kopie.
- **Kein Aufräumen:** Datenbanken von Konten, die sich nie wieder anmelden,
  bleiben auf dem Gerät. Ein Aufräumen käme mit dem Export.
- Zwei Backends mit zufällig gleicher Nutzer-ID würden sich eine Datenbank
  teilen. PocketBase vergibt zufällige IDs, das ist praktisch
  ausgeschlossen.

## Nicht Teil dieses PRs

Lokaler Export und Import (eigener PR), Auswahl oder Löschen alter
Konto-Datenbanken in der App.
