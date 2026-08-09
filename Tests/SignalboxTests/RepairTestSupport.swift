import Foundation
@testable import Signalbox

enum RepairTestSupport {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignalboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func application(isRunning: Bool = false) -> InspectedApplication {
        InspectedApplication(
            name: "Claude",
            bundleIdentifier: bundleIdentifier,
            version: "1.2.3",
            bundleURL: nil,
            executableArchitecture: .available("arm64"),
            codeSigningStatus: .available("valid"),
            isRunning: isRunning,
            iconFileURL: nil,
            matchingCrashReports: [],
            suggestedRecipeIDs: ["electron-cache-only.claude"],
            recipeEvidence: ["Repeated renderer crash signature"]
        )
    }

    static var recipe: RepairRecipe {
        RepairRecipeCatalog.recipe(for: bundleIdentifier)!
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func writeFile(named name: String, byteCount: Int, in directory: URL) throws {
        try Data(repeating: 0x53, count: byteCount).write(to: directory.appendingPathComponent(name))
    }

    static func backupStore(backupsRoot: URL) -> BackupStore {
        let fixtureRoot = backupsRoot.deletingLastPathComponent()
        return BackupStore(
            rootURL: backupsRoot,
            authorizedApplicationSupportParentURL: fixtureRoot
                .appendingPathComponent("Application Support", isDirectory: true),
            authorizedUserCachesRootURL: fixtureRoot
                .appendingPathComponent("Caches", isDirectory: true)
        )
    }

    static func makePlanFixture(
        root: URL,
        cacheNames: [String] = ["Cache"]
    ) async throws -> (RepairPlan, URL, URL) {
        let applicationSupportParent = root.appendingPathComponent("Application Support", isDirectory: true)
        let supportRoot = applicationSupportParent.appendingPathComponent("Claude", isDirectory: true)
        let cachesRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let backupsRoot = root.appendingPathComponent("Signalbox Backups", isDirectory: true)
        try createDirectory(supportRoot)
        try createDirectory(cachesRoot)
        for name in cacheNames {
            let cache = supportRoot.appendingPathComponent(name, isDirectory: true)
            try createDirectory(cache)
            try writeFile(named: "payload.bin", byteCount: 32, in: cache)
        }
        let planner = RepairPlanner(backupRootURL: backupsRoot)
        let plan = try await planner.makePlan(
            for: application(),
            recipe: recipe,
            supportRoot: .recipeResolved(applicationSupportParentURL: applicationSupportParent),
            userCachesRootURL: cachesRoot,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            suggestionReason: "A repeated renderer crash makes a cache reset a reasonable reversible experiment."
        )
        return (plan, supportRoot, backupsRoot)
    }
}
