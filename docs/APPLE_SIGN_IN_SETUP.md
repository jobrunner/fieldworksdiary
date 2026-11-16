# Apple-Sign-In — Setup-Anleitung

Schritt-für-Schritt-Anleitung für „Mit Apple anmelden“ in Legulus
gegen das Tabularius-Backend.

## Wie der Flow funktioniert

Legulus nutzt den **nativen** Sign-in-with-Apple-Flow (seit Phase R8).
Der PocketBase-OAuth2-Provider ist dafür nicht beteiligt:

1. Die App holt sich über `AuthenticationServices` ein `identityToken`
   (JWT, von Apple signiert, `aud` = Bundle-ID der App).
2. Sie POSTet es an `<TABULARIUS>/api/auth/apple-native`.
3. Tabularius prüft Signatur (Apple-JWKS, 1 h gecacht), Issuer,
   Ablauf und `aud` gegen die Liste erlaubter Bundle-IDs.
4. Tabularius sucht den User über `apple_user_id` (= Apples `sub`),
   verknüpft ihn ggf. per E-Mail mit einem bestehenden Passwort-User
   oder legt ihn neu an, und gibt ein PocketBase-Auth-Token zurück.

Für die iOS-App folgt daraus: **kein** Client-Secret-JWT, **kein**
`.p8`-Key und **keine** OAuth2-Konfiguration im PB-Admin. Eine frisch
leere Datenbank braucht für Apple-Login nichts außer dem Superuser fürs
Admin-UI. Website und PWA brauchen zusätzlich eine Services ID, siehe
Abschnitt 6.

## Werte

| Wert | Inhalt |
|------|--------|
| Team-ID | `XS554Q5YY9` |
| Bundle-ID Dev | `app.legulus.dev` |
| Bundle-ID Staging | `app.legulus.staging` |
| Bundle-ID Prod | `app.legulus.prod` |
| Tabularius Dev | `https://tabularius.tunnel.legulus.app` (sish-Tunnel) |
| Tabularius Staging | `https://tabularius-stage.legulus.app` |
| Tabularius Prod | `https://tabularius.legulus.app` |

---

## 1. Apple-Developer-Portal

https://developer.apple.com/account → **Certificates, Identifiers &
Profiles** → **Identifiers** → **+** → **App IDs** → **App**.

Pro Bundle-ID, die du wirklich baust:

| Description | Bundle ID | Capability |
|---|---|---|
| Legulus Dev | `app.legulus.dev` | Sign in with Apple |
| Legulus Beta | `app.legulus.staging` | Sign in with Apple |
| Legulus | `app.legulus.prod` | Sign in with Apple |

Bei „Sign in with Apple“ → **Configure** → **Enable as a primary App
ID** → **Save**.

Apples `sub` (bei uns `apple_user_id`) und die Relay-Adresse
`…@privaterelay.appleid.com` gelten **pro Developer-Team**, nicht pro
App-ID. Alle Bundle-IDs und Services IDs unter Team `XS554Q5YY9` sehen
für denselben Apple-User denselben `sub`. Deshalb lässt sich eine
Tabularius-Datenbank zwischen Dev, Stage und Prod umziehen, ohne dass
Apple-Logins ins Leere laufen (Abschnitt 7). Nur ein Wechsel des Teams
ändert den `sub`; das ginge nur über Apples Transfer-Flow.

Mit automatischem Signing (`CODE_SIGN_STYLE: Automatic`) legt Xcode
die App-IDs beim ersten Device-Build auch selbst an. Die Capability
kommt dann aus dem Entitlement. Prüfen lohnt sich trotzdem.

## 2. Xcode

`ios/project.yml` ist die Quelle (Team-ID, Bundle-IDs, Icons,
`TABULARIUS_ENDPOINT_DEFAULT` pro Config). Danach:

```bash
cd ios && xcodegen generate
```

Das Entitlement `com.apple.developer.applesignin` steht in
`ios/Legulus/Legulus.entitlements`.

## 3. Tabularius

### 3.1 — Erlaubte Audiences

