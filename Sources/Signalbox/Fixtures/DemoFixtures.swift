import Foundation

enum DemoFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00:00 UTC

    /// `at` is accepted for call-site symmetry but the demo deliberately stays
    /// fixed so screenshots, previews, and `--demo-mode` launches are repeatable.
    static func snapshot(at _: Date = referenceDate) -> SystemSnapshot {
        let date = referenceDate
        let reports = crashReports(at: date)
        let groups = CrashGrouper.groups(from: reports)
        let volumes = [demoVolume]
        let memory = demoMemory
        let running = runningApplications(at: date)
        let unavailable = [UnavailableEvidence(
            id: fixtureUUID(30),
            source: "System-wide diagnostic reports",
            reason: "Demo example: macOS privacy access was not granted.",
            collectedAt: date
        )]
        let generatedFindings = DiagnosisEngine().findings(
            volumes: volumes,
            memory: memory,
            crashGroups: groups,
            unavailableEvidence: unavailable,
            collectedAt: date
        )
        let stableFindings = generatedFindings.enumerated().map { index, finding in
            Finding(
                id: fixtureUUID(100 + index),
                title: finding.title,
                explanation: finding.explanation,
                severity: finding.severity,
                confidence: finding.confidence,
                evidenceSource: finding.evidenceSource,
                collectedAt: finding.collectedAt,
                recommendedNextStep: finding.recommendedNextStep,
                relatedEvidenceIDs: finding.relatedEvidenceIDs
            )
        }

        return SystemSnapshot(
            collectedAt: date,
            hostContext: demoHostContext,
            volumes: volumes,
            memory: memory,
            crashReports: reports,
            crashGroups: groups,
            runningApplications: running,
            unavailableEvidence: unavailable,
            evidence: [
                Evidence(
                    id: fixtureUUID(39),
                    title: "This Mac",
                    detail: "macOS 15.2.0 on Mac00,0 with 16 GB of memory.",
                    source: DiagnosticSource.host,
                    collectedAt: date
                ),
                Evidence(
                    id: fixtureUUID(40),
                    title: "Capacity for Macintosh HD",
                    detail: "8 GB available of 500 GB.",
                    source: DiagnosticSource.storage,
                    collectedAt: date,
                    attributes: ["mountPath": "/", "isInternal": "true"]
                ),
                Evidence(
                    id: fixtureUUID(41),
                    title: "Northstar crash pattern",
                    detail: "6 recent crash reports shared the signature “EXC_BAD_ACCESS · SIGSEGV”.",
                    source: DiagnosticSource.crashReports,
                    collectedAt: date,
                    attributes: ["count": "6"]
                ),
                Evidence(
                    id: fixtureUUID(42),
                    title: "Memory context",
                    detail: "A point-in-time context sample; low free memory alone is not treated as exhaustion.",
                    source: DiagnosticSource.memory,
                    collectedAt: date
                ),
                Evidence(
                    id: fixtureUUID(43),
                    title: "Unavailable evidence",
                    detail: unavailable[0].reason,
                    source: unavailable[0].source,
                    collectedAt: date
                )
            ],
            findings: stableFindings,
            isDemo: true
        )
    }

    static func applications(at _: Date = referenceDate) -> [InspectedApplication] {
        let reports = crashReports(at: referenceDate)
        return [
            InspectedApplication(
                name: "Northstar",
                bundleIdentifier: "com.example.northstar",
                version: "4.2.1",
                bundleURL: URL(fileURLWithPath: "/Applications/Northstar.app"),
                executableArchitecture: .available("Universal (Apple silicon, Intel 64-bit)"),
                codeSigningStatus: .available("Valid"),
                isRunning: true,
                iconFileURL: nil,
                matchingCrashReports: reports,
                suggestedRecipeIDs: ["electron-cache-only.northstar"],
                recipeEvidence: [
                    "A bundled cache-only recipe exactly matches this bundle identifier.",
                    "Six matching reports share a signature; this does not prove a cache fault."
                ]
            ),
            InspectedApplication(
                name: "Paper Lantern",
                bundleIdentifier: "com.example.paper-lantern",
                version: "2.0",
                bundleURL: URL(fileURLWithPath: "/Applications/Paper Lantern.app"),
                executableArchitecture: .available("Apple silicon"),
                codeSigningStatus: .available("Valid"),
                isRunning: false,
                iconFileURL: nil,
                matchingCrashReports: [],
                suggestedRecipeIDs: [],
                recipeEvidence: []
            )
        ]
    }

    static func crashReports(at date: Date = referenceDate) -> [CrashReportRecord] {
        [1, 4, 9, 16, 20, 23].enumerated().map { index, hoursAgo in
            CrashReportRecord(
                id: fixtureUUID(10 + index),
                applicationName: "Northstar",
                bundleIdentifier: "com.example.northstar",
                occurredAt: date.addingTimeInterval(TimeInterval(-hoursAgo * 3_600)),
                signature: "EXC_BAD_ACCESS · SIGSEGV",
                reportKind: "Crash",
                source: DiagnosticSource.crashReports
            )
        }
    }

    static func runningApplications(at date: Date = referenceDate) -> [RunningApplicationInfo] {
        [RunningApplicationInfo(
            id: "com.example.northstar",
            name: "Northstar",
            bundleIdentifier: "com.example.northstar",
            bundleURL: URL(fileURLWithPath: "/Applications/Northstar.app"),
            processIdentifier: 4_242,
            isActive: true,
            observedAt: date
        )]
    }

    /// Three fixed collections, three hours apart, ending at the reference
    /// date. They exercise every part of the timeline interface: a shrinking
    /// system volume, a report family that recurs across all three collections,
    /// and an evidence source that becomes unavailable and then recovers.
    static func timelineEntries() -> [SnapshotSummary] {
        let recurring = ReportGroupSummary(
            applicationIdentity: "bundle:com.example.northstar",
            applicationName: "Northstar",
            bundleIdentifier: "com.example.northstar",
            signature: "EXC_BAD_ACCESS · SIGSEGV",
            kind: .crash,
            count: 2,
            mostRecentAt: referenceDate.addingTimeInterval(-6 * 3_600)
        )
        let definitions: [(offsetHours: Int, availableGibibytes: Int64, groups: [ReportGroupSummary], unavailable: [String], severities: [String: Int])] = [
            (-6, 21, [recurring], [], ["notice": 1, "informational": 1]),
            (-3, 14, [
                ReportGroupSummary(
                    applicationIdentity: recurring.applicationIdentity,
                    applicationName: recurring.applicationName,
                    bundleIdentifier: recurring.bundleIdentifier,
                    signature: recurring.signature,
                    kind: .crash,
                    count: 4,
                    mostRecentAt: referenceDate.addingTimeInterval(-3 * 3_600)
                )
            ], ["System-wide diagnostic reports"], ["warning": 1, "notice": 2]),
            (0, 8, snapshot().crashGroups.map(ReportGroupSummary.init(group:)), ["System-wide diagnostic reports"], ["critical": 1, "warning": 1, "notice": 2])
        ]

        return definitions.enumerated().map { index, definition in
            SnapshotSummary(
                id: fixtureUUID(200 + index),
                collectedAt: referenceDate.addingTimeInterval(TimeInterval(definition.offsetHours * 3_600)),
                volumes: [VolumeSummary(
                    name: demoVolume.name,
                    mountPath: demoVolume.mountPath,
                    totalBytes: demoVolume.totalBytes,
                    availableBytes: definition.availableGibibytes * StorageHeadroomPolicy.gibibyte,
                    isInternal: true
                )],
                memory: MemorySummary(memory: demoMemory),
                reportGroups: definition.groups,
                unavailableSources: definition.unavailable,
                findingCountsBySeverity: definition.severities
            )
        }
    }

    /// A deliberately fictional model identifier so a screenshot of demo mode
    /// never suggests it describes the reader's own Mac.
    static let demoHostContext = HostContext(
        operatingSystemVersion: "15.2.0",
        operatingSystemBuild: .available("24C000"),
        hardwareModelIdentifier: .available("Mac00,0"),
        architecture: .available("Apple silicon (arm64)"),
        physicalMemoryBytes: 16 * 1_073_741_824,
        collectedAt: referenceDate
    )

    static let demoVolume = VolumeCapacity(
        id: "/",
        name: "Macintosh HD",
        mountPath: "/",
        totalBytes: 500 * StorageHeadroomPolicy.gibibyte,
        availableBytes: 8 * StorageHeadroomPolicy.gibibyte,
        isLocal: true,
        isInternal: true
    )

    static let demoMemory = MemoryStatistics(
        physicalBytes: 16 * 1_073_741_824,
        activeBytes: 6 * 1_073_741_824,
        inactiveBytes: 3 * 1_073_741_824,
        wiredBytes: 2 * 1_073_741_824,
        compressedBytes: 1 * 1_073_741_824,
        freeBytes: 4 * 1_073_741_824,
        pageSize: 16_384
    )

    private static func fixtureUUID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}
