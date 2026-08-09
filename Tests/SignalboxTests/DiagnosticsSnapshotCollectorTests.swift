import XCTest
@testable import Signalbox

final class DiagnosticsSnapshotCollectorTests: XCTestCase {
    func testCollectorSurfacesUnavailableProviderInsteadOfTreatingItAsHealthy() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let collector = SystemSnapshotCollector(
            diskProvider: MockDiskHealthProvider(volumes: [DemoFixtures.demoVolume]),
            memoryProvider: MockMemoryContextProvider(
                result: .unavailable(reason: "Permission was not granted for the test source.")
            ),
            reportProvider: MockDiagnosticReportProvider(reports: DemoFixtures.crashReports(at: date)),
            runningApplicationProvider: MockRunningApplicationProvider(
                applications: DemoFixtures.runningApplications(at: date)
            )
        )

        let snapshot = await collector.collect(at: date)

        XCTAssertNil(snapshot.memory)
        XCTAssertEqual(snapshot.unavailableEvidence.count, 1)
        XCTAssertEqual(snapshot.unavailableEvidence.first?.source, DiagnosticSource.memory)
        XCTAssertTrue(snapshot.findings.contains { $0.title == "Some evidence could not be inspected" })
        XCTAssertFalse(snapshot.isDemo)
    }

    func testDemoModeIsDeterministicAndDoesNotTouchInjectedProviders() async {
        let unavailable = "This mock must be bypassed in demo mode."
        let collector = SystemSnapshotCollector(
            diskProvider: MockDiskHealthProvider(result: .unavailable(reason: unavailable)),
            memoryProvider: MockMemoryContextProvider(result: .unavailable(reason: unavailable)),
            reportProvider: MockDiagnosticReportProvider(result: .unavailable(reason: unavailable)),
            runningApplicationProvider: MockRunningApplicationProvider(result: .unavailable(reason: unavailable))
        )

        let first = await collector.collect(at: .distantPast, isDemo: true)
        let second = await collector.collect(at: .distantFuture, isDemo: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.collectedAt, DemoFixtures.referenceDate)
        XCTAssertTrue(first.isDemo)
    }

    func testUnavailableRunningAppsDoNotBecomeAnObservedZeroCount() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let collector = SystemSnapshotCollector(
            diskProvider: MockDiskHealthProvider(volumes: [DemoFixtures.demoVolume]),
            memoryProvider: MockMemoryContextProvider(memory: DemoFixtures.demoMemory),
            reportProvider: MockDiagnosticReportProvider(reports: []),
            runningApplicationProvider: MockRunningApplicationProvider(
                result: .unavailable(reason: "Running application access failed.")
            )
        )

        let snapshot = await collector.collect(at: date)

        XCTAssertTrue(snapshot.unavailableEvidence.contains { $0.source == DiagnosticSource.runningApplications })
        XCTAssertFalse(
            snapshot.evidence.contains { $0.title == "Currently running applications" },
            "A failed provider must not be represented as an observed zero count."
        )
    }

    func testSingleCrashWithoutSignatureDoesNotClaimARecurringPattern() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let report = CrashReportRecord(
            applicationName: "Northstar",
            bundleIdentifier: "com.example.northstar",
            occurredAt: date,
            signature: "Crash signature unavailable",
            reportKind: "Crash",
            source: DiagnosticSource.crashReports
        )
        let collector = SystemSnapshotCollector(
            diskProvider: MockDiskHealthProvider(volumes: [DemoFixtures.demoVolume]),
            memoryProvider: MockMemoryContextProvider(memory: DemoFixtures.demoMemory),
            reportProvider: MockDiagnosticReportProvider(reports: [report]),
            runningApplicationProvider: MockRunningApplicationProvider(applications: [])
        )

        let snapshot = await collector.collect(at: date)
        let evidence = try XCTUnwrap(snapshot.evidence.first { $0.title == "Northstar crash pattern" })

        XCTAssertEqual(snapshot.crashGroups.first?.count, 1)
        XCTAssertTrue(evidence.detail.contains("no reliable recurring signature"))
        XCTAssertFalse(evidence.detail.localizedCaseInsensitiveContains("similar"))
        XCTAssertFalse(evidence.detail.localizedCaseInsensitiveContains("shared"))
    }

    func testDemoHistoryReliablyIncludesPartialAndConflictStates() async throws {
        let store = DemoRepairStore()
        let history = await store.history()
        let manifest = try XCTUnwrap(history.first)

        XCTAssertEqual(manifest.state, .partial)
        let outcome = try await store.restore(
            transactionID: manifest.transactionID,
            applicationIsRunning: false,
            choice: .originalOnly
        )
        guard case .conflict = outcome else {
            return XCTFail("The deterministic demo should expose restore-conflict UI.")
        }
    }
}