Default in `tabularius/main.go` (`defaultAppleAudiences`):
`app.legulus.dev`, `app.legulus.staging`, `app.legulus.prod`.

Abweichend per Env-Variable im Compose-File (kommagetrennt):

```yaml
environment:
  APPLE_ALLOWED_AUDIENCES: app.legulus.prod
```

Ich würde auf Prod nur `app.legulus.prod` zulassen, sobald es eigene
Dev-/Stage-Instanzen gibt. Bis dahin ist der Default bequemer.

### 3.2 — Superuser auf frischer DB

Beim ersten Start mit leerer DB schreibt PocketBase einen
Installer-Link ins Log (`docker compose logs tabularius`). Alternativ:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec tabularius \
  /app/tabularius superuser upsert <mail> <passwort>
```

Admin-UI: `<TABULARIUS>/_/`.

## 4. Testen

1. Bei einem Reset oder einer leeren DB: Auf dem iPhone unter
   Einstellungen → [Name] → Anmelden mit Apple → App → „Nicht mehr
   verwenden“. Apple liefert Name und E-Mail **nur beim allerersten**
   Login pro App. Ohne Reset legt Tabularius den User als
   `<sub>@apple.local` an.
2. Scheme wählen (`Legulus` = Dev, `-Staging`, `-Prod`), auf
   dem Gerät starten. Für Dev muss der sish-Tunnel laufen.
3. „Mit Apple anmelden“ tippen.
4. Im Admin unter **users**: ein User mit gesetzter `apple_user_id`
   und `verified = true`.

## 5. Debugging

| Symptom | Ursache / Fix |
|---|---|
| 401, Log `apple-signin: verify failed` | `aud` nicht erlaubt → Bundle-ID in `APPLE_ALLOWED_AUDIENCES` bzw. Default aufnehmen. Oder Token abgelaufen (Uhrzeit Gerät/Server). |
| 400 `identity_token is required` | App schickt kein Token - Client-Bug. |
| Apple-Dialog erscheint nicht | Capability fehlt auf der App-ID oder Provisioning-Profil veraltet → Xcode → Settings → Accounts → Download Manual Profiles. |
| User heißt `apple_<sub>`, Mail `…@apple.local` | Apple hat keine Mail mitgeschickt, weil die App schon autorisiert war → Schritt 4.1. |
| Dev-Build erreicht nichts, Tunnel-URL gibt 404 | sish-Tunnel läuft nicht oder die lokale Instanz ist aus. |

## 6. Website und PWA (geplant)

Zur iOS-App kommen eine Website und ggf. eine PWA. Ohne nativen
`AuthenticationServices`-Dialog läuft Apple-Login dort über
„Sign in with Apple JS“ oder den OAuth-Redirect, und dafür braucht es
eine **Services ID**.

### 6.1 — Services ID anlegen

Portal → **Identifiers** → **+** → **Services IDs**:

- Description: `Legulus Web`
- Identifier: z. B. `app.legulus.web` (darf keine Bundle-ID sein)
- „Sign in with Apple“ aktivieren → **Configure**:
  - **Primary App ID**: `app.legulus.prod`. Gruppiert die Website mit
    der App, sodass der User sie unter „Mit Apple anmelden“ als eine
    App sieht. Der `sub` ist ohnehin team-weit gleich, Web- und
    iOS-Login landen also im selben Tabularius-User.
  - **Domains**: die Web-Domain (z. B. `legulus.app`), ohne Schema
  - **Return URLs**: die Callback-URL der Website, HTTPS, exakt
    (Apple vergleicht zeichengenau)

Pro Stage mit eigener Domain eine eigene Services ID (z. B.
`app.legulus.web.stage`), jeweils mit der passenden primären App-ID.

### 6.2 — Welcher Weg im Backend

**Variante A (Empfehlung): Apple JS mit Popup, Token an den bestehenden
Endpoint.** Apple JS liefert im Popup-Modus direkt ein `id_token`, mit
`aud` = Services ID. Das geht an `POST /api/auth/apple-native` wie bei
iOS. Auf Backend-Seite muss nur die Services ID in die erlaubten
Audiences (`APPLE_ALLOWED_AUDIENCES` bzw. Default in `main.go`). Der
Vorteil: Es gibt einen einzigen User-Lookup über `apple_user_id`, also
keine Dubletten zwischen Web und App.

**Variante B: PocketBase-OAuth2-Provider „Apple“.** Dafür sind Client
ID = Services ID, ein Client-Secret-JWT aus dem `.p8`-Key
(`scripts/apple-client-secret.sh`, maximal 180 Tage gültig) und die
Return-URL `<TABULARIUS>/api/oauth2-redirect` nötig. Das Problem:
PocketBase verknüpft OAuth2-User über `_externalAuths`, nicht über
`apple_user_id`. Wer sich zuerst in der App und dann im Web anmeldet,
landet ohne Zusatzlogik in zwei Accounts (oder wird nur über die
E-Mail verknüpft, und die fehlt bei Relay-Adressen).

Ich halte A für den saubereren Weg. B lohnt sich nur, falls die Website
ohnehin das PocketBase-JS-SDK mit `authWithOAuth2` nutzt.

### 6.3 — Offene Punkte, bevor Web live geht

- **Nonce**: Der Verifier prüft heute kein `nonce`-Claim. Bei iOS ist
  das tragbar. Im Browser sollte die Website einen Nonce erzeugen, an
  Apple JS übergeben und mitschicken, und das Backend sollte ihn
  prüfen. Sonst lässt sich ein abgegriffenes `id_token` innerhalb
  seiner Laufzeit wiederverwenden.
- **Token-Revocation bei Account-Löschung**: Apple verlangt für
  App-Store-Apps mit Sign in with Apple, dass beim Löschen des Accounts
  das Token über `https://appleid.apple.com/auth/revoke` widerrufen
  wird. Dafür braucht es den `.p8`-Key und ein Client-Secret, also
  dann auch für iOS. Das ist im Backend noch nicht umgesetzt.
