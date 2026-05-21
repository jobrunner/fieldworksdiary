# ADR 0004: Logging über `slog` (Backend) und `os.Logger` (iOS)

**Datum:** 2026-05-16
**Status:** akzeptiert
**Kontext:** Pre-App-Store-Submit, Observability-Aufbau

## Entscheidung

1. **Backend** loggt ausschließlich über `log/slog` (Go-Stdlib seit
   1.21). JSON-Handler in Production, Text in Dev. Default-Level
   `Info`; Debug-Level über `PB_LOG_LEVEL=debug`.

2. **iOS** loggt ausschließlich über `os.Logger`. Eine zentrale
   Façade `Log.<category>` in `Core/Observability/Log.swift` stellt
   benannte Logger-Instanzen pro Subsystem-Bereich bereit (`Log.sync`,
   `Log.auth`, `Log.persistence`, `Log.network`, `Log.location`,
   `Log.ui`, `Log.metrics`, `Log.app`). Subsystem fix
   `org.fieldworksdiary.prod`.

3. **`print()` ist verboten** in iOS-Production-Code. SwiftLint hat
   eine Custom-Rule `no_print`, die das in der CI bemerkbar macht.

4. **PII-Regeln** sind in `.claude/rules/LOGGING.md` festgehalten und
   gelten für beide Stacks:
   - Keine Auth-Tokens, keine E-Mail-Adressen, keine
     Voll-Präzision-Koordinaten.
   - Keys sind standardisiert (`sample_id`, `excursion_id`, `user_id`,
     `request_id`, `service`, `cache`, `duration_ms`, `err`).
   - OSLog-Interpolationen sind by-default `.private` (redactet auf
     anderen Geräten); `.public` nur für nicht-sensible IDs.

## Alternativen, die wir verworfen haben

- **`zap` oder `zerolog` im Backend**: stärker performance-optimiert
  als `slog`, aber ohne aktuellen Anlass (kein gemessener
  Bottleneck). `slog` ist Stdlib, hat keinen Dependency-Cost und
  funktioniert sofort mit JSON-Handler.

- **Sentry oder Crashlytics im iOS**: Drittanbieter, kosten Geld bei
  Skalierung, leaken Telemetrie nach außen, brauchen separate
  Privacy-Manifest-Einträge. MetricKit (Apple-nativ) liefert für
  Crashes, Hangs und CPU-Exceptions schon vieles davon — siehe ADR
  0005.

- **Strukturlose `print`/`fmt.Println`-Logs**: gehen mittelfristig
  immer schief. Aggregierbarkeit (ELK/Loki) braucht strukturierten
  JSON-Output.

## Konsequenzen

- Logger-Instanzen werden per Konstruktor in Backend-Komponenten
  injiziert (z. B. `Enricher.Logger *slog.Logger`). Kein
  `slog.Default()` außerhalb von `main.go`.

- iOS-Helper sind statisch (`enum Log` mit `static let`-Loggern).
  Keine Dependency-Injection nötig — `Logger` ist thread-safe und
  zero-cost.

- Inspektion lokal:
  - Backend: `docker compose logs -f backend | jq` (JSON-Output)
  - iOS-Simulator: `xcrun simctl spawn booted log stream --predicate 'subsystem == "org.fieldworksdiary.prod"'`
  - iOS-Gerät: Console.app → Geräte → Filter auf Subsystem

- Crash-Reports/Hang-Reports werden über MetricKit gesammelt, NICHT
  über das Log-Subsystem — siehe ADR 0005.

## Referenzen

- Regel-Datei: `.claude/rules/LOGGING.md`.
- Backend-Beispiel: `backend/internal/enrichment/enrichment.go`.
- iOS-Helper: `ios/Fieldworksdiary/Core/Observability/Log.swift`.
- SwiftLint-Custom-Rule `no_print` in `.swiftlint.yml`.
