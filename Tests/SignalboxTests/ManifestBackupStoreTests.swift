import Foundation
import XCTest
@testable import Signalbox

final class ManifestBackupStoreTests: XCTestCase {
    func testManifestIsJSONRoundTrippableAndAppearsInHistory() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, _, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let manifest = try await RepairExecutor(backupStore: store).execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "9.9-test"
        )

        let manifestURL = URL(fileURLWithPath: manifest.backupDirectoryPath)
            .appendingPathComponent(BackupLayout.manifestFileName)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(object["transactionID"] as? String, manifest.transactionID.uuidString)
        XCTAssertEqual(object["targetBundleIdentifier"] as? String, RepairTestSupport.bundleIdentifier)
        XCTAssertEqual(object["signalboxVersion"] as? String, "9.9-test")
        XCTAssertNotNil(object["operations"] as? [[String: Any]])

        let history = try await store.history()
        let storedManifest = try await store.manifest(transactionID: manifest.transactionID)
        let storedBytes = try await store.totalBackupBytes()
        XCTAssertEqual(history.map(\.transactionID), [manifest.transactionID])
        XCTAssertEqual(storedManifest?.operations.first?.state, .moved)
        XCTAssertEqual(storedBytes, 32)

        let transactionChildren = try FileManager.default.contentsOfDirectory(
            atPath: manifest.backupDirectoryPath
        )
        XCTAssertEqual(Set(transactionChildren), Set([BackupLayout.itemsDirectoryName, BackupLayout.manifestFileName]))
    }

    func testRunningApplicationPreventsAnyTransactionCreation() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, _, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let executor = RepairExecutor(backupStore: RepairTestSupport.backupStore(backupsRoot: backupsRoot))
        do {
            _ = try await executor.execute(
                plan: plan,
                selectedItemIDs: [selected.id],
                applicationIsRunning: true,
                signalboxVersion: "test"
            )
            XCTFail("Expected the running-application guard")
        } catch let error as RepairExecutionError {
            XCTAssertEqual(error, .applicationRunning)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsRoot.path))
    }

    func testExecutorRechecksRunningStateImmediatelyBeforeMutation() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let executor = RepairExecutor(
            backupStore: RepairTestSupport.backupStore(backupsRoot: backupsRoot),
            applicationRunningCheck: { _ in true }
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                selectedItemIDs: [selected.id],
                applicationIsRunning: false,
                signalboxVersion: "test"
            )
            XCTFail("Expected the executor-level running-application guard")
        } catch let error as RepairExecutionError {
            XCTAssertEqual(error, .applicationRunning)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Cache").path))
    }

    func testHistoryRejectsSymlinkedManifest() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, _, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let manifest = try await RepairExecutor(backupStore: store).execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        let transactionURL = URL(fileURLWithPath: manifest.backupDirectoryPath, isDirectory: true)
        let manifestURL = transactionURL.appendingPathComponent(BackupLayout.manifestFileName)
        let realManifestURL = transactionURL.appendingPathComponent("manifest-real.json")
        try FileManager.default.moveItem(at: manifestURL, to: realManifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: realManifestURL)

        do {
            _ = try await store.history()
            XCTFail("A symlinked manifest must be rejected.")
        } catch let error as BackupStoreError {
            guard case .unsafeBackupPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHistoryRejectsPersistedDirectParentThatIsNotAnAuthorizedCatalogRoot() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, _, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let manifest = try await RepairExecutor(backupStore: store).execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )

        // This topology used to pass because Cache was a direct child of the
        // recorded root. The recorded root itself is untrusted manifest data.
        let rogueRoot = root.appendingPathComponent("Unrelated Valuable Data", isDirectory: true)
        let manifestURL = URL(fileURLWithPath: manifest.backupDirectoryPath)
            .appendingPathComponent(BackupLayout.manifestFileName)
        try rewriteManifest(at: manifestURL) { object in
            var operations = object["operations"] as! [[String: Any]]
            operations[0]["allowedRootPath"] = rogueRoot.path
            operations[0]["originalPath"] = rogueRoot.appendingPathComponent("Cache").path
            object["operations"] = operations
        }

        do {
            _ = try await store.history()
            XCTFail("A manifest-provided direct parent must not authorize a restore destination.")
        } catch let error as BackupStoreError {
            guard case .corruptManifest(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("exact catalog root"))
        }
    }

    func testBundleIdentifierCacheRequiresExactConfiguredCachesRoot() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (_, _, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let cachesRoot = root.appendingPathComponent("Caches", isDirectory: true)

        try await store.validateRootAuthorization(
            targetBundleIdentifier: RepairTestSupport.bundleIdentifier,
            originalPath: cachesRoot.appendingPathComponent(RepairTestSupport.bundleIdentifier).path,
            allowedRootPath: cachesRoot.path,
            sourceKind: .bundleIdentifierCache
        )

        let rogueRoot = root.appendingPathComponent("Other Caches", isDirectory: true)
        try RepairTestSupport.createDirectory(rogueRoot)
        do {
            try await store.validateRootAuthorization(
                targetBundleIdentifier: RepairTestSupport.bundleIdentifier,
                originalPath: rogueRoot.appendingPathComponent(RepairTestSupport.bundleIdentifier).path,
                allowedRootPath: rogueRoot.path,
                sourceKind: .bundleIdentifierCache
            )
            XCTFail("A bundle-ID-shaped directory outside the configured Caches root must be rejected.")
        } catch let error as BackupStoreError {
            guard case .corruptManifest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExplicitRootFailsClosedAcrossStoreRestartUntilUserReauthorizes() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let applicationSupportParent = root.appendingPathComponent("Application Support", isDirectory: true)
        let explicitRoot = applicationSupportParent.appendingPathComponent("Explicit Electron App", isDirectory: true)
        let cache = explicitRoot.appendingPathComponent("Cache", isDirectory: true)
        let cachesRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let backupsRoot = root.appendingPathComponent("Signalbox Backups", isDirectory: true)
        try RepairTestSupport.createDirectory(cache)
        try RepairTestSupport.createDirectory(cachesRoot)
        try RepairTestSupport.writeFile(named: "payload.bin", byteCount: 12, in: cache)

        let plan = try await RepairPlanner(backupRootURL: backupsRoot).makePlan(
            for: RepairTestSupport.application(),
            recipe: RepairRecipeCatalog.explicitRecipe(for: RepairTestSupport.bundleIdentifier),
            supportRoot: .explicitlySelected(explicitRoot),
            userCachesRootURL: cachesRoot,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            suggestionReason: "The user selected this support folder."
        )
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let firstStore = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let executor = RepairExecutor(backupStore: firstStore)

        do {
            _ = try await executor.execute(
                plan: plan,
                selectedItemIDs: [selected.id],
                applicationIsRunning: false,
                signalboxVersion: "test"
            )
            XCTFail("An explicit path string without live authorization must fail closed.")
        } catch let error as RepairExecutionError {
            guard case .unsafePath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsRoot.path))

        try await firstStore.reauthorizeExplicitSupportRoot(explicitRoot)
        let manifest = try await executor.execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))

        let relaunchedStore = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        do {
            _ = try await relaunchedStore.history()
            XCTFail("Ephemeral explicit-root authorization must not survive a store restart.")
        } catch let error as BackupStoreError {
            guard case .corruptManifest = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try await relaunchedStore.reauthorizeExplicitSupportRoot(explicitRoot)
        let history = try await relaunchedStore.history()
        XCTAssertEqual(history.map(\.transactionID), [manifest.transactionID])
    }

    private func rewriteManifest(
        at url: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutation(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
