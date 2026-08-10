import Foundation

protocol TimelineCSVExporting: Sendable {
    func csv(for entries: [SnapshotSummary]) -> String
}

/// Writes the recorded snapshot timeline as RFC 4180 CSV so it can be graphed
/// in a spreadsheet without Signalbox growing a chart engine.
///
/// The privacy boundary is the same one the Markdown exporter enforces, and for
/// the same reasons:
///
/// - Report signatures are never written. A signature is the timeline's
///   internal correlation key, and `ReportGroupSummary` is reduced to counts
///   here rather than being listed row by row.
/// - Home-directory paths are redacted to `~`, because a volume can be mounted
///   inside the home directory.
/// - A value that was never read is written as an empty cell, never as `0`.
///   A spreadsheet plots a zero; it cannot plot "macOS refused access", and a
///   run of false zeroes is exactly the kind of invented evidence this
///   application refuses to produce.
///
/// Text cells are escaped for two separate consumers. CSV quoting protects the
/// file format; a leading `=`, `+`, `-`, `@`, tab, or carriage return is also
/// prefixed with an apostrophe so a spreadsheet does not evaluate a volume name
/// as a formula. Volume names are attacker-influenced — mounting a disk image
/// is enough to choose one — and a name beginning `=HYPERLINK(...)` should
/// remain a name when the report is opened. Numeric columns are emitted
/// directly and never routed through the text escaper, so a legitimate negative
/// number could never acquire a stray apostrophe.
struct TimelineCSVExporter: TimelineCSVExporting, Sendable {
    static let columnHeaders = [
        "collected_at",
        "system_volume_name",
        "system_volume_mount_path",
        "system_volume_total_bytes",
        "system_volume_available_bytes",
        "physical_memory_bytes",
        "free_memory_bytes",
        "compressed_memory_bytes",
        "report_group_count",
        "report_total_count",
        "unavailable_source_count",
        "unavailable_sources",
        "findings_critical",
        "findings_warning",
        "findings_notice",
        "findings_informational"
    ]

    private let homeDirectoryPath: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeDirectoryPath = homeDirectory.standardizedFileURL.path
    }

    /// Rows are ordered oldest-first so a spreadsheet's default plot reads left
    /// to right in time.
    func csv(for entries: [SnapshotSummary]) -> String {
        var rows = [Self.columnHeaders.joined(separator: ",")]
        for entry in entries.sorted(by: { $0.collectedAt < $1.collectedAt }) {
            rows.append(row(for: entry))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private func row(for entry: SnapshotSummary) -> String {
        let volume = entry.systemVolume
        let cells = [
            text(date(entry.collectedAt)),
            text(volume?.name),
            text(volume?.mountPath),
            number(volume?.totalBytes),
            number(volume?.availableBytes),
            number(entry.memory?.physicalBytes),
            number(entry.memory?.freeBytes),
            number(entry.memory?.compressedBytes),
            number(entry.reportGroups.count),
            number(entry.reportGroups.reduce(0) { $0 + $1.count }),
            number(entry.unavailableSources.count),
            text(entry.unavailableSources.sorted().joined(separator: "; ")),
            number(entry.findingCountsBySeverity[Severity.critical.rawValue] ?? 0),
            number(entry.findingCountsBySeverity[Severity.warning.rawValue] ?? 0),
            number(entry.findingCountsBySeverity[Severity.notice.rawValue] ?? 0),
            number(entry.findingCountsBySeverity[Severity.informational.rawValue] ?? 0)
        ]
        return cells.joined(separator: ",")
    }

    /// An unread value is an empty cell. See the type comment: it must not
    /// become a zero that a chart would happily draw.
    private func number<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return quoted(defusingFormula(redactHome(in: value)))
    }

    private func defusingFormula(_ value: String) -> String {
        guard let first = value.first else { return value }
        return "=+-@\t\r".contains(first) ? "'" + value : value
    }

    /// Always quoted. Unconditional quoting keeps the writer easy to audit and
    /// costs a few bytes; a conditional rule is one forgotten character class
    /// away from emitting a broken file.
    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func redactHome(in value: String) -> String {
        guard !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" else { return value }
        return value.replacingOccurrences(of: homeDirectoryPath, with: "~")
    }

    private func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }
}
