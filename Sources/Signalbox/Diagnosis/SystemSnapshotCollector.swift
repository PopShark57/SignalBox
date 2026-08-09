import Foundation

struct SystemSnapshotCollector: Sendable {
    private let hostProvider: any HostContextProvider
    private let diskProvider: any DiskHealthProvider
    private let memoryProvider: any MemoryContextProvider
    private let reportProvider: any DiagnosticReportProvider
    private let runningApplicationProvider: any RunningApplicationProvider
    private let diagnosisEngine: DiagnosisEngine

    init(
        hostProvider: any HostContextProvider = LiveHostContextProvider(),
        diskProvider: any DiskHealthProvider = LiveDiskHealthProvider(),
        memoryProvider: any MemoryContextProvider = LiveMemoryContextProvider(),
        reportProvider: any DiagnosticReportProvider = LiveDiagnosticReportProvider(),
        runningApplicationProvider: any RunningApplicationProvider = LiveRunningApplicationProvider(),
        diagnosisEngine: DiagnosisEngine = DiagnosisEngine()
    ) {
        self.hostProvider = hostProvider
        self.diskProvider = diskProvider
        self.memoryProvider = memoryProvider
        self.reportProvider = reportProvider
        self.runningApplicationProvider = runningApplicationProvider
        self.diagnosisEngine = diagnosisEngine
    }

    func collect(at date: Date = Date(), isDemo: Bool = false) async -> SystemSnapshot {
        if isDemo {
            return DemoFixtures.snapshot()
        }

        async let hostResult = hostProvider.collectHostContext(at: date)
        async let volumeResult = diskProvider.collectVolumes(at: date)
        async let memoryResult = memoryProvider.collectMemory(at: date)
        async let reportResult = reportProvider.collectRecentReports(
            since: date.addingTimeInterval(-24 * 60 * 60),
            collectedAt: date
        )
        async let runningResult = runningApplicationProvider.collectRunningApplications(at: date)

        let (hostContextResult, volumesResult, memoryContextResult, reportsResult, applicationsResult) = await (
            hostResult,
            volumeResult,
            memoryResult,
            reportResult,
            runningResult
        )

        var unavailable: [UnavailableEvidence] = []

        let hostContext: HostContext?
        switch hostContextResult {
        case .available(let value):
            hostContext = value
        case .unavailable(let reason):
            hostContext = nil
            unavailable.append(UnavailableEvidence(source: DiagnosticSource.host, reason: reason, collectedAt: date))
        }

        let volumes: [VolumeCapacity]
        switch volumesResult {
        case .available(let value):
            volumes = value
        case .unavailable(let reason):
            volumes = []
            unavailable.append(UnavailableEvidence(source: DiagnosticSource.storage, reason: reason, collectedAt: date))
        }

        let memory: MemoryStatistics?
        switch memoryContextResult {
        case .available(let value):
            memory = value
        case .unavailable(let reason):
            memory = nil
            unavailable.append(UnavailableEvidence(source: DiagnosticSource.memory, reason: reason, collectedAt: date))
        }

        let crashReports: [CrashReportRecord]
        switch reportsResult {
        case .available(let value):
            crashReports = value
        case .unavailable(let reason):
            crashReports = []
            unavailable.append(UnavailableEvidence(source: DiagnosticSource.crashReports, reason: reason, collectedAt: date))
        }

        let runningApplications: [RunningApplicationInfo]
        let runningApplicationsWereAvailable: Bool
        switch applicationsResult {
        case .available(let value):
            runningApplications = value
            runningApplicationsWereAvailable = true
        case .unavailable(let reason):
            runningApplications = []
            runningApplicationsWereAvailable = false
            unavailable.append(UnavailableEvidence(source: DiagnosticSource.runningApplications, reason: reason, collectedAt: date))
        }

        let crashGroups = CrashGrouper.groups(from: crashReports)
        let evidence = makeEvidence(
            hostContext: hostContext,
            volumes: volumes,
            memory: memory,
            crashGroups: crashGroups,
            runningApplications: runningApplications,
            runningApplicationsWereAvailable: runningApplicationsWereAvailable,
            unavailable: unavailable,
            collectedAt: date
        )
        let findings = diagnosisEngine.findings(
            volumes: volumes,
            memory: memory,
            crashGroups: crashGroups,
            unavailableEvidence: unavailable,
            collectedAt: date
        )

        return SystemSnapshot(
            collectedAt: date,
            hostContext: hostContext,
            volumes: volumes,
            memory: memory,
            crashReports: crashReports,
            crashGroups: crashGroups,
            runningApplications: runningApplications,
            unavailableEvidence: unavailable,
            evidence: evidence,
            findings: findings,
            isDemo: false
        )
    }

