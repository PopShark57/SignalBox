import Foundation
import XCTest
@testable import Signalbox

final class SnapshotTimelineStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try RepairTestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        RepairTestSupport.removeTemporaryDirectory(root)
    }

    func testRoundTripsEntriesOldestFirst() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)
        let older = summary(offsetHours: -2)
        let newer = summary(offsetHours: 0)

        _ = try await store.record(newer)
        _ = try await store.record(older)
        let entries = try await store.entries()

        XCTAssertEqual(entries.map(\.collectedAt), [older.collectedAt, newer.collectedAt])
    }

    func testMissingArchiveIsAnEmptyTimelineRatherThanAnError() async throws {
        let store = SnapshotTimelineStore(directoryURL: root.appendingPathComponent("never-created", isDirectory: true))

        let entries = try await store.entries()

        XCTAssertTrue(entries.isEmpty)
    }

    func testArchiveIsBoundedAndDiscardsTheOldestEntries() async throws {
        let store = SnapshotTimelineStore(directoryURL: root, maximumEntries: 3)

        for offset in 0..<6 {
            _ = try await store.record(summary(offsetHours: -offset))
        }
        let entries = try await store.entries()

        XCTAssertEqual(entries.count, 3)
        let expected = (0...2).map { referenceDate.addingTimeInterval(TimeInterval(-$0 * 3_600)) }.sorted()
        XCTAssertEqual(entries.map(\.collectedAt), expected)
    }

    func testRecordingTheSameInstantReplacesRatherThanDuplicates() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)

        _ = try await store.record(summary(offsetHours: 0, reportCount: 2))
        _ = try await store.record(summary(offsetHours: 0, reportCount: 5))
        let entries = try await store.entries()

        XCTAssertEqual(entries.count, 1, "A repeated collection at one instant is a duplicate, not a second observation.")
        XCTAssertEqual(entries.first?.reportGroups.first?.count, 5)
    }

    func testDemoSnapshotsAreNeverRecorded() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)

        let entries = try await store.record(DemoFixtures.snapshot())

        XCTAssertTrue(entries.isEmpty)
        let reloaded = try await store.entries()
        XCTAssertTrue(reloaded.isEmpty, "Demo mode must never write into a real Mac's timeline.")
    }

    func testUnsupportedSchemaVersionIsReportedAndTheFileIsLeftIntact() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)
        _ = try await store.record(summary(offsetHours: 0))

        // Simulate an archive written by a newer Signalbox.
        let fileURL = store.fileURL
        let original = try Data(contentsOf: fileURL)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        object["schemaVersion"] = SnapshotSummary.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        let forged = try Data(contentsOf: fileURL)

        do {
            _ = try await store.entries()
            XCTFail("A future archive format must be reported, not silently accepted.")
        } catch let error as SnapshotTimelineError {
            guard case .unsupportedSchemaVersion = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), forged, "Signalbox must not overwrite an archive it cannot read.")
    }

    func testSymlinkedArchiveIsRejected() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)
        let decoy = root.appendingPathComponent("decoy.json")
        try Data("[]".utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: decoy)

        do {
            _ = try await store.entries()
            XCTFail("A symlinked timeline file must be rejected.")
        } catch let error as SnapshotTimelineError {
            guard case .unsafePath = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testClearRemovesOnlyTheTimelineFile() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)
        let sibling = root.appendingPathComponent("keep-me.txt")
        try Data("untouched".utf8).write(to: sibling)
        _ = try await store.record(summary(offsetHours: 0))

        try await store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testClearOnAnAbsentArchiveSucceedsQuietly() async throws {
        let store = SnapshotTimelineStore(directoryURL: root)

        try await store.clear()
    }

    // MARK: - Fixtures

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(offsetHours: Int, reportCount: Int = 2) -> SnapshotSummary {
        SnapshotSummary(
            collectedAt: referenceDate.addingTimeInterval(TimeInterval(offsetHours * 3_600)),
            volumes: [VolumeSummary(
                name: "Macintosh HD",
                mountPath: "/",
                totalBytes: 500 * StorageHeadroomPolicy.gibibyte,
                availableBytes: 40 * StorageHeadroomPolicy.gibibyte,
                isInternal: true
            )],
            memory: MemorySummary(memory: DemoFixtures.demoMemory),
            reportGroups: [ReportGroupSummary(
                applicationIdentity: "bundle:com.example.northstar",
                applicationName: "Northstar",
                bundleIdentifier: "com.example.northstar",
                signature: "EXC_BAD_ACCESS · SIGSEGV",
                kind: .crash,
                count: reportCount,
                mostRecentAt: referenceDate
            )],
            unavailableSources: [],
            findingCountsBySeverity: ["notice": 1]
        )
    }
}
