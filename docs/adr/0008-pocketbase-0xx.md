# ADR 0008: PocketBase 0.22 → 0.40.6

**Datum:** 2026-11-11
**Status:** akzeptiert (implementiert, Prod-Deploy steht aus)
**Kontext:** govulncheck/Trivy melden HIGH-Lücken in `labstack/echo/v5`
(GO-2026-6293, GO-2026-6885, CVE-2026-55677), das PocketBase 0.22.42
einbindet. Seit PocketBase 0.23 ist echo raus (eigener Router).

## Entscheidung

1. **Zielversion v0.40.6** (neueste). Sie enthält weiterhin die
   System-Migration `1717233556_v0.23_migrate.go` (+ `…migrate2-4`), die
   eine 0.22-`pb_data` beim ersten Start umbaut (`_admins` →
   `_superusers`, `schema` → `fields`, `created`/`updated` als
   `AutodateField`, Regeln `@request.data` → `@request.body`, Auth-
   Optionen, Token-Secrets). Damit genügt ein **Ein-Schritt-Deploy**,
   kein Zwischenstopp auf 0.23. Preis: v0.40 verlangt **Go 1.27**
   (go.mod `go 1.27.4`, Dockerfile `golang:1.27.4-alpine`, golangci-lint
   v2.15.0 per `install-mode: goinstall`, weil vorgebaute Releases
   Go-1.27-Exportdaten nicht laden).

2. **Alle 28 Migrationen inhaltlich treu portiert statt Squash.**
   Welche Migrationen auf Prod schon gelaufen sind, ist unbekannt. Die
   Dateinamen bleiben, also überspringt Prod alle schon angewandten
   (Tabelle `_migrations`), führt die fehlenden mit dem neuen Code aus,
   und eine frische DB läuft alle durch. Ein Squash hätte für eine
   teilmigrierte Prod-DB nicht funktioniert. Damit frische und
   upgegradete DBs gleich aussehen:
   - jede Collection bekommt `created`/`updated` als `AutodateField` mit
     denselben Feld-IDs, die das 0.23-Upgrade vergibt;
   - `users` bekommt das `username`-Feld (Pflicht, `users123456`
     autogeneriert, Unique-Index), das 0.22-User behalten;
   - Auth-Optionen wie das Upgrade sie aus den 0.22-Optionen ableitet
     (Passwort-Login per E-Mail, OAuth2 aus, Mindestlänge 8,
     Token-Laufzeit 14 Tage).

3. **Brücke für 0.22-Auth-Tokens** (`internal/api/legacy_token.go`).
   0.22-Tokens tragen `type: "authRecord"`, 0.23+ akzeptiert nur
   `"auth"`; ohne Brücke wären alle angemeldeten iOS-Apps nach dem Deploy
   ausgeloggt (auch `auth-refresh` scheitert). Das Secret bleibt beim
   Upgrade erhalten; die Middleware prüft Alt-Tokens wie 0.22 (Signatur,
   Ablauf). **Entfernen, sobald der Deploy länger als 14 Tage
   zurückliegt** (alte Token-Laufzeit).

4. **Verhalten 1:1, wo die iOS-App etwas sieht.** Hooks laufen als
   `OnRecord*Request` mit `e.Next()`; wo 0.22 `dao.SaveRecord` (ohne
   Validierung) benutzte, steht `SaveNoValidate`. Anonyme Creates
   scheitern weiter an der CreateRule (400). Der Placemark-Guard liefert
   denselben Fehler-Body wie 0.22.

## Akzeptierte Abweichungen

- Fehler-JSON: `{"status": 400, …}` statt `{"code": 400, …}`, einige
  Standardmeldungen anders formuliert („Only superusers …“, „Cannot be
  blank.“, „…authorization token.“), Feldfehler tragen teils `params`.
  Die iOS-App liest weder den Top-Level-Code noch die Meldungstexte
  maschinell (nur `message` zur Anzeige, `data.<feld>.code`,
  `data.current_version`).
- Schema-Details frisch vs. upgegradet (nicht API-sichtbar): JSON-Felder
  haben upgegradet `maxSize` 2 000 000 (0.22-Normalisierung), frisch die
  Werte aus den Migrationen; `users.name.max`, `avatar.maxSize`,
  Passwort-`cost`, Namen der System-Indexe auf `users` folgen den
  jeweiligen PocketBase-Defaults.
- PocketBase-0.23+-Features sind aktiv wie bei jeder Neuinstallation:
  Login-Benachrichtigung per Mail bei neuem Gerät (`authAlert`, braucht
  SMTP), `_authOrigins`.

## Verifikation

`scripts/pb-upgrade-check.sh`: altes Binary (6959bd6) und neues auf
Kopien derselben pb_data, Vergleich aller API-Antworten pro User,
Owner-Isolation, Dateien, Export, Fehlerformate, alter Token,
Superuser-Login; Schema frisch gegen upgegradet. Vor dem Prod-Deploy
gegen eine Kopie von `pb_data_prod` laufen lassen.
