import Foundation

enum Severity: String, Codable, CaseIterable, Sendable {
    case informational
    case notice
    case warning
    case critical
}

enum Confidence: String, Codable, CaseIterable, Sendable {
    case observed
    case strongInference = "strong inference"
    case possibleContributor = "possible contributor"
}

struct Evidence: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let source: String
    let collectedAt: Date
    let attributes: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        source: String,
        collectedAt: Date,
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.collectedAt = collectedAt
        self.attributes = attributes
    }
}

struct Finding: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let explanation: String
    let severity: Severity
    let confidence: Confidence
    let evidenceSource: String
    let collectedAt: Date
    let recommendedNextStep: String?
    let relatedEvidenceIDs: [UUID]

    init(
        id: UUID = UUID(),
        title: String,
        explanation: String,
        severity: Severity,
        confidence: Confidence,
        evidenceSource: String,
        collectedAt: Date,
        recommendedNextStep: String? = nil,
        relatedEvidenceIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.severity = severity
        self.confidence = confidence
        self.evidenceSource = evidenceSource
        self.collectedAt = collectedAt
        self.recommendedNextStep = recommendedNextStep
        self.relatedEvidenceIDs = relatedEvidenceIDs
    }
}

struct VolumeCapacity: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let mountPath: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isLocal: Bool
    let isInternal: Bool
}

struct MemoryStatistics: Codable, Hashable, Sendable {
    let physicalBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let pageSize: UInt64
}

/// The diagnostic-report families Signalbox recognizes.
///
/// `.ips` is a container used by many macOS report families. Only families with
/// a distinct, defensible meaning are admitted; everything else is discarded by
/// the parser rather than being labelled as one of these. Families are never
/// merged with one another: a hang is not evidence of a crash.
enum DiagnosticReportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case crash
    case hang
    case resourceLimit

    var displayName: String {
        switch self {
        case .crash: "Crash"
        case .hang: "Hang"
        case .resourceLimit: "Resource limit"
        }
    }

    /// Lower-cased noun used inside sentences, e.g. "6 recent hang reports".
    var noun: String {
        switch self {
        case .crash: "crash"
        case .hang: "hang"
        case .resourceLimit: "resource-limit"
        }
    }

    var unavailableSignatureText: String {
        switch self {
        case .crash: "Crash signature unavailable"
        case .hang: "Hang signature unavailable"
        case .resourceLimit: "Resource-limit signature unavailable"
        }
    }

    /// Heading used wherever a family gets its own list.
    var sectionTitle: String {
        switch self {
        case .crash: "Recent Crash Activity"
        case .hang: "Recent Hang Reports"
        case .resourceLimit: "Recent Resource-Limit Reports"
        }
    }

    /// One sentence explaining what this family does and does not establish.
    var sectionCaption: String {
        switch self {
        case .crash:
            "A crash report records that a process stopped unexpectedly."
        case .hang:
            "A hang report records that an app stopped responding for a while. It does not establish why, and it is never counted as a crash."
        case .resourceLimit:
            "A resource-limit report records that macOS noticed a process exceeding a CPU, memory, or wakeup budget. It is a usage notice, not a failure."
        }
    }

    /// Display order for sections and reports.
    var displayRank: Int {
        switch self {
        case .crash: 0
        case .hang: 1
        case .resourceLimit: 2
        }
    }
}

struct CrashReportRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let applicationName: String
    let bundleIdentifier: String?
    let occurredAt: Date
    let signature: String
    let kind: DiagnosticReportKind
    let reportKind: String
    let source: String

    init(
        id: UUID = UUID(),
        applicationName: String,
        bundleIdentifier: String?,
        occurredAt: Date,
        signature: String,
        kind: DiagnosticReportKind = .crash,
        reportKind: String? = nil,
        source: String
    ) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.occurredAt = occurredAt
        self.signature = signature
        self.kind = kind
        self.reportKind = reportKind ?? kind.displayName
        self.source = source
    }
}

struct CrashGroup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    /// Bundle-first identity shared with `CrashGrouper`, so the same app still
    /// correlates after a rename or localization change.
    let applicationIdentity: String
    let applicationName: String
    let bundleIdentifier: String?
    let signature: String
    let count: Int
    let mostRecentAt: Date
    let kind: DiagnosticReportKind
    let reportKind: String

    init(
        id: String,
        applicationIdentity: String,
        applicationName: String,
        bundleIdentifier: String?,
        signature: String,
        count: Int,
        mostRecentAt: Date,
        kind: DiagnosticReportKind = .crash,
        reportKind: String? = nil
    ) {
        self.id = id
        self.applicationIdentity = applicationIdentity
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.signature = signature
        self.count = count
        self.mostRecentAt = mostRecentAt
        self.kind = kind
        self.reportKind = reportKind ?? kind.displayName
    }
}

