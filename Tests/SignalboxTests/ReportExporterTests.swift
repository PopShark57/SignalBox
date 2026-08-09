import Foundation
import XCTest
@testable import Signalbox

final class ReportExporterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01T12:00:00Z
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    func testExportsSelectedStructuredSectionsAndRedactsHomeDirectory() {
        let exporter = ReportExporter(homeDirectory: home)
        let report = exporter.markdown(
            for: ReportExportPayload(
                generatedAt: date,
                snapshot: snapshot(),
                applications: [application()],
                repairHistory: [manifest()]
            )
        )

        XCTAssertTrue(report.contains("# Signalbox Diagnostic Report"))
        XCTAssertTrue(report.contains("## System Snapshot"))
        XCTAssertTrue(report.contains("## Selected Applications"))
        XCTAssertTrue(report.contains("## Selected Repair History"))
        XCTAssertTrue(report.contains("~/Library/Caches/com.example.Electron"))
        XCTAssertTrue(report.contains("Available storage is low enough to cause application instability."))
        XCTAssertFalse(report.contains("/Users/alice"))
        XCTAssertFalse(report.contains("alice"))
    }

    func testOmitsRawCrashAndPrivateFreeFormFields() {
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(
                generatedAt: date,
                snapshot: snapshot(),
                applications: [application()],
                repairHistory: [manifest()]
            )
        )

        XCTAssertFalse(report.contains("RAW_CRASH_BODY"), "Evidence details must never be exported")
        XCTAssertFalse(report.contains("private-attribute"), "Evidence attributes must never be exported")
        XCTAssertFalse(report.contains("SECRET_SIGNATURE"), "Crash signatures must never be exported")
        XCTAssertFalse(report.contains("unrelated-document-name.txt"), "Crash source paths must never be exported")
        XCTAssertFalse(report.contains("session-token.db"), "Repair operation paths must never be exported")
        XCTAssertFalse(report.contains("Operation failed at"), "Free-form manifest errors must never be exported")
        XCTAssertTrue(report.contains("Recorded errors: 1 (details omitted for privacy)"))
    }

    func testCollapsesNewlinesAndEscapesMarkdownFromDomainStrings() {
        let injected = InspectedApplication(
            name: "Example\n# Injected heading",
            bundleIdentifier: "com.example.*wild*",
            version: "1.0",
            bundleURL: nil,
            executableArchitecture: .available("arm64"),
            codeSigningStatus: .available("valid"),
            isRunning: false,
            iconFileURL: nil,
            matchingCrashReports: [],
            suggestedRecipeIDs: [],
            recipeEvidence: []
        )

        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: nil, applications: [injected])
        )

        XCTAssertTrue(report.contains("### Example \\# Injected heading"))
        XCTAssertTrue(report.contains("com.example.\\*wild\\*"))
        XCTAssertFalse(report.contains("\n# Injected heading"))
    }

    func testEmptySelectionIsExplicitAndDeterministic() {
        let exporter = ReportExporter(homeDirectory: home)
        let payload = ReportExportPayload(generatedAt: date, snapshot: nil)

        let first = exporter.markdown(for: payload)
        let second = exporter.markdown(for: payload)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("No report sections were selected."))
        XCTAssertTrue(first.hasSuffix("\n"))
    }

    func testRedactsBareHomePathFollowedByPunctuation() {
        let application = InspectedApplication(
            name: "Owner: /Users/alice.",
            bundleIdentifier: "com.example.redaction",
            version: "1",
            bundleURL: nil,
            executableArchitecture: .available("arm64"),
            codeSigningStatus: .available("valid"),
            isRunning: false,
            iconFileURL: nil,
            matchingCrashReports: [],
            suggestedRecipeIDs: [],
            recipeEvidence: []
        )

        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: nil, applications: [application])
        )

        XCTAssertFalse(report.contains("/Users/alice"))
        XCTAssertTrue(report.contains("Owner: ~."))
    }

    func testExportsHostDescriptionWithoutIdentifyingTheMachine() {
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: snapshot())
        )

        XCTAssertTrue(report.contains("### Host"))
        XCTAssertTrue(report.contains("- Hardware model identifier: Mac00,0"))
        XCTAssertTrue(report.contains("- Architecture: Apple silicon (arm64)"))
        XCTAssertTrue(report.contains("- macOS build: 24C000"))
    }

    func testSeparatesReportFamiliesAndNeverTotalsThemTogether() {
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: multiFamilySnapshot())
        )

        XCTAssertTrue(report.contains("### Recent Crash Activity"))
        XCTAssertTrue(report.contains("### Recent Hang Reports"))
        XCTAssertTrue(report.contains("is never counted as a crash"))
        // Each family lists its own count; there is no combined figure.
        XCTAssertTrue(report.contains("2 reports; most recent"))
        XCTAssertTrue(report.contains("1 report; most recent"))
        XCTAssertFalse(report.contains("3 reports"))
    }

    func testTimelineSectionReportsRecurrenceWithoutLeakingSignatures() {
        let recurrence = ReportRecurrence(
            correlationKey: "bundle:com.example.electron|secret_signature|crash",
            applicationIdentity: "bundle:com.example.electron",
            applicationName: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            kind: .crash,
            snapshotCount: 3,
            peakReportCount: 6,
            firstObservedAt: date.addingTimeInterval(-7_200),
            lastObservedAt: date,
            mostRecentReportAt: date
        )
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(
                generatedAt: date,
                snapshot: nil,
                timeline: ReportTimelineSection(
                    entryCount: 3,
                    earliestCollectedAt: date.addingTimeInterval(-7_200),
                    delta: SnapshotDelta(
                        previousCollectedAt: date.addingTimeInterval(-3_600),
                        currentCollectedAt: date,
                        systemVolumeAvailableByteChange: -2 * StorageHeadroomPolicy.gibibyte,
                        reportCountChange: 2,
                        newlyUnavailableSources: ["Recent diagnostic reports"],
                        resolvedUnavailableSources: []
                    ),
                    recurrences: [recurrence]
                )
            )
        )

        XCTAssertTrue(report.contains("## Snapshot Timeline"))
        XCTAssertTrue(report.contains("- Collections recorded locally: 3"))
        XCTAssertTrue(report.contains("appeared in 3 collections"))
        XCTAssertTrue(report.contains("largest single-collection count 6"))
        XCTAssertTrue(report.contains("Counts are not summed across collections"))
        XCTAssertTrue(report.contains("−2.0 GiB"))
        XCTAssertFalse(report.contains("secret_signature"), "A correlation key embeds the signature and must never be exported.")
        XCTAssertFalse(report.contains("No report sections were selected."))
    }

    func testTimelineWithASingleCollectionSaysThereIsNothingToCompare() {
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(
                generatedAt: date,
                snapshot: nil,
                timeline: ReportTimelineSection(
                    entryCount: 1,
                    earliestCollectedAt: date,
                    delta: nil,
                    recurrences: []
                )
            )
        )

        XCTAssertTrue(report.contains("Only one collection has been recorded"))
        XCTAssertTrue(report.contains("No report pattern was observed in more than one collection"))
    }

    private func multiFamilySnapshot() -> SystemSnapshot {
        let crash = CrashReportRecord(
            applicationName: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            occurredAt: date,
            signature: "EXC_BAD_ACCESS",
            kind: .crash,
            source: DiagnosticSource.crashReports
        )
        let secondCrash = CrashReportRecord(
            applicationName: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            occurredAt: date.addingTimeInterval(-60),
            signature: "EXC_BAD_ACCESS",
            kind: .crash,
            source: DiagnosticSource.crashReports
        )
        let hang = CrashReportRecord(
            applicationName: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            occurredAt: date,
            signature: "Unresponsive UI",
            kind: .hang,
            source: DiagnosticSource.crashReports
        )
        let reports = [crash, secondCrash, hang]

        return SystemSnapshot(
            collectedAt: date,
            volumes: [],
            memory: nil,
            crashReports: reports,
            crashGroups: CrashGrouper.groups(from: reports),
            runningApplications: [],
            unavailableEvidence: [],
            evidence: [],
            findings: [],
            isDemo: false
        )
    }

    private func snapshot() -> SystemSnapshot {
        let evidenceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let crash = CrashReportRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            applicationName: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            occurredAt: date,
            signature: "SECRET_SIGNATURE /Users/alice/Documents/private-file.txt",
            reportKind: "Crash",
            source: "/Users/alice/Library/Logs/DiagnosticReports/unrelated-document-name.txt"
        )
        let evidence = Evidence(
            id: evidenceID,
            title: "Storage capacity",
            detail: "RAW_CRASH_BODY /Users/alice/Secrets/secret.txt",
            source: "Volume resource values",
            collectedAt: date,
            attributes: ["private-attribute": "do-not-export"]
        )
        let finding = Finding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Low storage headroom",
            explanation: "Available storage is low enough to cause application instability.",
            severity: .warning,
            confidence: .strongInference,
            evidenceSource: "/Users/alice/Library",
            collectedAt: date,
            recommendedNextStep: "Free space, then observe whether the issue recurs.",
            relatedEvidenceIDs: [evidenceID]
        )

        return SystemSnapshot(
            collectedAt: date,
            hostContext: DemoFixtures.demoHostContext,
            volumes: [
                VolumeCapacity(
                    id: "root",
                    name: "Macintosh HD",
                    mountPath: "/",
                    totalBytes: 500 * 1_024 * 1_024 * 1_024,
                    availableBytes: 20 * 1_024 * 1_024 * 1_024,
                    isLocal: true,
                    isInternal: true
                )
            ],
            memory: MemoryStatistics(
                physicalBytes: 16 * 1_024 * 1_024 * 1_024,
                activeBytes: 4 * 1_024 * 1_024 * 1_024,
                inactiveBytes: 2 * 1_024 * 1_024 * 1_024,
                wiredBytes: 2 * 1_024 * 1_024 * 1_024,
                compressedBytes: 1 * 1_024 * 1_024 * 1_024,
                freeBytes: 1 * 1_024 * 1_024 * 1_024,
                pageSize: 16_384
            ),
            crashReports: [crash],
            crashGroups: [
                CrashGroup(
                    id: "electron-secret",
                    applicationIdentity: "bundle:com.example.electron",
                    applicationName: "Electron Example",
                    bundleIdentifier: "com.example.Electron",
                    signature: "SECRET_SIGNATURE /Users/alice/Documents/private-file.txt",
                    count: 2,
                    mostRecentAt: date,
                    reportKind: "Crash"
                )
            ],
            runningApplications: [
                RunningApplicationInfo(
                    id: "com.example.Electron",
                    name: "Electron Example",
                    bundleIdentifier: "com.example.Electron",
                    bundleURL: URL(fileURLWithPath: "/Users/alice/Applications/Electron Example.app"),
                    processIdentifier: 42,
                    isActive: true,
                    observedAt: date
                )
            ],
            unavailableEvidence: [
                UnavailableEvidence(
                    source: "Diagnostic Reports",
                    reason: "Permission denied under /Users/alice/Library/Logs",
                    collectedAt: date
                )
            ],
            evidence: [evidence],
            findings: [finding],
            isDemo: false
        )
    }

    private func application() -> InspectedApplication {
        InspectedApplication(
            name: "Electron Example",
            bundleIdentifier: "com.example.Electron",
            version: "4.2",
            bundleURL: URL(fileURLWithPath: "/Users/alice/Applications/Electron Example.app"),
            executableArchitecture: .available("arm64"),
            codeSigningStatus: .available("Signed with a valid Developer ID"),
            isRunning: true,
            iconFileURL: URL(fileURLWithPath: "/Users/alice/Private/icon.icns"),
            matchingCrashReports: snapshot().crashReports,
            suggestedRecipeIDs: ["electron-cache-only"],
            recipeEvidence: ["Two similar crashes were observed after startup."]
        )
    }

    private func manifest() -> BackupManifest {
        let metadata = FileMetadata(
            device: 1,
            inode: 2,
            mode: 0o40755,
            size: 4_096,
            modificationSeconds: 1_735_732_800,
            modificationNanoseconds: 0,
            isDirectory: true
        )
        let operation = RepairOperation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            originalPath: "/Users/alice/Documents/session-token.db",
            backupPath: "/Users/alice/Library/Application Support/Signalbox/Backups/session-token.db",
            originalMetadata: metadata,
            fileCount: 3,
            byteCount: 4_096,
            state: .moved,
            error: nil
        )
        return BackupManifest(
            transactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            creationDate: date,
            targetBundleIdentifier: "com.example.Electron",
            targetApplicationName: "Electron Example",
            targetApplicationVersion: "4.2",
            backupDirectoryPath: "/Users/alice/Library/Caches/com.example.Electron",
            operations: [operation],
            state: .partial,
            errors: ["Operation failed at /Users/alice/Documents/session-token.db"],
            signalboxVersion: "1.0"
        )
    }
}
