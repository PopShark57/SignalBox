import Foundation

/// The already-selected, structured data that may be included in an exported report.
///
/// Keeping the selection separate from the exporter makes the privacy boundary explicit:
/// the exporter never reads diagnostic files or walks the file system.
/// The timeline facts that may be exported.
///
/// A `ReportRecurrence` carries a `correlationKey` built from the report
/// signature. That key stays inside the app: this type exists so the exporter
/// is handed only what is safe to publish, and the exporter never reads a
/// signature even indirectly.
struct ReportTimelineSection: Sendable, Equatable {
    let entryCount: Int
    let earliestCollectedAt: Date?
    let delta: SnapshotDelta?
    let recurrences: [ReportRecurrence]

    var isEmpty: Bool {
        entryCount == 0 && delta == nil && recurrences.isEmpty
    }
}

struct ReportExportPayload: Sendable {
    let generatedAt: Date
    let snapshot: SystemSnapshot?
    let applications: [InspectedApplication]
    let repairHistory: [BackupManifest]
    let timeline: ReportTimelineSection?
    /// True when the snapshot section was asked for but no snapshot exists yet.
    /// Without this the exporter cannot tell "the user deselected it" from
    /// "there is nothing to include", and would report the wrong one.
    let snapshotWasRequestedButUnavailable: Bool

    init(
        generatedAt: Date,
        snapshot: SystemSnapshot?,
        applications: [InspectedApplication] = [],
        repairHistory: [BackupManifest] = [],
        timeline: ReportTimelineSection? = nil,
        snapshotWasRequestedButUnavailable: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.snapshot = snapshot
        self.applications = applications
        self.repairHistory = repairHistory
        self.timeline = timeline
        self.snapshotWasRequestedButUnavailable = snapshotWasRequestedButUnavailable
    }
}

protocol ReportExporting: Sendable {
    func markdown(for payload: ReportExportPayload) -> String
}

