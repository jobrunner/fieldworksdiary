# Apple-Sign-In — Setup-Anleitung

Vollständige Schritt-für-Schritt-Anleitung für das Einrichten von
"Mit Apple anmelden" gegen das PocketBase-Backend.

> **Vor Beginn**: Bundle-IDs und App-Namen sollten finalisiert sein.
> Diese Anleitung verwendet die Platzhalter `<BUNDLE_ID_*>` und
> `<TEAM_ID>` — überall im Dokument ersetzen, sobald die endgültigen
> Werte feststehen.
>
> Aktuelle Platzhalter im Code (Stand vor Rebranding):
> - Dev:     `org.fieldworksdiary.dev`
> - Staging: `org.fieldworksdiary.staging`
> - Prod:    `org.fieldworksdiary.prod`

Reihenfolge ist wichtig — von oben nach unten durcharbeiten. Es spielen
**drei Welten** zusammen: das Apple-Developer-Portal (wo Apple deine
Identität als Entwickler kennt), das Xcode-Projekt (lokal) und das
PocketBase-Backend (wo Apple-Tokens validiert werden).

---

## 1. Apple-Developer-Portal — einmaliges Setup

Öffne https://developer.apple.com/account und melde dich an. Unter
**Certificates, Identifiers & Profiles**:

### 1.1 — Team-ID notieren

Rechts oben im Header steht die **Team-ID** (10-Zeichen-Code,
in unserem Fall: `XS554Q5YY9`). Wir brauchen sie zweimal: in `ios/project.yml`
und im Client-Secret-Generator-Skript.

### 1.2 — App-IDs anlegen (3 Stück)

**Identifiers → + → App IDs → App → Continue**.

Pro Bundle-ID einmal:

| Description           | Bundle ID               | Capabilities         |
|-----------------------|-------------------------|----------------------|
| Diary Dev         | `<BUNDLE_ID_DEV>`       | ✅ Sign in with Apple |
| Diary Beta     | `<BUNDLE_ID_STAGING>`   | ✅ Sign in with Apple |
| Fieldworksdiary Production  | `<BUNDLE_ID_PROD>`      | ✅ Sign in with Apple |

Bei "Sign in with Apple" → **Configure** → **Enable as a primary
App ID** anklicken → **Save**.

Das **muss** für alle drei separat passieren — Apple bindet
Authorization-Codes an genau die Bundle-ID, von der sie ausgegeben
werden.

### 1.3 — Sign-in-with-Apple-Key erzeugen

**Keys → + → Sign in with Apple aktivieren → Configure**:

- Primary App ID: wähle **`<BUNDLE_ID_PROD>`** (Production)
- Save → Continue → Register

Du bekommst dann:

- Eine **Key-ID** (10 Zeichen, z. B. `7XK4F9D2AB`) — notieren
- Eine **`.p8`-Datei** zum Download — **das ist die einzige Chance,
  lade sie jetzt herunter**. Speicher sie sicher (z. B. 1Password /
  iCloud-Keychain), Apple zeigt sie nie wieder. Ein verlorener Key
  heißt: alten Key revoken, neuen erzeugen, alle Secrets neu
  generieren.

**Ein Key reicht für alle drei Bundle-IDs** — Apple erlaubt bis zu
zwei aktive Keys gleichzeitig, falls du rotieren musst.

### 1.4 — Services ID (überspringen für Native-only-iOS)

Für reine iOS-Apps mit nativem Sign-in-with-Apple **brauchst du keine
Services ID**. Die wäre nur nötig, wenn du Sign-in-with-Apple aus
einer Website heraus anbietest. Skip.

---

## 2. Xcode-Projekt — Team-ID + Capability

Das **Entitlement** ist bereits gesetzt (`ios/Fieldworksdiary/Fieldworksdiary.entitlements`
enthält `com.apple.developer.applesignin`).

Was fehlt: deine **Team-ID** muss aktiv sein, sonst kann Xcode keine
Provisioning-Profile auflösen.

`ios/project.yml` öffnen, im `Fieldworksdiary`-Target unter `settings.base`
ist die Zeile

```yaml
# DEVELOPMENT_TEAM: ABC123XYZ
```

als Kommentar. Das `#` entfernen und die Team-ID einsetzen:

```yaml
DEVELOPMENT_TEAM: <TEAM_ID>
```

Danach im `ios/`-Verzeichnis:

```bash
xcodegen generate
```

Damit kommt die Team-ID in die `.xcodeproj`. Xcode lädt dann
automatisch die richtigen Provisioning-Profile mit Sign-in-with-Apple-
Capability.

---

## 3. Client-Secret für PocketBase erzeugen

