import Foundation
import XCTest
@testable import Signalbox

/// Regressions for defects found by an adversarial review of this tree.
/// Each test names the false claim the app used to make.
final class AuditRegressionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_732_800)
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    // MARK: - Export

    /// A backslash cannot escape a backtick inside a CommonMark code span, so
    /// a volume name containing one used to close the span early and emit the
    /// rest as live Markdown/HTML — while silently truncating the path that was
    /// supposed to be the evidence.
    func testCodeSpansCannotBeEscapedByAHostileVolumeName() throws {
        let hostileMount = "/Volumes/Setup`<img src=x onerror=alert(1)>"
        let snapshot = SystemSnapshot(
            collectedAt: date,
            volumes: [VolumeCapacity(
                id: hostileMount,
                name: "Setup",
                mountPath: hostileMount,
                totalBytes: 100,
                availableBytes: 50,
                isLocal: true,
                isInternal: false
            )],
            memory: nil,
            crashReports: [],
            crashGroups: [],
            runningApplications: [],
            unavailableEvidence: [],
            evidence: [],
            findings: [],
            isDemo: false
        )

        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: snapshot)
        )

        let line = try XCTUnwrap(report.split(separator: "\n").first { $0.contains("/Volumes/Setup") })
        // The whole path survives, and the span is delimited by a longer run of
        // backticks than the one the path contains.
        XCTAssertTrue(line.contains(hostileMount), "The evidence must not be truncated: \(line)")
        XCTAssertTrue(line.contains("``\(hostileMount)``"), "Expected a widened code fence: \(line)")
        XCTAssertFalse(line.contains("\\`"), "A backslash escape is inert inside a code span: \(line)")
    }

    func testCodeSpanPadsWhenTheValueItselfStartsOrEndsWithABacktick() throws {
        let mount = "/Volumes/`odd`"
        let snapshot = SystemSnapshot(
            collectedAt: date,
            volumes: [VolumeCapacity(
                id: mount, name: "odd", mountPath: mount,
                totalBytes: 100, availableBytes: 50, isLocal: true, isInternal: false
            )],
            memory: nil, crashReports: [], crashGroups: [], runningApplications: [],
            unavailableEvidence: [], evidence: [], findings: [], isDemo: false
        )

        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(generatedAt: date, snapshot: snapshot)
        )
        let line = try XCTUnwrap(report.split(separator: "\n").first { $0.contains("/Volumes/") })

        XCTAssertTrue(line.contains("`` \(mount) ``"), "A value ending in a backtick needs padding: \(line)")
    }

    /// "No report sections were selected" was printed when the user had in fact
    /// selected the snapshot and none had been collected yet.
    func testUncollectedSnapshotIsAnAbsenceOfEvidenceNotAnEmptySelection() {
        let report = ReportExporter(homeDirectory: home).markdown(
            for: ReportExportPayload(
                generatedAt: date,
                snapshot: nil,
                snapshotWasRequestedButUnavailable: true
            )
        )

        XCTAssertTrue(report.contains("This is an absence of evidence, not a clean result."))
        XCTAssertFalse(report.contains("No report sections were selected."))
    }

    // MARK: - Restore state machine

    /// Restoring every backed-up item of a *partial* transaction left it stuck
    /// at `.restorePartial`, so the user was told "some items could not be
    /// restored" about an already-empty backup.
    func testFullyRestoringAPartialTransactionReachesRestored() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(
            root: root,
            cacheNames: ["Cache", "GPUCache"]
        )
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let executor = RepairExecutor(backupStore: store)

        let cache = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let gpuCache = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/GPUCache") })
        // Make GPUCache fail its pre-move metadata revalidation, producing a
        // genuine `.partial` transaction with one operation never moved.
        try RepairTestSupport.writeFile(named: "changed.bin", byteCount: 5, in: URL(fileURLWithPath: gpuCache.sourcePath))

        let repaired = try await executor.execute(
            plan: plan,
            selectedItemIDs: [cache.id, gpuCache.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertEqual(repaired.state, .partial)
        XCTAssertEqual(repaired.operations.filter { $0.state == .moved }.count, 1)
        XCTAssertEqual(repaired.operations.filter { $0.state == .failed }.count, 1)

        let outcome = try await executor.restore(
            transactionID: repaired.transactionID,
            applicationIsRunning: false
        )

        guard case .restored(let restored) = outcome else {
            return XCTFail("Every backed-up item was restored, so the outcome must be .restored, got \(outcome)")
        }
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(restored.backupByteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: supportRoot.appendingPathComponent("Cache/payload.bin").path
        ))
    }

    // MARK: - Providers

    /// One invalid byte anywhere in the read window discarded the whole report
    /// while the provider still reported success.
    func testLegacyCrashReportSurvivesInvalidUTF8() throws {
        var bytes = Array("""
        Process:               Northstar [123]
        Identifier:            com.example.northstar
        Date/Time:             2026-01-15 06:00:00.000 -0500
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
        Application Specific Information:
        """.utf8)
        bytes.append(0xFF) // A lone Latin-1 byte, as real reports contain.
        bytes.append(contentsOf: Array("\nThread 0 Crashed:\n".utf8))

        let report = try XCTUnwrap(BoundedCrashReportParser().parse(
            data: Data(bytes),
            fileURL: URL(fileURLWithPath: "/tmp/Northstar.crash"),
            fallbackDate: .distantPast
        ))

        XCTAssertEqual(report.applicationName, "Northstar")
        XCTAssertEqual(report.bundleIdentifier, "com.example.northstar")
        XCTAssertEqual(report.signature, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertFalse(report.signature.contains("\u{FFFD}"), "Replacement characters must be sanitized away.")
    }

    /// `FileHandle(forReadingFrom:)` reports a denied open as Cocoa 513, which
    /// was not recognized, so an unreadable report was skipped as if absent.
    func testPermissionDenialIsRecognizedForBothCocoaCodesAndUnderlyingErrors() {
        let readDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let writeDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: 4,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)]
        )
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        for error in [readDenied, writeDenied, wrapped] {
            XCTAssertTrue(
                ProviderFailureReason.readFailure(error, source: "a report").contains("denied permission"),
                "Expected a denial for \(error.domain) \(error.code)"
            )
        }
        XCTAssertFalse(
            ProviderFailureReason.readFailure(unrelated, source: "a report").contains("denied permission")
        )
    }
}
