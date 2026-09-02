import Foundation

/// A deliberately reduced, locally stored record of one collection.
///
/// Signalbox persists summaries rather than whole snapshots so the timeline can
/// answer "has this recurred?" without accumulating a behavioural log of the
/// Mac. Three exclusions are intentional and must stay excluded:
///
/// - Running applications. A dated list of what was open is an app-usage
///   history and is never needed to establish recurrence.
/// - Raw report content, file names, and paths. These never leave the parser.
/// - Free-form provider messages. Only the source name of an unavailable
///   evidence family is retained, not the failure text, which can embed paths.
struct SnapshotSummary: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    let collectedAt: Date
    let volumes: [VolumeSummary]
    let memory: MemorySummary?
    let reportGroups: [ReportGroupSummary]
    let unavailableSources: [String]
    let findingCountsBySeverity: [String: Int]
    let schemaVersion: Int

    init(
        id: UUID = UUID(),
        collectedAt: Date,
        volumes: [VolumeSummary],
        memory: MemorySummary?,
        reportGroups: [ReportGroupSummary],
        unavailableSources: [String],
        findingCountsBySeverity: [String: Int],
        schemaVersion: Int = SnapshotSummary.currentSchemaVersion
    ) {
        self.id = id
        self.collectedAt = collectedAt
        self.volumes = volumes
        self.memory = memory
        self.reportGroups = reportGroups
        self.unavailableSources = unavailableSources
        self.findingCountsBySeverity = findingCountsBySeverity
        self.schemaVersion = schemaVersion
    }

    /// Derives a summary from a collected snapshot. Demo snapshots are never
    /// recorded by the store, but the transform itself stays pure and testable.
    init(snapshot: SystemSnapshot) {
        self.init(
            collectedAt: snapshot.collectedAt,
            volumes: snapshot.volumes.filter(\.isLocal).map(VolumeSummary.init(volume:)),
            memory: snapshot.memory.map(MemorySummary.init(memory:)),
            reportGroups: snapshot.crashGroups.map(ReportGroupSummary.init(group:)),
            unavailableSources: snapshot.unavailableEvidence.map(\.source).sorted(),
            findingCountsBySeverity: Dictionary(
                snapshot.findings.map { ($0.severity.rawValue, 1) },
                uniquingKeysWith: +
            )
        )
    }

    var systemVolume: VolumeSummary? {
        volumes.first { $0.mountPath == "/" }
    }
}

struct VolumeSummary: Codable, Hashable, Sendable {
    let name: String
    let mountPath: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isInternal: Bool

    init(volume: VolumeCapacity) {
        name = volume.name
        mountPath = volume.mountPath
        totalBytes = volume.totalBytes
        availableBytes = volume.availableBytes
        isInternal = volume.isInternal
    }

    init(name: String, mountPath: String, totalBytes: Int64, availableBytes: Int64, isInternal: Bool) {
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isInternal = isInternal
    }

    var capacity: VolumeCapacity {
        VolumeCapacity(
            id: mountPath,
            name: name,
            mountPath: mountPath,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            isLocal: true,
            isInternal: isInternal
        )
    }
}

struct MemorySummary: Codable, Hashable, Sendable {
    let physicalBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let inactiveBytes: UInt64

    init(memory: MemoryStatistics) {
        physicalBytes = memory.physicalBytes
        compressedBytes = memory.compressedBytes
        freeBytes = memory.freeBytes
        inactiveBytes = memory.inactiveBytes
    }

    init(physicalBytes: UInt64, compressedBytes: UInt64, freeBytes: UInt64, inactiveBytes: UInt64) {
        self.physicalBytes = physicalBytes
        self.compressedBytes = compressedBytes
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
    }
}

/// The identity of a grouped report family within one snapshot.
///
/// `applicationIdentity` is the same bundle-first identity `CrashGrouper` uses,
/// so a renamed or localized app still correlates across snapshots.
struct ReportGroupSummary: Codable, Hashable, Sendable {
    let applicationIdentity: String
    let applicationName: String
    let bundleIdentifier: String?
    let signature: String
    let kind: DiagnosticReportKind
    let count: Int
    let mostRecentAt: Date

    init(group: CrashGroup) {
        applicationIdentity = group.applicationIdentity
        applicationName = group.applicationName
        bundleIdentifier = group.bundleIdentifier
        signature = group.signature
        kind = group.kind
        count = group.count
        mostRecentAt = group.mostRecentAt
    }

    init(
        applicationIdentity: String,
        applicationName: String,
        bundleIdentifier: String?,
        signature: String,
        kind: DiagnosticReportKind,
        count: Int,
        mostRecentAt: Date
    ) {
        self.applicationIdentity = applicationIdentity
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.signature = signature
        self.kind = kind
        self.count = count
        self.mostRecentAt = mostRecentAt
    }

