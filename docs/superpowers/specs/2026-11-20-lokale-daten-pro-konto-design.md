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
- **Bisherige Datenbank:** Die eine Datenbank früherer Versionen geht beim
  ersten Anmelden an das Konto, dem die meisten Proben darin gehören
  (Spalte `user_id`). Enthält sie keine Proben, ist sie nur ein Cache und
  geht an das angemeldete Konto. Hat das Zielkonto schon eine Datenbank,
  bleibt die alte Datei unangetastet liegen.
- **Abgemeldet** arbeitet die App auf einer leeren Datenbank im Speicher.

## Bewusst so

- **Fotos** bleiben im gemeinsamen Ordner `Documents/photos/<Sample-ID>/`.
  Die IDs sind zufällig, und nur die Datenbank des Besitzers verweist auf
  die Dateien.
- **Wartende GPS-Fixes** einer Probe verfallen beim Abmelden. Die Probe
  bleibt dann ohne Koordinate, bis man sie von Hand setzt.
- **Kein Aufräumen:** Datenbanken von Konten, die sich nie wieder anmelden,
  bleiben auf dem Gerät. Ein Aufräumen käme mit dem Export.
- Zwei Backends mit zufällig gleicher Nutzer-ID würden sich eine Datenbank
  teilen. PocketBase vergibt zufällige IDs, das ist praktisch
  ausgeschlossen.

## Nicht Teil dieses PRs

Lokaler Export und Import (eigener PR), Auswahl oder Löschen alter
Konto-Datenbanken in der App.
