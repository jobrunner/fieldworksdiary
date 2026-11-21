# Changelog

## [0.5.0](https://github.com/jobrunner/legulus/compare/v0.4.1...v0.5.0) (2026-11-21)


### Features

* **ios:** Foto-Import beim Nachtragen behält Auflösung und Metadaten ([3ec71bb](https://github.com/jobrunner/legulus/commit/3ec71bb9b9859d17ca1faf77eab57fad407029c7))
* **ios:** Fotodateien unverändert speichern, Vorschau und GPS-Metadaten ([e9b63b5](https://github.com/jobrunner/legulus/commit/e9b63b58ec88440f4d2e46b56130b8f1a4892074))
* **ios:** Fotos sofort speichern, Kamera einbinden, Löschen im Foto-Strip ([cc662c3](https://github.com/jobrunner/legulus/commit/cc662c33646464089abad2a5da168cf8ac59a587))
* **ios:** Fotos unabhängig von der Probe hochladen, WLAN-Einstellung, Löschen im Sync ([fa156d0](https://github.com/jobrunner/legulus/commit/fa156d0f0629815aa2ec163f80862677f7fa6e2e))
* **ios:** Kalender-Icon und Umbruch nach dem Wochentag in der Datumszeile ([5bf76fb](https://github.com/jobrunner/legulus/commit/5bf76fbe9a8f19ee32877a07a25c2157501195f4))
* **ios:** Kalender-Icon und Umbruch nach dem Wochentag in der Datumszeile ([a7c9194](https://github.com/jobrunner/legulus/commit/a7c9194a7f0f77d48918ce8a1f1f3f54aeafb409))
* **ios:** kleinere Schrift für die Sample-Nummer ([13d8d4e](https://github.com/jobrunner/legulus/commit/13d8d4e88069dcc30e5338146a745112e02dd6af))
* **ios:** kleinere Schrift für die Sample-Nummer ([02b28a8](https://github.com/jobrunner/legulus/commit/02b28a8ed858802f884c21ad39971f51ce34fee0))
* **ios:** Koordinate und Höhe per Tap kopieren ([eac42f3](https://github.com/jobrunner/legulus/commit/eac42f3105eb49cad1933c4d0baf4e10f00c9960))
* **ios:** Koordinate und Höhe per Tap kopieren ([b97cd61](https://github.com/jobrunner/legulus/commit/b97cd61af68f91c1ddea14715d4caf2b58c17062))
* **ios:** Serienkamera für Belegfotos ([086a30c](https://github.com/jobrunner/legulus/commit/086a30c53ef6cc928a77ed577fb64a170f6d3c77))
* **ios:** Serienkamera, Fotos im Original, Löschen und WLAN-Einstellung ([fe5b7de](https://github.com/jobrunner/legulus/commit/fe5b7de9626690d3b1f524fea19074bc10256dd5))
* **ios:** Stift-Icon statt Bearbeiten-Menü in der Sample-Ansicht ([bc50137](https://github.com/jobrunner/legulus/commit/bc5013706b46ead8fba4f44bc3636806532856ed))
* **ios:** Stift-Icon statt Bearbeiten-Menü in der Sample-Ansicht ([05fe90f](https://github.com/jobrunner/legulus/commit/05fe90fceae2bfe3a71c106942b93fb63ff2f1c2))
* **ios:** Zwischenablage-Texte für Koordinate und Höhe ([f042832](https://github.com/jobrunner/legulus/commit/f042832c5797fa2beb2c383d97388a4cba96c986))
* **tabularius:** 50-MB-Limit und idempotenter Upload für Sample-Fotos ([bafa75f](https://github.com/jobrunner/legulus/commit/bafa75f1bc42aa78980179d970164fbf92dd9fb2))
* **tabularius:** Abfragezeitpunkt für Tempus berechnen ([478bf8c](https://github.com/jobrunner/legulus/commit/478bf8cefaf7fa82a874135e4da5af566e9f1241))
* **tabularius:** Backfill bestehender Proben über Tempus ([78dbb10](https://github.com/jobrunner/legulus/commit/78dbb10f458c836687dc38a4044f20ee82006e0d))
* **tabularius:** Backfill bestehender Proben über Tempus ([9a88fa7](https://github.com/jobrunner/legulus/commit/9a88fa7b2b8c6e5b0fe95d583834b49899fa07da))
* **tabularius:** Felder für Wetter, Klima und Astronomie am Sample ([49d7e20](https://github.com/jobrunner/legulus/commit/49d7e2020173073d2cadcbcd70c353dc96416836))
* **tabularius:** Samples über Tempus anreichern ([5ec80a0](https://github.com/jobrunner/legulus/commit/5ec80a0adc9d984a2b9eadfa7de341242329e021))
* **tabularius:** Tempus-Anreicherung verdrahten und konfigurieren ([d325bf2](https://github.com/jobrunner/legulus/commit/d325bf2b263679e819f3bc23b6a17135ea17fd82))
* **tabularius:** Tempus-Antwort auf Sample-Felder abbilden ([12e38ab](https://github.com/jobrunner/legulus/commit/12e38abe80d15cd13ada420e2efdb9822bd2f382))
* **tabularius:** Tempus-Wrapper mit Retry und Cache ([754b95a](https://github.com/jobrunner/legulus/commit/754b95aa4a4b845aacd46599337dc2ec188923a7))
* **tabularius:** Wetter, Klima und Astronomie über Tempus anreichern ([33865c0](https://github.com/jobrunner/legulus/commit/33865c037b73fbe4e4a4007d96dc8ddd86d2f792))
* **tabularius:** Wetterwerte ganztägiger Proben bei Nachtexkursion neu abfragen ([931c871](https://github.com/jobrunner/legulus/commit/931c8716d544208b021a41a4076f80c503507a70))


### Bug Fixes

* Befunde aus dem Review der Serienkamera beheben ([8150288](https://github.com/jobrunner/legulus/commit/815028865135cacc5cd6297b68dcade908b93ed3))
* **build:** Tunnel-Ziel bricht auch bei HTTP-Fehlern des Backends ab ([711ae72](https://github.com/jobrunner/legulus/commit/711ae72e9d90fe82b316c6a7b6ed297239911d2e))
* **ios:** beendeter Sync-Runner schreibt nach einer späten Antwort nichts mehr ([5a11e37](https://github.com/jobrunner/legulus/commit/5a11e37fa791db2b6f9919f883a8e2dbb44f9514))
* **ios:** Befunde aus dem Review der Kontotrennung beheben ([18c5915](https://github.com/jobrunner/legulus/commit/18c59151cf537b7804579dd8146643303f6812ff))
* **ios:** Foto-Sync gegen Kontowechsel und verspätete Uploads absichern ([1408d12](https://github.com/jobrunner/legulus/commit/1408d121a591b1493c82d71a9db98aa35cfc1972))
* **ios:** Foto-Wandlung nacheinander, kein zweiter Versuch im Main-Actor, primäres HEIC-Bild ([8273fd7](https://github.com/jobrunner/legulus/commit/8273fd72cc20167194ec7c7dfafb2a006881e517))
* **ios:** Kopier-Button ohne eigenen Accessibility-Container ([4da124c](https://github.com/jobrunner/legulus/commit/4da124c671581e05502dac9ace9024724e70befb))
* **ios:** Kopier-Hinweis und Höhen-Rundung nach Review korrigieren ([5ec44ec](https://github.com/jobrunner/legulus/commit/5ec44ece665ea11c69a173207fdf9d67765c04f9))
* **ios:** lokale Daten pro Konto statt einer Datenbank für alle ([48503b0](https://github.com/jobrunner/legulus/commit/48503b0ba2c682ab32ed37849c8bd8712a0c2cf4))
* **ios:** lokale Daten pro Konto statt einer Datenbank für alle ([871f785](https://github.com/jobrunner/legulus/commit/871f7857fb864c2d039e7d67818379eaee7b2209))
* **ios:** weitere Befunde aus dem Review der Kontotrennung beheben ([bb1bab7](https://github.com/jobrunner/legulus/commit/bb1bab7c37ff0e7495c505ad09721054ba5c106d))
* **tabularius:** auch eine UUID nur aus Leerraum gilt als Schlüssel ([51d3d9d](https://github.com/jobrunner/legulus/commit/51d3d9dea0f818ce56f29320b9f8c080d3db9690))
* **tabularius:** Backfill zählt nur echte Tempus-Abfragen ([d3e79a0](https://github.com/jobrunner/legulus/commit/d3e79a02c3693ef829727030746b35a4dea1d287))
* **tabularius:** Befunde aus dem Review der Tempus-Anreicherung beheben ([f847b94](https://github.com/jobrunner/legulus/commit/f847b946972da1b2918b6c10ac2da65aa3a1f888))
* **tabularius:** Befunde aus dem Review des Tempus-Backfills beheben ([b730b47](https://github.com/jobrunner/legulus/commit/b730b47177227bdfed06f3adb16d242f7d8bd20d))
* **tabularius:** entfernte Koordinate wartet nicht auf einen Ortus-Lauf ([bb18bfc](https://github.com/jobrunner/legulus/commit/bb18bfc390357248ee7c8135e12a1f5a62316c25))
* **tabularius:** gelöschte Probe beim Zurücksetzen nach Nachtflag-Wechsel überspringen ([354a539](https://github.com/jobrunner/legulus/commit/354a53903950ad3e578d6fb2c6146e8424d1efed))
* **tabularius:** Proben ohne nutzbare Höhe blockieren nichts, alte DEM-Höhe wartet auf Ortus ([dbb3261](https://github.com/jobrunner/legulus/commit/dbb3261784396b3e9a966c76268dc6416a432371))
* **tabularius:** Tempus mit der Höhe der Probe abfragen ([56b80ef](https://github.com/jobrunner/legulus/commit/56b80ef6ba19607970f0ebb07cfa6db2b288e25a))
* **tabularius:** überlappende Anlage gruppiert nicht doppelt, PATCH auf Alt-Dublette bleibt möglich ([3d5a810](https://github.com/jobrunner/legulus/commit/3d5a810d20db9cdddbd528cbe087073d4b647b66))
* **tabularius:** UUID wie gespeichert vergleichen, Replay-Antwort wie eine normale Anlage aufbereiten ([e5df35c](https://github.com/jobrunner/legulus/commit/e5df35c6414fefc4d11ec85adf05de09899407ea))
* **tabularius:** Wettlauf-Fälle der Tempus-Anreicherung schließen ([2fd2580](https://github.com/jobrunner/legulus/commit/2fd2580fdefb65e0cb805f5acf9a297b679e7d31))
* **tabularius:** wiederholte Proben-Anlage legt keine zweite Probe an ([419c951](https://github.com/jobrunner/legulus/commit/419c9511b10cce496f2c2316f1f1158eb39a4f4d))
* **tabularius:** wiederholte Proben-Anlage legt keine zweite Probe an ([017eafa](https://github.com/jobrunner/legulus/commit/017eafa95e60f8e652cf95330088cb5547e113a8))


### Performance Improvements

* **ios:** Foto beim Import außerhalb des Main-Actors nach JPEG wandeln ([6c6e271](https://github.com/jobrunner/legulus/commit/6c6e271f5d52590af5e8b989a12f03d118451938))

## [0.4.1](https://github.com/jobrunner/legulus/compare/v0.4.0...v0.4.1) (2026-11-17)


### Documentation

* Changelog 0.4.0 zur Datenbank-Übernahme korrigieren ([3e3c55b](https://github.com/jobrunner/legulus/commit/3e3c55bb8d2564a5ac235f1b060ea8d0e499461a))

## [0.4.0](https://github.com/jobrunner/fieldworksdiary/compare/v0.3.1...v0.4.0) (2026-11-16)


### ⚠ BREAKING CHANGES

* **ios:** Die lokale Datenbank heißt legulus.sqlite. Die alte Datei fieldworksdiary.sqlite wird beim ersten Start übernommen (15ca93c), bestehende Installationen behalten ihre Daten. Die Sync-Cursor haben neue Keys, deshalb gleicht die App nach dem Update einmalig vollständig mit dem Server ab.
* **tabularius:** Das Image liegt jetzt unter ghcr.io/jobrunner/tabularius, die Version kommt aus TABULARIUS_VERSION (vorher FWD_VERSION), Staging nutzt TABULARIUS_IMAGE. Compose-Service und Container heißen tabularius bzw. tabularius-{dev,test,staging,prod}, die Projekte legulus, legulus-staging und legulus-prod. Auf dem Server vor dem Update die alten Container stoppen und .env sowie deploy.sh anpassen. Lokal wandert pb_data nach tabularius/pb_data.

### Bug Fixes

* **ci:** ghcr-tag liest neuen Tag nach dem PUT mehrfach nach ([7302614](https://github.com/jobrunner/fieldworksdiary/commit/7302614e0fe2a0b932cc77092d2fe32b5a77bd78))
* **ios:** alte Datenbankdatei beim ersten Start übernehmen ([15ca93c](https://github.com/jobrunner/fieldworksdiary/commit/15ca93c7d56c0815db027f4dbb56c54f7fdbce36))


### Code Refactoring

* **ios:** Projekt, Targets und Package heißen Legulus ([45beb25](https://github.com/jobrunner/fieldworksdiary/commit/45beb252a533d41c0f16d4e64e9a5e93908f5a28))


### Build System

* **tabularius:** Backend heißt tabularius, Image ghcr.io/jobrunner/tabularius ([d86b951](https://github.com/jobrunner/fieldworksdiary/commit/d86b9517cf9520b80d9965e52b079e291edcfbf6))

## [0.3.1](https://github.com/jobrunner/fieldworksdiary/compare/v0.3.0...v0.3.1) (2026-11-16)


### Bug Fixes

* **backend:** Test-Instanz nur auf Loopback veröffentlichen ([59f5226](https://github.com/jobrunner/fieldworksdiary/commit/59f5226d70a50f98eca2da8124919b291151b86f))
* **ios:** Sample-Ansicht bei Anzeigezoom nicht mehr nach links verschoben ([0309186](https://github.com/jobrunner/fieldworksdiary/commit/03091867456e747e5b4f9766b873b5a2249b02d2))
* **ios:** Sample-Ansicht bei Anzeigezoom nicht mehr nach links verschoben ([38da18a](https://github.com/jobrunner/fieldworksdiary/commit/38da18adc06f8e5195f6aa8431f29df4d7fdbdc8))
* **ios:** Test-Instanz an allen Test-Einstiegen einheitlich vorbereiten ([1912efd](https://github.com/jobrunner/fieldworksdiary/commit/1912efdad28a8a3349cb09146d52a26946a9c220))

## [0.3.0](https://github.com/jobrunner/fieldworksdiary/compare/v0.2.0...v0.3.0) (2026-11-16)


### ⚠ BREAKING CHANGES

* **backend:** Tokens für org.fieldworksdiary.* werden ohne APPLE_ALLOWED_AUDIENCES-Override nicht mehr akzeptiert.
* **ios:** Bundle-IDs wechseln von org.fieldworksdiary.* auf app.legulus.*. Bestehende Installationen werden nicht aktualisiert, sondern stehen als eigene App daneben; Keychain-Service und Log-Subsystem heißen app.legulus.*.

### Features

* **backend:** Apple-Audiences und Ortus-Default auf legulus.app ([957aad9](https://github.com/jobrunner/fieldworksdiary/commit/957aad932103d652b16ae712f258001d08825275))
* **ios:** Rebranding auf Legulus mit eigenen Icons und Endpoints pro Stage ([1353367](https://github.com/jobrunner/fieldworksdiary/commit/135336767c33bb9ec3d9eefa92a209087f26ba5b))


### Bug Fixes

* **build:** commit-msg-Hook nutzt gebautes commitlint auch ohne Nix im PATH ([1c5148d](https://github.com/jobrunner/fieldworksdiary/commit/1c5148d70724b75d0ee667f66c9afe4a1500a69e))

## [0.2.0](https://github.com/jobrunner/fieldworksdiary/compare/v0.1.0...v0.2.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* Versionsnummern beginnen wieder bei 0.1.0, die Image-Tags 0.2.0 und 0.3.0 entfallen.
* **deps:** Fehler-JSON heißt jetzt {"status":…} statt {"code":…}, einige Standardmeldungen sind umformuliert. Die iOS-App liest beides nicht (nur message, data.<feld>, data.current_version).
* Entfernt werden placemarks.country, administrative_area, sub_administrative_area, locality, sub_locality, postal_code, name, thoroughfare; samples.mtb; fieldtrips.admin_units, mtb, country, admin_area; die Collection sample_sequences; iOS local_samples. admin_units_*, backend_code, altitude, local_fieldtrips.admin_units_json, mtb_json, country, admin_area, local_placemarks-Altspalten und die Tabelle local_sequences. Erst nach dem Backfill in Prod deployen.
* **backend:** Das Backend vergibt keine Sample-IDs mehr; Kollisionen pro User bekommen einen Suffix " (n)".
* **backend:** labelloc- und MTB-Dienst samt Env/Konstanten sind entfernt; ORTUS_BASE_URL ersetzt sie. Export-data.json hat neue Schlüssel placemarks und sample_features.
* **backend:** samples.altitude heißt jetzt elevation; geocoding_source-Wert backend-service heißt backend_service.

### Features

* **auth:** native Sign in with Apple via identityToken verify (Option B) ([#19](https://github.com/jobrunner/fieldworksdiary/issues/19)) ([be3eec5](https://github.com/jobrunner/fieldworksdiary/commit/be3eec5cd49be8308ce6456eacce4c2b2453ecd1))
* **backend:** 0.22-Auth-Tokens nach dem Upgrade weiter akzeptieren ([5ef3dc7](https://github.com/jobrunner/fieldworksdiary/commit/5ef3dc791272c4b89b4ba097960d413f343be2a9))
* **backend:** Backfill der Ortsdaten über Ortus ([44370dd](https://github.com/jobrunner/fieldworksdiary/commit/44370dd0a3e2197b205c42f3a0de68b2610af8a0))
* **backend:** Bereinigungsentwurf der Landesbegriffe (77 Länder, ungeprüft) ([23f5528](https://github.com/jobrunner/fieldworksdiary/commit/23f5528b28b24808fc5a2758816005def05f76f7))
* **backend:** Endpoints zum Auflösen von Ortsdaten und Ersetzen von Features ([715de94](https://github.com/jobrunner/fieldworksdiary/commit/715de94f1eb6412f113f9966a7fa490cd80bd2bf))
* **backend:** Fieldtrip folgt dem Sammeltag nachgetragener Samples ([20acd4d](https://github.com/jobrunner/fieldworksdiary/commit/20acd4d8f7447fd607f969bbfd83b4dd9910dca2))
* **backend:** Label-Tabelle für Admin-Ebenen (Generator + Loader) ([e63767b](https://github.com/jobrunner/fieldworksdiary/commit/e63767b8776a575dc0eddacf051fd8efec2513da))
* **backend:** Migration für Zeitzone, Sammeltag, Höhe und ID-Einstellungen ([710e9bf](https://github.com/jobrunner/fieldworksdiary/commit/710e9bfd4184783ed9f119b7ac2012cb4233b5cb))
* **backend:** Ortus-Antwort auf flache Ortsspalten abbilden ([f1b65de](https://github.com/jobrunner/fieldworksdiary/commit/f1b65de01d1d3acc613b7a5c82a1cb6465d78fe2))
* **backend:** Ortus-Client mit Retry und Cache ([f27dc1d](https://github.com/jobrunner/fieldworksdiary/commit/f27dc1d86dae187c2bb1d8903eb1ec95dcbc2c9d))
* **backend:** R3 schema migrations + Spec-aligned field names ([d6d5b78](https://github.com/jobrunner/fieldworksdiary/commit/d6d5b785dd3b41c4bace3caf5404265c4019fcfc))
* **backend:** Sample-ID wird nicht mehr vergeben oder umnummeriert ([dbd6366](https://github.com/jobrunner/fieldworksdiary/commit/dbd6366bd6f94d698ca64f426b8ce674105266f0))
* **backend:** Schema für Ortus-Ortsdaten, altitude → elevation ([5d15ba1](https://github.com/jobrunner/fieldworksdiary/commit/5d15ba1a6a9856ac5f49680991dce66e62908542))
* **backend:** TK25-Quadrant aus Koordinate berechnen ([e3dc405](https://github.com/jobrunner/fieldworksdiary/commit/e3dc405aacc2dee53aaa4f074977f6699a0da0ee))
* **backend:** Zeitzone aus Ortus, nur noch eine Höhe am Sample ([b89f283](https://github.com/jobrunner/fieldworksdiary/commit/b89f28345b93b1c6b3b7a310ed0b26d638543d3f))
* **enrichment:** Samples über Ortus anreichern ([14f0527](https://github.com/jobrunner/fieldworksdiary/commit/14f0527fc0288b02bf555fa5f5660452e460a1a3))
* **fusion:** R6.1 — server-side locality merge + remap events ([9ef7063](https://github.com/jobrunner/fieldworksdiary/commit/9ef7063982f2b9a3b03619c442c1e4377c9d3ca2))
* **fusion:** R6.2 — iOS pulls + applies locality remap events ([262ea62](https://github.com/jobrunner/fieldworksdiary/commit/262ea62c8cd20e2426aa115dfc2ba65c6a469a26))
* **fusion:** R6.3 — trivial client-side locality fusion ([a55b2c6](https://github.com/jobrunner/fieldworksdiary/commit/a55b2c6b13a7c1484bbfc82af6f6e81698a64dc1))
* **geo:** GEOTRANS für Koordinatenformate und Umrechnung ([d9a2e51](https://github.com/jobrunner/fieldworksdiary/commit/d9a2e5114ff50290bb4d33dbdfe5fe1ecabd0cb1))
* **ios:** Anlegen mit Viertelstunden-Fenster, Ortszeit-Sammeltag und ID-Vorschlag ([fc5e98f](https://github.com/jobrunner/fieldworksdiary/commit/fc5e98fcf1e2600c6b505d1812ef5943fa9918d3))
* **ios:** Bearbeiten-Formular mit Gruppen Koordinate, Zeit, Ortsdaten ([625debf](https://github.com/jobrunner/fieldworksdiary/commit/625debf7af97978ad3afedce5a38e2d21b65eccc))
* **ios:** edit existing samples in the editor view ([ccb9658](https://github.com/jobrunner/fieldworksdiary/commit/ccb96585da7b792e3216fcedbd609db863c15f46))
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
* **ios:** R4 model layer + GRDB v10 (Spec-Alignment) ([fedd0f2](https://github.com/jobrunner/fieldworksdiary/commit/fedd0f23ea5a878644c1c05c50ca718739f6cb6e))
* **ios:** re-hydrate on foreground + editor/gallery previews ([#46](https://github.com/jobrunner/fieldworksdiary/issues/46)) ([f27eab0](https://github.com/jobrunner/fieldworksdiary/commit/f27eab0013d200871019a66543f236e59aa986e3))
* **ios:** Sample sofort anlegen, Editor speichert beim Zurück ([485878f](https://github.com/jobrunner/fieldworksdiary/commit/485878fd9db687a193ae4a90eca88828160f59f9))
* **ios:** Sample-Ansicht aufgeräumt - Koordinatensystem, Peilung, Ränder ([5f9b92e](https://github.com/jobrunner/fieldworksdiary/commit/5f9b92eb3b21aba4a24ca24f8b48348d1d025d02))
* **ios:** Sample-Ansicht zeigt Ortsdaten kompakt, Bearbeiten über Formular ([8d08ae0](https://github.com/jobrunner/fieldworksdiary/commit/8d08ae090b3a24cf1563493a2c0b8e92d5695cc0))
* **ios:** Zeit- und ID-Logik im Package FieldworksGeo ([80f77a7](https://github.com/jobrunner/fieldworksdiary/commit/80f77a7b264f4a50e5ea74c88dbfd5090398f506))
* **ios:** Zeitzone aus Ortus übernehmen ([310de05](https://github.com/jobrunner/fieldworksdiary/commit/310de0564b8cb3a5bbf7155ec52d08a031b875ac))
* **ios:** Zeitzone und eine Höhe in Persistenz und Sync ([d50cae2](https://github.com/jobrunner/fieldworksdiary/commit/d50cae2ffbdef886be0a09be9c943afe5dc1adb2))
* **location:** Accuracy- und Staleness-Filter aus der Vorgänger-App übernehmen ([#47](https://github.com/jobrunner/fieldworksdiary/issues/47)) ([f9010bf](https://github.com/jobrunner/fieldworksdiary/commit/f9010bf65d68d448b23208b8bc58f0d7bf9bab67))
* **location:** Hintergrund-Ortung bis zum Fix je Sample ([149bee9](https://github.com/jobrunner/fieldworksdiary/commit/149bee95d6562506ae6759e4c3925d8784d3bfd4))
* Ortus-Ortsdaten, Zeitzone/ID/Höhe, Sofort-Anlage, Probe nachtragen (Phasen O2, Z, O3, E, N) ([bd3ef6f](https://github.com/jobrunner/fieldworksdiary/commit/bd3ef6f1349e04ade8efe91355cd8f1c6b164b8b))
* **placemark:** R7.1 + R7.2 — backend reverse-geocoding pipeline ([1f02b3c](https://github.com/jobrunner/fieldworksdiary/commit/1f02b3cadfd1493909f59ee0d9541f9ac505fe4e))
* **placemark:** R7.3 — backfill legacy admin_units into placemarks ([cd5570f](https://github.com/jobrunner/fieldworksdiary/commit/cd5570f64c1623ec41bb74a7d590f496cda14c59))
* **sync:** Ortsdaten und Features synchronisieren ([d8f0eae](https://github.com/jobrunner/fieldworksdiary/commit/d8f0eae2557367b5b7dd147330c8a42ac7cf5aef))
* **sync:** Ortsvorschlag übernehmen/verwerfen und erneut senden ([7482ec6](https://github.com/jobrunner/fieldworksdiary/commit/7482ec65ebdd36532589e2c6fe2ef12f7ee7b479))
* **sync:** R5.0 ADR + R5.2 outbox infrastructure ([a63b851](https://github.com/jobrunner/fieldworksdiary/commit/a63b8515aa6594379b4f4dca311d445b97fdd918))
* **sync:** R5.1 — optimistic concurrency via `version` + 409 ([60a7b4a](https://github.com/jobrunner/fieldworksdiary/commit/60a7b4adb28479c94ddec2266090bb7a4c27cbed))
* **sync:** R5b — route SyncRunner through the outbox ([2c72b18](https://github.com/jobrunner/fieldworksdiary/commit/2c72b184afdd4bec3022934070a76dcf758e8379))
* **sync:** R8d (1/2) — LocalityClient wire-fix + locality-create outbox dispatch ([5a6c5fb](https://github.com/jobrunner/fieldworksdiary/commit/5a6c5fb31d696bc9baccb48f2aebcfed05e82300))
* **sync:** Samples lokal und auf dem Server löschen ([691a9d6](https://github.com/jobrunner/fieldworksdiary/commit/691a9d6deca9bfa0bab1eb57307384c0c4591f98))
* **ui:** R8a — Placemark display in LocalityDetailView ([3eb5cf4](https://github.com/jobrunner/fieldworksdiary/commit/3eb5cf4266842bae5b2f35098142acd743b3bd5e))
* **ui:** R8b — manual placemark override sheet + reset ([82a2d39](https://github.com/jobrunner/fieldworksdiary/commit/82a2d39ec7d10abb91bd10d513bdcba1f7b9e084))
* **ui:** R8c — remap toast + needs-review badge in localities list ([13b697d](https://github.com/jobrunner/fieldworksdiary/commit/13b697d955950a44d8d7c99f7d8f37d2ee2c7bc3))
* **ui:** R8d (2/2) — AddSample mode picker + offline-fusion in editor ([78349de](https://github.com/jobrunner/fieldworksdiary/commit/78349decfd00266187e4cc23936ea7cb3c04576a))
* **ui:** R8e — clustered map, sample-id template, extended filters ([ab60c9f](https://github.com/jobrunner/fieldworksdiary/commit/ab60c9f22c38b46010c12204c4810de7576cfe1c))
* versioning + changelog via release-please (wie ortus/tempus/hostus) ([#50](https://github.com/jobrunner/fieldworksdiary/issues/50)) ([998161f](https://github.com/jobrunner/fieldworksdiary/commit/998161f5ac96c947ab881a1467be645af57fccce))


### Bug Fixes

* **auth:** behalte Session bei Netzwerkfehler beim Token-Refresh ([#45](https://github.com/jobrunner/fieldworksdiary/issues/45)) ([efa2716](https://github.com/jobrunner/fieldworksdiary/commit/efa27165851d65d6b892d48cc2eab53253e60e5f))
* **backend:** adminlabels-gen überschreibt die kuratierte Tabelle nur mit -force ([dd57da9](https://github.com/jobrunner/fieldworksdiary/commit/dd57da91e88277d40aa3524c1b305d7250c2d189))
* **backend:** Backfill idempotent, Besitzer-Klone, Remap-Zählung ([0d1fe76](https://github.com/jobrunner/fieldworksdiary/commit/0d1fe76da37aa14a8126da70b480b146e3a586f0))
* **backend:** Backfill setzt Ortus-Zeitzone auch für bereits angereicherte Proben ([4493b4c](https://github.com/jobrunner/fieldworksdiary/commit/4493b4c945e81fe79c8305089458e37957d1f47d))
* **backend:** bestehende golangci-lint-Funde beheben ([b06af7a](https://github.com/jobrunner/fieldworksdiary/commit/b06af7aeaf1fec845fd5b1ac39ed4084e904379b))
* **backend:** bump Go deps to close govulncheck findings ([#43](https://github.com/jobrunner/fieldworksdiary/issues/43)) ([82e8b0c](https://github.com/jobrunner/fieldworksdiary/commit/82e8b0c6c60bef29c38205b778512b8f852f8abb))
* **backend:** Dedup-Hash härten, mtb_quadrant als Zahl, Eingaben validieren ([6066de2](https://github.com/jobrunner/fieldworksdiary/commit/6066de2755830a328a15799f292c07b855604d04))
* **backend:** Export liefert nur sichtbare Placemarks ([445d8d3](https://github.com/jobrunner/fieldworksdiary/commit/445d8d381007e7095346ae76cc6ead569a202bd9))
* **backend:** Legacy-Placemarks in Migration 27 mappen, Localities nachanreichern ([cd6601b](https://github.com/jobrunner/fieldworksdiary/commit/cd6601b840850f4deb0c9cc70e7c3997133fea12))
* **backend:** Ortsstatus bei Koordinatenänderung und Client-Höhe korrekt führen ([2b75aa4](https://github.com/jobrunner/fieldworksdiary/commit/2b75aa46a72ea5ec18e8a63a4ae14039c2c94250))
* **backend:** Placemark-Referenzen und -Sichtbarkeit auf shared/eigene Zeilen begrenzen ([41f6d5f](https://github.com/jobrunner/fieldworksdiary/commit/41f6d5fab5e046a86bb1ccfcf1c347477e817deb))
* **backend:** Zeitzone nicht von device über location_service/manual überschreiben ([04b7383](https://github.com/jobrunner/fieldworksdiary/commit/04b7383d4ca297d35972f2ee97094bbf98d112fb))
* **devshell:** override SDKROOT to system SDK on Darwin ([eb1db41](https://github.com/jobrunner/fieldworksdiary/commit/eb1db41cb2eb0478f7b6498cebf34d0e445a9bd8))
* **enrichment:** Version erhöhen, Schreiben in Transaktion, DEM-Höhe auffrischen ([e9e2d33](https://github.com/jobrunner/fieldworksdiary/commit/e9e2d3396633f59007e15a3494f8392a1b50548f))
* ganztägige Samples bleiben bei Zonenwechsel auf 00:00 ([342b1c6](https://github.com/jobrunner/fieldworksdiary/commit/342b1c68ef122a6d09f4b073c63fb4f2d1153c4e))
* **geoplace:** MTB-Blattnummer aus den Feature-Properties lesen ([1b221d8](https://github.com/jobrunner/fieldworksdiary/commit/1b221d8efea93e6f1e7ef1778db42235ada9ebe5))
* **ios:** ausstehenden Einstellungs-Push vor dem Gleichheitscheck abbrechen ([bf9edf6](https://github.com/jobrunner/fieldworksdiary/commit/bf9edf6467673cc83b849f7de68d4f3caf1ad128))
* **ios:** Bearbeiten-Formular — Ganztägig-Tag, Genauigkeit löschen, MGRS-Vorbelegung ([4131ccb](https://github.com/jobrunner/fieldworksdiary/commit/4131ccb31e5bf3579df870752ac8190404caa6f5))
* **ios:** compensate iOS-26 NavigationStack leading-shift in editor ([#33](https://github.com/jobrunner/fieldworksdiary/issues/33)) ([96faf6e](https://github.com/jobrunner/fieldworksdiary/commit/96faf6eb77fd588b66865b29ae9ed7b5fa29ff4d))
* **ios:** disable two SwiftFormat rules that drifted in since June ([#44](https://github.com/jobrunner/fieldworksdiary/issues/44)) ([a35eb58](https://github.com/jobrunner/fieldworksdiary/commit/a35eb58a4128f947500b288cde6c63ac49620f30))
* **ios:** DST-sicheres Abrunden, kein Force-Unwrap im ID-Template ([adfed36](https://github.com/jobrunner/fieldworksdiary/commit/adfed366ebb93cccfb003e123fca2b6b6f4e2fd7))
* **ios:** expose endpoint pre-login + make welcome screen scrollable ([800c3f4](https://github.com/jobrunner/fieldworksdiary/commit/800c3f40c5c1448d0a8d0800b2716d29a59da14d))
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
* **ios:** modern toolbar(.hidden) on HomeView for iOS 26 stability ([#31](https://github.com/jobrunner/fieldworksdiary/issues/31)) ([95accad](https://github.com/jobrunner/fieldworksdiary/commit/95accad00eb09fc25fab78342f2e85f37de2fb9e))
* **ios:** nachgetragenes Sample ohne Koordinate sucht keine Position ([8e27cad](https://github.com/jobrunner/fieldworksdiary/commit/8e27cadc797a90e5d527ffa412fc769ecfc603c8))
* **ios:** Nachtragen-Review — EXIF-Präzision, Import-Race, Scrim-Token ([61965d3](https://github.com/jobrunner/fieldworksdiary/commit/61965d3a6a8b8d08519cc13f06fce0567050eb95))
* **ios:** Ortseditor ändert nur Bearbeitetes, Dialog nach Kartenschließen ([8e76e0a](https://github.com/jobrunner/fieldworksdiary/commit/8e76e0a433aa5f0248fca2b9c1c83aba4fda3479))
* **ios:** Ortszeile der Exkursionen aus den Proben abgeleitet ([7a2cd79](https://github.com/jobrunner/fieldworksdiary/commit/7a2cd7941420e26213b5a0c8e4fbe49ba1862e11))
* **ios:** Ortszeile der Exkursionen folgt Proben, Zeile skaliert bis AX5 ([00ce570](https://github.com/jobrunner/fieldworksdiary/commit/00ce570a70964f3c27b100546325d6115ced776b))
* **ios:** Ortus-Hierarchieeintrag ohne level bricht Dekodierung nicht ab ([c85fa72](https://github.com/jobrunner/fieldworksdiary/commit/c85fa72e138d8fdd918f1eb26a87432ec87742a4))
* **ios:** PATCH-Antwort der Einstellungen nicht mehr in AppConfig zurückspielen ([ee2bacb](https://github.com/jobrunner/fieldworksdiary/commit/ee2bacb3bbb3044c63394fa3f57c8c3ef739866f))
* **ios:** Phase-Z-Review – Zone zur Nutzungszeit, Server-Zone beim 409, Offset tippbar ([80d08c4](https://github.com/jobrunner/fieldworksdiary/commit/80d08c4598b9b6a7009847549bc41121aa47739a))
* **ios:** readable PocketBase error in auth flows ([#20](https://github.com/jobrunner/fieldworksdiary/issues/20)) ([c30304d](https://github.com/jobrunner/fieldworksdiary/commit/c30304db5c7775095019b0bacd1e99032640caf3))
* **ios:** Retry-Test zählt alle Build-Versuche ([e67e9f7](https://github.com/jobrunner/fieldworksdiary/commit/e67e9f74a37ac29fecb53ed7464169d7ad9b015b))
* **ios:** Sammeltag nachgetragener Samples nur bei Zeitänderung neu ([9d81443](https://github.com/jobrunner/fieldworksdiary/commit/9d81443d7343b4e475b5e8489defdea5422762bc))
* **ios:** sample editor — edge clipping, AX5 robustness, doppeltes Sammeltag ([45fffd2](https://github.com/jobrunner/fieldworksdiary/commit/45fffd2d2db269baac760618723eb1206ea997ce))
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
* **ui:** HomeHeader-Hintergrund bis in die Status-Bar-Fläche ziehen ([#48](https://github.com/jobrunner/fieldworksdiary/issues/48)) ([1f5b00e](https://github.com/jobrunner/fieldworksdiary/commit/1f5b00ee6bfcb599bf90db2f69ee057d264d381b))


### Performance Improvements

* **sync:** Enrichment-Poll gebündelt nach der Push-Schleife ([aa6a272](https://github.com/jobrunner/fieldworksdiary/commit/aa6a2723248ff6695e184ed89f10187b54670128))


### Miscellaneous Chores

* Versionierung auf 0.1.0 zurücksetzen ([c46d8be](https://github.com/jobrunner/fieldworksdiary/commit/c46d8bee8c4dcd33818a80ce2f6424cafa5c5c35))


### Code Refactoring

* alte Ortsspalten entfernt ([5cad22b](https://github.com/jobrunner/fieldworksdiary/commit/5cad22bce75e2463608dd178b969f4eee007c020))
* **backend:** labelloc und MTB-Dienst durch Ortus ersetzt ([dd2faba](https://github.com/jobrunner/fieldworksdiary/commit/dd2faba6f3f380f23c50c31a96d39f362d5f8fd9))


### Build System

* **deps:** PocketBase 0.22.42 -&gt; 0.40.6 (Go 1.27.4) ([e73ae0b](https://github.com/jobrunner/fieldworksdiary/commit/e73ae0b7434c2504f7958ffaf02b03d36903db1e))

## 0.1.0 (2026-11-14)

Neuer Startpunkt der Versionierung. Die früheren Releases 0.2.0 und
0.3.0 sind zurückgezogen; ihre Änderungen stecken vollständig in 0.1.0
und sind in der Git-History nachvollziehbar.

Ab dieser Version ist ein Release-Image nachvollziehbar: Der Git-Tag
`vX.Y.Z` zeigt auf das Image `ghcr.io/jobrunner/fieldworksdiary:X.Y.Z`,
dessen signierte Build-Provenance auf den Release-Commit verweist.
