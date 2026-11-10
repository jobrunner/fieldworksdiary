@testable import Fieldworksdiary
import XCTest

@MainActor
private final class FakeFixSource: PendingFixSource {
    var onFix: (@MainActor (LocationProvider.Fix) -> Void)?
    private(set) var running = false
    func start() { running = true }
    func stop() { running = false }
    func emit(_ fix: LocationProvider.Fix) { onFix?(fix) }
}

@MainActor
final class PendingFixServiceTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    private var source: FakeFixSource!
    private var service: PendingFixService!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var resolved: [String] = []
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", timeZone: berlin,
                                 settings: { SampleIDSettings(cutoffHour: 5) })
        mutations = PendingMutationsStore(database: database)
        source = FakeFixSource()
        resolved = []
        service = PendingFixService(
            store: store, mutations: mutations, source: source,
            now: { [unowned self] in clock }, timerInterval: nil,
            onCoordinateSet: { [unowned self] in resolved.append($0) }
        )
    }

    override func tearDownWithError() throws {
        service = nil
        source = nil
        mutations = nil
        store = nil
        database = nil
        try super.tearDownWithError()
    }

    private func fix(accuracy: Double = 10, lat: Double = 47.5, lon: Double = 11.5) -> LocationProvider.Fix {
        LocationProvider.Fix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy,
                             verticalAccuracy: 5, altitude: 640)
    }

    /// A sample without coordinate, created at `createdAt`.
    private func seedSampleWithoutCoordinate(createdAt: Date? = nil) throws -> LocalSample {
        let sample = try store.createLocal(lat: 1, lon: 1)
        let created = createdAt ?? clock
        try database.writer.write { db in
            guard var row = try LocalSample.fetchOne(db, key: sample.id) else { return }
            row.latitude = nil
            row.longitude = nil
            row.createdAt = created
            try row.update(db)
        }
        return try XCTUnwrap(store.fetchById(sample.id))
    }

    func testOneFixServesTwoSamplesExactlyOnce() throws {
        let a = try seedSampleWithoutCoordinate()
        let b = try seedSampleWithoutCoordinate()
        service.register(sampleID: a.id, createdAt: clock)
        service.register(sampleID: b.id, createdAt: clock)
        XCTAssertTrue(source.running)

        source.emit(fix(lat: 47.5, lon: 11.5))
        source.emit(fix(lat: 48.0, lon: 12.0))

        for id in [a.id, b.id] {
            let stored = try XCTUnwrap(store.fetchById(id))
            XCTAssertEqual(stored.latitude, 47.5)
            XCTAssertEqual(stored.longitude, 11.5)
            XCTAssertEqual(stored.locationSource, LocationSource.locationService.rawValue)
            XCTAssertEqual(stored.elevation, 640)
            XCTAssertEqual(stored.verticalAccuracy, 5)
            XCTAssertEqual(stored.horizontalAccuracy, 10)
        }
        XCTAssertEqual(Set(resolved), [a.id, b.id])
        XCTAssertEqual(resolved.count, 2)
        XCTAssertFalse(source.running)
        XCTAssertEqual(service.pendingCount, 0)
    }

    func testSampleWithManualCoordinateIsSkipped() throws {
        let sample = try seedSampleWithoutCoordinate()
        service.register(sampleID: sample.id, createdAt: clock)
        try store.updateCoordinate(id: sample.id, latitude: 40, longitude: 8, mutationsStore: mutations)

        source.emit(fix())

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.latitude, 40)
        XCTAssertEqual(stored.locationSource, LocationSource.user.rawValue)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertFalse(source.running)
    }

    func testGivesUpAfterFiveMinutes() throws {
        let sample = try seedSampleWithoutCoordinate()
        service.register(sampleID: sample.id, createdAt: clock)

        clock = clock.addingTimeInterval(PendingFixService.timeLimit + 1)
        source.emit(fix())

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertFalse(stored.hasCoordinate)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(source.running)
    }

    func testExpireOverdueStopsLocating() throws {
        let sample = try seedSampleWithoutCoordinate()
        service.register(sampleID: sample.id, createdAt: clock)
        clock = clock.addingTimeInterval(PendingFixService.timeLimit)
        service.expireOverdue()
        XCTAssertFalse(source.running)
    }

    func testImpreciseFixIsIgnored() throws {
        let sample = try seedSampleWithoutCoordinate()
        service.register(sampleID: sample.id, createdAt: clock)

        source.emit(fix(accuracy: LocationThreshold.horizontalAccuracy + 1))

        XCTAssertFalse(try XCTUnwrap(store.fetchById(sample.id)).hasCoordinate)
        XCTAssertTrue(source.running)

        source.emit(fix(accuracy: 20))
        XCTAssertTrue(try XCTUnwrap(store.fetchById(sample.id)).hasCoordinate)
    }

    func testResumePendingPicksUpYoungSamplesWithoutCoordinateOnly() throws {
        let young = try seedSampleWithoutCoordinate(createdAt: clock.addingTimeInterval(-60))
        let old = try seedSampleWithoutCoordinate(createdAt: clock.addingTimeInterval(-600))
        let withCoordinate = try store.createLocal(lat: 1, lon: 1)

        service.resumePending()
        XCTAssertTrue(source.running)
        source.emit(fix())

        XCTAssertTrue(try XCTUnwrap(store.fetchById(young.id)).hasCoordinate)
        XCTAssertFalse(try XCTUnwrap(store.fetchById(old.id)).hasCoordinate)
        XCTAssertEqual(try XCTUnwrap(store.fetchById(withCoordinate.id)).latitude, 1)
        XCTAssertEqual(resolved, [young.id])
    }
}
