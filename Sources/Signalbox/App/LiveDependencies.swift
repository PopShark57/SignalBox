import AppKit
import Foundation

@MainActor
extension SignalboxDependencies {
    static func production() -> SignalboxDependencies {
        let collector = SystemSnapshotCollector()
        let catalog = LiveApplicationCatalogProvider()
        let data = SignalboxDataClient { requestedAt, demoMode in
            if demoMode {
                return SignalboxLoadResult(
                    snapshot: DemoFixtures.snapshot(),
                    applications: DemoFixtures.applications()
                )
            }

            let collectedSnapshot = await collector.collect(at: requestedAt, isDemo: false)
            let collectedApplications = await catalog.collectApplications(
                at: requestedAt,
                runningApplications: collectedSnapshot.runningApplications,
                crashes: collectedSnapshot.crashReports
            )
            let applications: [InspectedApplication]
            let finalSnapshot: SystemSnapshot
            switch collectedApplications {
            case .available(let value):
                applications = value
                finalSnapshot = collectedSnapshot
            case .unavailable(let reason):
                applications = []
                finalSnapshot = collectedSnapshot.addingUnavailableEvidence(
                    source: "Installed application catalog",
                    reason: reason,
                    collectedAt: requestedAt
                )
            }
            return SignalboxLoadResult(snapshot: finalSnapshot, applications: applications)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let backupRoot = applicationSupport
            .appendingPathComponent("Signalbox", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        let timelineStore = SnapshotTimelineStore(
            directoryURL: applicationSupport
                .appendingPathComponent("Signalbox", isDirectory: true)
                .appendingPathComponent("Timeline", isDirectory: true)
        )
        let backupStore = BackupStore(
            rootURL: backupRoot,
            authorizedApplicationSupportParentURL: applicationSupport,
            authorizedUserCachesRootURL: caches
        )
        let planner = RepairPlanner(backupRootURL: backupRoot)
        let executor = RepairExecutor(
            backupStore: backupStore,
            applicationRunningCheck: { bundleIdentifier in
                await MainActor.run {
                    !NSRunningApplication.runningApplications(
                        withBundleIdentifier: bundleIdentifier
                    ).isEmpty
                }
            }
        )
        let liveRepairs = SignalboxRepairClient(
            availableRecipes: { application in
                RepairRecipeCatalog.recipe(for: application.bundleIdentifier).map { [$0] } ?? []
            },
            makePlan: { application, recipe, createdAt in
                try await planner.makePlan(
                    for: application,
                    recipe: recipe,
                    supportRoot: .recipeResolved(applicationSupportParentURL: applicationSupport),
                    userCachesRootURL: caches,
                    createdAt: createdAt,
                    suggestionReason: application.recipeEvidence.first ?? recipe.rationale
                )
            },
            history: { try await executor.reconciledHistory() },
            execute: { plan, selectedIDs, isRunning, version in
                try await executor.execute(
                    plan: plan,
                    selectedItemIDs: selectedIDs,
                    applicationIsRunning: isRunning,
                    signalboxVersion: version
                )
            },
            restore: { transactionID, isRunning, choice in
                try await executor.restore(
                    transactionID: transactionID,
                    applicationIsRunning: isRunning,
                    destinationPolicy: choice == .originalOnly ? .originalOnly : .suggestedAlternate
                )
            }
        )

        return SignalboxDependencies(
            data: data,
            liveRepairs: liveRepairs,
            demoRepairs: DemoRepairStore.client(),
            liveTimeline: .store(timelineStore),
            demoTimeline: .demo(),
            applications: .workspace,
            reportExporter: ReportExporter(),
            clock: { Date() },
            defaults: .standard,
            processInfo: .processInfo
        )
    }
}

private extension SystemSnapshot {
    /// Adds a source that failed *after* the snapshot was assembled.
    ///
    /// The matching `Finding` is added too. Without it the Overview would list
    /// the source under "Unavailable Evidence" while the Findings card stayed
    /// silent, which reads as "we looked and everything was fine".
    func addingUnavailableEvidence(source: String, reason: String, collectedAt: Date) -> SystemSnapshot {
        let unavailable = UnavailableEvidence(source: source, reason: reason, collectedAt: collectedAt)
        let unavailableRecord = Evidence(
            title: "Unavailable evidence",
            detail: reason,
            source: source,
            collectedAt: collectedAt
        )
        let unavailableFinding = Finding(
            title: "Some evidence could not be inspected",
            explanation: "\(source) was unavailable: \(reason) Missing evidence is not treated as a healthy result.",
            severity: .notice,
            confidence: .observed,
            evidenceSource: source,
            collectedAt: collectedAt,
            recommendedNextStep: "Review macOS privacy access and try Refresh if you want Signalbox to inspect this source."
        )
        return SystemSnapshot(
            collectedAt: self.collectedAt,
            hostContext: hostContext,
            volumes: volumes,
            memory: memory,
            crashReports: crashReports,
            crashGroups: crashGroups,
            runningApplications: runningApplications,
            unavailableEvidence: unavailableEvidence + [unavailable],
            evidence: evidence + [unavailableRecord],
            findings: findings + [unavailableFinding],
            isDemo: isDemo
        )
    }
}
