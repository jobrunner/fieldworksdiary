# tests/

Manuelle und Newman-fähige API-Smoke-Tests gegen das Backend.

## Voraussetzung

```bash
docker compose up --build
```

Backend läuft dann auf `http://localhost:8090`. Erster Start: kurz
warten, bis die Auto-Migrationen durch sind (`/api/health` antwortet
mit 200 — siehe erster Request in beiden Suiten).

## `api.http` — VSCode REST Client / IntelliJ HTTP Client

Direkt in der IDE öffnen, einzelne Requests mit dem „Send Request"-
Button feuern. Die `# @name xxx`-Anker erlauben es, IDs und
Excursion-Refs aus früheren Antworten in Folge-Requests einzusetzen
(`{{xxx.response.body.id}}`). Top-down ausführen.

Gut für: schnell mal was probieren, Edge-Cases im Code-Review prüfen.

## `Fieldworksdiary.postman_collection.json` — Postman v2.1

In Postman: **Import → File → Fieldworksdiary.postman_collection.json**.
Variablen:

- `baseUrl` (default `http://localhost:8090`) — zur Not auf
  `http://<lan-ip>:8090` umstellen, wenn von einem echten Gerät aus
  getestet wird.
- `s1_id`, `s1_excursion`, `lapalma_id` — werden über Test-Scripts
  zwischen den Requests verkettet, manuell nichts setzen.

Jeder Request hat **`pm.test()`-Assertions**: Code-Format `YYMMDD/N`,
gleiche/unterschiedliche Excursion-IDs, `admin_units.locality`,
`mtb.sheet_number`, `astro.moon_phase` im Bereich, `mtb.found=false`
außerhalb DE.

Headless ausführen mit Newman:

```bash
npm install -g newman
newman run tests/Fieldworksdiary.postman_collection.json \
  --env-var baseUrl=http://localhost:8090 \
  --delay-request 1500
```

Das `--delay-request` ist wichtig: Anreicherung läuft asynchron, ohne
Pause sind `admin_units` / `mtb` beim Get-Request noch leer. 1.5 s pro
Request reicht für Cache-Hits; auf einer kalten Datenbank lieber 3 s.

## Reset zwischen Läufen

Die Tests sind nicht idempotent (jeder POST erzeugt neue Records).
Für einen sauberen Lauf:

```bash
docker compose down
rm -rf backend/pb_data
docker compose up --build
```
