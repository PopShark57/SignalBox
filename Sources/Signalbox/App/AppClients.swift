import AppKit
import Foundation

struct SignalboxLoadResult: Sendable {
    let snapshot: SystemSnapshot
    let applications: [InspectedApplication]
}

struct SignalboxDataClient: Sendable {
    let load: @Sendable (_ requestedAt: Date, _ demoMode: Bool) async -> SignalboxLoadResult
}

enum SignalboxRestoreChoice: Sendable, Equatable {
    case originalOnly
    case suggestedAlternate
}

struct SignalboxRepairClient: Sendable {
    let availableRecipes: @Sendable (_ application: InspectedApplication) async -> [RepairRecipe]
    let makePlan: @Sendable (_ application: InspectedApplication, _ recipe: RepairRecipe, _ createdAt: Date) async throws -> RepairPlan
    let history: @Sendable () async throws -> [BackupManifest]
    let execute: @Sendable (_ plan: RepairPlan, _ selectedItemIDs: Set<UUID>, _ applicationIsRunning: Bool, _ signalboxVersion: String) async throws -> BackupManifest
    let restore: @Sendable (_ transactionID: UUID, _ applicationIsRunning: Bool, _ choice: SignalboxRestoreChoice) async throws -> RestoreOutcome
}

/// Records and reads the local snapshot timeline. Demo mode gets an in-memory
/// implementation so a demonstration never writes to the real archive.
struct SignalboxTimelineClient: Sendable {
    let entries: @Sendable () async throws -> [SnapshotSummary]
    let record: @Sendable (_ snapshot: SystemSnapshot) async throws -> [SnapshotSummary]
    let clear: @Sendable () async throws -> Void

    static func store(_ store: SnapshotTimelineStore) -> SignalboxTimelineClient {
        SignalboxTimelineClient(
            entries: { try await store.entries() },
            record: { try await store.record($0) },
            clear: { try await store.clear() }
        )
    }

    /// A fixed, plausible six-collection history so demo mode can exercise
    /// the delta and recurrence interface without inventing a live timeline.
    static func demo() -> SignalboxTimelineClient {
        let entries = DemoFixtures.timelineEntries()
        return SignalboxTimelineClient(
            entries: { entries },
            record: { _ in entries },
            clear: { }
        )
    }
}

@MainActor
struct SignalboxApplicationClient {
    let isRunning: (_ bundleIdentifier: String) -> Bool
    let requestQuit: (_ bundleIdentifier: String) -> Bool
    let reveal: (_ directoryURL: URL) -> Bool

    static let workspace = SignalboxApplicationClient(
        isRunning: { bundleIdentifier in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        },
        requestQuit: { bundleIdentifier in
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard !applications.isEmpty else { return true }
            return applications.allSatisfy { $0.terminate() }
        },
        reveal: { directoryURL in
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
            return true
        }
    )
}

@MainActor
struct SignalboxDependencies {
    let data: SignalboxDataClient
    let liveRepairs: SignalboxRepairClient
    let demoRepairs: SignalboxRepairClient
    let liveTimeline: SignalboxTimelineClient
    let demoTimeline: SignalboxTimelineClient
    let applications: SignalboxApplicationClient
    let reportExporter: any ReportExporting
    let timelineCSVExporter: any TimelineCSVExporting
    let clock: @Sendable () -> Date
    let defaults: UserDefaults
    let processInfo: ProcessInfo
}

enum DemoModePreference {
    static let defaultsKey = "Signalbox.demoMode"
    static let enableArgument = "--demo-mode"
    static let shortEnableArgument = "--demo"
    static let disableArgument = "--live-mode"
    static let environmentKey = "SIGNALBOX_DEMO_MODE"

    static func initialValue(processInfo: ProcessInfo, defaults: UserDefaults) -> Bool {
        let arguments = processInfo.arguments
        if arguments.contains(enableArgument) || arguments.contains(shortEnableArgument) { return true }
        if arguments.contains(disableArgument) { return false }

        if let rawValue = processInfo.environment[environmentKey]?.lowercased() {
            if ["1", "true", "yes", "on"].contains(rawValue) { return true }
            if ["0", "false", "no", "off"].contains(rawValue) { return false }
        }

        return defaults.bool(forKey: defaultsKey)
    }
}

