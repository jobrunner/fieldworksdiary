# ADR 0002: Auth-Modell und Daten-Scope per `owner`-Filter

**Datum:** 2026-05-13
**Status:** akzeptiert
**Kontext:** Phase 11 (Auth & Multi-User)

## Entscheidung

1. **Identität** kommt aus der eingebauten PocketBase-`users`-
   Collection. Login-Methoden: E-Mail/Passwort (alle Plattformen) und
   Sign-in-with-Apple (iOS). Passwort-Reset und E-Mail-Verifizierung
   nutzen die mitgelieferten PocketBase-Endpoints.

2. **Daten-Scope:** Jeder schreibgeschützte Record (`samples`,
   `excursions`, `localities`, `people`, `determinations`,
   `label_pdfs`) bekommt ein `owner`-Feld (Relation → `_users`).
   Owner wird **serverseitig** im before-create-Hook auf die Auth-ID
   gesetzt (Client darf das Feld nicht selbst beeinflussen).
   Collection-Rules erzwingen
   `@request.auth.id != '' && owner = @request.auth.id` für List/View/
   Update/Delete; Create erlaubt jeder authentifizierte Request, der
   Hook stellt sicher, dass der Owner korrekt sitzt.

3. **Auth auf Custom-Routen:** Die Label-Render-Routen (`/api/labels/
   locality`, `/api/labels/determination`) hängen vor jedem Aufruf
   `apis.RequireRecordAuth("users")` und prüfen pro angefragter
   Sample-ID gegen `auth.Id == sample.owner` — fremde Sample-IDs
   liefern HTTP 403.

4. **iOS hält den Token im Keychain**
   (`kSecAttrAccessibleAfterFirstUnlock`), nicht in UserDefaults.
   Auf Logout / User-Wechsel werden die lokalen Stores (`local_samples`,
   `local_sequences`, `local_excursions`, `local_localities`) per
   `DELETE FROM` truncated, bevor die neuen Daten gepullt werden.

## Begründung

**Warum „shared pool + owner-Filter" und nicht „strikt pro Benutzer":**

- **Erweiterbar.** Sharing („Diesen Fundort mit J. Müller teilen") wird
  später additiv: ein zusätzliches `shared_with`-Relations-Feld und
  eine erweiterte Rule. Bei strikt getrennten Schemas wäre das ein
  Datenmodell-Bruch.
- **Forschungskontext.** Lokalitäten sind in der Praxis oft geteilt
  (mehrere Sammler am selben Fundort). Das Modell modelliert das
  später korrekt; das jetzige `owner`-only ist nur der Default-Filter.
- **Einfacher Datenexport.** Ein zukünftiger gemeinsamer Datensatz für
  z. B. Forschungsgruppen läuft über dieselben Tabellen.

**Warum Hook-gesetzter Owner statt Client-Pflichtfeld:**

- Der Client kann den Header nicht beeinflussen. Ein böswilliger Client
  könnte sonst einen fremden Owner auf einen Record schreiben („Phantom-
  Record für Nutzer X").
- Die Migration vermeidet `MinSelect: 1` auf `owner` aus genau dem
  gleichen Grund wie beim `code`-Feld in Phase 1: PocketBase validiert
  vor dem Hook, der Required-Check würde Inserts ohne Owner ablehnen,
  bevor der Hook ihn überhaupt setzen kann.

**Warum `apis.ContextAuthRecordKey` statt `apis.RequestInfo(c).AuthRecord`:**

- `ContextRequestInfoKey` wird nur in PocketBase-Collection-Handlern
  initialisiert. Auf Custom-Routen ist `info` schlicht nicht da.
- Die Pre-Middleware `apis.LoadAuthContext` befüllt aber für *jede*
  Route `ContextAuthRecordKey` mit dem `*models.Record` des
  authentifizierten Benutzers — auch auf Custom-Routen.
- Konsequenz: Hooks und Custom-Routen lesen direkt
  `e.HttpContext.Get(apis.ContextAuthRecordKey).(*models.Record)`.

## Konsequenzen

- **Web- und Android-Clients** können dieselbe Auth wiederverwenden,
  ohne dass am Datenmodell etwas zu ändern wäre.
- **Multi-Device-Sync** ist ein reiner Read-Side-Pull: die Server-
  Filter sorgen automatisch dafür, dass jedes Device nur die eigenen
  Records sieht.
- **Sharing-Erweiterung** (geplant für Phase 12+) braucht ein neues
  Relations-Feld plus eine OR-Erweiterung der Rule, kein Datenmigrations-
  Großprojekt.
- **Account-Löschung** funktioniert über `CascadeDelete: true` auf der
  `owner`-Relation. Wenn der User-Record entfernt wird, kaskadieren
  Samples / Excursions / Localities / Determinations / Permits weg.
- **Lokale DB-Bereinigung** ist deutlich strenger als sie sein müsste
  (wir könnten bei gleichem Auth-User die Daten behalten). Das ist
  bewusst — Multi-User auf einem Gerät ist eine Randerscheinung, und
  ein voller Wipe stellt sicher, dass keine Phantom-Rows zurückbleiben.

## Alternativen

| Option | Bewertung |
|---|---|
| Strikt pro Benutzer (separate Collections pro Account) | Schemata würden sich vervielfachen; Sharing wäre praktisch unmöglich. Verworfen. |
| Client setzt `owner` mit eigener Auth-ID | Vertrauen in den Client; offen für Phantom-Records. Verworfen. |
| Nur Sign-in-with-Apple, kein E-Mail/Passwort | UX-First-Argument, aber Sperre für Android/Web. Verworfen. |
| OAuth2-Provider via PocketBase ohne Custom-Apple-Konfig | PocketBase liefert den Mechanismus, aber Apple verlangt Service-ID + Private Key; das ist ein zusätzlicher Setup-Schritt, kein architektonischer. |
