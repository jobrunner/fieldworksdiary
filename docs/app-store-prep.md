# App-Store-Pre-Flight — Fieldworksdiary

Checklist für TestFlight + App-Store-Submission. Was hier ohne Tick
steht, ist menschlich vor der Submission zu erledigen — der Code
selbst ist nach Phase 11d soweit.

## 1. Apple Developer Account

- [ ] Apple Developer Program-Mitgliedschaft aktiv ($99 / Jahr).
- [ ] Bundle ID `app.legulus.prod` im Developer-Portal
      registriert (oder eine neue, falls die App vor Submit umbenannt
      wird).
- [ ] Capability **Sign in with Apple** auf der Bundle ID aktiviert.

## 2. Sign-in-with-Apple-Setup (Backend-seitig)

Native Flow über `POST /api/auth/apple-native` - für die iOS-App keine
Services ID und kein OAuth2-Provider in PocketBase. Details (auch zu
Website/PWA) in `docs/APPLE_SIGN_IN_SETUP.md`.

- [ ] `app.legulus.prod` steht in den erlaubten Audiences von
      Tabularius (Default in `backend/main.go`, sonst
      `APPLE_ALLOWED_AUDIENCES`).
- [ ] Smoke-Test: in der iOS-App auf einem Gerät auf den
      „Sign in with Apple"-Button tippen → Login funktioniert.
- [ ] Token-Revocation bei Account-Löschung (`/auth/revoke`, braucht
      `.p8`-Key + Client-Secret) - Pflicht für den Review.

## 3. Xcode-Projekt

- [x] `Sign in with Apple`-Entitlement in
      `ios/Fieldworksdiary/Fieldworksdiary.entitlements`.
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
      gehostet — z. B. `https://legulus.app/datenschutz`).
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