Apple verlangt als OAuth2-`client_secret` einen **JWT**, signiert mit
dem `.p8`-Schlüssel. Du musst den lokal generieren. Der JWT darf
maximal 180 Tage gelten — danach erneuern.

Im Repo liegt das Skript `scripts/apple-client-secret.sh`. Aufruf:

```bash
bash scripts/apple-client-secret.sh \
  --team-id  <TEAM_ID> \
  --key-id   <KEY_ID> \
  --client   <BUNDLE_ID_DEV> \
  --key-file ~/Downloads/AuthKey_<KEY_ID>.p8
```

Output ist ein langer JWT-String (`eyJhbGciOiJFUz…`). Den brauchst
du für den nächsten Schritt.

**Wichtig**: Pro Stage einmal aufrufen, jeweils mit der passenden
Bundle-ID als `--client`:

- Dev-PocketBase     → `--client <BUNDLE_ID_DEV>`
- Staging-PocketBase → `--client <BUNDLE_ID_STAGING>`
- Prod-PocketBase    → `--client <BUNDLE_ID_PROD>`

Der gleiche JWT lässt sich nicht für zwei Bundle-IDs verwenden
(Apple verweigert den Token-Exchange mit `invalid_grant`, weil der
Code an Bundle-ID A ausgestellt war und du als Bundle-ID B kommst).

---

## 4. PocketBase-Backend konfigurieren

Im Browser zum PB-Admin der jeweiligen Stage einloggen:

- Dev:     `http://<DEV_HOST>:8090/_/`
- Staging: `https://staging.<DEINE-DOMAIN>/_/`
- Prod:    `https://api.<DEINE-DOMAIN>/_/`

### 4.1 — OAuth2-Apple-Provider aktivieren

**Collections** in der Seitenleiste → Klick auf die **users**-Collection
→ oben rechts **Edit Collection** → Tab **Options**.

Runterscrollen zu **OAuth2** → den **Apple**-Block aufklappen:

- **Enabled** anschalten
- **Client ID**: die Bundle-ID **dieser** Stage
  (z. B. `<BUNDLE_ID_DEV>` auf dem Dev-PocketBase)
- **Client secret**: den JWT aus Schritt 3 reinpasten
  (der lange `eyJ…`-String)

**Save changes** unten.

### 4.2 — Allowed-Auth-Origins prüfen

In der gleichen Settings-Sektion: stelle sicher, dass
**Allow OAuth2 sign-up** aktiv ist (sonst kann sich niemand neu
anmelden). Optional auch **Manage email/password** aktiv lassen —
sonst können Apple-User keinen Email-Login mehr nachziehen.

### 4.3 — Token-Erneuerung im Kalender vormerken

Setz dir einen Kalender-Reminder auf das Ablaufdatum (das Skript zeigt
es nach jedem Run als Hinweis an). 2 Wochen vorher: Skript erneut
laufen lassen, neuen JWT in PB-Admin pasten, speichern. Apple-Login
funktioniert sofort weiter — kein App-Update nötig.

---

## 5. Testen

1. **Alte App vom Device löschen** (falls die Bundle-ID sich geändert
   hat, sonst kommt es zu Profile-Konflikten).

2. Xcode öffnen, Scheme **`Fieldworksdiary`** (Debug) wählen, Device als
   Run-Destination.

3. **Run** (▶). Beim ersten Launch kommt evtl. ein Dialog "Möchte
   'Diary Dev' Geräte im lokalen Netzwerk finden?" — **Erlauben**.

4. In der App den Backend-Endpoint setzen (für Dev: `http://<DEV_HOST>:8090`).

5. **"Mit Apple anmelden"** tippen:
   - Apple-System-Dialog erscheint
   - Beim allerersten Mal: Name + Email-Sharing-Option auswählen
     (Email teilen oder verbergen). Apple gibt diese Daten **nur
     einmalig** mit — wenn du den User in PocketBase später löschst
     und neu anlegst, kommt **kein** Name/Email mehr, nur die
     Apple-User-ID. Tipp für Tests: in iOS-Einstellungen →
     Apple-ID → Sign in with Apple → die App entfernen, dann fragt's
     beim nächsten Mal wieder.
   - Mit Face-ID / Touch-ID / Apple-ID-Passwort bestätigen
   - Apple gibt der App `identityToken` + `authorizationCode` zurück
   - Die App POSTet das an
     `<BACKEND>/api/collections/users/auth-with-oauth2`
   - PocketBase tauscht den Code bei Apple gegen einen ID-Token ein,
     validiert die JWT-Signatur, erstellt einen User in der
     `users`-Collection (oder lädt den existierenden)
   - User landet in der App eingeloggt

