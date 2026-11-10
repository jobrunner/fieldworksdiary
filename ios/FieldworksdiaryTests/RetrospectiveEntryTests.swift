import CoreGraphics
@testable import Fieldworksdiary
import FieldworksGeo
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Phase N: „Probe nachtragen“ — the coordinate dialog, the photo
/// import and the metadata reader.
@MainActor
final class RetrospectiveEntryTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var photos: LocalPhotoStore!
    private var placemarks: LocalPlacemarkStore!
    private var features: LocalSampleFeatureStore!
    private var localities: LocalLocalityStore!
    private var mutations: PendingMutationsStore!
    private var sync: SyncRunner!
    // swiftlint:disable force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let canary = TimeZone(identifier: "Atlantic/Canary")!
    // swiftlint:enable force_unwrapping
    /// 2026-11-10 10:07 Europe/Berlin.
    private var now = Date(timeIntervalSince1970: 1_794_301_620)

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(
            database: database, userId: "u1", timeZone: berlin,
            settings: { SampleIDSettings(cutoffHour: 5) }
        )
        photos = LocalPhotoStore(database: database)
        placemarks = LocalPlacemarkStore(database: database)
        features = LocalSampleFeatureStore(database: database)
        localities = LocalLocalityStore(database: database)
        mutations = PendingMutationsStore(database: database)
        sync = SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "" }, // no-op pass on kick()
            retryInterval: .seconds(3600)
        )
    }

    override func tearDownWithError() throws {
        if let all = try? samples.fetchAll() {
            for sample in all { PhotoStorage.deleteSampleDir(sampleID: sample.id) }
        }
        sync = nil
        mutations = nil
        localities = nil
        features = nil
        placemarks = nil
        photos = nil
        samples = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - dialog „Mit Koordinate“

    func testDialog_Success_CreatesRetrospectiveSampleWithPlaceDataFromOneQuery() async throws {
        let ortus = StubOrtus(.success(try OrtusFixtures.decode(OrtusFixtures.answerJSON(lat: 49.6812304, lon: 10.0313449))))
        let vm = makeDialog(ortus)
        vm.system = .etrs89utm32
        vm.first = "574400"
        vm.second = "5503700"

        let id = await vm.submit()

        let sampleID = try XCTUnwrap(id)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(ortus.inputQueries, [CoordinateInput(system: .etrs89utm32, first: "574400", second: "5503700")])
        XCTAssertEqual(ortus.pointQueries, 0, "only one Ortus request")
        let sample = try XCTUnwrap(samples.fetchById(sampleID))
        XCTAssertEqual(sample.latitude, 49.68123, "WGS84 from the answer, 6 decimals")
        XCTAssertEqual(sample.longitude, 10.031345)
        XCTAssertTrue(sample.isRetrospective)
        XCTAssertEqual(sample.locationSource, LocationSource.user.rawValue)
        XCTAssertEqual(sample.locationStatus, .backendService)
        let placemark = try XCTUnwrap(placemarks.fetchById(try XCTUnwrap(sample.placemark)))
        XCTAssertEqual(placemark.admin[.municipality]?.name, "Ochsenfurt")
        XCTAssertEqual(sample.mtbSheetNumber, "6326")
        XCTAssertEqual(sample.elevation, 236, "DEM height")
        XCTAssertEqual(sample.elevationSource, .backendService)
        XCTAssertEqual(sample.timezone, "Europe/Berlin")
        XCTAssertEqual(sample.timezoneSource, .locationService)
        XCTAssertEqual(sample.beginDate, SampleTime.roundedDown(now, in: berlin), "begin = now, Phase Z rounding")
        XCTAssertEqual(sample.sampleID, "261110/1")
        XCTAssertEqual(vm.created?.id, sampleID)
        XCTAssertEqual(try mutations.fetch(entityType: .sample).map(\.op), [.create])
    }

    func testDialog_OrtusZoneUsedForSample() async throws {
        let ortus = StubOrtus(.success(try OrtusFixtures.decode(OrtusFixtures.answerJSON(lat: 28.68, lon: -17.76, zone: "Atlantic/Canary"))))
        let vm = makeDialog(ortus)
        vm.first = "28,68"
        vm.second = "-17,76"

        let submitted = await vm.submit()
        let id = try XCTUnwrap(submitted)

        let sample = try XCTUnwrap(samples.fetchById(id))
        XCTAssertEqual(sample.timezone, "Atlantic/Canary")
        XCTAssertEqual(sample.timezoneSource, .locationService)
    }

    func testDialog_Failures_NoSample_ExactMessage_InputsKept() async throws {
        let cases: [(Error, String)] = [
            (OrtusQueryError.noWGS84, "Ortus konnte die Koordinate nicht umrechnen."),
            (OrtusQueryError.offline, "Keine Verbindung zu Ortus. Bitte später erneut versuchen."),
            (OrtusQueryError.server(message: "mgrs: invalid input"),
             "Ortus konnte die Koordinate nicht umrechnen: mgrs: invalid input"),
            (OrtusQueryError.server(message: nil), "Ortus konnte die Koordinate nicht umrechnen."),
        ]
        for (error, message) in cases {
            let vm = makeDialog(StubOrtus(.failure(error)))
            vm.system = .mgrs
            vm.first = "32UXX1"
            vm.code = "Altfund 7"

            let id = await vm.submit()

            XCTAssertNil(id)
            XCTAssertEqual(vm.errorMessage, message)
            XCTAssertEqual(vm.system, .mgrs)
            XCTAssertEqual(vm.first, "32UXX1")
            XCTAssertEqual(vm.code, "Altfund 7")
            XCTAssertFalse(vm.isSubmitting)
            XCTAssertEqual(try samples.count(), 0)
            XCTAssertEqual(try mutations.fetch(entityType: .sample).count, 0)
        }
    }

    func testDialog_EmptyInput_LocalValidationMessage() async throws {
        let ortus = StubOrtus(.failure(OrtusQueryError.offline))
        let vm = makeDialog(ortus)
        vm.first = ""
        vm.second = "10.03"

        let id = await vm.submit()

        XCTAssertNil(id)
        XCTAssertEqual(vm.errorMessage, "Bitte eine gültige Koordinate eingeben.")
        XCTAssertEqual(vm.second, "10.03")
        XCTAssertEqual(ortus.inputQueries.count, 0, "caught before any request")
        XCTAssertEqual(try samples.count(), 0)
    }

    func testDialog_AnswerWithoutWGS84_IsAFailure() async throws {
        let vm = makeDialog(StubOrtus(.success(try OrtusFixtures.decode("{}"))))
        vm.first = "49.68"
        vm.second = "10.03"

        let id = await vm.submit()

        XCTAssertNil(id)
        XCTAssertEqual(vm.errorMessage, "Ortus konnte die Koordinate nicht umrechnen.")
        XCTAssertEqual(try samples.count(), 0)
    }

    func testDialog_NoEndpoint_ReportsOffline() async throws {
        let vm = makeDialog(nil)
        vm.first = "49.68"
        vm.second = "10.03"

        let id = await vm.submit()

        XCTAssertNil(id)
        XCTAssertEqual(vm.errorMessage, "Keine Verbindung zu Ortus. Bitte später erneut versuchen.")
    }

    func testDialog_Cancelled_NoMessageNoSample() async throws {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let vm = makeDialog(StubOrtus(.failure(error)))
            vm.first = "49.68"
            vm.second = "10.03"

            let id = await vm.submit()

            XCTAssertNil(id)
            XCTAssertNil(vm.errorMessage, "a cancelled request shows no Ortus error")
            XCTAssertEqual(try samples.count(), 0)
        }
    }

    func testDialog_DefaultSystemFollowsDisplayFormat() {
        XCTAssertEqual(makeDialog(nil, format: .mgrs).system, .mgrs)
        for format in CoordinateDisplayFormat.allCases where format != .mgrs {
            XCTAssertEqual(makeDialog(nil, format: format).system, .wgs84, "\(format)")
        }
    }

    func testDialog_KeptSuggestion_HandsRunningToEditor_TypedIDVerbatim() async throws {
        let answer = try OrtusFixtures.decode(OrtusFixtures.answerJSON(lat: 49.68123, lon: 10.03134))
        let kept = makeDialog(StubOrtus(.success(answer)))
        kept.first = "49.68123"
        kept.second = "10.03134"
        XCTAssertEqual(kept.code, "261110/1")
        _ = await kept.submit()
        XCTAssertEqual(kept.created?.suggestedRunning, nil, "<seq> format has no running counter")

        let typed = makeDialog(StubOrtus(.success(answer)))
        typed.code = "  Altfund 3 "
        typed.first = "49.68123"
        typed.second = "10.03134"
        let submitted = await typed.submit()
        let id = try XCTUnwrap(submitted)
        XCTAssertEqual(try samples.fetchById(id)?.sampleID, "Altfund 3")
    }

    // MARK: - photo import

    func testPhotoWithoutGPS_SampleWithoutCoordinateWithPhoto_NoBackgroundFix() async throws {
        // No background fix is structural: `RetrospectiveSampleCreator`
        // has no `PendingFixService` to register with.
        let ortus = StubOrtus(.failure(OrtusQueryError.offline))
        let data = try Self.makeImage(exif: ["DateTimeOriginal": "2019:06:01 14:30:00"])

        let outcome = try await makeImporter(ortus).importPhoto(data)

        guard case let .created(created) = outcome else { return XCTFail("expected a sample") }
        let sample = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertNil(sample.latitude)
        XCTAssertNil(sample.longitude)
        XCTAssertTrue(sample.isRetrospective)
        XCTAssertEqual(sample.timezone, "Europe/Berlin", "device zone")
        XCTAssertEqual(sample.timezoneSource, .device)
        XCTAssertEqual(sample.beginDate, try Self.date("2019-06-01 14:30", berlin))
        XCTAssertEqual(sample.collectingDay, "2019-06-01")
        XCTAssertEqual(sample.sampleID, "190601/1", "id suggested for the capture day")
        XCTAssertEqual(try photos.fetchBySample(created.id).count, 1, "photo attached")
        XCTAssertEqual(ortus.inputQueries.count, 0)
    }

    func testPhotoWithoutAnyMetadata_SampleNowWithPhoto() async throws {
        let outcome = try await makeImporter(StubOrtus(.failure(OrtusQueryError.offline)))
            .importPhoto(try Self.makeImage())

        guard case let .created(created) = outcome else { return XCTFail("expected a sample") }
        let sample = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertNil(sample.latitude)
        XCTAssertEqual(sample.beginDate, SampleTime.roundedDown(now, in: berlin))
        XCTAssertEqual(try photos.fetchBySample(created.id).count, 1)
    }

    func testPhotoWithGPS_Success_CaptureTimeReadInOrtusZone() async throws {
        let ortus = StubOrtus(.success(try OrtusFixtures.decode(OrtusFixtures.answerJSON(lat: 28.68, lon: -17.76, zone: "Atlantic/Canary"))))
        // No offset in the photo: the wall clock 23:30 is read in the
        // Ortus zone (Canary, 22:30 UTC), not in the device zone (Berlin).
        let data = try Self.makeImage(
            gps: (28.68, "N", 17.76, "W"),
            exif: ["DateTimeOriginal": "2019:06:01 23:30:00"]
        )

        let outcome = try await makeImporter(ortus).importPhoto(data)

        guard case let .created(created) = outcome else { return XCTFail("expected a sample") }
        // EXIF stores GPS as DMS rationals: the query carries what the
        // reader returns, which may differ from 28.68 in the 6th decimal.
        let read = try XCTUnwrap(PhotoMetadataReader.read(data, fallbackZone: berlin).coordinate)
        XCTAssertEqual(ortus.inputQueries.count, 1)
        XCTAssertEqual(ortus.inputQueries.first?.system, .wgs84)
        XCTAssertEqual(ortus.inputQueries.first?.first, String(format: "%.6f", read.lat))
        XCTAssertEqual(ortus.inputQueries.first?.second, String(format: "%.6f", read.lon))
        let sample = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(sample.latitude, 28.68)
        XCTAssertEqual(sample.longitude, -17.76)
        XCTAssertEqual(sample.timezone, "Atlantic/Canary")
        XCTAssertEqual(sample.beginDate, try Self.date("2019-06-01 23:30", canary), "re-read in the Ortus zone")
        XCTAssertEqual(sample.collectingDay, "2019-06-01")
        XCTAssertEqual(sample.sampleID, "190601/1")
        XCTAssertEqual(sample.locationStatus, .backendService)
        XCTAssertEqual(try photos.fetchBySample(created.id).count, 1)
    }

    func testPhotoWithGPS_OrtusFails_DialogSeededAndPhotoGoesToItsSample() async throws {
        let data = try Self.makeImage(
            gps: (49.68123, "N", 10.03134, "E"),
            exif: ["DateTimeOriginal": "2019:06:01 14:30:00", "OffsetTimeOriginal": "+02:00"]
        )

        let outcome = try await makeImporter(StubOrtus(.failure(OrtusQueryError.offline))).importPhoto(data)

        guard case let .needsDialog(seed) = outcome else { return XCTFail("expected the dialog") }
        // EXIF stores GPS as DMS rationals: expect what the reader returns.
        let read = try XCTUnwrap(PhotoMetadataReader.read(data, fallbackZone: berlin).coordinate)
        let expected = CoordinateInput(
            system: .wgs84,
            first: String(format: "%.6f", read.lat),
            second: String(format: "%.6f", read.lon)
        )
        XCTAssertEqual(seed.input, expected)
        XCTAssertEqual(read.lat, 49.68123, accuracy: 1e-5)
        XCTAssertEqual(read.lon, 10.03134, accuracy: 1e-5)
        XCTAssertEqual(seed.errorMessage, "Keine Verbindung zu Ortus. Bitte später erneut versuchen.")
        XCTAssertEqual(try samples.count(), 0, "nothing created yet")

        let ortus = StubOrtus(.success(try OrtusFixtures.decode(OrtusFixtures.answerJSON(lat: 49.68123, lon: 10.03134))))
        let vm = RetrospectiveCoordinateViewModel(
            ortus: ortus, creator: makeCreator(), displayFormat: .decimalSign,
            prefill: seed.input, initialError: seed.errorMessage, photo: seed.photo
        )
        XCTAssertEqual(vm.errorMessage, seed.errorMessage)
        XCTAssertEqual(vm.first, expected.first)
        XCTAssertEqual(vm.code, "190601/1", "id suggested for the capture day")

        let submitted = await vm.submit()
        let id = try XCTUnwrap(submitted)
        let sample = try XCTUnwrap(samples.fetchById(id))
        XCTAssertEqual(sample.beginDate, try Self.date("2019-06-01 14:30", berlin), "explicit +02:00")
        XCTAssertEqual(try photos.fetchBySample(id).count, 1, "the picked photo is attached")
    }

    // MARK: - PhotoMetadataReader

    func testReader_JPEGWithSouthWestGPSAndOffset() throws {
        let data = try Self.makeImage(
            gps: (33.45, "S", 70.66, "W"),
            exif: ["DateTimeOriginal": "2019:06:01 14:30:00", "OffsetTimeOriginal": "-04:00"]
        )

        let meta = PhotoMetadataReader.read(data, fallbackZone: berlin)

        let coordinate = try XCTUnwrap(meta.coordinate)
        XCTAssertEqual(coordinate.lat, -33.45, accuracy: 1e-5)
        XCTAssertEqual(coordinate.lon, -70.66, accuracy: 1e-5)
        XCTAssertTrue(meta.hadExplicitOffset)
        XCTAssertEqual(meta.capturedAt, Date(timeIntervalSince1970: 1_559_413_800), "2019-06-01 18:30 UTC")
    }

    func testReader_JPEGWithoutOffset_ReadInFallbackZone() throws {
        let data = try Self.makeImage(exif: ["DateTimeOriginal": "2019:06:01 14:30:00"])

        let meta = PhotoMetadataReader.read(data, fallbackZone: canary)

        XCTAssertNil(meta.coordinate)
        XCTAssertFalse(meta.hadExplicitOffset)
        XCTAssertEqual(meta.capturedAt, try Self.date("2019-06-01 14:30", canary))
    }

    func testReader_JPEGWithoutEXIF() throws {
        let meta = PhotoMetadataReader.read(try Self.makeImage(), fallbackZone: berlin)

        XCTAssertNil(meta.coordinate)
        XCTAssertNil(meta.capturedAt)
        XCTAssertFalse(meta.hadExplicitOffset)
    }

    func testReader_NotAnImage() {
        let meta = PhotoMetadataReader.read(Data("nope".utf8), fallbackZone: berlin)
        XCTAssertNil(meta.coordinate)
        XCTAssertNil(meta.capturedAt)
    }

    func testReader_HEIC() throws {
        let data: Data
        do {
            data = try Self.makeImage(
                type: .heic,
                gps: (49.68123, "N", 10.03134, "E"),
                exif: ["DateTimeOriginal": "2019:06:01 14:30:00", "OffsetTimeOriginal": "+02:00"]
            )
        } catch {
            throw XCTSkip("HEIC encoding not available here")
        }

        let meta = PhotoMetadataReader.read(data, fallbackZone: canary)

        let coordinate = try XCTUnwrap(meta.coordinate)
        XCTAssertEqual(coordinate.lat, 49.68123, accuracy: 1e-5)
        XCTAssertEqual(coordinate.lon, 10.03134, accuracy: 1e-5)
        XCTAssertEqual(meta.capturedAt, try Self.date("2019-06-01 14:30", berlin))
    }

    func testReader_ParseOffset() {
        XCTAssertEqual(PhotoMetadataReader.parseOffset("+02:00"), 7200)
        XCTAssertEqual(PhotoMetadataReader.parseOffset("-03:30"), -12600)
        XCTAssertEqual(PhotoMetadataReader.parseOffset("+0100"), 3600)
        XCTAssertNil(PhotoMetadataReader.parseOffset("02:00"))
        XCTAssertNil(PhotoMetadataReader.parseOffset(""))
    }

    // MARK: - helpers

    /// `resolverOrtus` is handed to the resolver too, so a second
    /// request made while applying the answer would be counted.
    private func makeCreator(resolverOrtus: OrtusQuerying? = nil) -> RetrospectiveSampleCreator {
        let resolver = SampleLocationResolver(
            ortus: resolverOrtus, samples: samples, placemarks: placemarks, features: features, mutations: mutations
        )
        let berlin = self.berlin
        return RetrospectiveSampleCreator(
            store: samples, photoStore: photos, mutationsStore: mutations, resolver: resolver,
            sync: sync, deviceZone: { berlin }, now: { [unowned self] in now }
        )
    }

    private func makeDialog(
        _ ortus: OrtusQuerying?, format: CoordinateDisplayFormat = .decimalSign
    ) -> RetrospectiveCoordinateViewModel {
        RetrospectiveCoordinateViewModel(
            ortus: ortus, creator: makeCreator(resolverOrtus: ortus), displayFormat: format
        )
    }

    private func makeImporter(_ ortus: OrtusQuerying?) -> RetrospectivePhotoImporter {
        RetrospectivePhotoImporter(ortus: ortus, creator: makeCreator())
    }

    private static func date(_ text: String, _ zone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    private enum ImageError: Error { case encode }

    /// A tiny image written at runtime with ImageIO, carrying the given
    /// GPS and Exif blocks (no binary fixtures in the repo).
    private static func makeImage(
        type: UTType = .jpeg,
        gps: (lat: Double, latRef: String, lon: Double, lonRef: String)? = nil,
        exif: [String: String]? = nil
    ) throws -> Data {
        guard let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ImageError.encode }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else { throw ImageError.encode }

        var properties: [CFString: Any] = [:]
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: gps.lat,
                kCGImagePropertyGPSLatitudeRef: gps.latRef,
                kCGImagePropertyGPSLongitude: gps.lon,
                kCGImagePropertyGPSLongitudeRef: gps.lonRef,
            ]
        }
        if let exif {
            var block: [CFString: Any] = [:]
            if let original = exif["DateTimeOriginal"] { block[kCGImagePropertyExifDateTimeOriginal] = original }
            if let offset = exif["OffsetTimeOriginal"] { block[kCGImagePropertyExifOffsetTimeOriginal] = offset }
            properties[kCGImagePropertyExifDictionary] = block
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw ImageError.encode }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encode }
        return data as Data
    }
}
