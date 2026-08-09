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

    // MARK: - Fixtures

    private func entry(
        offsetHours: Int,
        availableGibibytes: Int64 = 40,
        reportCount: Int = 2,
        signature: String = "EXC_BAD_ACCESS · SIGSEGV",
        kind: DiagnosticReportKind = .crash,
        unavailableSources: [String] = []
    ) -> SnapshotSummary {
        SnapshotSummary(
            collectedAt: referenceDate.addingTimeInterval(TimeInterval(offsetHours * 3_600)),
            volumes: [VolumeSummary(
                name: "Macintosh HD",
                mountPath: "/",
                totalBytes: 500 * StorageHeadroomPolicy.gibibyte,
                availableBytes: availableGibibytes * StorageHeadroomPolicy.gibibyte,
                isInternal: true
            )],
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