struct RunningApplicationInfo: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let processIdentifier: Int32?
    let isActive: Bool
    let observedAt: Date
}

struct UnavailableEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let source: String
    let reason: String
    let collectedAt: Date

    init(id: UUID = UUID(), source: String, reason: String, collectedAt: Date) {
        self.id = id
        self.source = source
        self.reason = reason
        self.collectedAt = collectedAt
    }
}

/// Basic host identification shown alongside a snapshot and included in reports.
///
/// This is ordinary first-line context (OS build, model, architecture). It
/// deliberately excludes serial numbers, host names, user names, and anything
/// else that identifies the individual machine or its owner.
struct HostContext: Codable, Hashable, Sendable {
    let operatingSystemVersion: String
    let operatingSystemBuild: InspectionValue
    let hardwareModelIdentifier: InspectionValue
    let architecture: InspectionValue
    let physicalMemoryBytes: UInt64
    let collectedAt: Date
}

struct SystemSnapshot: Codable, Hashable, Sendable {
    let collectedAt: Date
    let hostContext: HostContext?
    let volumes: [VolumeCapacity]
    let memory: MemoryStatistics?
    let crashReports: [CrashReportRecord]
    let crashGroups: [CrashGroup]
    let runningApplications: [RunningApplicationInfo]
    let unavailableEvidence: [UnavailableEvidence]
    let evidence: [Evidence]
    let findings: [Finding]
    let isDemo: Bool

    init(
        collectedAt: Date,
        hostContext: HostContext? = nil,
        volumes: [VolumeCapacity],
        memory: MemoryStatistics?,
        crashReports: [CrashReportRecord],
        crashGroups: [CrashGroup],
        runningApplications: [RunningApplicationInfo],
        unavailableEvidence: [UnavailableEvidence],
        evidence: [Evidence],
        findings: [Finding],
        isDemo: Bool
    ) {
        self.collectedAt = collectedAt
        self.hostContext = hostContext
        self.volumes = volumes
        self.memory = memory
        self.crashReports = crashReports
        self.crashGroups = crashGroups
        self.runningApplications = runningApplications
        self.unavailableEvidence = unavailableEvidence
        self.evidence = evidence
        self.findings = findings
        self.isDemo = isDemo
    }

    /// Reports grouped by family, in a stable display order.
    func groups(of kind: DiagnosticReportKind) -> [CrashGroup] {
        crashGroups.filter { $0.kind == kind }
    }

    /// Only the families that actually produced a group, in display order. A
    /// family with no evidence is omitted rather than shown as an empty
    /// "all clear", which would imply Signalbox looked and found nothing wrong.
    var observedReportKinds: [DiagnosticReportKind] {
        DiagnosticReportKind.allCases
            .filter { kind in crashGroups.contains { $0.kind == kind } }
            .sorted { $0.displayRank < $1.displayRank }
    }
}

enum InspectionValue: Codable, Hashable, Sendable {
    case available(String)
    case unavailable(String)

    /// The value alone, with an unavailable reason reduced to a short marker.
    /// Use this inside a sentence; use the UI/export formatters when the reason
    /// itself should be shown to the reader.
    var plainText: String {
        switch self {
        case .available(let value): value
        case .unavailable: "an unreported model"
        }
    }

    private enum CodingKeys: String, CodingKey { case state, value }
    private enum State: String, Codable { case available, unavailable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available: self = .available(try container.decode(String.self, forKey: .value))
        case .unavailable: self = .unavailable(try container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let value):
            try container.encode(State.available, forKey: .state)
            try container.encode(value, forKey: .value)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .value)
        }
    }
}

struct InspectedApplication: Identifiable, Codable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let version: String
    let bundleURL: URL?
    let executableArchitecture: InspectionValue
    let codeSigningStatus: InspectionValue
    let isRunning: Bool
    let iconFileURL: URL?
    let matchingCrashReports: [CrashReportRecord]
    let suggestedRecipeIDs: [String]
    let recipeEvidence: [String]
}

enum ProviderResult<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(reason: String)
}
