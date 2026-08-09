import Foundation

enum RepairSourceKind: String, Codable, Hashable, Sendable {
    case applicationSupportCache
    case bundleIdentifierCache
}

struct RepairRecipe: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let applicationSupportDirectoryName: String?
    let allowedCacheDirectoryNames: [String]
    let includesBundleIdentifierCache: Bool
    let rationale: String
}

/// Describes how the application-support root was obtained. A catalog root is
/// resolved from an exact bundle-ID recipe; an explicit root represents a
/// folder the user deliberately selected.
enum RepairSupportRoot: Hashable, Sendable {
    case recipeResolved(applicationSupportParentURL: URL)
    case explicitlySelected(URL)
}

struct FileMetadata: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let isDirectory: Bool
}

struct RepairPlanItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourcePath: String
    let displayPath: String
    let allowedRootPath: String
    let sourceKind: RepairSourceKind
    let exists: Bool
    let selectedByDefault: Bool
    let fileCount: Int
    let byteCount: Int64
    let previewMetadata: FileMetadata?
    let unavailableReason: String?

    init(
        id: UUID = UUID(),
        sourcePath: String,
        displayPath: String,
        allowedRootPath: String,
        sourceKind: RepairSourceKind,
        exists: Bool,
        selectedByDefault: Bool = false,
        fileCount: Int = 0,
        byteCount: Int64 = 0,
        previewMetadata: FileMetadata? = nil,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.displayPath = displayPath
        self.allowedRootPath = allowedRootPath
        self.sourceKind = sourceKind
        self.exists = exists
        self.selectedByDefault = selectedByDefault
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.previewMetadata = previewMetadata
        self.unavailableReason = unavailableReason
    }
}

struct RepairPlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let targetApplication: InspectedApplication
    let recipe: RepairRecipe
    let backupDirectoryPath: String
    let items: [RepairPlanItem]
    let suggestionReason: String

    init(
        id: UUID = UUID(),
        createdAt: Date,
        targetApplication: InspectedApplication,
        recipe: RepairRecipe,
        backupDirectoryPath: String,
        items: [RepairPlanItem],
        suggestionReason: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetApplication = targetApplication
        self.recipe = recipe
        self.backupDirectoryPath = backupDirectoryPath
        self.items = items
        self.suggestionReason = suggestionReason
    }
}

enum RepairOperationState: String, Codable, Hashable, Sendable {
    case planned
    case moved
    case failed
    case restoring
    case restored
    case restoreConflict
    case skipped
}

struct RepairOperation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let originalPath: String
    let backupPath: String
    let allowedRootPath: String
    let sourceKind: RepairSourceKind
    let originalMetadata: FileMetadata
    let fileCount: Int
    let byteCount: Int64
    var state: RepairOperationState
    var error: String?
    var restoredPath: String?

    init(
        id: UUID = UUID(),
        originalPath: String,
        backupPath: String,
        allowedRootPath: String? = nil,
        sourceKind: RepairSourceKind = .applicationSupportCache,
        originalMetadata: FileMetadata,
        fileCount: Int,
        byteCount: Int64,
        state: RepairOperationState,
        error: String? = nil,
        restoredPath: String? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.allowedRootPath = allowedRootPath
            ?? URL(fileURLWithPath: originalPath).deletingLastPathComponent().path
        self.sourceKind = sourceKind
        self.originalMetadata = originalMetadata
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.state = state
        self.error = error
        self.restoredPath = restoredPath
    }
}

enum RepairTransactionState: String, Codable, Hashable, Sendable {
    case planned
    case completed
    case partial
    case failed
    case restored
    case restorePartial
}

struct BackupManifest: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { transactionID }
    let transactionID: UUID
    let creationDate: Date
    let targetBundleIdentifier: String
    let targetApplicationName: String
    let targetApplicationVersion: String
    let backupDirectoryPath: String
    var operations: [RepairOperation]
    var state: RepairTransactionState
    var errors: [String]
    let signalboxVersion: String

    var movedItemCount: Int { operations.filter { $0.state == .moved || $0.state == .restoring || $0.state == .restored || $0.state == .restoreConflict }.count }
    var backupByteCount: Int64 {
        operations
            .filter { $0.state == .moved || $0.state == .restoring || $0.state == .restoreConflict }
            .reduce(0) { $0 + $1.byteCount }
    }
}

enum RepairExecutionError: LocalizedError, Equatable {
    case applicationRunning
    case noItemsSelected
    case unsafePath(String)
    case sourceChanged(String)
    case sourceUnavailable(String)
    case crossVolumeMove(String)
    case destinationExists(String)
    case manifestWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationRunning: return "The target application must be closed before continuing."
        case .noItemsSelected: return "Select at least one cache item to continue."
        case .unsafePath(let message): return "The proposed path is not safe: \(message)"
        case .sourceChanged(let path): return "The source changed after preview: \(path)"
        case .sourceUnavailable(let path): return "The source is unavailable: \(path)"
        case .crossVolumeMove(let path): return "A same-volume atomic move is not possible for: \(path)"
        case .destinationExists(let path): return "The destination already exists: \(path)"
        case .manifestWriteFailed(let message): return "The backup manifest could not be written: \(message)"
        }
    }
}

enum RestoreOutcome: Equatable, Sendable {
    case restored(BackupManifest)
    case conflict(originalPath: String, suggestedAlternatePath: String)
    case partial(BackupManifest)
}

enum RestoreDestinationPolicy: Equatable, Sendable {
    /// Restore only to the recorded original locations. Any conflict stops the
    /// restore before a filesystem move occurs.
    case originalOnly
    /// Keep a newly-created original intact and restore the backup beside it
    /// using a deterministic, non-overwriting alternate name.
    case suggestedAlternate
}