/// Produces a Markdown report from Signalbox domain models only.
///
/// Raw diagnostic reports are intentionally not an input. Evidence details, evidence
/// attributes, crash signatures, diagnostic source paths, bundle paths, icon paths, and
/// repair operation paths are omitted because they can contain unrelated file names or
/// sensitive data.
struct ReportExporter: ReportExporting, Sendable {
    private let homeDirectoryPath: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeDirectoryPath = homeDirectory.standardizedFileURL.path
    }

    func markdown(for payload: ReportExportPayload) -> String {
        var lines: [String] = [
            "# Signalbox Diagnostic Report",
            "",
            "- Generated: \(date(payload.generatedAt))",
            "",
            "> Privacy note: This report contains structured Signalbox data only. Raw crash-report contents, crash signatures, and unrelated file names are not included. Home-directory paths are shown as `~`.",
            ""
        ]

        if let snapshot = payload.snapshot {
            appendSnapshot(snapshot, to: &lines)
        } else if payload.snapshotWasRequestedButUnavailable {
            lines.append("## System Snapshot")
            lines.append("")
            lines.append("The system snapshot was requested, but no collection had completed when this report was generated. This is an absence of evidence, not a clean result.")
            lines.append("")
        }

        if !payload.applications.isEmpty {
            appendApplications(payload.applications, to: &lines)
        }

        if let timeline = payload.timeline, !timeline.isEmpty {
            appendTimeline(timeline, to: &lines)
        }

        if !payload.repairHistory.isEmpty {
            appendRepairHistory(payload.repairHistory, to: &lines)
        }

        if payload.snapshot == nil,
           !payload.snapshotWasRequestedButUnavailable,
           payload.applications.isEmpty,
           payload.repairHistory.isEmpty,
           payload.timeline.map(\.isEmpty) ?? true {
            lines.append("No report sections were selected.")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func appendSnapshot(_ snapshot: SystemSnapshot, to lines: inout [String]) {
        lines.append("## System Snapshot")
        lines.append("")
        lines.append("- Collected: \(date(snapshot.collectedAt))")
        lines.append("- Data source: \(snapshot.isDemo ? "Deterministic demo fixtures" : "This Mac")")
        lines.append("")

        lines.append("### Host")
        lines.append("")
        if let host = snapshot.hostContext {
            // Model, OS, and architecture only. The serial number, hardware
            // UUID, host name, computer name, and user name are never
            // collected, so they cannot appear here.
            lines.append("- macOS version: \(safe(host.operatingSystemVersion))")
            lines.append("- macOS build: \(inspection(host.operatingSystemBuild))")
            lines.append("- Hardware model identifier: \(inspection(host.hardwareModelIdentifier))")
            lines.append("- Architecture: \(inspection(host.architecture))")
            lines.append("- Physical memory: \(bytes(host.physicalMemoryBytes))")
        } else {
            lines.append("Host description was unavailable for this snapshot.")
        }
        lines.append("")

        lines.append("### Local Volumes")
        lines.append("")
        let localVolumes = snapshot.volumes.filter(\.isLocal)
        if localVolumes.isEmpty {
            lines.append("No local-volume evidence was available.")
        } else {
            for volume in localVolumes {
                lines.append("- **\(safe(volume.name))** at \(inlineCode(volume.mountPath)): \(bytes(volume.availableBytes)) available of \(bytes(volume.totalBytes))")
            }
        }
        lines.append("")

        lines.append("### Memory Context")
        lines.append("")
        if let memory = snapshot.memory {
            lines.append("- Physical memory: \(bytes(memory.physicalBytes))")
            lines.append("- Active: \(bytes(memory.activeBytes)); inactive: \(bytes(memory.inactiveBytes)); wired: \(bytes(memory.wiredBytes)); compressed: \(bytes(memory.compressedBytes)); free: \(bytes(memory.freeBytes))")
            lines.append("- These values are context for this snapshot; low free memory alone does not prove memory exhaustion.")
        } else {
            lines.append("Memory evidence was unavailable for this snapshot.")
        }
        lines.append("")

        lines.append("### Findings")
        lines.append("")
        if snapshot.findings.isEmpty {
            lines.append("No findings were produced. This is not a guarantee that the Mac has no problems.")
            lines.append("")
        } else {
            for finding in snapshot.findings {
                lines.append("#### \(safe(finding.title))")
                lines.append("")
                lines.append("- Severity: \(label(finding.severity.rawValue))")
                lines.append("- Confidence: \(label(finding.confidence.rawValue))")
                lines.append("- Evidence source: \(safe(finding.evidenceSource))")
                lines.append("- Collected: \(date(finding.collectedAt))")
                lines.append("- Explanation: \(safe(finding.explanation, limit: 2_000))")
                if let nextStep = finding.recommendedNextStep, !nextStep.isEmpty {
                    lines.append("- Suggested next step: \(safe(nextStep, limit: 1_000))")
                }
                lines.append("")
            }
        }

        lines.append("### Evidence Index")
        lines.append("")
        if snapshot.evidence.isEmpty {
            lines.append("No evidence records were included.")
        } else {
            for evidence in snapshot.evidence {
                // Deliberately omit detail and attributes. Providers may use those fields to
                // retain private paths or other supporting context needed only inside the app.
                lines.append("- **\(safe(evidence.title))** — \(safe(evidence.source)), collected \(date(evidence.collectedAt))")
            }
        }
        lines.append("")

        // Families are listed separately and never totalled together: a hang is
        // not evidence of a crash, and a resource-limit notice is not a failure.
        let observedKinds = snapshot.observedReportKinds
        if observedKinds.isEmpty {
            lines.append("### Recent Diagnostic Reports")
            lines.append("")
            lines.append("No grouped recent diagnostic reports were observed in the selected snapshot.")
            lines.append("")
        } else {
            for kind in observedKinds {
                lines.append("### \(kind.sectionTitle)")
                lines.append("")
                lines.append(safe(kind.sectionCaption, limit: 400))
                lines.append("")
                for group in snapshot.groups(of: kind) {
                    let bundle = group.bundleIdentifier.map { " (\(safe($0)))" } ?? ""
                    let reportNoun = group.count == 1 ? "report" : "reports"
                    lines.append("- **\(safe(group.applicationName))**\(bundle): \(group.count) \(reportNoun); most recent \(date(group.mostRecentAt))")
                }
                lines.append("")
            }
        }

        lines.append("### Recently Running Applications")
        lines.append("")
        if snapshot.runningApplications.isEmpty {
            lines.append("No running-application evidence was available.")
        } else {
            for application in snapshot.runningApplications {
                let bundle = application.bundleIdentifier.map { " (\(safe($0)))" } ?? ""
                lines.append("- \(safe(application.name))\(bundle), observed \(date(application.observedAt))")
            }
        }
        lines.append("")

        lines.append("### Unavailable Evidence")
        lines.append("")
        if snapshot.unavailableEvidence.isEmpty {
            lines.append("All configured evidence sources reported a result.")
        } else {
            for unavailable in snapshot.unavailableEvidence {
                lines.append("- **\(safe(unavailable.source))** — \(safe(unavailable.reason, limit: 1_000)) (\(date(unavailable.collectedAt)))")
            }
        }
        lines.append("")
    }

    private func appendTimeline(_ timeline: ReportTimelineSection, to lines: inout [String]) {
        lines.append("## Snapshot Timeline")
        lines.append("")
        lines.append("> Signalbox stores a reduced summary of each collection on this Mac only. Running applications, report contents, file names, and provider messages are never recorded.")
        lines.append("")
        lines.append("- Collections recorded locally: \(timeline.entryCount)")
        if let earliest = timeline.earliestCollectedAt {
            lines.append("- Earliest recorded collection: \(date(earliest))")
        }
        lines.append("")

        lines.append("### Change Since the Previous Collection")
        lines.append("")
        if let delta = timeline.delta {
            lines.append("- Previous collection: \(date(delta.previousCollectedAt))")
            lines.append("- Elapsed: \(duration(delta.elapsed))")
            if let change = delta.systemVolumeAvailableByteChange {
                lines.append("- System-volume available capacity: \(signedBytes(change))")
            } else {
                lines.append("- System-volume available capacity: not comparable, because one of the two collections did not read the system volume")
            }
            lines.append("- Reports visible in the collection window: \(signedCount(delta.reportCountChange))")
            if !delta.newlyUnavailableSources.isEmpty {
                lines.append("- Newly unavailable evidence sources: \(delta.newlyUnavailableSources.map { safe($0) }.joined(separator: ", "))")
            }
            if !delta.resolvedUnavailableSources.isEmpty {
                lines.append("- Evidence sources that became available again: \(delta.resolvedUnavailableSources.map { safe($0) }.joined(separator: ", "))")
            }
            if delta.isUnchanged {
                lines.append("- Nothing Signalbox tracks changed between these two collections.")
            }
        } else {
            lines.append("Only one collection has been recorded, so there is nothing to compare yet.")
        }
        lines.append("")

        lines.append("### Recurring Across Collections")
        lines.append("")
        if timeline.recurrences.isEmpty {
            lines.append("No report pattern was observed in more than one collection. This is not a guarantee that nothing recurs.")
        } else {
            lines.append("Counts are not summed across collections, because each collection re-reads the same rolling window of reports.")
            lines.append("")
            for recurrence in timeline.recurrences {
                // The correlation key embeds the report signature and is
                // deliberately not exported.
                let bundle = recurrence.bundleIdentifier.map { " (\(safe($0)))" } ?? ""
                lines.append("- **\(safe(recurrence.applicationName))**\(bundle): the same \(recurrence.kind.noun) pattern appeared in \(recurrence.snapshotCount) collections; largest single-collection count \(recurrence.peakReportCount); most recent report \(date(recurrence.mostRecentReportAt))")
            }
        }
        lines.append("")
    }

    private func appendApplications(_ applications: [InspectedApplication], to lines: inout [String]) {
        lines.append("## Selected Applications")
        lines.append("")

        for application in applications {
            lines.append("### \(safe(application.name))")
            lines.append("")
            lines.append("- Bundle identifier: \(safe(application.bundleIdentifier))")
            lines.append("- Version: \(safe(application.version))")
            lines.append("- Executable architecture: \(inspection(application.executableArchitecture))")
            lines.append("- Code-signing status: \(inspection(application.codeSigningStatus))")
            lines.append("- Running when inspected: \(application.isRunning ? "Yes" : "No")")
            lines.append("- Matching recent crash reports: \(application.matchingCrashReports.count)")
            if !application.suggestedRecipeIDs.isEmpty {
                lines.append("- Suggested First Aid recipes: \(application.suggestedRecipeIDs.map { safe($0) }.joined(separator: ", "))")
            }
            if !application.recipeEvidence.isEmpty {
                lines.append("- Recipe evidence:")
                for evidence in application.recipeEvidence {
                    lines.append("  - \(safe(evidence, limit: 500))")
                }
            }
            lines.append("")
        }
    }

    private func appendRepairHistory(_ history: [BackupManifest], to lines: inout [String]) {
        lines.append("## Selected Repair History")
        lines.append("")

        for manifest in history {
            lines.append("### \(safe(manifest.targetApplicationName)) — \(date(manifest.creationDate))")
            lines.append("")
            lines.append("- Transaction: \(manifest.transactionID.uuidString.lowercased())")
            lines.append("- Bundle identifier: \(safe(manifest.targetBundleIdentifier))")
            lines.append("- Application version: \(safe(manifest.targetApplicationVersion))")
            lines.append("- Result: \(label(manifest.state.rawValue))")
            lines.append("- Items recorded: \(manifest.operations.count)")
            lines.append("- Items moved or restored: \(manifest.movedItemCount)")
            lines.append("- Backup size represented by manifest: \(bytes(manifest.backupByteCount))")
            lines.append("- Backup location: \(inlineCode(manifest.backupDirectoryPath))")
            if !manifest.errors.isEmpty {
                // Error strings often embed source paths. Export the count rather than those
                // free-form messages; the full manifest remains available in the backup.
                lines.append("- Recorded errors: \(manifest.errors.count) (details omitted for privacy)")
            }
            lines.append("- Operation states: \(operationStateSummary(manifest.operations))")
            lines.append("")
        }
    }

    private func operationStateSummary(_ operations: [RepairOperation]) -> String {
        let counts = Dictionary(grouping: operations, by: \.state).mapValues(\.count)
        let rendered = RepairOperationState.allCasesForReport.compactMap { state -> String? in
            guard let count = counts[state] else { return nil }
            return "\(label(state.rawValue)): \(count)"
        }
        return rendered.isEmpty ? "None" : rendered.joined(separator: "; ")
    }

    private func inspection(_ value: InspectionValue) -> String {
        switch value {
        case .available(let value):
            return safe(value)
        case .unavailable(let reason):
            return "Unavailable — \(safe(reason, limit: 500))"
        }
    }

    private func label(_ value: String) -> String {
        safe(value.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private func bytes<T: BinaryInteger>(_ value: T) -> String {
        let byteCount = max(0, Double(Int64(clamping: value)))
        let units = ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]
        guard byteCount >= 1_024 else {
            return "\(Int64(byteCount)) bytes"
        }

        var amount = byteCount
        var unitIndex = 0
        while amount >= 1_024, unitIndex < units.count - 1 {
            amount /= 1_024
            unitIndex += 1
        }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), amount, units[unitIndex])
    }

    private func signedBytes(_ value: Int64) -> String {
        guard value != 0 else { return "unchanged" }
        return "\(value > 0 ? "+" : "−")\(bytes(value.magnitude))"
    }

    private func signedCount(_ value: Int) -> String {
        guard value != 0 else { return "unchanged" }
        return "\(value > 0 ? "+" : "−")\(abs(value))"
    }

    private func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((max(0, interval) / 60).rounded())
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
        return parts.joined(separator: " ")
    }

    /// Wraps a value in a Markdown code span that cannot be escaped from.
    ///
    /// A backslash cannot neutralize a backtick here: CommonMark does not
    /// process backslash escapes *inside* a code span, so `` `a\`b` `` ends the
    /// span at the backslash-backtick and emits the rest as live Markdown. The
    /// only correct construction is to delimit with a longer run of backticks
    /// than any run the content contains, padding with spaces when the content
    /// itself starts or ends with one.
    ///
    /// This matters because a volume name is attacker-influenced: mounting a
    /// disk image named ``Setup`<img src=x onerror=…>`` would otherwise put raw
    /// HTML into a report the user is about to paste somewhere, and silently
    /// truncate the path that was supposed to be the evidence.
    private func inlineCode(_ value: String) -> String {
        let redacted = limited(redactHome(in: collapseWhitespace(value)), to: 1_000)
        let fence = String(repeating: "`", count: longestBacktickRun(in: redacted) + 1)
        let padding = (redacted.hasPrefix("`") || redacted.hasSuffix("`")) ? " " : ""
        return fence + padding + redacted + padding + fence
    }

    private func longestBacktickRun(in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func safe(_ value: String, limit: Int = 1_000) -> String {
        var result = redactHome(in: collapseWhitespace(value))
        for token in ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: token, with: "\\\(token)")
        }
        return limited(result, to: limit)
    }

    private func collapseWhitespace(_ value: String) -> String {
        let withoutControls = String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined())
        return withoutControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func redactHome(in value: String) -> String {
        guard !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" else { return value }

        // Replace every occurrence, not only slash-delimited paths. Structured
        // provider messages can contain punctuation immediately after the home
        // path (for example, "Owner: /Users/name."). Privacy is preferable to
        // preserving a rare longer string that merely shares this prefix.
        var redacted = value.replacingOccurrences(of: homeDirectoryPath, with: "~")

        let encodedHome = homeDirectoryPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? homeDirectoryPath
        redacted = redacted.replacingOccurrences(of: encodedHome, with: "~", options: [.caseInsensitive])
        return redacted
    }

    private func limited(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

private extension RepairOperationState {
    static let allCasesForReport: [RepairOperationState] = [
        .planned, .moved, .failed, .restoring, .restored, .restoreConflict, .skipped
    ]
}
