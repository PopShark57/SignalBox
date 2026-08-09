import Foundation

enum SnapshotTimelineError: LocalizedError, Equatable, Sendable {
    case unsafePath(String)
    case unreadableArchive(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "The snapshot timeline path is not safe: \(path)"
        case .unreadableArchive(let reason):
            return "The snapshot timeline could not be read: \(reason)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "The stored snapshot timeline uses format \(found), but this version of Signalbox understands format \(supported). Signalbox left the existing file untouched."
        case .io(let reason):
            return "The snapshot timeline could not be saved: \(reason)"
        }
    }
}

/// Persists a bounded series of reduced snapshot summaries so Signalbox can
/// answer "has this recurred?" without keeping a behavioural log of the Mac.
///
/// Three deliberate limits:
///
/// - Only `SnapshotSummary` is written, never a whole `SystemSnapshot`. Running
///   applications, raw report content, file names, and free-form provider text
///   are excluded by the summary type itself.
/// - The archive is capped at `maximumEntries`; the oldest entries fall off.
///   Signalbox is a diagnostic tool, not a monitoring agent.
/// - Demo snapshots are never recorded, so turning on demo mode can never
///   contaminate the record of a real Mac.
actor SnapshotTimelineStore {
    static let defaultMaximumEntries = 60

    nonisolated let fileURL: URL
    private let maximumEntries: Int
    private let fileManager: FileManager

    init(
        directoryURL: URL,
        fileName: String = "snapshots.json",
        maximumEntries: Int = SnapshotTimelineStore.defaultMaximumEntries,
        fileManager: FileManager = .default
    ) {
        self.fileURL = directoryURL.standardizedFileURL.appendingPathComponent(fileName)
        self.maximumEntries = max(2, maximumEntries)
        self.fileManager = fileManager
    }

    /// Returns entries oldest-first. A missing file is an empty timeline, which
    /// is a truthful "nothing recorded yet" rather than an error.
    func entries() throws -> [SnapshotSummary] {
        guard let metadata = try metadataIfPresent() else { return [] }
        guard !metadata.isDirectory else {
            throw SnapshotTimelineError.unsafePath(fileURL.path)
        }
        if try FileSystemMetadataReader.isSymbolicLink(at: fileURL) {
            throw SnapshotTimelineError.unsafePath(fileURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw SnapshotTimelineError.unreadableArchive(error.localizedDescription)
        }

        let archive: SnapshotTimelineArchive
        do {
            archive = try Self.decoder().decode(SnapshotTimelineArchive.self, from: data)
        } catch {
            throw SnapshotTimelineError.unreadableArchive(error.localizedDescription)
        }
        guard archive.schemaVersion == SnapshotSummary.currentSchemaVersion else {
            throw SnapshotTimelineError.unsupportedSchemaVersion(
                found: archive.schemaVersion,
                supported: SnapshotSummary.currentSchemaVersion
            )
        }

        return Self.ordered(archive.entries)
    }

    /// Records one collection and returns the resulting timeline, oldest-first.
    ///
    /// Demo snapshots are rejected here as well as at the call site so a future
    /// caller cannot accidentally write fixtures into a real timeline.
    @discardableResult
    func record(_ snapshot: SystemSnapshot) throws -> [SnapshotSummary] {
        guard !snapshot.isDemo else { return try entries() }
        return try record(SnapshotSummary(snapshot: snapshot))
    }

    @discardableResult
    func record(_ summary: SnapshotSummary) throws -> [SnapshotSummary] {
        var existing = try entries()
        // A repeated collection at the exact same instant is a duplicate, not a
        // second observation; replacing it keeps recurrence counts honest.
        existing.removeAll { $0.collectedAt == summary.collectedAt }
        existing.append(summary)

        let trimmed = Array(Self.ordered(existing).suffix(maximumEntries))
        try write(SnapshotTimelineArchive(entries: trimmed))
        return trimmed
    }

    /// Deletes the stored timeline. This is the only destructive operation in
    /// Signalbox, it affects only Signalbox's own file, and it is always the
    /// result of an explicit request.
    func clear() throws {
        guard try metadataIfPresent() != nil else { return }
        if try FileSystemMetadataReader.isSymbolicLink(at: fileURL) {
            throw SnapshotTimelineError.unsafePath(fileURL.path)
        }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw SnapshotTimelineError.io(error.localizedDescription)
        }
    }

    private func write(_ archive: SnapshotTimelineArchive) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw SnapshotTimelineError.io(error.localizedDescription)
        }
        if try FileSystemMetadataReader.isSymbolicLink(at: directoryURL) {
            throw SnapshotTimelineError.unsafePath(directoryURL.path)
        }
        if try FileSystemMetadataReader.isSymbolicLink(at: fileURL) {
            throw SnapshotTimelineError.unsafePath(fileURL.path)
        }

        do {
            let data = try Self.encoder().encode(archive)
            try data.write(to: fileURL, options: .atomic)
        } catch let error as SnapshotTimelineError {
            throw error
        } catch {
            throw SnapshotTimelineError.io(error.localizedDescription)
        }
    }

    private func metadataIfPresent() throws -> FileMetadata? {
        do {
            return try FileSystemMetadataReader.metadataIfPresent(at: fileURL)
        } catch {
            throw SnapshotTimelineError.unsafePath("\(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// Oldest-first, with the identifier breaking ties so two entries recorded
    /// in the same instant still have a stable order across launches.
    private static func ordered(_ entries: [SnapshotSummary]) -> [SnapshotSummary] {
        entries.sorted {
            $0.collectedAt == $1.collectedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.collectedAt < $1.collectedAt
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
