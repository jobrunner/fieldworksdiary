# ADR 0007: Realtime-Subscriptions vs. REST-Polling für Pull-Sync

**Datum:** 2026-05-26
**Status:** akzeptiert
**Kontext:** Phase R5 (Sync-Schicht, gap-analysis.md NEW-8)

## Frage

Die Spec verlangt einen Sync-Mechanismus, der Records, die auf
Server-Seite ändern (Enrichment, Locality-Fusion, Placemark-Anhängen,
Cross-Device-Edits), zeitnah auf alle Clients zieht. Zwei Wege:

- **Realtime:** PocketBase bietet `/api/realtime` (SSE-basiert) mit
  per-Collection-Subscriptions. Der Client hält eine offene Verbindung
  und bekommt Push-Events bei Create/Update/Delete.
- **Polling:** Der Client zieht in festen Intervallen
  `GET /api/collections/<name>/records?sort=-updated&filter=updated > {:last}`
  und merged die neuen Records lokal.

## Entscheidung

**Polling für den Pull-Pfad, mit Push-Trigger nach jedem eigenen Write.**

Konkret:

1. Jeder iOS-Hydrator (SamplesHydrator, FieldtripsHydrator,
   LocalitiesHydrator, künftig PlacemarksHydrator + RemapEventsPuller)
   pollt mit `updated > lastSeen`-Filter alle 30 s, wenn die App im
   Vordergrund ist; im Hintergrund nur bei expliziten Triggern
   (Notification, App-Foreground, manueller Pull-to-Refresh).
2. Nach jedem **eigenen** erfolgreichen Push (z. B. neues Sample)
   triggert der `SyncRunner` einen sofortigen Pull für die Owning-
   Collection — so wird Enrichment, das das Backend in einer
   Goroutine nachzieht, ohne sichtbare Verzögerung sichtbar.
3. Kein offener SSE-Stream. Kein Battery-Drain durch persistente
   Verbindung. Kein Wake-Logic im Background.

## Begründung

Drei Punkte tragen die Entscheidung:

**1. Keine SSE-Client-Library für Swift, die PB versteht.**
PocketBase's Realtime ist ein eigenes SSE-Frame-Format mit einem
Subscription-Handshake über REST (`POST /api/realtime`,
Heartbeat-Logik, Re-Subscribe nach Disconnect). Eine `URLSession`-
basierte SSE-Implementation wäre ein eigener Mini-Brocken: Buffering
parser, Reconnect-Backoff, Lifecycle gegen `UIApplication`-States,
Auth-Refresh, Subscription-State-Sync. Das ist nicht Spec-Kernscope.

**2. Realistische Update-Frequenz ist niedrig.**
Die App ist Single-User-pro-Device. Cross-Device-Edits passieren bei
einem Sammler im Feld extrem selten; meist ist nur ein Gerät aktiv.
Selbst der Worst-Case (zwei Sammler-Geräte) sieht keine ms-Latenz-
Anforderung — 30 s Polling-Lag ist für einen Sammeltag-Workflow
folgenlos.

**3. Battery / Bandbreite.**
Auf einer 8h-Exkursion im Funkloch ist eine offene SSE-Verbindung
ein Battery-Risiko (Modem hält wach, Retry-Loops) und ein
Bandbreite-Risiko (PB-Heartbeats summieren sich). 30s-Polling mit
Conditional-Filter ist HTTP/2-Multiplex-freundlich, läuft nur bei
aktiver App-Phase, und ein Fehler schlägt nicht durch — der nächste
Pull holt nach.

Die Spec nennt Realtime als bevorzugt, lässt aber explizit „REST-
Polling als Fallback" offen. Für unsere Workflow-Realität ist
Polling kein Fallback, sondern die saubere Wahl.

## Konsequenzen

- **R5.3** entfällt als eigene Phase. Das Polling läuft schon in den
  bestehenden Hydratoren (SamplesHydrator etc.); R5 ergänzt nur eine
  Cursor-Logik (`lastSeen`-Timestamp pro Collection) und den
  Push-Trigger nach eigenen Writes.
- **Locality-Remap-Events** (Phase R6) werden ebenfalls per Polling
  gezogen, nicht per Subscription. Ein separater
  `RemapEventsPuller` mit kleinem Cursor-Intervall.
- **Multi-Device-Konfliktauflösung** verlässt sich allein auf die
  `version`-Spalte (R5.1) und auf `client_updated_at` als Tiebreaker.
- **Re-Verhandlung:** wenn der Workflow um mehrere parallel
  arbeitende Geräte erweitert wird (Forschungsgruppe), gehen wir
  R5.3 nochmal an. Bis dahin keine WebSocket/SSE-Investition.

## Tests

Keine direkten Tests für diesen ADR — der Pull-Pfad ist über die
bestehenden Hydrator-Tests + neue Cursor-Tests in R5.1/R5.2
abgedeckt. Ein Manual-Test gehört zur R5-Abnahme: zwei Devices auf
denselben User, eines schreibt, das andere zeigt das Sample
innerhalb der nächsten 30 s nach Pull-Trigger.