6. Im PB-Admin nachsehen: **users**-Collection sollte einen neuen User
   haben, mit einer langen ID und der von Apple übermittelten Email
   (oder einer Apple-Relay-Adresse `…@privaterelay.appleid.com`).

---

## 6. Debugging — wenn was schiefgeht

### `invalid_client` / `invalid_grant` vom PocketBase

→ Die **Client-ID** in PB stimmt nicht mit der Bundle-ID überein,
gegen die der Code ausgegeben wurde. Beispiel: Dev-Bundle-ID
`<BUNDLE_ID_DEV>` in der App, aber in PocketBase steht
`<BUNDLE_ID_PROD>` als Client-ID. Apple sagt "der Code gehört zu
einer anderen App".

**Fix**: Bundle-ID prüfen (in `project.yml`), PB-Client-ID anpassen,
oder ein neues `client_secret` mit der korrekten Bundle-ID als
`--client` erzeugen.

### `client_secret expired` (nach ~180 Tagen)

→ Apple lehnt den JWT ab. Skript aus Schritt 3 erneut laufen, neuen
JWT in PB pasten, fertig.

### Apple-Dialog kommt gar nicht erst auf

→ Sign-in-with-Apple-Capability ist auf der App-ID nicht aktiv, oder
das Provisioning-Profile ist veraltet.

**Fix**: in Xcode → Target Fieldworksdiary → Signing & Capabilities →
**+ Capability** → **Sign in with Apple**. Dann Profile manuell
neu laden (Xcode → Settings → Accounts → Download Manual Profiles).

### "Es besteht anscheinend keine Verbindung zum Internet"

→ ATS blockt rohe IP. Schon gefixt mit der separaten
`Info.debug.plist`; nochmal sicherstellen, dass der **Debug**-Build
benutzt wird (= App heißt "Diary Dev" mit blauem `DEV`-Badge
auf der Welcome-Screen).

### "OAuth2 provider not configured"

→ PB-Admin → users-Collection → Options → OAuth2 → Apple ist nicht
angeschaltet, oder der Save-Button wurde nicht gedrückt.

---

## 7. Quick-Reference

| Wo | Was |
|---|---|
| Apple-Portal | 3× App-ID mit Sign-in-with-Apple anlegen |
| Apple-Portal | 1× Key (.p8) generieren, Key-ID notieren |
| Apple-Portal | Team-ID notieren |
| Lokal | `bash scripts/apple-client-secret.sh …` → JWT generieren |
| `project.yml` | `DEVELOPMENT_TEAM: <TEAM_ID>` eintragen, `xcodegen generate` |
| PB-Admin | users → Options → OAuth2 → Apple → Client-ID + JWT eintragen |
| Device | Alte App löschen, Debug-Scheme neu installieren, testen |

Sobald Team-ID + Key-ID vorliegen, sind das ~15 Minuten reine
Klick-Arbeit pro Stage.

---

## 8. Werte-Sammlung (ausfüllen, sobald bekannt)

Diese Tabelle ist der schnelle Lookup beim späteren Reaktivieren —
nach dem Rebranding hier die finalen Werte eintragen.

| Wert | Inhalt |
|------|--------|
| Team-ID | `_______________` |
| Bundle-ID Dev | `_______________` |
| Bundle-ID Staging | `_______________` |
| Bundle-ID Prod | `_______________` |
| Sign-in-with-Apple Key-ID | `_______________` |
| `.p8`-Schlüssel Speicherort | `_______________` |
| JWT-Ablaufdatum Dev | `_______________` |
| JWT-Ablaufdatum Staging | `_______________` |
| JWT-Ablaufdatum Prod | `_______________` |

> **Sicherheits-Reminder**: Diese Tabelle **nicht committen**, sobald
> echte Werte drinstehen. Stattdessen in einem Password-Manager
> ablegen. Bundle-IDs und Team-ID sind zwar öffentlich erkennbar (aus
> dem `.app`-Bundle), aber Key-ID + `.p8` + JWT sind Geheimnisse.

---

## Verwandte Dokumente

- [`docs/ENVIRONMENTS.md`](ENVIRONMENTS.md) — Drei-Stage-Setup
  (Dev/Staging/Prod) inkl. Bundle-ID-Mapping
- [`docs/RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md) — Pre-Flight
  vor jedem Submit
- [`SECURITY.md`](../SECURITY.md) — Threat-Model inkl. Auth-Pfade
- [`docs/adr/0002-auth-and-owner-scoping.md`](adr/0002-auth-and-owner-scoping.md)
  — Architektur-Entscheidung zum Auth-Modell
