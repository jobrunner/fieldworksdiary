# App-Store-Pre-Flight — Fieldworksdiary

Checklist für TestFlight + App-Store-Submission. Was hier ohne Tick
steht, ist menschlich vor der Submission zu erledigen — der Code
selbst ist nach Phase 11d soweit.

## 1. Apple Developer Account

- [ ] Apple Developer Program-Mitgliedschaft aktiv ($99 / Jahr).
- [ ] Bundle ID `com.weevilapp.Weevilapp` im Developer-Portal
      registriert (oder eine neue, falls die App vor Submit umbenannt
      wird).
- [ ] Capability **Sign in with Apple** auf der Bundle ID aktiviert.

## 2. Sign-in-with-Apple-Setup (Backend-seitig)

- [ ] Service ID im Developer-Portal anlegen (z. B.
      `com.weevilapp.Weevilapp.signin`).
- [ ] Domain & Return URLs eintragen — Return URL ist der
      Self-Hosted-Endpoint plus `/api/oauth2-redirect`.
- [ ] Private Key (`.p8`) erzeugen, Team ID und Key ID notieren.
- [ ] In der PocketBase Admin-UI unter `_users` → Auth-Provider →
      Apple aktivieren und die vier Werte (Client ID = Service ID,
      Team ID, Key ID, Private Key) eintragen.
- [ ] Smoke-Test: in der iOS-App auf einem Gerät auf den
      „Sign in with Apple"-Button tippen → Login funktioniert.

## 3. Xcode-Projekt

- [x] `Sign in with Apple`-Entitlement in
      `ios/Weevilapp/Weevilapp.entitlements`.
- [x] `CODE_SIGN_ENTITLEMENTS` in `ios/project.yml` gesetzt.
- [x] `PrivacyInfo.xcprivacy` im App-Target.
- [ ] In `ios/project.yml` (oder per Xcode → Signing & Capabilities)
      `DEVELOPMENT_TEAM` setzen.
- [ ] Marketing-Version + Build-Nummer pflegen
      (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` in
      `project.yml`).
- [ ] App-Icon + Launch-Screen final.

## 4. App-Store-Connect

- [ ] App in App Store Connect anlegen.
- [ ] Kategorie wählen (z. B. „Bildung" oder „Forschungs-Tools").
- [ ] Beschreibungstexte (DE + EN), Keywords, Promotional Text.
- [ ] Altersfreigabe-Fragebogen ausfüllen.
- [ ] Datenschutz-URL = öffentlich erreichbare HTTPS-Adresse der
      Datenschutzerklärung (`docs/datenschutz.md` als Quelle, irgendwo
      gehostet — z. B. `https://fieldworksdiary.<domain>/datenschutz`).
- [ ] Support-URL eintragen.

## 5. Privacy Nutrition Labels

Aus dem PrivacyInfo.xcprivacy abgeleitet — bitte beim Submit
manuell synchron halten:

- **Data Linked to You**
  - Email Address — Zweck: App Functionality
  - Name — Zweck: App Functionality
  - Precise Location — Zweck: App Functionality
- **Data Not Linked**: keine
- **Tracking**: nein

## 6. Screenshots

- [ ] 6.7"-Display (iPhone 15 Pro Max): mind. 1, max. 10.
- [ ] 5.5"-Display (iPhone 8 Plus): mind. 1, max. 10.
- [ ] 12.9"-iPad-Pro (3.+ Gen.): mind. 1, max. 10.
- Empfehlung: vier Hauptscreens (Neue Probe, Exkursionsliste,
  Fundortdetail, Probe-Detail) mit Demo-Daten aus Würzburg.

## 7. TestFlight

- [ ] Über Xcode → Archive einen Release-Build erzeugen, danach
      Validate → Upload to App Store Connect.
- [ ] In App Store Connect den Build einer internen
      TestFlight-Gruppe zuweisen.
- [ ] Mindestens eine externe Beta-Runde (z. B. eigene Geräte +
      Mitsammler) durchspielen, bevor das Review eingereicht wird.

## 8. Review-Vorbereitung

- [ ] Demo-Account anlegen (Email/Passwort), den Apple-Review-Team
      nutzt — Credentials im Review-Notiz-Feld hinterlegen.
- [ ] Hinweis, dass das Backend ein selbst gehosteter Server ist und
      ausschließlich über HTTPS erreichbar.
- [ ] Hinweis auf die Account-Löschung in den Einstellungen.

## 9. Nach dem Submit

- [ ] Crash-Logs in Xcode/App Store Connect monitoren.
- [ ] Versionsplan: nach Genehmigung Tag im Git, Release-Branch
      `release/0.1.0`.

## Was die Codebasis schon liefert

- Account-Löschung via Sheet (zweistufige Confirmation mit
  „DELETE"-Eingabe). Backend löscht den User; alle abhängigen Records
  cascaden über die `owner`-Relation.
- E-Mail-Verifizierung und Passwort-Reset über die PocketBase-
  Default-Endpoints — funktioniert, sobald SMTP auf der Docker-Maschine
  konfiguriert ist.
- Privacy-Manifest mit deklarierten Datentypen, API-Reason-Codes für
  UserDefaults, FileTimestamp, SystemBootTime, DiskSpace.
- Auth-Header-Pflicht für **alle** Datenzugriffe; ungeloggte Calls
  liefern HTTP 401.
- Lokale Daten werden bei User-Wechsel / Logout aus der GRDB-Datei
  gelöscht.
