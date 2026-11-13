# Changelog

## [0.3.0](https://github.com/jobrunner/fieldworksdiary/compare/v0.2.0...v0.3.0) (2026-11-13)


### ⚠ BREAKING CHANGES

* **deps:** Fehler-JSON heißt jetzt {"status":…} statt {"code":…}, einige Standardmeldungen sind umformuliert. Die iOS-App liest beides nicht (nur message, data.<feld>, data.current_version).
* Entfernt werden placemarks.country, administrative_area, sub_administrative_area, locality, sub_locality, postal_code, name, thoroughfare; samples.mtb; fieldtrips.admin_units, mtb, country, admin_area; die Collection sample_sequences; iOS local_samples. admin_units_*, backend_code, altitude, local_fieldtrips.admin_units_json, mtb_json, country, admin_area, local_placemarks-Altspalten und die Tabelle local_sequences. Erst nach dem Backfill in Prod deployen.
* **backend:** Das Backend vergibt keine Sample-IDs mehr; Kollisionen pro User bekommen einen Suffix " (n)".
* **backend:** labelloc- und MTB-Dienst samt Env/Konstanten sind entfernt; ORTUS_BASE_URL ersetzt sie. Export-data.json hat neue Schlüssel placemarks und sample_features.
* **backend:** samples.altitude heißt jetzt elevation; geocoding_source-Wert backend-service heißt backend_service.

### Features

