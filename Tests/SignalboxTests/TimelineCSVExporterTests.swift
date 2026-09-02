import Foundation
import XCTest
@testable import Signalbox

final class TimelineCSVExporterTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01T12:00:00Z
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    func testWritesOneRowPerCollectionOldestFirst() throws {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, availableGibibytes: 10),
            entry(offsetHours: -2, availableGibibytes: 30)
        ])

        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3, "A header and one row per collection.")
        XCTAssertEqual(rows[0], TimelineCSVExporter.columnHeaders.joined(separator: ","))
        XCTAssertTrue(rows[1].hasPrefix("\"2025-01-01T10:00:00Z\""))
        XCTAssertTrue(rows[2].hasPrefix("\"2025-01-01T12:00:00Z\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testAnUnreadValueIsAnEmptyCellAndNeverAZero() throws {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, availableGibibytes: nil, memory: nil)
        ])
        let row = try XCTUnwrap(csv.components(separatedBy: "\r\n").dropFirst().first)
        let cells = row.components(separatedBy: ",")

        let headers = TimelineCSVExporter.columnHeaders
        for column in [
            "system_volume_name",
            "system_volume_mount_path",
            "system_volume_total_bytes",
            "system_volume_available_bytes",
            "physical_memory_bytes",
            "free_memory_bytes",
            "compressed_memory_bytes"
        ] {
            let index = try XCTUnwrap(headers.firstIndex(of: column))
            XCTAssertEqual(
                cells[index],
                "",
                "\(column) was never read, and a spreadsheet would happily plot a zero."
            )
        }
    }

    func testNeverWritesAReportSignature() {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, signature: "SECRET_SIGNATURE_VALUE")
        ])

        XCTAssertFalse(csv.contains("SECRET_SIGNATURE_VALUE"))
        XCTAssertFalse(csv.contains("Northstar"), "Per-report identity is not part of the timeline export.")
    }

    func testRedactsTheHomeDirectoryFromVolumeText() {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, volumeName: "Image at /Users/alice/Disks/Scratch")
        ])

        XCTAssertTrue(csv.contains("\"Image at ~/Disks/Scratch\""))
        XCTAssertFalse(csv.contains("/Users/alice"))
    }

    /// A volume name is chosen by whoever mounts the disk, so it reaches the
    /// spreadsheet as untrusted text on both axes: the CSV grammar and the
    /// spreadsheet's own formula evaluator.
    func testQuotesAndDefusesAnAttackerChosenVolumeName() throws {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, volumeName: "=HYPERLINK(\"http://example.test\",\"Click\"),extra")
        ])
        let row = try XCTUnwrap(csv.components(separatedBy: "\r\n").dropFirst().first)

        XCTAssertTrue(
            row.contains("\"'=HYPERLINK(\"\"http://example.test\"\",\"\"Click\"\"),extra\""),
            "The name must stay one quoted cell, and must not open as a formula."
        )
        XCTAssertFalse(row.contains("\"=HYPERLINK"), "A cell must never begin with a live formula.")
    }

    func testNumericColumnsAreNotRoutedThroughTheTextEscaper() throws {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [
            entry(offsetHours: 0, availableGibibytes: 10)
        ])
        let row = try XCTUnwrap(csv.components(separatedBy: "\r\n").dropFirst().first)
        let cells = row.components(separatedBy: ",")
        let index = try XCTUnwrap(TimelineCSVExporter.columnHeaders.firstIndex(of: "system_volume_available_bytes"))

        XCTAssertEqual(cells[index], String(10 * StorageHeadroomPolicy.gibibyte))
    }

    func testCountsReportsAndFindingsWithoutMergingFamilies() throws {
        let summary = SnapshotSummary(
            collectedAt: referenceDate,
            volumes: [],
            memory: nil,
            reportGroups: [
                group(kind: .crash, count: 4),
                group(kind: .hang, count: 3)
            ],
            unavailableSources: ["Recent diagnostic reports", "Mounted local volumes"],
            findingCountsBySeverity: ["critical": 1, "warning": 2, "notice": 3, "informational": 4]
        )

        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [summary])
        let row = try XCTUnwrap(csv.components(separatedBy: "\r\n").dropFirst().first)
        let cells = row.components(separatedBy: ",")

        func cell(_ column: String) throws -> String {
            let index = try XCTUnwrap(TimelineCSVExporter.columnHeaders.firstIndex(of: column))
            return cells[index]
        }

        XCTAssertEqual(try cell("report_group_count"), "2")
        XCTAssertEqual(try cell("report_total_count"), "7")
        XCTAssertEqual(try cell("unavailable_source_count"), "2")
        XCTAssertEqual(try cell("findings_critical"), "1")
        XCTAssertEqual(try cell("findings_warning"), "2")
        XCTAssertEqual(try cell("findings_notice"), "3")
        XCTAssertEqual(try cell("findings_informational"), "4")
        XCTAssertTrue(row.contains("\"Mounted local volumes; Recent diagnostic reports\""))
    }

    func testAnEmptyTimelineStillWritesItsHeader() {
        let csv = TimelineCSVExporter(homeDirectory: home).csv(for: [])

        XCTAssertEqual(csv, TimelineCSVExporter.columnHeaders.joined(separator: ",") + "\r\n")
    }

    // MARK: - Fixtures

    private func group(kind: DiagnosticReportKind, count: Int, signature: String = "EXC_BAD_ACCESS") -> ReportGroupSummary {
        ReportGroupSummary(
            applicationIdentity: "bundle:com.example.northstar",
            applicationName: "Northstar",
            bundleIdentifier: "com.example.northstar",
            signature: signature,
            kind: kind,
            count: count,
            mostRecentAt: referenceDate
        )
    }

    private func entry(
        offsetHours: Int,
        availableGibibytes: Int64? = 20,
        memory: MemorySummary? = MemorySummary(memory: DemoFixtures.demoMemory),
        signature: String = "EXC_BAD_ACCESS",
        volumeName: String = "Macintosh HD",
        mountPath: String = "/"
    ) -> SnapshotSummary {
        SnapshotSummary(
            collectedAt: referenceDate.addingTimeInterval(TimeInterval(offsetHours * 3_600)),
            volumes: availableGibibytes.map { available in
                [VolumeSummary(
                    name: volumeName,
                    mountPath: mountPath,
                    totalBytes: 500 * StorageHeadroomPolicy.gibibyte,
                    availableBytes: available * StorageHeadroomPolicy.gibibyte,
                    isInternal: true
                )]
            } ?? [],
            memory: memory,
            reportGroups: [group(kind: .crash, count: 2, signature: signature)],
            unavailableSources: [],
            findingCountsBySeverity: [:]
        )
    }
}