    private func makeEvidence(
        hostContext: HostContext?,
        volumes: [VolumeCapacity],
        memory: MemoryStatistics?,
        crashGroups: [CrashGroup],
        runningApplications: [RunningApplicationInfo],
        runningApplicationsWereAvailable: Bool,
        unavailable: [UnavailableEvidence],
        collectedAt: Date
    ) -> [Evidence] {
        var evidence: [Evidence] = []

        if let hostContext {
            evidence.append(Evidence(
                title: "This Mac",
                detail: "macOS \(hostContext.operatingSystemVersion) on \(hostContext.hardwareModelIdentifier.plainText) with \(ByteCountFormatter.string(fromByteCount: clampedInt64(hostContext.physicalMemoryBytes), countStyle: .memory)) of memory.",
                source: DiagnosticSource.host,
                collectedAt: hostContext.collectedAt
            ))
        }

        evidence += volumes.map { volume in
            return Evidence(
                title: "Capacity for \(volume.name)",
                detail: "\(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file)) available of \(ByteCountFormatter.string(fromByteCount: volume.totalBytes, countStyle: .file)).",
                source: DiagnosticSource.storage,
                collectedAt: collectedAt,
                attributes: [
                    "mountPath": volume.mountPath,
                    "isInternal": String(volume.isInternal)
                ]
            )
        }

        if let memory {
            evidence.append(Evidence(
                title: "Memory context",
                detail: "Physical \(ByteCountFormatter.string(fromByteCount: clampedInt64(memory.physicalBytes), countStyle: .memory)); compressed \(ByteCountFormatter.string(fromByteCount: clampedInt64(memory.compressedBytes), countStyle: .memory)); free \(ByteCountFormatter.string(fromByteCount: clampedInt64(memory.freeBytes), countStyle: .memory)).",
                source: DiagnosticSource.memory,
                collectedAt: collectedAt
            ))
        }

        evidence.append(contentsOf: crashGroups.map { group in
            // The placeholder text differs per family, so compare against this
            // group's own family rather than a hardcoded crash string.
            let signatureIsUnavailable = CrashGrouper.signatureIsUnavailable(
                group.signature,
                kind: group.kind
            )
            let detail: String
            if group.count > 1 {
                detail = "\(group.count) recent \(group.kind.noun) reports shared the same bounded signature."
            } else if signatureIsUnavailable {
                detail = "One recent \(group.kind.noun) report was observed, but no reliable recurring signature was available."
            } else {
                detail = "One recent \(group.kind.noun) report was observed. A single report is not treated as a recurring pattern."
            }
            return Evidence(
                title: "\(group.applicationName) \(group.kind.noun) pattern",
                detail: detail,
                source: DiagnosticSource.crashReports,
                collectedAt: collectedAt,
                attributes: ["count": String(group.count), "kind": group.kind.rawValue]
            )
        })

        if runningApplicationsWereAvailable {
            evidence.append(Evidence(
                title: "Currently running applications",
                detail: "Observed \(runningApplications.count) regular applications.",
                source: DiagnosticSource.runningApplications,
                collectedAt: collectedAt,
                attributes: ["count": String(runningApplications.count)]
            ))
        }

        evidence.append(contentsOf: unavailable.map { item in
            Evidence(
                title: "Unavailable evidence",
                detail: item.reason,
                source: item.source,
                collectedAt: item.collectedAt
            )
        })

        return evidence
    }

    private func clampedInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
