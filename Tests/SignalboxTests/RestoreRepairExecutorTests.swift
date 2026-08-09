import Foundation
import XCTest
@testable import Signalbox

final class RestoreRepairExecutorTests: XCTestCase {
    func testSuccessfulRestoreUsesRenameAndUpdatesManifest() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let executor = RepairExecutor(backupStore: store)
        let repaired = try await executor.execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.sourcePath))

        let outcome = try await executor.restore(
            transactionID: repaired.transactionID,
            applicationIsRunning: false
        )
        guard case .restored(let restored) = outcome else {
            return XCTFail("Expected a complete restore, got \(outcome)")
        }
        let original = supportRoot.appendingPathComponent("Cache", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("payload.bin").path))
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(restored.operations.first?.state, .restored)
        XCTAssertEqual(restored.operations.first?.restoredPath, original.resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.backupByteCount, 0)
        let storedManifest = try await store.requiredManifest(transactionID: repaired.transactionID)
        XCTAssertEqual(storedManifest.state, .restored)
    }

    func testConflictStopsWithoutOverwriteAndCanRestoreBesideOriginal() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let executor = RepairExecutor(backupStore: store)
        let repaired = try await executor.execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )

        let newlyCreatedOriginal = supportRoot.appendingPathComponent("Cache", isDirectory: true)
        try RepairTestSupport.createDirectory(newlyCreatedOriginal)
        try RepairTestSupport.writeFile(named: "new-session.bin", byteCount: 7, in: newlyCreatedOriginal)

        let conflict = try await executor.restore(
            transactionID: repaired.transactionID,
            applicationIsRunning: false,
            destinationPolicy: .originalOnly
        )
        let alternatePath: String
        guard case .conflict(let originalPath, let suggestion) = conflict else {
            return XCTFail("Expected a restore conflict, got \(conflict)")
        }
        XCTAssertEqual(originalPath, newlyCreatedOriginal.resolvingSymlinksInPath().path)
        alternatePath = suggestion
        XCTAssertTrue(FileManager.default.fileExists(atPath: newlyCreatedOriginal.appendingPathComponent("new-session.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.operations[0].backupPath))

        let alternateOutcome = try await executor.restore(
            transactionID: repaired.transactionID,
            applicationIsRunning: false,
            destinationPolicy: .suggestedAlternate
        )
        guard case .restored(let restored) = alternateOutcome else {
            return XCTFail("Expected an alternate restore, got \(alternateOutcome)")
        }
        XCTAssertEqual(restored.operations.first?.restoredPath, alternatePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newlyCreatedOriginal.appendingPathComponent("new-session.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: alternatePath).appendingPathComponent("payload.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repaired.operations[0].backupPath))
    }

    /// Opening the restore dialog and backing out must leave the transaction
    /// exactly as it was. A conflict is a fact about the filesystem, not an
    /// event in the transaction's history.
    func testDeclinedConflictLeavesTheManifestUnchangedAndDoesNotAccumulateErrors() async throws {
        let root = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(root) }
        let (plan, supportRoot, backupsRoot) = try await RepairTestSupport.makePlanFixture(root: root)
        let selected = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("/Cache") })
        let store = RepairTestSupport.backupStore(backupsRoot: backupsRoot)
        let executor = RepairExecutor(backupStore: store)
        let repaired = try await executor.execute(
            plan: plan,
            selectedItemIDs: [selected.id],
            applicationIsRunning: false,
            signalboxVersion: "test"
        )
        XCTAssertEqual(repaired.state, .completed)

        let recreated = supportRoot.appendingPathComponent("Cache", isDirectory: true)
        try RepairTestSupport.createDirectory(recreated)
        try RepairTestSupport.writeFile(named: "new-session.bin", byteCount: 7, in: recreated)

        // Hit the conflict several times, as a user opening and cancelling the
        // dialog would.
        for _ in 0..<5 {
            let outcome = try await executor.restore(
                transactionID: repaired.transactionID,
                applicationIsRunning: false,
                destinationPolicy: .originalOnly
            )
            guard case .conflict = outcome else {
                return XCTFail("Expected a restore conflict, got \(outcome)")
            }
        }

        let stored = try await store.requiredManifest(transactionID: repaired.transactionID)
        XCTAssertEqual(stored.state, .completed, "A declined conflict must not downgrade a completed transaction.")
        XCTAssertEqual(stored.operations.first?.state, .moved)
        XCTAssertTrue(stored.errors.isEmpty, "Reporting a conflict must not append an error on every attempt.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.operations[0].backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recreated.appendingPathComponent("new-session.bin").path))
    }
}
