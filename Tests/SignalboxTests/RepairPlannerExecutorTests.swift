import Foundation
import XCTest
@testable import Signalbox

final class RepairPlannerExecutorTests: XCTestCase {
    func testRecipeMatchingIsExactAndCatalogUsesOnlyAuditedNames() {
        let recipe = RepairRecipeCatalog.recipe(for: RepairTestSupport.bundleIdentifier)
        XCTAssertNotNil(recipe)
        XCTAssertEqual(Set(recipe!.allowedCacheDirectoryNames), ElectronCacheDirectory.auditedNameSet)
        XCTAssertNil(RepairRecipeCatalog.recipe(for: "Claude"))
        XCTAssertNil(RepairRecipeCatalog.recipe(for: RepairTestSupport.bundleIdentifier + ".helper"))
    }

    func testPlannerCountsAsynchronouslyAndDoesNotCreateBackup() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, _, _) = try await RepairTestSupport.makePlanFixture(root: root)

        let cache = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        XCTAssertTrue(cache.exists)
        XCTAssertEqual(cache.fileCount, 1)
        XCTAssertEqual(cache.byteCount, 32)
        XCTAssertFalse(cache.selectedByDefault)
        XCTAssertNotNil(cache.previewMetadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.backupDirectoryPath))
        XCTAssertTrue(plan.items.allSatisfy { $0.selectedByDefault == false })
    }

    func testExplicitSupportRootIsUsedWithoutGuessingAnAppName() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let selected = root.appendingPathComponent("A folder the user selected", isDirectory: true)
        let cache = selected.appendingPathComponent("Cache", isDirectory: true)
        let userCaches = root.appendingPathComponent("Caches", isDirectory: true)
        try RepairTestSupport.createDirectory(cache)
        try RepairTestSupport.createDirectory(userCaches)
        let planner = RepairPlanner(backupRootURL: root.appendingPathComponent("Backups"))
        let recipe = RepairRecipeCatalog.explicitRecipe(for: RepairTestSupport.bundleIdentifier)
        let plan = try await planner.makePlan(
            for: RepairTestSupport.application(),
            recipe: recipe,
            supportRoot: .explicitlySelected(selected),
            userCachesRootURL: userCaches,
            suggestionReason: "User explicitly selected the support folder."
        )
        XCTAssertTrue(plan.items.contains { $0.sourcePath.hasSuffix("/A folder the user selected/Cache") })
    }

    func testChangedMetadataIsRejectedAndSourceRemainsUntouched() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let item = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: item.sourcePath
        )

        let executor = RepairExecutor(backupStore: RepairTestSupport.backupStore(backupsRoot: backupsRoot))
        let manifest = try await executor.execute(
            plan: plan,
            selectedItemIDs: [item.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertEqual(manifest.state, .failed)
        XCTAssertEqual(manifest.operations.first?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.operations[0].backupPath))
    }

    func testPartialTransactionMovesSafeItemAndLeavesChangedItem() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(
            root: root,
            cacheNames: ["Cache", "GPUCache"]
        )
        let cacheItem = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let changedItem = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/GPUCache") })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: changedItem.sourcePath
        )

        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let manifest = try await RepairExecutor(backupStore: store).execute(
            plan: plan,
            selectedItemIDs: [cacheItem.id, changedItem.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertEqual(manifest.state, .partial)
        XCTAssertEqual(manifest.operations.filter { $0.state == .moved }.count, 1)
        XCTAssertEqual(manifest.operations.filter { $0.state == .failed }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Cache").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("GPUCache").path))
    }
}
