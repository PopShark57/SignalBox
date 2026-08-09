import XCTest
@testable import Signalbox

final class DiagnosticsPolicyTests: XCTestCase {
    private let gib = StorageHeadroomPolicy.gibibyte

    func testStorageThresholdsAreAuditableAndOrdered() {
        let policy = StorageHeadroomPolicy()

        XCTAssertEqual(policy.level(for: volume(available: 4 * gib)), .criticallyLow)
        XCTAssertEqual(policy.level(for: volume(available: 10 * gib)), .low)
        XCTAssertEqual(policy.level(for: volume(available: 25 * gib)), .limited)
        XCTAssertEqual(policy.level(for: volume(available: 80 * gib)), .adequate)
        XCTAssertTrue(policy.thresholdSummary.contains("heuristic"), policy.thresholdSummary)
    }

    func testPercentageRuleIsCappedForVeryLargeVolumes() {
        let policy = StorageHeadroomPolicy()
        let hugeVolume = VolumeCapacity(
            id: "huge",
            name: "Huge",
            mountPath: "/Volumes/Huge",
            totalBytes: 100_000 * gib,
            availableBytes: 100 * gib,
            isLocal: true,
            isInternal: false
        )

        XCTAssertEqual(policy.level(for: hugeVolume), .adequate)
    }

    func testCrashGroupingNormalizesCosmeticDifferences() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = [
            report(signature: "EXC_BAD_ACCESS   SIGSEGV", date: date),
            report(signature: "exc_bad_access sigsegv", date: date.addingTimeInterval(60)),
            report(signature: "SIGABRT", date: date.addingTimeInterval(120))
        ]

        let groups = CrashGrouper.groups(from: reports)

        XCTAssertEqual(groups.map(\.count), [2, 1])
        XCTAssertEqual(groups.first?.mostRecentAt, date.addingTimeInterval(60))
    }

    func testCrashGroupingUsesBundleIdentityAcrossRenamedApplications() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = [
            report(applicationName: "Northstar", signature: "EXC_BAD_ACCESS", date: date),
            report(applicationName: "Estrella del Norte", signature: "EXC_BAD_ACCESS", date: date.addingTimeInterval(60))
        ]

        let groups = CrashGrouper.groups(from: reports)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.applicationName, "Estrella del Norte")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
    }

    func testUnavailableSignaturesRemainIndividualWithUniqueDeterministicIDs() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = [
            report(applicationName: "Northstar", signature: "Crash signature unavailable", date: date),
            report(applicationName: "Estrella del Norte", signature: "Crash signature unavailable", date: date),
            report(applicationName: "Northstar", signature: "Crash signature unavailable", date: date.addingTimeInterval(60))
        ]

        let forward = CrashGrouper.groups(from: reports)
        let reversed = CrashGrouper.groups(from: Array(reports.reversed()))

        XCTAssertEqual(forward.map(\.count), [1, 1, 1])
        XCTAssertEqual(Set(forward.map(\.id)).count, forward.count)
        XCTAssertEqual(Set(forward.map(\.id)), Set(reversed.map(\.id)))
    }

    func testDiagnosisUsesCorrelationSafeLanguage() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = (0..<3).map { offset in
            report(signature: "EXC_BAD_ACCESS", date: date.addingTimeInterval(TimeInterval(offset)))
        }
        let findings = DiagnosisEngine().findings(
            volumes: [volume(available: 8 * gib)],
            memory: DemoFixtures.demoMemory,
            crashGroups: CrashGrouper.groups(from: reports),
            unavailableEvidence: [],
            collectedAt: date
        )

        let combined = findings.map(\.explanation).joined(separator: " ").lowercased()
        XCTAssertTrue(combined.contains("not proven") || combined.contains("does not prove"))
        XCTAssertFalse(combined.contains("storage caused"))
        XCTAssertFalse(findings.isEmpty)
    }

    func testLowExternalStorageDoesNotClaimSystemDiskInstability() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let external = VolumeCapacity(
            id: "/Volumes/External",
            name: "External",
            mountPath: "/Volumes/External",
            totalBytes: 500 * gib,
            availableBytes: 4 * gib,
            isLocal: true,
            isInternal: false
        )
        let findings = DiagnosisEngine().findings(
            volumes: [external],
            memory: nil,
            crashGroups: CrashGrouper.groups(from: [
                report(signature: "EXC_BAD_ACCESS", date: date),
                report(signature: "EXC_BAD_ACCESS", date: date.addingTimeInterval(1))
            ]),
            unavailableEvidence: [],
            collectedAt: date
        )
        let text = findings.map { $0.title + " " + $0.explanation }.joined(separator: " ").lowercased()

        XCTAssertTrue(text.contains("does not imply pressure on the mac's system volume"))
        XCTAssertFalse(findings.contains { $0.title == "Storage pressure is a possible contributor" })
    }

    private func volume(available: Int64) -> VolumeCapacity {
        VolumeCapacity(
            id: "/",
            name: "Macintosh HD",
            mountPath: "/",
            totalBytes: 500 * gib,
            availableBytes: available,
            isLocal: true,
            isInternal: true
        )
    }

    private func report(
        applicationName: String = "Northstar",
        signature: String,
        date: Date
    ) -> CrashReportRecord {
        CrashReportRecord(
            applicationName: applicationName,
            bundleIdentifier: "com.example.northstar",
            occurredAt: date,
            signature: signature,
            reportKind: "Crash",
            source: DiagnosticSource.crashReports
        )
    }
}
