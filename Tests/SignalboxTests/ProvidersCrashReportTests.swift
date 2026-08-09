import Foundation
import XCTest
@testable import Signalbox

final class ProvidersCrashReportTests: XCTestCase {
    func testIPSParserRetainsOnlyBoundedGroupingFields() throws {
        let data = Data("""
        {"app_name":"Northstar","timestamp":"2026-01-15T11:00:00Z","bundleID":"com.example.northstar","bug_type":"309"}
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"namespace":"SIGNAL"},"procPath":"/Users/private-name/Secret.app","threads":[{"frames":[{"symbol":"privateFunction"}]}]}
        """.utf8)
        let parser = BoundedCrashReportParser(maximumBytes: 16_384)

        let report = try XCTUnwrap(parser.parse(
            data: data,
            fileURL: URL(fileURLWithPath: "/Users/private-name/Northstar_2026-01-15.ips"),
            fallbackDate: .distantPast
        ))

        XCTAssertEqual(report.applicationName, "Northstar")
        XCTAssertEqual(report.bundleIdentifier, "com.example.northstar")
        XCTAssertEqual(report.signature, "EXC_BAD_ACCESS · SIGSEGV · SIGNAL")
        XCTAssertFalse(report.signature.contains("private-name"))
        XCTAssertFalse(report.source.contains("/Users/"))
    }

    func testLegacyParserBuildsSignatureWithoutRawThreadContent() throws {
        let data = Data("""
        Process:               Northstar [123]
        Identifier:            com.example.northstar
        Date/Time:             2026-01-15 06:00:00.000 -0500
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
        Termination Reason:    Namespace SIGNAL, Code 11
        Thread 0 Crashed:
        0 SecretFramework /Users/private-name/Documents/private-file
        """.utf8)

        let report = try XCTUnwrap(BoundedCrashReportParser().parse(
            data: data,
            fileURL: URL(fileURLWithPath: "/tmp/Northstar.crash"),
            fallbackDate: .distantPast
        ))

        XCTAssertEqual(report.signature, "EXC_BAD_ACCESS (SIGSEGV) · Namespace SIGNAL")
        XCTAssertFalse(report.signature.contains("private-file"))
    }

    func testIPSParserLabelsResourceLimitReportsAsTheirOwnFamily() throws {
        let data = Data("""
        {"app_name":"Northstar","timestamp":"2026-01-15T11:00:00Z","bundleID":"com.example.northstar","bug_type":"385"}
        {"procName":"Northstar","resourceException":{"limit":"CPU"}}
        """.utf8)

        let report = try XCTUnwrap(BoundedCrashReportParser().parse(
            data: data,
            fileURL: URL(fileURLWithPath: "/tmp/Northstar-resource.ips"),
            fallbackDate: .distantPast
        ))

        // Self-describing payload evidence outranks the numeric bug_type: a
        // payload carrying `resourceException` is a resource-limit report even
        // though 385 is in no family table.
        XCTAssertEqual(report.kind, .resourceLimit)
        XCTAssertEqual(report.reportKind, "Resource limit")
        XCTAssertNotEqual(report.kind, .crash, "A resource notice must never be labeled a crash.")
    }

    func testUnrecognizedIPSFamiliesAreDiscardedRatherThanGuessed() {
        let data = Data("""
        {"app_name":"Northstar","timestamp":"2026-01-15T11:00:00Z","bundleID":"com.example.northstar","bug_type":"999"}
        {"procName":"Northstar","somethingUnrelated":{"value":1}}
        """.utf8)

        let report = BoundedCrashReportParser().parse(
            data: data,
            fileURL: URL(fileURLWithPath: "/tmp/Northstar-unknown.ips"),
            fallbackDate: .distantPast
        )

        XCTAssertNil(report, "A family Signalbox cannot name must be discarded, never guessed at.")
    }

    func testHangReportsAreNeverMergedIntoCrashEvidence() throws {
        let data = Data("""
        {"app_name":"Northstar","timestamp":"2026-01-15T11:00:00Z","bundleID":"com.example.northstar","bug_type":"142"}
        {"procName":"Northstar","hangType":"Unresponsive UI"}
        """.utf8)
        let hang = try XCTUnwrap(BoundedCrashReportParser().parse(
            data: data,
            fileURL: URL(fileURLWithPath: "/tmp/Northstar-hang.ips"),
            fallbackDate: .distantPast
        ))
        XCTAssertEqual(hang.kind, .hang)

        // Same app, same signature text, different family: grouping must keep
        // them apart so a hang can never inflate a crash count.
        let crash = CrashReportRecord(
            applicationName: hang.applicationName,
            bundleIdentifier: hang.bundleIdentifier,
            occurredAt: hang.occurredAt,
            signature: hang.signature,
            kind: .crash,
            source: DiagnosticSource.crashReports
        )
        let groups = CrashGrouper.groups(from: [hang, crash])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.count), [1, 1])
        XCTAssertEqual(Set(groups.map(\.kind)), [.hang, .crash])
    }

    func testTruncatedIPSDetailsDoNotCreateCoarseReportTypeSignature() throws {
        let metadata = """
        {"app_name":"Northstar","timestamp":"2026-01-15T11:00:00Z","bundleID":"com.example.northstar","bug_type":"309"}
        """
        let truncatedDetails = """
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"threads":[{"frames":[
        """
        let parser = BoundedCrashReportParser(maximumBytes: 4_096)

        let report = try XCTUnwrap(parser.parse(
            data: Data((metadata + "\n" + truncatedDetails).utf8),
            fileURL: URL(fileURLWithPath: "/tmp/Northstar-truncated.ips"),
            fallbackDate: .distantPast
        ))

        XCTAssertEqual(report.signature, "Crash signature unavailable")
        XCTAssertFalse(report.signature.contains("309"))
        XCTAssertFalse(report.signature.contains("EXC_BAD_ACCESS"))
    }

    func testLiveProviderTreatsMissingDirectoryAsNoReports() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let provider = LiveDiagnosticReportProvider(reportDirectories: [missing])

        let result = await provider.collectRecentReports(since: .distantPast, collectedAt: Date())

        guard case .available(let reports) = result else {
            return XCTFail("A missing diagnostic-report directory should degrade to an empty result.")
        }
        XCTAssertTrue(reports.isEmpty)
    }
}