* **backend:** 0.22-Auth-Tokens nach dem Upgrade weiter akzeptieren ([5ef3dc7](https://github.com/jobrunner/fieldworksdiary/commit/5ef3dc791272c4b89b4ba097960d413f343be2a9))
* **backend:** Backfill der Ortsdaten über Ortus ([44370dd](https://github.com/jobrunner/fieldworksdiary/commit/44370dd0a3e2197b205c42f3a0de68b2610af8a0))
* **backend:** Bereinigungsentwurf der Landesbegriffe (77 Länder, ungeprüft) ([23f5528](https://github.com/jobrunner/fieldworksdiary/commit/23f5528b28b24808fc5a2758816005def05f76f7))
* **backend:** Endpoints zum Auflösen von Ortsdaten und Ersetzen von Features ([715de94](https://github.com/jobrunner/fieldworksdiary/commit/715de94f1eb6412f113f9966a7fa490cd80bd2bf))
* **backend:** Fieldtrip folgt dem Sammeltag nachgetragener Samples ([20acd4d](https://github.com/jobrunner/fieldworksdiary/commit/20acd4d8f7447fd607f969bbfd83b4dd9910dca2))
* **backend:** Label-Tabelle für Admin-Ebenen (Generator + Loader) ([e63767b](https://github.com/jobrunner/fieldworksdiary/commit/e63767b8776a575dc0eddacf051fd8efec2513da))
* **backend:** Migration für Zeitzone, Sammeltag, Höhe und ID-Einstellungen ([710e9bf](https://github.com/jobrunner/fieldworksdiary/commit/710e9bfd4184783ed9f119b7ac2012cb4233b5cb))
* **backend:** Ortus-Antwort auf flache Ortsspalten abbilden ([f1b65de](https://github.com/jobrunner/fieldworksdiary/commit/f1b65de01d1d3acc613b7a5c82a1cb6465d78fe2))
* **backend:** Ortus-Client mit Retry und Cache ([f27dc1d](https://github.com/jobrunner/fieldworksdiary/commit/f27dc1d86dae187c2bb1d8903eb1ec95dcbc2c9d))
* **backend:** Sample-ID wird nicht mehr vergeben oder umnummeriert ([dbd6366](https://github.com/jobrunner/fieldworksdiary/commit/dbd6366bd6f94d698ca64f426b8ce674105266f0))
* **backend:** Schema für Ortus-Ortsdaten, altitude → elevation ([5d15ba1](https://github.com/jobrunner/fieldworksdiary/commit/5d15ba1a6a9856ac5f49680991dce66e62908542))
* **backend:** TK25-Quadrant aus Koordinate berechnen ([e3dc405](https://github.com/jobrunner/fieldworksdiary/commit/e3dc405aacc2dee53aaa4f074977f6699a0da0ee))
* **backend:** Zeitzone aus Ortus, nur noch eine Höhe am Sample ([b89f283](https://github.com/jobrunner/fieldworksdiary/commit/b89f28345b93b1c6b3b7a310ed0b26d638543d3f))
* **enrichment:** Samples über Ortus anreichern ([14f0527](https://github.com/jobrunner/fieldworksdiary/commit/14f0527fc0288b02bf555fa5f5660452e460a1a3))
* **geo:** GEOTRANS für Koordinatenformate und Umrechnung ([d9a2e51](https://github.com/jobrunner/fieldworksdiary/commit/d9a2e5114ff50290bb4d33dbdfe5fe1ecabd0cb1))
* **ios:** Anlegen mit Viertelstunden-Fenster, Ortszeit-Sammeltag und ID-Vorschlag ([fc5e98f](https://github.com/jobrunner/fieldworksdiary/commit/fc5e98fcf1e2600c6b505d1812ef5943fa9918d3))
* **ios:** Bearbeiten-Formular mit Gruppen Koordinate, Zeit, Ortsdaten ([625debf](https://github.com/jobrunner/fieldworksdiary/commit/625debf7af97978ad3afedce5a38e2d21b65eccc))
* **ios:** eine Höhe mit optionalem Fehler, Hinweis bei doppelter ID ([daaaefe](https://github.com/jobrunner/fieldworksdiary/commit/daaaefe264e8081f6740f506a5c9d656cfca661c))
* **ios:** Einstellungen für Sample-ID-Format und Tagesrollover ([0d7f342](https://github.com/jobrunner/fieldworksdiary/commit/0d7f342638863ce01c37c156f8d6b7ad60077670))
* **ios:** Exposition und Hangneigung in einer Zeile, MTB davor ([7ca27d5](https://github.com/jobrunner/fieldworksdiary/commit/7ca27d500c90b009ea71c5d94e4549494be93b98))
* **ios:** Feature-Flags über Flipt ([52eb51c](https://github.com/jobrunner/fieldworksdiary/commit/52eb51cdbb9179658e364b728b874be2e5eb02a2))
* **ios:** FieldworksGeo-Package mit Label-Tabelle und TK25 ([0c81a96](https://github.com/jobrunner/fieldworksdiary/commit/0c81a965f16bc6e4c8d03e87d888b64d357210e4))
* **ios:** lokale Persistenz für Ortsdaten und Features ([8316319](https://github.com/jobrunner/fieldworksdiary/commit/8316319952723289dbcd7e6583d31edefce17e16))
* **ios:** nachgetragene Samples und Koordinatenformat-Einstellung ([73fd157](https://github.com/jobrunner/fieldworksdiary/commit/73fd1573094d5d133e7959cb3b844ea92d51b33c))
* **ios:** Ortsdaten beim Anlegen sofort über Ortus ([9efc5ff](https://github.com/jobrunner/fieldworksdiary/commit/9efc5ff6356213db5ea20b84e5186b9d3de10770))
* **ios:** Ortsfelder mit Landesbegriffen anzeigen, bearbeiten und filtern ([5964f82](https://github.com/jobrunner/fieldworksdiary/commit/5964f82d5b0f79c887a88bde223a3da5f070dd0e))
* **ios:** Ortszeit-Anzeige, Zeitfenster und Zeitzonenwahl im Sample ([39286ae](https://github.com/jobrunner/fieldworksdiary/commit/39286ae201bf07c996af3fb9c60dd2d9eceed2dd))
* **ios:** Ortus-Anfrage mit Koordinatensystem ([af264b5](https://github.com/jobrunner/fieldworksdiary/commit/af264b5d7fd105b8703718a32c9358f684ce0fbd))
* **ios:** Ortus-Mapping und Feld-Labels im FieldworksGeo-Package ([657af0c](https://github.com/jobrunner/fieldworksdiary/commit/657af0c126f86e054cf9539865146e790b9f4171))
* **ios:** Probe nachtragen als eigener Home-Eintrag ([2d04ae3](https://github.com/jobrunner/fieldworksdiary/commit/2d04ae3509760cd92cd20dadc9df47ba23f684ba))
* **ios:** Probe nachtragen mit Koordinate oder aus Foto ([b71b5c5](https://github.com/jobrunner/fieldworksdiary/commit/b71b5c5ff1369873fd9dcf820d45ee66a69936df))
* **ios:** Sample sofort anlegen, Editor speichert beim Zurück ([485878f](https://github.com/jobrunner/fieldworksdiary/commit/485878fd9db687a193ae4a90eca88828160f59f9))
* **ios:** Sample-Ansicht aufgeräumt - Koordinatensystem, Peilung, Ränder ([5f9b92e](https://github.com/jobrunner/fieldworksdiary/commit/5f9b92eb3b21aba4a24ca24f8b48348d1d025d02))
* **ios:** Sample-Ansicht zeigt Ortsdaten kompakt, Bearbeiten über Formular ([8d08ae0](https://github.com/jobrunner/fieldworksdiary/commit/8d08ae090b3a24cf1563493a2c0b8e92d5695cc0))
* **ios:** Zeit- und ID-Logik im Package FieldworksGeo ([80f77a7](https://github.com/jobrunner/fieldworksdiary/commit/80f77a7b264f4a50e5ea74c88dbfd5090398f506))
* **ios:** Zeitzone aus Ortus übernehmen ([310de05](https://github.com/jobrunner/fieldworksdiary/commit/310de0564b8cb3a5bbf7155ec52d08a031b875ac))
* **ios:** Zeitzone und eine Höhe in Persistenz und Sync ([d50cae2](https://github.com/jobrunner/fieldworksdiary/commit/d50cae2ffbdef886be0a09be9c943afe5dc1adb2))
* **location:** Hintergrund-Ortung bis zum Fix je Sample ([149bee9](https://github.com/jobrunner/fieldworksdiary/commit/149bee95d6562506ae6759e4c3925d8784d3bfd4))
* Ortus-Ortsdaten, Zeitzone/ID/Höhe, Sofort-Anlage, Probe nachtragen (Phasen O2, Z, O3, E, N) ([bd3ef6f](https://github.com/jobrunner/fieldworksdiary/commit/bd3ef6f1349e04ade8efe91355cd8f1c6b164b8b))
* **sync:** Ortsdaten und Features synchronisieren ([d8f0eae](https://github.com/jobrunner/fieldworksdiary/commit/d8f0eae2557367b5b7dd147330c8a42ac7cf5aef))
* **sync:** Ortsvorschlag übernehmen/verwerfen und erneut senden ([7482ec6](https://github.com/jobrunner/fieldworksdiary/commit/7482ec65ebdd36532589e2c6fe2ef12f7ee7b479))
* **sync:** Samples lokal und auf dem Server löschen ([691a9d6](https://github.com/jobrunner/fieldworksdiary/commit/691a9d6deca9bfa0bab1eb57307384c0c4591f98))


### Bug Fixes

* **backend:** adminlabels-gen überschreibt die kuratierte Tabelle nur mit -force ([dd57da9](https://github.com/jobrunner/fieldworksdiary/commit/dd57da91e88277d40aa3524c1b305d7250c2d189))
* **backend:** Backfill idempotent, Besitzer-Klone, Remap-Zählung ([0d1fe76](https://github.com/jobrunner/fieldworksdiary/commit/0d1fe76da37aa14a8126da70b480b146e3a586f0))
* **backend:** Backfill setzt Ortus-Zeitzone auch für bereits angereicherte Proben ([4493b4c](https://github.com/jobrunner/fieldworksdiary/commit/4493b4c945e81fe79c8305089458e37957d1f47d))
* **backend:** bestehende golangci-lint-Funde beheben ([b06af7a](https://github.com/jobrunner/fieldworksdiary/commit/b06af7aeaf1fec845fd5b1ac39ed4084e904379b))
* **backend:** Dedup-Hash härten, mtb_quadrant als Zahl, Eingaben validieren ([6066de2](https://github.com/jobrunner/fieldworksdiary/commit/6066de2755830a328a15799f292c07b855604d04))
* **backend:** Export liefert nur sichtbare Placemarks ([445d8d3](https://github.com/jobrunner/fieldworksdiary/commit/445d8d381007e7095346ae76cc6ead569a202bd9))
* **backend:** Legacy-Placemarks in Migration 27 mappen, Localities nachanreichern ([cd6601b](https://github.com/jobrunner/fieldworksdiary/commit/cd6601b840850f4deb0c9cc70e7c3997133fea12))
* **backend:** Ortsstatus bei Koordinatenänderung und Client-Höhe korrekt führen ([2b75aa4](https://github.com/jobrunner/fieldworksdiary/commit/2b75aa46a72ea5ec18e8a63a4ae14039c2c94250))
* **backend:** Placemark-Referenzen und -Sichtbarkeit auf shared/eigene Zeilen begrenzen ([41f6d5f](https://github.com/jobrunner/fieldworksdiary/commit/41f6d5fab5e046a86bb1ccfcf1c347477e817deb))
* **backend:** Zeitzone nicht von device über location_service/manual überschreiben ([04b7383](https://github.com/jobrunner/fieldworksdiary/commit/04b7383d4ca297d35972f2ee97094bbf98d112fb))
* **enrichment:** Version erhöhen, Schreiben in Transaktion, DEM-Höhe auffrischen ([e9e2d33](https://github.com/jobrunner/fieldworksdiary/commit/e9e2d3396633f59007e15a3494f8392a1b50548f))
* ganztägige Samples bleiben bei Zonenwechsel auf 00:00 ([342b1c6](https://github.com/jobrunner/fieldworksdiary/commit/342b1c68ef122a6d09f4b073c63fb4f2d1153c4e))
* **geoplace:** MTB-Blattnummer aus den Feature-Properties lesen ([1b221d8](https://github.com/jobrunner/fieldworksdiary/commit/1b221d8efea93e6f1e7ef1778db42235ada9ebe5))
* **ios:** ausstehenden Einstellungs-Push vor dem Gleichheitscheck abbrechen ([bf9edf6](https://github.com/jobrunner/fieldworksdiary/commit/bf9edf6467673cc83b849f7de68d4f3caf1ad128))
* **ios:** Bearbeiten-Formular — Ganztägig-Tag, Genauigkeit löschen, MGRS-Vorbelegung ([4131ccb](https://github.com/jobrunner/fieldworksdiary/commit/4131ccb31e5bf3579df870752ac8190404caa6f5))
* **ios:** DST-sicheres Abrunden, kein Force-Unwrap im ID-Template ([adfed36](https://github.com/jobrunner/fieldworksdiary/commit/adfed366ebb93cccfb003e123fca2b6b6f4e2fd7))
* **ios:** Feature-Flags mit Retry und Timeout ([9761fb8](https://github.com/jobrunner/fieldworksdiary/commit/9761fb89ead3cc3f86400d01a1b9530aed3d84ba))
* **ios:** Formular-Abfrage überlebt Scrollen, Karte auch ohne Koordinate ([b915467](https://github.com/jobrunner/fieldworksdiary/commit/b915467683be277130d41a443464749e40165373))
* **ios:** Fundort eines gelöschten neuen Samples mitlöschen ([e6fa95f](https://github.com/jobrunner/fieldworksdiary/commit/e6fa95f933601eaf0a7d9308e332fd6d134dc7da))
* **ios:** Fundort-Ortsangaben mit flachem Ortsbody überschreiben ([fc11dcc](https://github.com/jobrunner/fieldworksdiary/commit/fc11dccc962800879eae36571e6e03b8edd7b7d0))
* **ios:** Fundort-Ortsangaben über backend_id auflösen ([997eeec](https://github.com/jobrunner/fieldworksdiary/commit/997eeece53087315b51c0f7870a6a11d1d018f84))
* **ios:** Fusion und Ortsangaben auch bei spätem Fix, Doppeltipp-Schutz ([23adc6d](https://github.com/jobrunner/fieldworksdiary/commit/23adc6d940f558ef80e8b37c05b6405b9554ca39))
* **ios:** Hintergrund-Fix mit derselben Schwelle wie der Editor ([6b3df9e](https://github.com/jobrunner/fieldworksdiary/commit/6b3df9e15feb84b0a7900e2d9f35038241df17a8))
* **ios:** Hintergrund-Fix nur für auf diesem Gerät angelegte Samples ([35f1e28](https://github.com/jobrunner/fieldworksdiary/commit/35f1e28deb566470df571e6345ff778fa878ebcc))
* **ios:** Kartenwahl für neues Sample fusioniert auch offline ([29e374f](https://github.com/jobrunner/fieldworksdiary/commit/29e374f53d4ef2da2b21951cc5d20ac385296bf7))
* **ios:** Koordinate von local_samples nullable (Migration v16) ([80bcd45](https://github.com/jobrunner/fieldworksdiary/commit/80bcd459467ad5e38daaaaa790c43c093d76458a))
* **ios:** nachgetragenes Sample ohne Koordinate sucht keine Position ([8e27cad](https://github.com/jobrunner/fieldworksdiary/commit/8e27cadc797a90e5d527ffa412fc769ecfc603c8))
* **ios:** Nachtragen-Review — EXIF-Präzision, Import-Race, Scrim-Token ([61965d3](https://github.com/jobrunner/fieldworksdiary/commit/61965d3a6a8b8d08519cc13f06fce0567050eb95))
* **ios:** Ortseditor ändert nur Bearbeitetes, Dialog nach Kartenschließen ([8e76e0a](https://github.com/jobrunner/fieldworksdiary/commit/8e76e0a433aa5f0248fca2b9c1c83aba4fda3479))
* **ios:** Ortszeile der Exkursionen aus den Proben abgeleitet ([7a2cd79](https://github.com/jobrunner/fieldworksdiary/commit/7a2cd7941420e26213b5a0c8e4fbe49ba1862e11))
* **ios:** Ortszeile der Exkursionen folgt Proben, Zeile skaliert bis AX5 ([00ce570](https://github.com/jobrunner/fieldworksdiary/commit/00ce570a70964f3c27b100546325d6115ced776b))
* **ios:** Ortus-Hierarchieeintrag ohne level bricht Dekodierung nicht ab ([c85fa72](https://github.com/jobrunner/fieldworksdiary/commit/c85fa72e138d8fdd918f1eb26a87432ec87742a4))
* **ios:** PATCH-Antwort der Einstellungen nicht mehr in AppConfig zurückspielen ([ee2bacb](https://github.com/jobrunner/fieldworksdiary/commit/ee2bacb3bbb3044c63394fa3f57c8c3ef739866f))
* **ios:** Phase-Z-Review – Zone zur Nutzungszeit, Server-Zone beim 409, Offset tippbar ([80d08c4](https://github.com/jobrunner/fieldworksdiary/commit/80d08c4598b9b6a7009847549bc41121aa47739a))
* **ios:** Retry-Test zählt alle Build-Versuche ([e67e9f7](https://github.com/jobrunner/fieldworksdiary/commit/e67e9f74a37ac29fecb53ed7464169d7ad9b015b))
* **ios:** Sammeltag nachgetragener Samples nur bei Zeitänderung neu ([9d81443](https://github.com/jobrunner/fieldworksdiary/commit/9d81443d7343b4e475b5e8489defdea5422762bc))
* **ios:** v13 setzt backend_id für bestehende Ortszeilen ([2467864](https://github.com/jobrunner/fieldworksdiary/commit/246786479e0bf9dea68008b6c17fdf054d8f7c47))
* **ios:** Wisch-Geste zurück im Sample-Editor abschalten ([a83cdc6](https://github.com/jobrunner/fieldworksdiary/commit/a83cdc64937953717025071fdbbe5cb6d9350998))
* **ios:** Zeitfelder beim Sichern nur bei Änderung übernehmen ([54654ea](https://github.com/jobrunner/fieldworksdiary/commit/54654eacf857f4fecf3f41247895e3cac24457b9))
* **services:** keine Koordinaten in Fehlern, Status-Code loggen, Cache-Fehler tolerieren ([35b36a4](https://github.com/jobrunner/fieldworksdiary/commit/35b36a4a59423aa6b1861e115095deefd3f48c34))
* **sync:** 409 nach Anreicherung auflösen, Ortsdaten nicht zurücksetzen ([b01df60](https://github.com/jobrunner/fieldworksdiary/commit/b01df604662dc37461a09469ca2530025c842067))
* **sync:** Fieldtrip aus der PATCH-Antwort übernehmen ([6e21cd5](https://github.com/jobrunner/fieldworksdiary/commit/6e21cd58f25f1c040e3eda36c4c709c59fc04790))
* **sync:** Ortsedits während Push behalten, 409-Abbruch parken ([16fdb53](https://github.com/jobrunner/fieldworksdiary/commit/16fdb53982e751e597a5b4253b48cad988c08d12))
* **sync:** Sample-Löschung atomar, 404 beim Update und Create-Race abgedeckt ([47dc8ab](https://github.com/jobrunner/fieldworksdiary/commit/47dc8abd7013b5bcf128c249f1d53cc7b703cfe3))
* **sync:** Samples vollständig und inkrementell hydrieren statt 200er-Limit ([6930030](https://github.com/jobrunner/fieldworksdiary/commit/693003056ab965c33c7940959ba18c205f7db630))
* **sync:** Samples-Hydration per Keyset-Paging, Cursor nicht über fehlgeschlagene Ortsdaten ([4352fd7](https://github.com/jobrunner/fieldworksdiary/commit/4352fd7d1195a7214b773894d34bf5b40dfd860b))
* **sync:** Server-Feldfehler ohne „Placemark“ anzeigen ([d6c045f](https://github.com/jobrunner/fieldworksdiary/commit/d6c045feb9bb5a84491bbe7eaf53f9a309c3be4f))
* **theme:** Markenfarbe in Fläche und Vordergrund aufteilen ([456faf3](https://github.com/jobrunner/fieldworksdiary/commit/456faf3cedf1f1784b4773d46dc5c2f9514d2eb7))


### Performance Improvements

* **sync:** Enrichment-Poll gebündelt nach der Push-Schleife ([aa6a272](https://github.com/jobrunner/fieldworksdiary/commit/aa6a2723248ff6695e184ed89f10187b54670128))


### Code Refactoring

* alte Ortsspalten entfernt ([5cad22b](https://github.com/jobrunner/fieldworksdiary/commit/5cad22bce75e2463608dd178b969f4eee007c020))
* **backend:** labelloc und MTB-Dienst durch Ortus ersetzt ([dd2faba](https://github.com/jobrunner/fieldworksdiary/commit/dd2faba6f3f380f23c50c31a96d39f362d5f8fd9))


### Build System

* **deps:** PocketBase 0.22.42 -&gt; 0.40.6 (Go 1.27.4) ([e73ae0b](https://github.com/jobrunner/fieldworksdiary/commit/e73ae0b7434c2504f7958ffaf02b03d36903db1e))

## [0.2.0](https://github.com/jobrunner/fieldworksdiary-ng/compare/v0.1.0...v0.2.0) (2026-08-28)


### Features

* versioning + changelog via release-please (wie ortus/tempus/hostus) ([#50](https://github.com/jobrunner/fieldworksdiary-ng/issues/50)) ([5a508c6](https://github.com/jobrunner/fieldworksdiary-ng/commit/5a508c6b6a8d0960c1704461ebd63ef234b30386))
