import Foundation
import XCTest
@testable import Signalbox

final class ManualRecoveryWriterTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    private let date = Date(timeIntervalSince1970: 1_735_732_800)

    func testDescribesEachBackedUpItemAsAMoveBackToItsOriginalPath() {
        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [operation(name: "Cache", state: .moved)])
        )

        XCTAssertTrue(steps.contains("~/Library/Application Support/Northstar/Cache"))
        XCTAssertTrue(steps.contains("~/Library/Application Support/Signalbox/Backups/T1/Cache"))
        XCTAssertTrue(steps.contains("Items still in the backup folder: 1"))
        XCTAssertFalse(steps.contains("/Users/alice"), "Paths are written with ~ so they stay shareable.")
    }

    /// The one instruction that must never appear. Signalbox moved these items
    /// and never deleted them; a recovery procedure that told a user to clear
    /// the destination first would destroy the data the backup exists to hold.
    func testNeverInstructsADeletion() {
        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [
                operation(name: "Cache", state: .moved),
                operation(name: "GPUCache", state: .failed)
            ])
        )

        let stepLines = steps.components(separatedBy: "\n").filter { $0.hasPrefix("   ") }
        XCTAssertFalse(stepLines.isEmpty, "The fixture must actually produce steps to inspect.")
        for line in stepLines {
            for forbidden in ["delete", "remove", "erase", "trash", "rm "] {
                XCTAssertFalse(
                    line.localizedCaseInsensitiveContains(forbidden),
                    "No step may say \"\(forbidden)\", but this one does: \(line)"
                )
            }
        }
        XCTAssertTrue(steps.contains("Do not delete anything"))
    }

    func testEveryMoveIsConditionalOnTheDestinationNotExisting() {
        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [operation(name: "Cache", state: .moved)])
        )

        XCTAssertTrue(steps.contains("Check whether that path exists."))
        XCTAssertTrue(steps.contains("If it does not exist, move"))
        XCTAssertTrue(steps.contains("leave both"))
    }

    func testAnOperationThatWasNeverMovedIsNotOfferedAsRecoverable() {
        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [
                operation(name: "Cache", state: .failed),
                operation(name: "GPUCache", state: .skipped),
                operation(name: "Code Cache", state: .planned)
            ])
        )

        XCTAssertTrue(steps.contains("Nothing in this transaction is waiting in the backup folder."))
        XCTAssertTrue(steps.contains("Recorded with no item to recover:"))
        XCTAssertTrue(steps.contains("the move failed, so the original was left where it was."))
        XCTAssertFalse(steps.contains("If it does not exist, move"))
    }

    /// An interrupted or conflicted restore is the case a user is most likely
    /// to be recovering from by hand, and in both the item is still in the
    /// backup folder.
    func testInterruptedAndConflictedRestoresAreStillRecoverable() {
        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [
                operation(name: "Cache", state: .restoring),
                operation(name: "GPUCache", state: .restoreConflict)
            ])
        )

        XCTAssertTrue(steps.contains("Items still in the backup folder: 2"))
        XCTAssertTrue(RepairOperationState.restoring.backupStillHoldsItem)
        XCTAssertTrue(RepairOperationState.restoreConflict.backupStillHoldsItem)
        XCTAssertFalse(RepairOperationState.restored.backupStillHoldsItem)
    }

    func testAlreadyRestoredItemsReportWhereTheyWentWhenItWasNotTheOriginal() {
        var restored = operation(name: "Cache", state: .restored)
        restored.restoredPath = "/Users/alice/Desktop/Signalbox Restored Cache"

        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(
            for: manifest(operations: [restored])
        )

        XCTAssertTrue(steps.contains("already restored."))
        XCTAssertTrue(steps.contains("Restored to ~/Desktop/Signalbox Restored Cache"))
    }

    func testCarriesTheTransactionIdentityNeededToFindTheFolder() {
        let record = manifest(operations: [operation(name: "Cache", state: .moved)])

        let steps = ManualRecoveryWriter(homeDirectory: home).plainText(for: record)

        XCTAssertTrue(steps.contains(record.transactionID.uuidString.lowercased()))
        XCTAssertTrue(steps.contains("Northstar"))
        XCTAssertTrue(steps.contains("com.example.northstar"))
        XCTAssertTrue(steps.contains("Try Repair History → Restore first."))
    }

    // MARK: - Fixtures

    private func manifest(operations: [RepairOperation]) -> BackupManifest {
        BackupManifest(
            transactionID: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            creationDate: date,
            targetBundleIdentifier: "com.example.northstar",
            targetApplicationName: "Northstar",
            targetApplicationVersion: "4.2.1",
            backupDirectoryPath: "/Users/alice/Library/Application Support/Signalbox/Backups/T1",
            operations: operations,
            state: .partial,
            errors: [],
            signalboxVersion: "1.0"
        )
    }

    private func operation(name: String, state: RepairOperationState) -> RepairOperation {
        RepairOperation(
            originalPath: "/Users/alice/Library/Application Support/Northstar/\(name)",
            backupPath: "/Users/alice/Library/Application Support/Signalbox/Backups/T1/\(name)",
            originalMetadata: FileMetadata(
                device: 1,
                inode: 2,
                mode: 0o40755,
                size: 96,
                modificationSeconds: 0,
                modificationNanoseconds: 0,
                isDirectory: true
            ),
            fileCount: 12,
            byteCount: 4_096,
            state: state
        )
    }
}
