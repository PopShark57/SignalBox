import Foundation

/// Turns a series of stored snapshot summaries into the two questions the
/// timeline exists to answer: *what changed since last time?* and *has this
/// happened before?*
///
/// Everything here is a pure function of the stored summaries, so the same
/// timeline always produces the same answer and the logic is testable without
/// touching the file system.
enum SnapshotTimelineAnalyzer {
    /// Compares the two most recent collections. Returns nil when fewer than
    /// two collections have been recorded — one snapshot is not a trend.
    static func delta(for entries: [SnapshotSummary]) -> SnapshotDelta? {
        let ordered = entries.sorted { $0.collectedAt < $1.collectedAt }
        guard ordered.count >= 2 else { return nil }
        let previous = ordered[ordered.count - 2]
        let current = ordered[ordered.count - 1]

        // Only report a capacity change when both collections actually saw the
        // system volume. A missing reading is unknown, not zero.
        let capacityChange: Int64?
        if let currentBytes = current.systemVolume?.availableBytes,
           let previousBytes = previous.systemVolume?.availableBytes {
            capacityChange = currentBytes.subtractingReportingOverflow(previousBytes).overflow
                ? nil
                : currentBytes - previousBytes
        } else {
            capacityChange = nil
        }

        let previousSources = Set(previous.unavailableSources)
        let currentSources = Set(current.unavailableSources)

        return SnapshotDelta(
            previousCollectedAt: previous.collectedAt,
            currentCollectedAt: current.collectedAt,
            systemVolumeAvailableByteChange: capacityChange,
            reportCountChange: totalReportCount(current) - totalReportCount(previous),
            newlyUnavailableSources: currentSources.subtracting(previousSources).sorted(),
            resolvedUnavailableSources: previousSources.subtracting(currentSources).sorted()
        )
    }

    /// Finds report families seen in at least `minimumSnapshots` distinct
    /// collections.
    ///
    /// Groups whose signature could not be read are excluded outright: without
    /// a signature there is nothing to correlate on, and claiming recurrence
    /// from an app name alone would invent a pattern.
    static func recurrences(
        in entries: [SnapshotSummary],
        minimumSnapshots: Int = 2
    ) -> [ReportRecurrence] {
        let threshold = max(2, minimumSnapshots)
        var accumulator: [String: Accumulator] = [:]

        for entry in entries.sorted(by: { $0.collectedAt < $1.collectedAt }) {
            // A family can appear once per snapshot at most; guard against a
            // malformed archive listing the same key twice in one entry.
            var seenInThisEntry: Set<String> = []
            for group in entry.reportGroups {
                guard !CrashGrouper.signatureIsUnavailable(group.signature, kind: group.kind) else { continue }
                let key = group.correlationKey
                guard seenInThisEntry.insert(key).inserted else { continue }
                accumulator[key, default: Accumulator(key: key, group: group, observedAt: entry.collectedAt)]
                    .absorb(group: group, observedAt: entry.collectedAt)
            }
        }

        return accumulator.values
            .filter { $0.snapshotCount >= threshold }
            .map(\.recurrence)
            .sorted {
                if $0.snapshotCount != $1.snapshotCount { return $0.snapshotCount > $1.snapshotCount }
                if $0.mostRecentReportAt != $1.mostRecentReportAt { return $0.mostRecentReportAt > $1.mostRecentReportAt }
                return $0.correlationKey < $1.correlationKey
            }
    }

    /// Findings for the Overview and the exported report.
    ///
    /// A recurrence across collections is stronger evidence than a single
    /// collection's count, because it survived a restart of the observation
    /// window. It is still only an observation of *recurrence*, never of cause,
    /// and the wording says so.
    static func findings(
        for recurrences: [ReportRecurrence],
        collectedAt: Date
    ) -> [Finding] {
        recurrences.map { recurrence in
            let isFailureFamily = recurrence.kind != .resourceLimit
            return Finding(
                title: "\(recurrence.applicationName) has repeated the same \(recurrence.kind.noun) pattern across snapshots",
                explanation: "Signalbox saw this bounded signature in \(recurrence.snapshotCount) separate collections, most recently \(recurrence.peakReportCount == 1 ? "once" : "up to \(recurrence.peakReportCount) times in one collection"). Recurrence across collections is observed; it still does not identify a cause.",
                severity: (isFailureFamily && recurrence.snapshotCount >= 4) ? .warning : .notice,
                confidence: .observed,
                evidenceSource: DiagnosticSource.snapshotTimeline,
                collectedAt: collectedAt,
                recommendedNextStep: isFailureFamily
                    ? "Check for an update to \(recurrence.applicationName), and note what you were doing before the next one."
                    : "Note what this app was doing when the budget was exceeded. A repeated notice is not by itself a malfunction."
            )
        }
    }

    private static func totalReportCount(_ entry: SnapshotSummary) -> Int {
        entry.reportGroups.reduce(0) { $0 + $1.count }
    }

    private struct Accumulator {
        let key: String
        private var applicationIdentity: String
        private var applicationName: String
        private var bundleIdentifier: String?
        private var kind: DiagnosticReportKind
        private(set) var snapshotCount = 0
        private var peakReportCount = 0
        private var firstObservedAt: Date
        private var lastObservedAt: Date
        private var mostRecentReportAt: Date

        init(key: String, group: ReportGroupSummary, observedAt: Date) {
            self.key = key
            applicationIdentity = group.applicationIdentity
            applicationName = group.applicationName
            bundleIdentifier = group.bundleIdentifier
            kind = group.kind
            firstObservedAt = observedAt
            lastObservedAt = observedAt
            mostRecentReportAt = group.mostRecentAt
        }

        mutating func absorb(group: ReportGroupSummary, observedAt: Date) {
            snapshotCount += 1
            peakReportCount = max(peakReportCount, group.count)
            firstObservedAt = min(firstObservedAt, observedAt)
            lastObservedAt = max(lastObservedAt, observedAt)
            mostRecentReportAt = max(mostRecentReportAt, group.mostRecentAt)
            // Prefer the newest display name so a renamed or relocalized app is
            // shown the way the user currently sees it.
            applicationName = group.applicationName
            bundleIdentifier = group.bundleIdentifier ?? bundleIdentifier
        }

        var recurrence: ReportRecurrence {
            ReportRecurrence(
                correlationKey: key,
                applicationIdentity: applicationIdentity,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                kind: kind,
                snapshotCount: snapshotCount,
                peakReportCount: peakReportCount,
                firstObservedAt: firstObservedAt,
                lastObservedAt: lastObservedAt,
                mostRecentReportAt: mostRecentReportAt
            )
        }
    }
}
