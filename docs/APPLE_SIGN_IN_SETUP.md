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

Daraus folgt: **kein** Client-Secret-JWT, **kein** `.p8`-Key, **keine**
Services ID und **keine** OAuth2-Konfiguration im PB-Admin. Eine frisch
leere Datenbank braucht für Apple-Login nichts außer dem Superuser fürs
Admin-UI. `scripts/apple-client-secret.sh` stammt aus dem alten
OAuth2-Weg und wird nur gebraucht, falls je ein Web-Login dazukommt.

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

Apples `sub` ist pro Team und primärer App-ID stabil. Neue Bundle-IDs
sind für Apple neue Apps: Ein User, der sich unter `org.fieldworksdiary.*`
angemeldet hatte, bekommt unter `app.legulus.*` ggf. einen anderen `sub`.

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
`ios/Fieldworksdiary/Fieldworksdiary.entitlements`.

## 3. Tabularius

### 3.1 — Erlaubte Audiences

Default in `backend/main.go` (`defaultAppleAudiences`):
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
Installer-Link ins Log (`docker compose logs backend`). Alternativ:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec backend \
  /app/fieldworksdiary superuser upsert <mail> <passwort>
```

Admin-UI: `<TABULARIUS>/_/`.

## 4. Testen

1. Bei einem Reset oder einer leeren DB: Auf dem iPhone unter
   Einstellungen → [Name] → Anmelden mit Apple → App → „Nicht mehr
   verwenden“. Apple liefert Name und E-Mail **nur beim allerersten**
   Login pro App. Ohne Reset legt Tabularius den User als
   `<sub>@apple.local` an.
2. Scheme wählen (`Fieldworksdiary` = Dev, `-Staging`, `-Prod`), auf
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

## Verwandte Dokumente

- [`docs/ENVIRONMENTS.md`](ENVIRONMENTS.md) — Stages, Bundle-IDs, URLs
- [`docs/adr/0002-auth-and-owner-scoping.md`](adr/0002-auth-and-owner-scoping.md)
- `backend/internal/api/apple_signin.go`, `backend/internal/services/apple.go`
