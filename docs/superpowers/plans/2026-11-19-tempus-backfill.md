# Tempus-Backfill (PR 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bestehende Proben, die vor Phase T angelegt wurden (leerer `conditions_status`), bekommen ihre Wetter-, Klima- und Astronomiewerte über ein Kommando, das in Portionen läuft und sich fortsetzen lässt.

**Architecture:** Das Kommando `tempus-backfill` nutzt die Anreicherung aus PR 7 (`enrichment.ConditionsEnricher`) Probe für Probe, mit Pause zwischen den Abfragen und einer Obergrenze pro Lauf. Verarbeitete Proben haben danach einen Status, ein weiterer Lauf macht bei den übrigen weiter.

**Tech Stack:** Go, PocketBase als Library, cobra-Kommando wie `ortus-backfill`.

**Spec:** `docs/superpowers/specs/2026-11-19-tempus-wetter-klima-design.md`, Abschnitt „Reihenfolge und PRs“ (PR 9) und „Datenhaltung“ (leerer Status).

## Global Constraints

- Branch `feat/tempus-backfill` auf `feat/tempus-backend`. Commits: Conventional Commits, Scope `tabularius`, Footer `Claude-Session: https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`.
- Logging nach `.claude/rules/LOGGING.md`, keine Koordinaten.
- Keine echten Dienst-Adressen in Doku, Tests, Commit- oder PR-Texten.
- Abweichung von der Spec, bewusst: Einzelabfragen statt Batch-Endpunkt. Grund: Die Einzelabfrage nutzt Abbildung, Statusregeln, Cache und Wettlauf-Schutz aus PR 7 unverändert; der Batch-Endpunkt bräuchte einen zweiten Schreibweg. Die Schonung der Wetterquelle übernimmt die Obergrenze pro Lauf (Default 200) und die Pause zwischen Abfragen (Default 2 s).
- Vor dem PR: `go test ./...`, `go vet ./...`, `golangci-lint run` sauber.

## Review Focus

1. Abbruch mitten im Lauf (Ctrl-C, Timeout): bereits verarbeitete Proben bleiben verarbeitet, der nächste Lauf setzt bei den übrigen fort. → Test in Task 1.
2. Tempus nicht erreichbar: die Probe bleibt `pending` (der Stundenlauf versucht sie erneut), der Backfill zählt sie als Versuch und läuft weiter. → Test in Task 1.
3. Probe ohne Koordinate oder mit vorhandenem Status: wird nie angefasst. → Test in Task 1.
4. Eine Probe bekommt während des Laufs von der App Werte: der Backfill überschreibt sie nicht. → Test in Task 1.
5. `TEMPUS_BASE_URL` leer: das Kommando endet mit einem Fehler statt still nichts zu tun. → Test in Task 2.

### Task 1: Backfill-Lauf

**Files:**
- Modify: `tabularius/internal/enrichment/conditions.go`
- Create: `tabularius/internal/backfill/conditions.go`
- Test: `tabularius/internal/backfill/conditions_test.go`, `tabularius/internal/enrichment/conditions_test.go`

**Interfaces:**
- Produces:
  - `func (e *ConditionsEnricher) BackfillSample(ctx context.Context, sampleID string) bool` — setzt eine Probe mit leerem Status und Koordinate in einer Transaktion auf `pending` (ohne Versions-Sprung) und ruft `EnrichSample`. Gibt `false` zurück, wenn die Probe nicht (mehr) in Frage kommt.
  - `type ConditionsRunner struct { App core.App; Conditions *enrichment.ConditionsEnricher; Limit int; Interval time.Duration; Logger *slog.Logger }`
  - `type ConditionsResult struct { Queried, Remaining int }`
  - `func (r *ConditionsRunner) Run(ctx context.Context) (ConditionsResult, error)` — älteste Proben zuerst (`created`), höchstens `Limit` (0 = Default 200), Pause `Interval` (0 = Default 2 s) zwischen zwei Abfragen. `Remaining` = Proben mit leerem Status und Koordinate nach dem Lauf.

- [ ] Failing Tests: `TestBackfillSample_FillsLegacySample`, `TestBackfillSample_SkipsSampleWithStatusOrWithoutCoordinate`, `TestBackfillSample_TempusDownLeavesPending`, `TestConditionsRunner_RespectsLimitAndResumes` (3 Altproben, Limit 2 → Queried 2, Remaining 1; zweiter Lauf → Queried 1, Remaining 0; dritter → 0/0), `TestConditionsRunner_SkipsProcessedAndCoordinateless`, `TestConditionsRunner_CancelledContextStops` (bereits verarbeitete bleiben), `TestConditionsRunner_NilEnricherIsAnError`.
- [ ] Implementieren, Tests grün, Commit `feat(tabularius): Backfill bestehender Proben über Tempus`

### Task 2: Kommando, Doku, PR

**Files:**
- Modify: `tabularius/main.go` (Kommando `tempus-backfill` neben `ortus-backfill`, Flags `--limit`, `--interval`)
- Test: `tabularius/main_test.go` (oder die Datei, in der `newBackfillRunner` getestet wird)
- Modify: `docs/ENVIRONMENTS.md`, `PHASES.md`

- [ ] Failing Test: `newConditionsBackfillRunner` mit leerer URL → Fehler; mit URL → Runner mit den übergebenen Werten.
- [ ] Implementieren. Ausgabe am Ende: Zahl der Abfragen und der verbleibenden Proben.
- [ ] Doku: Aufruf, Empfehlung (täglich wiederholen, bis nichts mehr verbleibt), Hinweis auf die Reihenfolge vor PR 10.
- [ ] `go test ./...`, `go vet`, `golangci-lint`; Commit `feat(tabularius): Kommando tempus-backfill`; Push; PR gegen `feat/tempus-backend` (nach dessen Merge gegen `main`); `copilot-pr-review`.
