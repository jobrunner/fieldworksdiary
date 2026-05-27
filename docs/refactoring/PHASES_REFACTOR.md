# PHASES_REFACTOR.md — Refactoring-Initiative „Sample / Locality / Placemark"

**Initiative abgeschlossen: 2026-05-27.**

Der Refactor von Sample/Locality/Placemark ist in seinem geplanten
Scope (R0–R8e) durch und auf `main` gemerged. Diese Datei ist auf eine
Abschluss-Notiz reduziert; die ausführungsfertigen Baupläne und der
Session-Übergabe-Leitfaden (`CONTINUATION.md`) wurden nach Abschluss
entfernt. Die Ist-/Soll-Artefakte aus R0 (`inventory.md`,
`gap-analysis.md`) bleiben als historische Referenz erhalten.

Nicht Teil dieser Initiative und weiterhin offen sind die als
Folge-Features gelisteten Phasen **R9** (Export GPX/CSV/JSON),
**R10** (Daten-Migration Bestand) und **R11** (Planning-Feature).

---

## Phasenübersicht (Endstand)

| Phase | Titel | Status |
|---|---|---|
| R0 | Inventur | done |
| R1 | Designfragen / Decisions | done |
| R2 | Rename Excursion → Fieldtrip | done |
| R3 | PB-Schema-Erweiterungen | done |
| R4 | iOS-Modelle synchron | done |
| R5 / R5b | Sync: Outbox + Version-Conflict + SyncRunner-Verdrahtung | done |
| R6.1–R6.3 | Locality-Fusion (Server, iOS-Remap, Offline-Algorithmus) | done |
| R7.1–R7.3 | Placemark-Pipeline (Auto-Geocode, Manual-Override, Backfill) | done |
| R7.4 | Drop `samples.admin_units` | done |
| R8a | UI: Placemark-Display in Locality-Detail | done |
| R8b | UI: Manual-Override-Sheet + Reset | done |
| R8c | UI: Remap-Toast + FlagAmbiguous-Badge | done |
| R8d | UI: AddSample-Mode-Picker + Offline-Fusion-Integration | done |
| R8e | UI: Cluster-Map / Sample-ID-Template / erweiterte Filter | done |
| R9 | Export (GPX/CSV/JSON) | offen (Folge-Feature) |
| R10 | Daten-Migration Bestand | offen (Folge-Feature) |
| R11 | Planning-Feature (`planned_locality`) | offen (Folge-Feature) |

---

## Bestätigte Designentscheidungen (aus R1)

Vom User in der Phase-1-Abnahme akzeptiert; hier als bleibende
Referenz, weil sie das Datenmodell prägen.

| Punkt | Entscheidung |
|---|---|
| 1.1 Sample.notes | optional, UI normalisiert leer → `nil` |
| 1.2 Sample.location | optional am Modell, required am Use-Case |
| 1.3 Locality.notes/location | location required, notes optional |
| 1.4 Placemark-Felder | gemäß Spec-Tabelle; Hash NFC+lowercased+`\|`-join im Backend |
| 1.5 Sample.version | behalten + zusätzlich `client_updated_at` |
| 1.6 Sample.fieldtrip | required |
| 1.7 Sample.locality | **required** (Spec) — impliziert Bestands-Backfill |
| NEW-1 Naming | Excursion → Fieldtrip, UI-Strings „Exkursion" bleiben |
| NEW-2 Fieldtrip-Felder | `mtb`/`astro`/`day_of_year`/`country`/`admin_area`/`permit_*` behalten; `admin_units` bleibt als Fieldtrip-Snapshot (Sample-Spalte in R7.4 gedroppt) |
| NEW-3 Locality.radius_m | behalten als „beobachtete Streuung" |
| NEW-4 Locality.name | behalten, optional |
| NEW-5 geocache vs placemarks | beide behalten (verschiedene Layer) |
| NEW-6 Backfill | Migrations-Skript erzeugt 1:1-Localities, danach Server-Fusion |
| NEW-7 OpenAPI | wird in jeder Schema-Phase synchron aktualisiert |
| NEW-9 Plan-Doc | diese Datei, koexistierend mit `PHASES.md` |

User-Modifikationen am Ist-Stand:
- `beginDate`/`endDate` sind **DateTime-Typ**, nicht reine Date.
- `sample_id` ist **unique pro owner**.

---

## Wichtige Drift-Wächter (weiterhin gültig)

- **Placemark-Dedup-Hash** steht an drei Stellen in lockstep:
  `internal/enrichment/placemark.go`, `internal/api/placemark.go`,
  `migrations/1700000020_…`. Alle drei sind über
  `…LockedConstant`-Tests auf denselben kanonischen SHA-256 gepinnt —
  bei einem Touch an einer Stelle alle drei nachziehen.
- **`Codes.formatCode` (iOS)** hält den Default `<YY><MM><DD>/<seq>`
  byte-genau zum Go-Server-Format; abweichende User-Templates sind
  nur provisorisch (der Server relabelt beim Sync).