- **Key**: Ein Sign-in-with-Apple-Key (`.p8`) reicht für alle App- und
  Services-IDs des Teams. Key-ID und Datei gehören in den
  Password-Manager, nicht ins Repo.

## 7. Eine Datenbank für Dev, Stage und Prod

Möglich, weil `apple_user_id` team-weit gilt. Eine Kopie von Prod nach
Stage oder Dev (`pb_data/`) funktioniert für Apple-Logins ohne
Nacharbeit. Beim Kopieren wandert aber mehr mit als die Daten:

- **Token-Secrets:** PocketBase legt die Signatur-Secrets für Auth-Tokens
  in der DB ab. Nach einer Kopie sind Prod-Tokens auch auf Stage gültig
  und umgekehrt. Nach jedem Kopieren auf der Ziel-Instanz im Admin unter
  Collections → users → Options → Tokens die Tokens invalidieren
  (dasselbe für `_superusers`).
- **Settings:** Application URL, SMTP und ggf. S3 stehen in der DB. Nach
  der Kopie anpassen, sonst verschickt Stage Mails mit Prod-Links.
- **Superuser:** kommen mit. Auf Dev/Stage ggf. per
  `superuser upsert` ein eigenes Passwort setzen.
- **Audiences:** Was ein Login auf welcher Instanz darf, steuert
  `APPLE_ALLOWED_AUDIENCES`, nicht die DB. Der Default lässt alle drei
  Bundle-IDs überall zu. Wer verhindern will, dass sich eine Dev-App an
  Prod anmeldet, setzt pro Instanz nur die passende Bundle-ID.

## Verwandte Dokumente

- [`docs/ENVIRONMENTS.md`](ENVIRONMENTS.md) — Stages, Bundle-IDs, URLs
- [`docs/adr/0002-auth-and-owner-scoping.md`](adr/0002-auth-and-owner-scoping.md)
- `tabularius/internal/api/apple_signin.go`, `tabularius/internal/services/apple.go`
