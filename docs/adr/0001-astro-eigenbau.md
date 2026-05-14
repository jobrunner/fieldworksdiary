# ADR 0001: Astro-Berechnung als Eigenbau, nicht via Library

**Datum:** 2026-05-10
**Status:** akzeptiert
**Kontext:** Phase 2b (`PROJECT_PLAN.md` §6.5)

## Entscheidung

Sonnen- und Mondzeiten sowie die Mond-Sichtbarkeit pro Excursion werden
in `internal/astro/` selbst implementiert (NOAA für Sonne, Meeus
simplifiziert für Mond) — keine Drittanbieter-Library.

## Begründung

**Pro Eigenbau:**

- **Pure Mathematik, klein.** ~250 Zeilen plus Tests reichen für
  unsere Genauigkeitsanforderungen (Sonne ±5min, Mondphase ±0.05,
  Altitude ±0.5°). Eine Library (`github.com/sj14/astral`,
  `github.com/sixdouglas/suncalc`) würde mehr Abhängigkeiten
  einschleppen, als sie spart.
- **Volle Kontrolle.** Wir können die Genauigkeit aufgabenscharf
  trimmen — z. B. Mond-Altitude alle 60 s scannen reicht für „Mond
  war anwesend?", muss nicht sub-Bogensekunden präzise sein.
- **Keine Lizenz-/Wartungsrisiken** an einem zentralen Datenpunkt.
- **Tests gegen externe Referenz** (timeanddate.com, Mondkalender)
  sind ohnehin Pflicht; wir würden eine Library-Wahl genauso
  validieren müssen.

**Akzeptierte Schwächen:**

- Topozentrische Mondparallaxe (~1°) wird ignoriert. Für
  „Mond hoch / niedrig"-Aussagen unkritisch; relevant nur bei
  Mondsichtbarkeit knapp am Horizont.
- Atmosphärische Refraktion wird nur über die Standard-Sonnen-Zenith
  von 90.833° abgebildet; präzise Refraktionskorrektur fehlt.
- Keine Berücksichtigung von Höhe über dem Meeresspiegel beim
  Sonnenhorizont. Vernachlässigbar bei < 1000 m.

## Alternativen

| Option | Bewertung |
|---|---|
| `github.com/sj14/astral` (Port von Python astral) | Vollständig, aber mehr Code als wir brauchen, und API-Drift bei Updates. |
| `github.com/sixdouglas/suncalc` (suncalc.js-Port) | Kleinere Lib, hat alles. Wartung unklar (letzter Commit?). |
| `github.com/janczer/goMoonPhase` | Nur Mondphase, kein Mondaufgang/-Altitude. |

## Konsequenzen

- Wenn wir später Sub-Minuten-Genauigkeit brauchen (z. B. für
  präzise Belichtungszeiten in Etiketten), wechseln wir auf eine
  Library oder eine Meeus-Vollimplementierung. Der API-Vertrag
  von `internal/astro/` bleibt stabil.
- `ScanMoonRiseSet` ist mit 1-min-Auflösung gestartet (1440
  Samples/Tag). Wenn Performance Thema wird, kann die Auflösung
  adaptiv werden (grobes Raster + Bisektion am Crossing).
