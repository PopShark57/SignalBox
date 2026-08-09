import Darwin
import Foundation

struct LiveDiagnosticReportProvider: DiagnosticReportProvider {
    private struct Candidate: Sendable {
        let url: URL
        let modifiedAt: Date
    }

    let reportDirectories: [URL]
    let maximumReports: Int
    let parser: BoundedCrashReportParser

    init(
        reportDirectories: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        ],
        maximumReports: Int = 200,
        maximumBytesPerReport: Int = 256 * 1_024
    ) {
        self.reportDirectories = reportDirectories
        self.maximumReports = max(1, maximumReports)
        self.parser = BoundedCrashReportParser(maximumBytes: maximumBytesPerReport)
    }

    func collectRecentReports(since date: Date, collectedAt: Date) async -> ProviderResult<[CrashReportRecord]> {
        await Task.detached(priority: .utility) {
            collectSynchronously(since: date)
        }.value
    }

    private func collectSynchronously(since date: Date) -> ProviderResult<[CrashReportRecord]> {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var candidates: [Candidate] = []

        for directory in reportDirectories {
            do {
                let urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
                for url in urls where ["ips", "crash"].contains(url.pathExtension.lowercased()) {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true else { continue }
                    let modifiedAt = values.contentModificationDate ?? .distantPast
                    if modifiedAt >= date {
                        candidates.append(Candidate(url: url, modifiedAt: modifiedAt))
                    }
                }
            } catch {
                let nsError = error as NSError
                let missingByCocoa = nsError.domain == NSCocoaErrorDomain
                    && (nsError.code == NSFileNoSuchFileError
                        || nsError.code == NSFileReadNoSuchFileError)
                let missingByPOSIX = nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
                if missingByCocoa || missingByPOSIX {
                    continue
                }
                return .unavailable(reason: ProviderFailureReason.readFailure(error, source: "recent diagnostic reports"))
            }
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        var reports: [CrashReportRecord] = []

        for candidate in candidates.prefix(maximumReports) {
            do {
                let handle = try FileHandle(forReadingFrom: candidate.url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: parser.maximumBytes) ?? Data()
                if let report = parser.parse(data: data, fileURL: candidate.url, fallbackDate: candidate.modifiedAt),
                   report.occurredAt >= date {
                    reports.append(report)
                }
            } catch {
                let reason = ProviderFailureReason.readFailure(error, source: "a recent diagnostic report")
                if reason.contains("denied permission") {
                    return .unavailable(reason: reason)
                }
                // A report may be replaced while the directory is being scanned.
                // Skip that file rather than retaining partial or raw content.
            }
        }

        return .available(reports.sorted { $0.occurredAt > $1.occurredAt })
    }
}