/// An in-memory repair workflow for deterministic demos. It never touches the file system
/// and, importantly, cannot quit a real application that happens to share the fixture's ID.
actor DemoRepairStore {
    static let fixtureDate = Date(timeIntervalSince1970: 1_735_732_800)

    private var manifests: [BackupManifest]

    init() {
        manifests = [Self.seedManifest()]
    }

    func recipes(for application: InspectedApplication) -> [RepairRecipe] {
        guard !application.suggestedRecipeIDs.isEmpty else { return [] }
        return [
            RepairRecipe(
                id: application.suggestedRecipeIDs.first ?? "demo-electron-cache-only",
                name: "Reversible cache-only repair",
                bundleIdentifier: application.bundleIdentifier,
                applicationSupportDirectoryName: "Northstar",
                allowedCacheDirectoryNames: ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"],
                includesBundleIdentifierCache: true,
                rationale: "The recent evidence is consistent with a disposable cache problem. Moving only known cache folders is a cautious experiment, not a guaranteed fix."
            )
        ]
    }

    func makePlan(
        application: InspectedApplication,
        recipe: RepairRecipe,
        createdAt: Date
    ) -> RepairPlan {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let supportRoot = home + "/Library/Application Support/Northstar"
        let cachesRoot = home + "/Library/Caches"
        let itemDefinitions: [(UUID, String, String, RepairSourceKind, Int, Int64)] = [
            (Self.uuid("10000000-0000-0000-0000-000000000001"), supportRoot + "/Cache", supportRoot, .applicationSupportCache, 84, 12_582_912),
            (Self.uuid("10000000-0000-0000-0000-000000000002"), supportRoot + "/GPUCache", supportRoot, .applicationSupportCache, 18, 2_621_440),
            (Self.uuid("10000000-0000-0000-0000-000000000003"), cachesRoot + "/" + application.bundleIdentifier, cachesRoot, .bundleIdentifierCache, 31, 5_242_880),
            (Self.uuid("10000000-0000-0000-0000-000000000004"), supportRoot + "/DawnWebGPUCache", supportRoot, .applicationSupportCache, 0, 0)
        ]
        let metadata = FileMetadata(
            device: 1,
            inode: 9_001,
            mode: 0o40755,
            size: 96,
            modificationSeconds: Int64(Self.fixtureDate.timeIntervalSince1970),
            modificationNanoseconds: 0,
            isDirectory: true
        )
        let items = itemDefinitions.enumerated().map { index, definition in
            RepairPlanItem(
                id: definition.0,
                sourcePath: definition.1,
                displayPath: definition.1.replacingOccurrences(of: home, with: "~"),
                allowedRootPath: definition.2,
                sourceKind: definition.3,
                exists: index != itemDefinitions.count - 1,
                selectedByDefault: false,
                fileCount: definition.4,
                byteCount: definition.5,
                previewMetadata: index == itemDefinitions.count - 1 ? nil : metadata,
                unavailableReason: nil
            )
        }

        return RepairPlan(
            id: Self.uuid("10000000-0000-0000-0000-000000000010"),
            createdAt: createdAt,
            targetApplication: application,
            recipe: recipe,
            backupDirectoryPath: home + "/Library/Application Support/Signalbox/Backups/DEMO-2025-01-01",
            items: items,
            suggestionReason: application.recipeEvidence.first ?? recipe.rationale
        )
    }

    func history() -> [BackupManifest] {
        manifests.sorted { $0.creationDate > $1.creationDate }
    }

    func execute(
        plan: RepairPlan,
        selectedItemIDs: Set<UUID>,
        applicationIsRunning: Bool,
        signalboxVersion: String
    ) throws -> BackupManifest {
        if applicationIsRunning { throw RepairExecutionError.applicationRunning }
        let selectedItems = plan.items.filter { selectedItemIDs.contains($0.id) }
        if selectedItems.isEmpty { throw RepairExecutionError.noItemsSelected }

        let operations = selectedItems.compactMap { item -> RepairOperation? in
            guard let metadata = item.previewMetadata else { return nil }
            return RepairOperation(
                id: item.id,
                originalPath: item.sourcePath,
                backupPath: plan.backupDirectoryPath + "/" + URL(fileURLWithPath: item.sourcePath).lastPathComponent,
                originalMetadata: metadata,
                fileCount: item.fileCount,
                byteCount: item.byteCount,
                state: .moved,
                error: nil
            )
        }
        let manifest = BackupManifest(
            transactionID: plan.id,
            creationDate: plan.createdAt,
            targetBundleIdentifier: plan.targetApplication.bundleIdentifier,
            targetApplicationName: plan.targetApplication.name,
            targetApplicationVersion: plan.targetApplication.version,
            backupDirectoryPath: plan.backupDirectoryPath,
            operations: operations,
            state: .completed,
            errors: [],
            signalboxVersion: signalboxVersion
        )
        manifests.removeAll { $0.transactionID == manifest.transactionID }
        manifests.append(manifest)
        return manifest
    }

    func restore(
        transactionID: UUID,
        applicationIsRunning: Bool,
        choice: SignalboxRestoreChoice
    ) throws -> RestoreOutcome {
        if applicationIsRunning { throw RepairExecutionError.applicationRunning }
        guard let index = manifests.firstIndex(where: { $0.transactionID == transactionID }) else {
            throw RepairExecutionError.sourceUnavailable(transactionID.uuidString)
        }

        if choice == .originalOnly, manifests[index].state == .partial {
            return .conflict(
                originalPath: "~/Library/Application Support/Northstar/Cache",
                suggestedAlternatePath: "~/Desktop/Signalbox Restored Cache"
            )
        }

        var restored = manifests[index]
        for operationIndex in restored.operations.indices {
            restored.operations[operationIndex].state = .restored
            restored.operations[operationIndex].error = nil
        }
        restored.state = .restored
        restored.errors = []
        manifests[index] = restored
        return .restored(restored)
    }

    nonisolated static func client(store: DemoRepairStore = DemoRepairStore()) -> SignalboxRepairClient {
        SignalboxRepairClient(
            availableRecipes: { application in
                await store.recipes(for: application)
            },
            makePlan: { application, recipe, createdAt in
                await store.makePlan(application: application, recipe: recipe, createdAt: createdAt)
            },
            history: {
                await store.history()
            },
            execute: { plan, selectedItemIDs, applicationIsRunning, signalboxVersion in
                try await store.execute(
                    plan: plan,
                    selectedItemIDs: selectedItemIDs,
                    applicationIsRunning: applicationIsRunning,
                    signalboxVersion: signalboxVersion
                )
            },
            restore: { transactionID, applicationIsRunning, choice in
                try await store.restore(
                    transactionID: transactionID,
                    applicationIsRunning: applicationIsRunning,
                    choice: choice
                )
            }
        )
    }

    private static func seedManifest() -> BackupManifest {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let metadata = FileMetadata(
            device: 1,
            inode: 8_001,
            mode: 0o40755,
            size: 96,
            modificationSeconds: Int64(fixtureDate.timeIntervalSince1970),
            modificationNanoseconds: 0,
            isDirectory: true
        )
        let operation = RepairOperation(
            id: uuid("20000000-0000-0000-0000-000000000001"),
            originalPath: home + "/Library/Application Support/Northstar/Code Cache",
            backupPath: home + "/Library/Application Support/Signalbox/Backups/DEMO-2024-12-22/Code Cache",
            originalMetadata: metadata,
            fileCount: 42,
            byteCount: 7_340_032,
            state: .moved,
            error: nil
        )
        return BackupManifest(
            transactionID: uuid("20000000-0000-0000-0000-000000000010"),
            creationDate: fixtureDate.addingTimeInterval(-864_000),
            targetBundleIdentifier: "com.example.northstar",
            targetApplicationName: "Northstar",
            targetApplicationVersion: "4.2.1",
            backupDirectoryPath: home + "/Library/Application Support/Signalbox/Backups/DEMO-2024-12-22",
            operations: [operation],
            state: .partial,
            errors: ["Demo fixture: one optional cache changed after preview and was left untouched."],
            signalboxVersion: "1.0-demo"
        )
    }

    private nonisolated static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