    /// Correlation key. Unavailable signatures are never correlated, so callers
    /// must filter them out before grouping across snapshots.
    var correlationKey: String {
        [applicationIdentity, signature.lowercased(), kind.rawValue].joined(separator: "|")
    }
}

/// The on-disk envelope. Keeping the version outside the entries lets a future
/// reader reject or migrate a whole archive rather than guessing per entry.
struct SnapshotTimelineArchive: Codable, Sendable {
    let schemaVersion: Int
    var entries: [SnapshotSummary]

    init(schemaVersion: Int = SnapshotSummary.currentSchemaVersion, entries: [SnapshotSummary] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

/// A change between the two most recent snapshots, shown on Overview.
struct SnapshotDelta: Hashable, Sendable {
    let previousCollectedAt: Date
    let currentCollectedAt: Date
    let systemVolumeAvailableByteChange: Int64?
    let reportCountChange: Int
    let newlyUnavailableSources: [String]
    let resolvedUnavailableSources: [String]

    var elapsed: TimeInterval {
        currentCollectedAt.timeIntervalSince(previousCollectedAt)
    }

    /// True when nothing Signalbox tracks moved between the two collections.
    /// A missing system-volume reading is unknown, not zero, so it is never
    /// treated as unchanged.
    var isUnchanged: Bool {
        systemVolumeAvailableByteChange == 0
            && reportCountChange == 0
            && newlyUnavailableSources.isEmpty
            && resolvedUnavailableSources.isEmpty
    }
}

/// One system-volume capacity reading taken from a recorded collection.
struct CapacityReading: Hashable, Sendable {
    let collectedAt: Date
    let availableBytes: Int64
    let totalBytes: Int64
}

/// How the system volume's available capacity moved across the recorded
/// collections.
///
/// This is a count of observed movements, never a rate and never a projection.
/// Signalbox is refreshed by hand, so the gaps between collections are
/// arbitrary: "fell in four of five intervals" says nothing about how fast it
/// fell, and nothing about what happens next. Deriving GB-per-day from
/// unevenly spaced, user-triggered samples would be exactly the kind of
/// confident-sounding number this application exists to avoid.
///
/// An interval whose two collections did not both read the system volume is
/// counted as *not comparable*. It is never folded into "unchanged", because a
/// missing reading is unknown, not zero.
struct CapacityTrend: Hashable, Sendable {
    /// The canonical caveat. Both the interface and the exported report use
    /// this exact sentence, so the two can never drift apart.
    static let samplingCaveat = "Collections are triggered by hand, so these intervals are not evenly spaced. This counts observed movements; it is not a rate of change and not a prediction."

    /// Collections that carried a system-volume reading.
    let readingCount: Int
    let fallingIntervalCount: Int
    let risingIntervalCount: Int
    let unchangedIntervalCount: Int
    /// Intervals where at least one of the two collections did not read the
    /// system volume.
    let notComparableIntervalCount: Int
    let firstReading: CapacityReading
    let latestReading: CapacityReading
    let lowestReading: CapacityReading
    let highestReading: CapacityReading
    /// Latest reading minus the first, or nil if that subtraction would
    /// overflow because the archive holds implausible values.
    let netChangeBytes: Int64?

    var comparableIntervalCount: Int {
        fallingIntervalCount + risingIntervalCount + unchangedIntervalCount
    }

    var observedSpan: TimeInterval {
        latestReading.collectedAt.timeIntervalSince(firstReading.collectedAt)
    }
}

/// One report family that has been observed across more than one collection.
///
/// Counts are deliberately **not** summed across snapshots. Each collection
/// re-reads the same rolling window of report files, so the same underlying
/// report is normally present in several consecutive snapshots. Adding those
/// counts together would manufacture a large, false total. What is genuinely
/// new information is *how many separate collections* saw the pattern, so that
/// is what Signalbox reports, alongside the largest single-collection count.
struct ReportRecurrence: Identifiable, Hashable, Sendable {
    var id: String { correlationKey }

    let correlationKey: String
    let applicationIdentity: String
    let applicationName: String
    let bundleIdentifier: String?
    let kind: DiagnosticReportKind
    /// Number of distinct collections in which this pattern appeared.
    let snapshotCount: Int
    /// The largest count seen within any single collection.
    let peakReportCount: Int
    let firstObservedAt: Date
    let lastObservedAt: Date
    let mostRecentReportAt: Date

    /// How long the pattern has been visible to Signalbox.
    var observedSpan: TimeInterval {
        lastObservedAt.timeIntervalSince(firstObservedAt)
    }
}
