import Combine
import Foundation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview
    case applications
    case repairHistory
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .applications: "Apps"
        case .repairHistory: "Repair History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .applications: "app.dashed"
        case .repairHistory: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct AppIssue: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct RestoreConflictPresentation: Identifiable, Equatable {
    let id = UUID()
    let transactionID: UUID
    let originalPath: String
    let suggestedAlternatePath: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: SidebarDestination = .overview
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var applications: [InspectedApplication] = []
    @Published private(set) var repairHistory: [BackupManifest] = []
    @Published var selectedApplicationID: String?
    @Published var applicationSearchText = ""
    @Published var showsOnlyActionableApplications = false
    @Published private(set) var recipesByBundleIdentifier: [String: [RepairRecipe]] = [:]

    @Published private(set) var isRefreshing = false
    @Published private(set) var isPreparingRepair = false
    @Published private(set) var isExecutingRepair = false
    @Published private(set) var isRestoring = false
    @Published private(set) var lastRefreshedAt: Date?

    @Published var repairPlan: RepairPlan?
    @Published var selectedRepairItemIDs: Set<UUID> = []
    @Published var hasConfirmedRepair = false

    @Published var restoreManifest: BackupManifest?
    @Published var hasConfirmedRestore = false
    @Published var restoreConflict: RestoreConflictPresentation?

    @Published var issue: AppIssue?
    @Published private(set) var isDemoMode: Bool
    @Published private var demoClosedBundleIdentifiers: Set<String> = []

    /// Locally recorded collections, oldest first, and what they imply.
    @Published private(set) var timeline: [SnapshotSummary] = []
    @Published private(set) var snapshotDelta: SnapshotDelta?
    @Published private(set) var recurrences: [ReportRecurrence] = []
    /// Why the timeline is empty, when the reason is a failure rather than a
    /// first run. Shown in place of the timeline, never as a modal alert.
    @Published private(set) var timelineUnavailableReason: String?

    @Published var isShowingReportPreview = false
    @Published var reportIncludesSnapshot = true
    @Published var reportIncludesTimeline = true
    @Published var reportApplicationIDs: Set<String> = []
    @Published var reportTransactionIDs: Set<UUID> = []
    @Published private(set) var reportGeneratedAt: Date?

    private let dependencies: SignalboxDependencies
    private var refreshGeneration = UUID()
    private var activeLoadTask: Task<SignalboxLoadResult, Never>?

    init(dependencies: SignalboxDependencies) {
        self.dependencies = dependencies
        isDemoMode = DemoModePreference.initialValue(
            processInfo: dependencies.processInfo,
            defaults: dependencies.defaults
        )
    }

    var selectedApplication: InspectedApplication? {
        guard let selectedApplicationID else { return nil }
        return applications.first { $0.id == selectedApplicationID }
    }

    /// The list after the search text and the "actionable only" filter.
    ///
    /// A live catalog is routinely 100+ apps, so without this the Apps screen
    /// is unusable for the case it exists to serve: finding the one app that is
    /// misbehaving.
    var visibleApplications: [InspectedApplication] {
        let query = applicationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return applications.filter { application in
            if showsOnlyActionableApplications,
               application.suggestedRecipeIDs.isEmpty,
               application.matchingCrashReports.isEmpty {
                return false
            }
            guard !query.isEmpty else { return true }
            return application.name.localizedCaseInsensitiveContains(query)
                || application.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var applicationFilterSummary: String {
        let visible = visibleApplications.count
        let total = applications.count
        if total == 0 { return "No applications were inspected." }
        if visible == total { return "\(total) apps inspected." }
        return "Showing \(visible) of \(total) inspected apps."
    }

    var selectedApplicationRecipes: [RepairRecipe] {
        guard let selectedApplication else { return [] }
        return recipesByBundleIdentifier[selectedApplication.bundleIdentifier] ?? []
    }

    var selectedRepairByteCount: Int64 {
        guard let repairPlan else { return 0 }
        return repairPlan.items
            .filter { selectedRepairItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.byteCount }
    }

    var canExecuteRepair: Bool {
        guard let repairPlan else { return false }
        return hasConfirmedRepair
            && !selectedRepairItemIDs.isEmpty
            && !isApplicationRunning(bundleIdentifier: repairPlan.targetApplication.bundleIdentifier)
            && !isExecutingRepair
    }

    var canRestore: Bool {
        guard let restoreManifest else { return false }
        return hasConfirmedRestore
            && !isApplicationRunning(bundleIdentifier: restoreManifest.targetBundleIdentifier)
            && !isRestoring
    }

    /// Findings derived from the timeline rather than from this collection.
    /// They are kept separate from `snapshot.findings` because their evidence
    /// source is different and a reader should be able to tell them apart.
    var timelineFindings: [Finding] {
        SnapshotTimelineAnalyzer.findings(
            for: recurrences,
            collectedAt: snapshot?.collectedAt ?? dependencies.clock()
        )
    }

    var reportMarkdown: String {
        let generatedAt = reportGeneratedAt ?? dependencies.clock()
        let selectedApplications = applications.filter { reportApplicationIDs.contains($0.id) }
        let selectedHistory = repairHistory.filter { reportTransactionIDs.contains($0.transactionID) }
        return dependencies.reportExporter.markdown(
            for: ReportExportPayload(
                generatedAt: generatedAt,
                snapshot: reportIncludesSnapshot ? snapshot : nil,
                applications: selectedApplications,
                repairHistory: selectedHistory,
                timeline: reportIncludesTimeline
                    ? ReportTimelineSection(
                        entryCount: timeline.count,
                        earliestCollectedAt: timeline.first?.collectedAt,
                        delta: snapshotDelta,
                        recurrences: recurrences
                    )
                    : nil,
                snapshotWasRequestedButUnavailable: reportIncludesSnapshot && snapshot == nil
            )
        )
    }

    var signalboxVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    func start() async {
        guard snapshot == nil else { return }
        await refresh()
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        isRefreshing = true

        let requestedAt = dependencies.clock()
        let repairClient = currentRepairClient
        activeLoadTask?.cancel()
        let loadTask = Task {
            await dependencies.data.load(requestedAt, isDemoMode)
        }
        activeLoadTask = loadTask
        let loaded = await loadTask.value

        guard generation == refreshGeneration else { return }
        activeLoadTask = nil
        snapshot = loaded.snapshot
        applications = loaded.applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        lastRefreshedAt = loaded.snapshot.collectedAt

        if let selectedApplicationID,
           !applications.contains(where: { $0.id == selectedApplicationID }) {
            self.selectedApplicationID = nil
        }
        if selectedApplicationID == nil {
            selectedApplicationID = applications.first?.id
        }

        await recordAndReloadTimeline(for: loaded.snapshot)
        guard generation == refreshGeneration else { return }

        // Every publishing write below follows an `await`, so each one needs its
        // own staleness check. Without them a slow live refresh could resume
        // after a fast demo refresh had already finished and overwrite demo
        // state with the user's real recipes and backup manifests — mixing a
        // real transaction list into an interface still labelled "Demo Data",
        // and routing its Restore button to the demo client.
        let loadedRecipes = await loadRecipes(for: applications, using: repairClient)
        guard generation == refreshGeneration else { return }
        recipesByBundleIdentifier = loadedRecipes

        do {
            let loadedHistory = try await repairClient.history()
                .sorted { $0.creationDate > $1.creationDate }
            guard generation == refreshGeneration else { return }
            repairHistory = loadedHistory
        } catch {
            guard generation == refreshGeneration else { return }
            repairHistory = []
            issue = AppIssue(
                title: "Repair history unavailable",
                message: error.localizedDescription
            )
        }

        guard generation == refreshGeneration else { return }
        isRefreshing = false
    }

    func setDemoMode(_ enabled: Bool) async {
        guard enabled != isDemoMode else { return }
        isDemoMode = enabled
        dependencies.defaults.set(enabled, forKey: DemoModePreference.defaultsKey)
        demoClosedBundleIdentifiers = []
        selectedApplicationID = nil
        selectedRepairItemIDs = []
        repairPlan = nil
        restoreManifest = nil
        restoreConflict = nil
        // All of this belongs to the mode being left. `isDemoMode` already
        // drives the demo badge and the repair client, so leaving the previous
        // mode's data on screen during the await would show real backup
        // transactions under a "Demo Data" badge, or the reverse.
        snapshot = nil
        applications = []
        repairHistory = []
        recipesByBundleIdentifier = [:]
        reportApplicationIDs = []
        reportTransactionIDs = []
        // Timeline state belongs to whichever mode produced it; carrying demo
        // recurrences into live mode would be a false claim about this Mac.
        timeline = []
        snapshotDelta = nil
        recurrences = []
        timelineUnavailableReason = nil
        await refresh()
    }

    /// Records this collection and recomputes the delta and recurrences.
    ///
    /// A timeline failure never blocks or interrupts diagnostics: the rest of
    /// the snapshot is still valid evidence, so the reason is surfaced in place
    /// of the timeline rather than as a modal alert.
    private func recordAndReloadTimeline(for snapshot: SystemSnapshot) async {
        let client = isDemoMode ? dependencies.demoTimeline : dependencies.liveTimeline
        do {
            let entries = try await client.record(snapshot)
            timeline = entries
            snapshotDelta = SnapshotTimelineAnalyzer.delta(for: entries)
            recurrences = SnapshotTimelineAnalyzer.recurrences(in: entries)
            timelineUnavailableReason = nil
        } catch {
            timeline = []
            snapshotDelta = nil
            recurrences = []
            timelineUnavailableReason = error.localizedDescription
        }
    }

    /// Deletes the stored timeline after an explicit request. Backups,
    /// manifests, and every other Signalbox record are untouched.
    func clearTimeline() async {
        let client = isDemoMode ? dependencies.demoTimeline : dependencies.liveTimeline
        do {
            try await client.clear()
            timeline = []
            snapshotDelta = nil
            recurrences = []
            timelineUnavailableReason = nil
            issue = AppIssue(
                title: "Snapshot history cleared",
                message: isDemoMode
                    ? "Demo mode uses a fixed in-memory timeline, so nothing was stored or deleted on this Mac."
                    : "Signalbox deleted its own snapshot summaries. Backups and repair manifests were not touched."
            )
        } catch {
            issue = AppIssue(title: "Snapshot history was not cleared", message: error.localizedDescription)
        }
    }

    func selectApplication(_ application: InspectedApplication) {
        selectedApplicationID = application.id
    }

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        if isDemoMode {
            guard !demoClosedBundleIdentifiers.contains(bundleIdentifier) else { return false }
            return applications.first { $0.bundleIdentifier == bundleIdentifier }?.isRunning ?? false
        }
        return dependencies.applications.isRunning(bundleIdentifier)
    }

    func requestQuit(bundleIdentifier: String, applicationName: String) async {
        if isDemoMode {
            demoClosedBundleIdentifiers.insert(bundleIdentifier)
            return
        }

        guard dependencies.applications.requestQuit(bundleIdentifier) else {
            issue = AppIssue(
                title: "Couldn’t ask \(applicationName) to quit",
                message: "Quit the app normally, then return to Signalbox. Signalbox never force-quits an application."
            )
            return
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        if dependencies.applications.isRunning(bundleIdentifier) {
            issue = AppIssue(
                title: "\(applicationName) is still running",
                message: "The quit request was sent, but the app has not closed. Save your work and quit it normally before continuing."
            )
        }
    }

    func prepareRepair(using recipe: RepairRecipe) async {
        guard let application = applications.first(where: { $0.bundleIdentifier == recipe.bundleIdentifier }) else {
            issue = AppIssue(title: "App unavailable", message: "Refresh and select the app again.")
            return
        }

        isPreparingRepair = true
        defer { isPreparingRepair = false }
        do {
            let plan = try await currentRepairClient.makePlan(application, recipe, dependencies.clock())
            repairPlan = plan
            // Optional repair operations are deliberately never preselected, even if an
            // external planner accidentally marks one as selected by default.
            selectedRepairItemIDs = []
            hasConfirmedRepair = false
        } catch {
            issue = AppIssue(title: "Repair preview unavailable", message: error.localizedDescription)
        }
    }

    func toggleRepairItem(_ item: RepairPlanItem) {
        guard item.exists, item.unavailableReason == nil else { return }
        if selectedRepairItemIDs.contains(item.id) {
            selectedRepairItemIDs.remove(item.id)
        } else {
            selectedRepairItemIDs.insert(item.id)
        }
    }

    func cancelRepairPreview() {
        guard !isExecutingRepair else { return }
        repairPlan = nil
        selectedRepairItemIDs = []
        hasConfirmedRepair = false
    }

    func executeRepair() async {
        guard let repairPlan else { return }
        guard hasConfirmedRepair else {
            issue = AppIssue(title: "Confirmation required", message: "Confirm that you understand the repair is a reversible experiment.")
            return
        }

        let isRunning = isApplicationRunning(
            bundleIdentifier: repairPlan.targetApplication.bundleIdentifier
        )
        guard !isRunning else {
            issue = AppIssue(
                title: "Close \(repairPlan.targetApplication.name) first",
                message: "Signalbox will not move caches while the target app is running."
            )
            return
        }

        isExecutingRepair = true
        defer { isExecutingRepair = false }
        do {
            let manifest = try await currentRepairClient.execute(
                repairPlan,
                selectedRepairItemIDs,
                isRunning,
                signalboxVersion
            )
            upsert(manifest)
            self.repairPlan = nil
            selectedRepairItemIDs = []
            hasConfirmedRepair = false
            switch manifest.state {
            case .completed:
                issue = AppIssue(
                    title: "Cache backup completed",
                    message: "The selected caches were moved to a reversible backup. This does not prove the underlying issue is fixed."
                )
            case .partial:
                issue = AppIssue(
                    title: "Cache backup partially completed",
                    message: "Some selected caches were moved; others were left untouched. Review the retained manifest in Repair History."
                )
            case .failed:
                issue = AppIssue(
                    title: "No cache items were moved",
                    message: "The safety checks stopped the repair. The manifest records what failed, and the original sources were left untouched."
                )
            default:
                issue = AppIssue(
                    title: "Repair needs review",
                    message: "The transaction ended in an unexpected state. Review the retained manifest before taking another action."
                )
            }
        } catch {
            issue = AppIssue(title: "Repair did not complete", message: error.localizedDescription)
            if let updated = try? await currentRepairClient.history() {
                repairHistory = updated.sorted { $0.creationDate > $1.creationDate }
            }
        }
    }

    func beginRestore(_ manifest: BackupManifest) {
        restoreManifest = manifest
        hasConfirmedRestore = false
    }

    func cancelRestore() {
        guard !isRestoring else { return }
        restoreManifest = nil
        hasConfirmedRestore = false
    }

    func executeRestore(choice: SignalboxRestoreChoice = .originalOnly) async {
        guard let manifest = restoreManifest else { return }
        guard hasConfirmedRestore || choice == .suggestedAlternate else {
            issue = AppIssue(title: "Confirmation required", message: "Confirm the restore after closing the target app.")
            return
        }
        let isRunning = isApplicationRunning(bundleIdentifier: manifest.targetBundleIdentifier)
        guard !isRunning else {
            issue = AppIssue(
                title: "Close \(manifest.targetApplicationName) first",
                message: "Signalbox will not restore a cache while the target app is running."
            )
            return
        }

        isRestoring = true
        defer { isRestoring = false }
        do {
            let outcome = try await currentRepairClient.restore(
                manifest.transactionID,
                isRunning,
                choice
            )
            switch outcome {
            case .restored(let updated):
                upsert(updated)
                restoreManifest = nil
                hasConfirmedRestore = false
                restoreConflict = nil
                issue = AppIssue(
                    title: "Restore completed",
                    message: "The backed-up items were restored."
                )
            case .partial(let updated):
                upsert(updated)
                restoreManifest = nil
                hasConfirmedRestore = false
                restoreConflict = nil
                issue = AppIssue(
                    title: "Restore partially completed",
                    message: "Some items could not be restored. The backup and manifest were kept."
                )
            case .conflict(let originalPath, let suggestedAlternatePath):
                restoreConflict = RestoreConflictPresentation(
                    transactionID: manifest.transactionID,
                    originalPath: originalPath,
                    suggestedAlternatePath: suggestedAlternatePath
                )
            }
        } catch {
            issue = AppIssue(title: "Restore did not complete", message: error.localizedDescription)
        }
    }

    /// Takes the conflict by value.
    ///
    /// `.alert(item:)` writes nil back through its binding as part of
    /// dismissing the alert, and it does so before the `Task` the button
    /// enqueues gets to run. Reading `restoreConflict` here would therefore
    /// always find nil and silently do nothing, which is exactly what the
    /// previous `guard restoreConflict != nil` did: the "Restore to Alternate"
    /// button appeared to work and never restored anything.
    func restoreToSuggestedAlternate(_ conflict: RestoreConflictPresentation) async {
        guard restoreManifest?.transactionID == conflict.transactionID else { return }
        restoreConflict = nil
        await executeRestore(choice: .suggestedAlternate)
    }

    func revealBackup(_ manifest: BackupManifest) {
        let url = URL(fileURLWithPath: manifest.backupDirectoryPath, isDirectory: true)
        if !dependencies.applications.reveal(url) {
            issue = AppIssue(
                title: "Backup not found",
                message: "Signalbox could not reveal this backup. It may have been moved outside Signalbox."
            )
        }
    }

    func beginReportPreview() {
        reportGeneratedAt = dependencies.clock()
        isShowingReportPreview = true
    }

    func closeReportPreview() {
        isShowingReportPreview = false
    }

    func reportExported(to url: URL) {
        issue = AppIssue(
            title: "Report exported",
            message: "Saved \(url.lastPathComponent). Raw crash-report contents were not included."
        )
    }

    func reportCopied() {
        issue = AppIssue(
            title: "Report copied",
            message: "The clipboard now holds exactly the sanitized Markdown shown in the preview."
        )
    }

    func reportExportFailed(_ error: Error) {
        issue = AppIssue(title: "Report could not be exported", message: error.localizedDescription)
    }

    private var currentRepairClient: SignalboxRepairClient {
        isDemoMode ? dependencies.demoRepairs : dependencies.liveRepairs
    }

    private func loadRecipes(
        for applications: [InspectedApplication],
        using client: SignalboxRepairClient
    ) async -> [String: [RepairRecipe]] {
        await withTaskGroup(of: (String, [RepairRecipe]).self) { group in
            for application in applications {
                group.addTask {
                    let recipes = await client.availableRecipes(application)
                    return (application.bundleIdentifier, recipes)
                }
            }

            var result: [String: [RepairRecipe]] = [:]
            for await (bundleIdentifier, recipes) in group {
                result[bundleIdentifier] = recipes
            }
            return result
        }
    }

    private func upsert(_ manifest: BackupManifest) {
        repairHistory.removeAll { $0.transactionID == manifest.transactionID }
        repairHistory.append(manifest)
        repairHistory.sort { $0.creationDate > $1.creationDate }
    }
}
