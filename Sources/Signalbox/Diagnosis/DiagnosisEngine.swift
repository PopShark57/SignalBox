import Foundation

enum DiagnosticSource {
    static let host = "macOS host description"
    static let storage = "Mounted local volumes"
    static let memory = "macOS virtual-memory statistics"
    static let crashReports = "Recent diagnostic reports"
    static let runningApplications = "macOS running applications"
    static let snapshotTimeline = "Signalbox snapshot timeline"
}

struct DiagnosisEngine: Sendable {
    let storagePolicy: StorageHeadroomPolicy

    init(storagePolicy: StorageHeadroomPolicy = StorageHeadroomPolicy()) {
        self.storagePolicy = storagePolicy
    }

    func findings(
        volumes: [VolumeCapacity],
        memory: MemoryStatistics?,
        crashGroups: [CrashGroup],
        unavailableEvidence: [UnavailableEvidence],
        collectedAt: Date
    ) -> [Finding] {
        var results: [Finding] = []
        let localVolumes = volumes.filter(\.isLocal)
        // Only pressure on an internal volume is a plausible contributor to
        // general application instability. A nearly full removable volume can
        // affect writes to that volume, but it is not evidence of system-disk
        // pressure.
        let pressuredVolumes = localVolumes.filter {
            $0.mountPath == "/" && storagePolicy.level(for: $0) >= .low
        }

        results.append(contentsOf: localVolumes.compactMap { storageFinding(for: $0, collectedAt: collectedAt) })

        if let memory {
            results.append(memoryFinding(for: memory, collectedAt: collectedAt))
        }

        results.append(contentsOf: crashGroups.compactMap { reportFinding(for: $0) })

        // A resource-limit notice is a usage observation, not a failure, so it
        // is deliberately excluded from the storage-pressure correlation.
        let recurringFailures = crashGroups.filter { $0.count >= 2 && $0.kind != .resourceLimit }
        if !pressuredVolumes.isEmpty, !recurringFailures.isEmpty {
            let families = Set(recurringFailures.map(\.kind))
                .sorted { $0.displayRank < $1.displayRank }
                .map { "\($0.noun) reports" }
                .joined(separator: " and ")
            results.append(Finding(
                title: "Storage pressure is a possible contributor",
                explanation: "Low available storage and recurring \(families) were observed in the same collection window. Storage pressure may be contributing to them; this is not proven.",
                severity: .warning,
                confidence: .possibleContributor,
                evidenceSource: "\(DiagnosticSource.storage) and \(DiagnosticSource.crashReports)",
                collectedAt: collectedAt,
                recommendedNextStep: "Create additional free space, then observe whether they continue before drawing a conclusion."
            ))
        }

        results.append(contentsOf: unavailableEvidence.map { unavailable in
            Finding(
                title: "Some evidence could not be inspected",
                explanation: "\(unavailable.source) was unavailable: \(unavailable.reason) Missing evidence is not treated as a healthy result.",
                severity: .notice,
                confidence: .observed,
                evidenceSource: unavailable.source,
                collectedAt: unavailable.collectedAt,
                recommendedNextStep: "Review macOS privacy access and try Refresh if you want Signalbox to inspect this source."
            )
        })

        return results.sorted {
            if $0.severity != $1.severity {
                return severityRank($0.severity) > severityRank($1.severity)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func storageFinding(for volume: VolumeCapacity, collectedAt: Date) -> Finding? {
        let available = byteCount(volume.availableBytes)
        let explanationSuffix = "\(storagePolicy.thresholdSummary) This is evidence of limited headroom, not proof of the cause of any crash."

        if volume.mountPath != "/" {
            switch storagePolicy.level(for: volume) {
            case .criticallyLow:
                return Finding(
                    title: "Very little storage remains on \(volume.name)",
                    explanation: "\(volume.name) has \(available) available. This may prevent new writes to that volume, but it does not imply pressure on the Mac's system volume. \(explanationSuffix)",
                    severity: .warning,
                    confidence: .observed,
                    evidenceSource: DiagnosticSource.storage,
                    collectedAt: collectedAt,
                    recommendedNextStep: "Create space on this volume before copying or saving large files to it."
                )
            case .low, .limited:
                return Finding(
                    title: "Storage headroom is limited on \(volume.name)",
                    explanation: "\(volume.name) has \(available) available. This may affect work saved to that volume; it is not evidence of system-volume pressure. \(explanationSuffix)",
                    severity: .notice,
                    confidence: .observed,
                    evidenceSource: DiagnosticSource.storage,
                    collectedAt: collectedAt,
                    recommendedNextStep: "Keep an eye on this volume before large transfers."
                )
            case .adequate:
                return nil
            }
        }

        switch storagePolicy.level(for: volume) {
        case .criticallyLow:
            return Finding(
                title: "Available storage is critically low",
                explanation: "\(volume.name) has \(available) available. This is low enough to cause application or system instability. \(explanationSuffix)",
                severity: .critical,
                confidence: .strongInference,
                evidenceSource: DiagnosticSource.storage,
                collectedAt: collectedAt,
                recommendedNextStep: "Safely create additional free space before starting storage-intensive work."
            )
        case .low:
            return Finding(
                title: "Available storage is low enough to cause application instability",
                explanation: "\(volume.name) has \(available) available. \(explanationSuffix)",
                severity: .warning,
                confidence: .possibleContributor,
                evidenceSource: DiagnosticSource.storage,
                collectedAt: collectedAt,
                recommendedNextStep: "Create additional free space and check whether the behavior changes."
            )
        case .limited:
            return Finding(
                title: "Storage headroom is becoming limited",
                explanation: "\(volume.name) has \(available) available. \(explanationSuffix)",
                severity: .notice,
                confidence: .observed,
                evidenceSource: DiagnosticSource.storage,
                collectedAt: collectedAt,
                recommendedNextStep: "Keep an eye on available space before large downloads or updates."
            )
        case .adequate:
            return nil
        }
    }

    private func memoryFinding(for memory: MemoryStatistics, collectedAt: Date) -> Finding {
        let reusable = memory.freeBytes.addingReportingOverflow(memory.inactiveBytes)
        let reusableBytes = reusable.overflow ? UInt64.max : reusable.partialValue
        let reusableFraction = memory.physicalBytes > 0
            ? Double(reusableBytes) / Double(memory.physicalBytes)
            : 1
        let compressedFraction = memory.physicalBytes > 0
            ? Double(memory.compressedBytes) / Double(memory.physicalBytes)
            : 0

        if reusableFraction < 0.05, compressedFraction > 0.20 {
            return Finding(
                title: "Memory conditions merit observation",
                explanation: "This point-in-time snapshot shows little immediately reusable memory and substantial compression. That can accompany memory pressure, but it does not prove an application exhausted memory or show whether pressure was sustained.",
                severity: .notice,
                confidence: .possibleContributor,
                evidenceSource: DiagnosticSource.memory,
                collectedAt: collectedAt,
                recommendedNextStep: "Use Activity Monitor's Memory Pressure graph while the problem is occurring for stronger evidence."
            )
        }

        return Finding(
            title: "No evidence of ordinary memory exhaustion was observed in this snapshot",
            explanation: "Immediately reusable memory was not exceptionally low under this heuristic. A single snapshot cannot rule out earlier or intermittent pressure, and low free memory alone is not treated as exhaustion.",
            severity: .informational,
            confidence: .observed,
            evidenceSource: DiagnosticSource.memory,
            collectedAt: collectedAt
        )
    }

    private func reportFinding(for group: CrashGroup) -> Finding? {
        guard group.count >= 2 else { return nil }

        // A resource-limit notice describes usage, not failure, so it never
        // escalates to a warning and its next step is worded accordingly.
        let isFailureFamily = group.kind != .resourceLimit
        let severity: Severity = (isFailureFamily && group.count >= 6) ? .warning : .notice
        let nextStep = isFailureFamily
            ? "Check for an app update and note what action preceded the next \(group.kind.noun)."
            : "Note what this app was doing at the time. Exceeding a budget is not by itself a malfunction."

        return Finding(
            title: "\(group.applicationName) produced recurring \(group.kind.noun) reports",
            explanation: "This application produced \(group.count) similar \(group.kind.displayName.lowercased()) reports with the same bounded signature. The recurrence is observed; the signature does not by itself prove the underlying cause.",
            severity: severity,
            confidence: .observed,
            evidenceSource: DiagnosticSource.crashReports,
            collectedAt: group.mostRecentAt,
            recommendedNextStep: nextStep
        )
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .informational: return 0
        case .notice: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }
}
