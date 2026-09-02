import Foundation
import XCTest
@testable import Signalbox

final class SnapshotTimelineAnalyzerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeltaRequiresTwoCollections() {
        XCTAssertNil(SnapshotTimelineAnalyzer.delta(for: []))
        XCTAssertNil(SnapshotTimelineAnalyzer.delta(for: [entry(offsetHours: 0)]))
    }

    func testDeltaComparesTheTwoMostRecentCollections() throws {
        let entries = [
            entry(offsetHours: -6, availableGibibytes: 40, reportCount: 1),
            entry(offsetHours: -3, availableGibibytes: 30, reportCount: 2),
            entry(offsetHours: 0, availableGibibytes: 22, reportCount: 5)
        ]

        let delta = try XCTUnwrap(SnapshotTimelineAnalyzer.delta(for: entries))

        XCTAssertEqual(delta.previousCollectedAt, referenceDate.addingTimeInterval(-3 * 3_600))
        XCTAssertEqual(delta.currentCollectedAt, referenceDate)
        XCTAssertEqual(delta.systemVolumeAvailableByteChange, -8 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(delta.reportCountChange, 3)
        XCTAssertFalse(delta.isUnchanged)
    }

    func testDeltaIsOrderIndependent() throws {
        let entries = [
            entry(offsetHours: 0, availableGibibytes: 22),
            entry(offsetHours: -3, availableGibibytes: 30)
        ]

        let forward = try XCTUnwrap(SnapshotTimelineAnalyzer.delta(for: entries))
        let reversed = try XCTUnwrap(SnapshotTimelineAnalyzer.delta(for: entries.reversed()))

        XCTAssertEqual(forward, reversed)
    }

    func testMissingSystemVolumeMakesCapacityChangeUnknownRatherThanZero() throws {
        let withoutVolume = SnapshotSummary(
            collectedAt: referenceDate.addingTimeInterval(-3_600),
            volumes: [],
            memory: nil,
            reportGroups: [],
            unavailableSources: ["Mounted local volumes"],
            findingCountsBySeverity: [:]
        )

        let delta = try XCTUnwrap(
            SnapshotTimelineAnalyzer.delta(for: [withoutVolume, entry(offsetHours: 0)])
        )

        XCTAssertNil(
            delta.systemVolumeAvailableByteChange,
            "An unread volume is unknown, and must never be reported as a zero change."
        )
    }

    func testMissingSystemVolumeIsNeverReportedAsUnchanged() throws {
        // Same reports and sources — only capacity is unread on both sides.
        let previous = entry(offsetHours: -3, reportCount: 2, hasSystemVolume: false)
        let current = entry(offsetHours: 0, reportCount: 2, hasSystemVolume: false)

        let delta = try XCTUnwrap(SnapshotTimelineAnalyzer.delta(for: [previous, current]))

        XCTAssertNil(delta.systemVolumeAvailableByteChange)
        XCTAssertEqual(delta.reportCountChange, 0)
        XCTAssertTrue(delta.newlyUnavailableSources.isEmpty)
        XCTAssertTrue(delta.resolvedUnavailableSources.isEmpty)
        XCTAssertFalse(
            delta.isUnchanged,
            "An unread volume is unknown, not zero; isUnchanged must not invent that nothing moved."
        )
    }

    func testDeltaTracksSourcesBecomingUnavailableAndRecovering() throws {
        let previous = entry(offsetHours: -3, unavailableSources: ["Recent diagnostic reports"])
        let current = entry(offsetHours: 0, unavailableSources: ["macOS running applications"])

        let delta = try XCTUnwrap(SnapshotTimelineAnalyzer.delta(for: [previous, current]))

        XCTAssertEqual(delta.newlyUnavailableSources, ["macOS running applications"])
        XCTAssertEqual(delta.resolvedUnavailableSources, ["Recent diagnostic reports"])
    }

    func testRecurrenceCountsCollectionsAndNeverSumsReportCounts() throws {
        // The same rolling window is re-read each time, so the same underlying
        // reports appear in every collection. Summing 4 + 6 + 6 would invent 16.
        let entries = [
            entry(offsetHours: -6, reportCount: 4),
            entry(offsetHours: -3, reportCount: 6),
            entry(offsetHours: 0, reportCount: 6)
        ]

        let recurrence = try XCTUnwrap(SnapshotTimelineAnalyzer.recurrences(in: entries).first)

        XCTAssertEqual(recurrence.snapshotCount, 3)
        XCTAssertEqual(recurrence.peakReportCount, 6)
        XCTAssertEqual(recurrence.applicationName, "Northstar")
        XCTAssertEqual(recurrence.kind, .crash)
        XCTAssertEqual(recurrence.firstObservedAt, referenceDate.addingTimeInterval(-6 * 3_600))
        XCTAssertEqual(recurrence.lastObservedAt, referenceDate)
    }

    func testASinglecollectionIsNotARecurrence() {
        XCTAssertTrue(SnapshotTimelineAnalyzer.recurrences(in: [entry(offsetHours: 0)]).isEmpty)
    }

    func testUnavailableSignaturesAreNeverCorrelatedAcrossCollections() {
        let entries = (0..<3).map { offset in
            entry(
                offsetHours: -offset,
                signature: DiagnosticReportKind.crash.unavailableSignatureText
            )
        }

        XCTAssertTrue(
            SnapshotTimelineAnalyzer.recurrences(in: entries).isEmpty,
            "Without a signature there is nothing to correlate, so no recurrence may be claimed."
        )
    }

    func testDifferentFamiliesNeverMergeIntoOneRecurrence() {
        let entries = (0..<3).flatMap { offset in
            [
                entry(offsetHours: -offset, kind: .crash),
                entry(offsetHours: -offset, kind: .hang)
            ]
        }

        let recurrences = SnapshotTimelineAnalyzer.recurrences(in: entries)

        XCTAssertEqual(Set(recurrences.map(\.kind)), [.crash, .hang])
        XCTAssertEqual(recurrences.count, 2)
    }

    func testFindingsAreObservationsAndNeverClaimACause() throws {
        let entries = (0..<4).map { entry(offsetHours: -$0) }
        let recurrences = SnapshotTimelineAnalyzer.recurrences(in: entries)

        let findings = SnapshotTimelineAnalyzer.findings(for: recurrences, collectedAt: referenceDate)
        let finding = try XCTUnwrap(findings.first)

        XCTAssertEqual(finding.confidence, .observed)
        XCTAssertEqual(finding.evidenceSource, DiagnosticSource.snapshotTimeline)
        XCTAssertTrue(finding.explanation.contains("does not identify a cause"))
        XCTAssertFalse(finding.explanation.localizedCaseInsensitiveContains("caused"))
    }

    func testResourceLimitRecurrenceNeverEscalatesToAWarning() throws {
        let entries = (0..<6).map { entry(offsetHours: -$0, kind: .resourceLimit) }
        let recurrences = SnapshotTimelineAnalyzer.recurrences(in: entries)

        let finding = try XCTUnwrap(
            SnapshotTimelineAnalyzer.findings(for: recurrences, collectedAt: referenceDate).first
        )

        XCTAssertEqual(finding.severity, .notice, "A usage notice is not a failure, however often it repeats.")
    }

    // MARK: - Comparing any two collections

    func testComparingTwoChosenCollectionsIgnoresTheOrderTheyWerePicked() {
        let older = entry(offsetHours: -6, availableGibibytes: 40, reportCount: 1)
        let newer = entry(offsetHours: 0, availableGibibytes: 22, reportCount: 5)

        let forward = SnapshotTimelineAnalyzer.delta(from: older, to: newer)
        let backward = SnapshotTimelineAnalyzer.delta(from: newer, to: older)

        XCTAssertEqual(
            forward,
            backward,
            "Click order must never flip the sign of a change the user is trying to read."
        )
        XCTAssertEqual(forward.systemVolumeAvailableByteChange, -18 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(forward.reportCountChange, 4)
        XCTAssertEqual(forward.previousCollectedAt, older.collectedAt)
    }

    func testComparingDistantCollectionsSkipsEverythingBetweenThem() {
        let entries = [
            entry(offsetHours: -6, availableGibibytes: 40),
            entry(offsetHours: -3, availableGibibytes: 5),
            entry(offsetHours: 0, availableGibibytes: 38)
        ]

        let delta = SnapshotTimelineAnalyzer.delta(from: entries[0], to: entries[2])

        XCTAssertEqual(delta.systemVolumeAvailableByteChange, -2 * StorageHeadroomPolicy.gibibyte)
    }

    // MARK: - Capacity trend

    func testCapacityTrendCountsMovementsBetweenConsecutiveCollections() throws {
        let entries = [
            entry(offsetHours: -8, availableGibibytes: 30),
            entry(offsetHours: -6, availableGibibytes: 40),
            entry(offsetHours: -4, availableGibibytes: 40),
            entry(offsetHours: -2, availableGibibytes: 25),
            entry(offsetHours: 0, availableGibibytes: 20)
        ]

        let trend = try XCTUnwrap(SnapshotTimelineAnalyzer.capacityTrend(in: entries))

        XCTAssertEqual(trend.readingCount, 5)
        XCTAssertEqual(trend.risingIntervalCount, 1)
        XCTAssertEqual(trend.unchangedIntervalCount, 1)
        XCTAssertEqual(trend.fallingIntervalCount, 2)
        XCTAssertEqual(trend.comparableIntervalCount, 4)
        XCTAssertEqual(trend.notComparableIntervalCount, 0)
        XCTAssertEqual(trend.lowestReading.availableBytes, 20 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(trend.highestReading.availableBytes, 40 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(trend.netChangeBytes, -10 * StorageHeadroomPolicy.gibibyte)
    }

    func testAnUnreadVolumeMakesAnIntervalNotComparableRatherThanUnchanged() throws {
        let entries = [
            entry(offsetHours: -4, availableGibibytes: 30),
            entry(offsetHours: -2, hasSystemVolume: false),
            entry(offsetHours: 0, availableGibibytes: 30)
        ]

        let trend = try XCTUnwrap(SnapshotTimelineAnalyzer.capacityTrend(in: entries))

        XCTAssertEqual(trend.readingCount, 2)
        XCTAssertEqual(trend.notComparableIntervalCount, 2)
        XCTAssertEqual(
            trend.comparableIntervalCount,
            0,
            "A collection that never read the volume must not manufacture an unchanged interval."
        )
        XCTAssertEqual(trend.netChangeBytes, 0, "The two readings that do exist are still comparable to each other.")
    }

    func testCapacityTrendNeedsTwoActualReadings() {
        XCTAssertNil(SnapshotTimelineAnalyzer.capacityTrend(in: []))
        XCTAssertNil(
            SnapshotTimelineAnalyzer.capacityTrend(in: [entry(offsetHours: 0)]),
            "One reading is a measurement, not a movement."
        )
        XCTAssertNil(
            SnapshotTimelineAnalyzer.capacityTrend(in: [
                entry(offsetHours: -2, hasSystemVolume: false),
                entry(offsetHours: 0, availableGibibytes: 10)
            ]),
            "A single reading beside an unread collection is still one reading."
        )
    }

    func testCapacityTrendIsOrderIndependentAndUsesCollectionTime() throws {
        let entries = [
            entry(offsetHours: 0, availableGibibytes: 10),
            entry(offsetHours: -4, availableGibibytes: 30),
            entry(offsetHours: -2, availableGibibytes: 20)
        ]

        let trend = try XCTUnwrap(SnapshotTimelineAnalyzer.capacityTrend(in: entries))

        XCTAssertEqual(trend.firstReading.availableBytes, 30 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(trend.latestReading.availableBytes, 10 * StorageHeadroomPolicy.gibibyte)
        XCTAssertEqual(trend.fallingIntervalCount, 2)
    }

    // MARK: - Fixtures

    private func entry(
        offsetHours: Int,
        availableGibibytes: Int64 = 40,
        reportCount: Int = 2,
        signature: String = "EXC_BAD_ACCESS · SIGSEGV",
        kind: DiagnosticReportKind = .crash,
        unavailableSources: [String] = [],
        hasSystemVolume: Bool = true
    ) -> SnapshotSummary {
        SnapshotSummary(
            collectedAt: referenceDate.addingTimeInterval(TimeInterval(offsetHours * 3_600)),
            volumes: hasSystemVolume ? [VolumeSummary(
                name: "Macintosh HD",
                mountPath: "/",
                totalBytes: 500 * StorageHeadroomPolicy.gibibyte,
                availableBytes: availableGibibytes * StorageHeadroomPolicy.gibibyte,
                isInternal: true
            )] : [],
            memory: MemorySummary(memory: DemoFixtures.demoMemory),
            reportGroups: [ReportGroupSummary(
                applicationIdentity: "bundle:com.example.northstar",
                applicationName: "Northstar",
                bundleIdentifier: "com.example.northstar",
                signature: signature,
                kind: kind,
                count: reportCount,
                mostRecentAt: referenceDate.addingTimeInterval(TimeInterval(offsetHours * 3_600))
            )],
            unavailableSources: unavailableSources,
            findingCountsBySeverity: [:]
        )
    }
}
