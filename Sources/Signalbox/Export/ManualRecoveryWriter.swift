import Foundation

/// Turns one backup manifest into the plain-text recovery procedure for that
/// specific transaction.
///
/// Signalbox's promise is that every transaction is recoverable by hand from an
/// ordinary folder and a readable `manifest.json`. That promise is only as good
/// as the reader's ability to act on it, and the general instructions in the
/// documentation ask them to translate a procedure into their own paths while
/// something is already broken. This writes the same procedure with the paths
/// filled in.
///
/// Three rules hold whatever the manifest says:
///
/// - Every step is a **move**, never a delete. Nothing here can destroy data,
///   and no step is ever phrased as "remove the old one first".
/// - An operation is only presented as recoverable when the backup actually
///   still holds it. A restored or failed operation is described as what it is.
/// - Every step is conditional on the destination not existing. If the
///   application has recreated the cache, the honest instruction is to stop and
///   leave both copies alone, exactly as Signalbox's own restore does.
///
/// The text is derived from the manifest alone; the file system is never read.
/// So this describes what Signalbox recorded, and says so — the reader is asked
/// to confirm each path before moving anything.
struct ManualRecoveryWriter: Sendable {
    private let homeDirectoryPath: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeDirectoryPath = homeDirectory.standardizedFileURL.path
    }

    func plainText(for manifest: BackupManifest) -> String {
        var lines = [
            "Signalbox manual recovery steps",
            "",
            "Application: \(manifest.targetApplicationName) \(manifest.targetApplicationVersion)",
            "Bundle identifier: \(manifest.targetBundleIdentifier)",
            "Transaction: \(manifest.transactionID.uuidString.lowercased())",
            "Created: \(date(manifest.creationDate))",
            "Recorded state: \(label(manifest.state.rawValue))",
            "Backup folder: \(tilde(manifest.backupDirectoryPath))",
            "Written by Signalbox \(manifest.signalboxVersion)",
            "",
            "These steps come from the manifest Signalbox wrote, not from reading the",
            "disk just now. Confirm each path before moving anything.",
            "",
            "Try Repair History → Restore first. It performs these same moves, checks",
            "for conflicts before touching anything, and updates the manifest. Use these",
            "steps when Signalbox itself is unavailable.",
            "",
            "Close \(manifest.targetApplicationName) before you begin.",
            ""
        ]

        let recoverable = manifest.operations.filter { $0.state.backupStillHoldsItem }
        if recoverable.isEmpty {
            lines.append("Nothing in this transaction is waiting in the backup folder.")
            lines.append("")
        } else {
            lines.append("Items still in the backup folder: \(recoverable.count)")
            lines.append("")
            for (index, operation) in recoverable.enumerated() {
                lines.append("\(index + 1). \(tilde(operation.originalPath))")
                lines.append("   a. Check whether that path exists.")
                lines.append("      If it does, \(manifest.targetApplicationName) has recreated it. Stop: leave both")
                lines.append("      copies where they are and use Signalbox's alternate restore location.")
                lines.append("   b. If it does not exist, move")
                lines.append("      \(tilde(operation.backupPath))")
                lines.append("      to exactly")
                lines.append("      \(tilde(operation.originalPath))")
                lines.append("   c. Recorded at backup time: \(operation.fileCount) files, \(bytes(operation.byteCount)).")
                lines.append("")
            }
        }

        let unmoved = manifest.operations.filter { !$0.state.backupStillHoldsItem }
        if !unmoved.isEmpty {
            lines.append("Recorded with no item to recover:")
            lines.append("")
            for operation in unmoved {
                lines.append("- \(tilde(operation.originalPath)) — \(operation.state.recoveryNote)")
                if operation.state == .restored, let restoredPath = operation.restoredPath,
                   restoredPath != operation.originalPath {
                    lines.append("  Restored to \(tilde(restoredPath)) instead of its original location.")
                }
            }
            lines.append("")
        }

        lines.append("Do not delete anything as part of this procedure. Signalbox moved these")
        lines.append("items; it never deleted them, and recovery is a move back.")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private func tilde(_ path: String) -> String {
        guard !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" else { return path }
        if path == homeDirectoryPath { return "~" }
        return path.replacingOccurrences(of: homeDirectoryPath + "/", with: "~/")
    }

    private func label(_ value: String) -> String {
        value.replacingOccurrences(of: "restore", with: "restore ").capitalized
    }

    private func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}

extension RepairOperationState {
    /// Whether the backup directory should still contain this item.
    ///
    /// `.restoring` and `.restoreConflict` are included deliberately: both mean
    /// a restore began or was blocked, and in each case the item was last
    /// recorded in the backup. Excluding them would tell a user recovering by
    /// hand that there is nothing to recover, while their cache sat in the
    /// backup folder.
    var backupStillHoldsItem: Bool {
        switch self {
        case .moved, .restoring, .restoreConflict: true
        case .planned, .failed, .restored, .skipped: false
        }
    }

    var recoveryNote: String {
        switch self {
        case .planned: "planned only; it was never moved, so the original is untouched."
        case .moved: "in the backup folder."
        case .failed: "the move failed, so the original was left where it was."
        case .restoring: "a restore was interrupted; the item was last recorded in the backup folder."
        case .restored: "already restored."
        case .restoreConflict: "a restore stopped at a conflict; the item is still in the backup folder."
        case .skipped: "skipped, so the original was left where it was."
        }
    }
}
