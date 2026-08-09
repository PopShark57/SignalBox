import Foundation

enum BackupStoreError: LocalizedError, Equatable, Sendable {
    case unsafeBackupPath(String)
    case transactionAlreadyExists(String)
    case manifestNotFound(UUID)
    case corruptManifest(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unsafeBackupPath(let path): return "The backup path is not safe: \(path)"
        case .transactionAlreadyExists(let path): return "A backup transaction already exists at \(path)."
        case .manifestNotFound(let id): return "No backup manifest was found for transaction \(id.uuidString)."
        case .corruptManifest(let reason): return "The backup manifest is invalid: \(reason)"
        case .io(let reason): return "Backup storage failed: \(reason)"
        }
    }
}

actor BackupStore {
    nonisolated let rootURL: URL
    private let fileManager: FileManager
    private let authorizedApplicationSupportParentURL: URL
    private let authorizedUserCachesRootURL: URL
    private var explicitlyReauthorizedSupportRootPaths: Set<String> = []
    private let validator = PathSafetyValidator()

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        authorizedApplicationSupportParentURL: URL? = nil,
        authorizedUserCachesRootURL: URL? = nil
    ) {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.authorizedApplicationSupportParentURL = (
            authorizedApplicationSupportParentURL
                ?? homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        ).standardizedFileURL
        self.authorizedUserCachesRootURL = (
            authorizedUserCachesRootURL
                ?? homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        ).standardizedFileURL
    }

    /// Records an ephemeral authorization obtained from an explicit folder
    /// selection. It is intentionally not persisted: after relaunch the user
    /// must select that support root again before its manifest can be loaded or
    /// restored. The root must remain inside the configured Application
    /// Support parent and is revalidated on every manifest access.
    func reauthorizeExplicitSupportRoot(_ rootURL: URL) throws {
        do {
            let validated = try validator.validate(
                source: rootURL,
                inside: authorizedApplicationSupportParentURL,
                requireExistingDirectory: true
            )
            explicitlyReauthorizedSupportRootPaths.insert(validated.sourceURL.path)
        } catch {
            throw BackupStoreError.unsafeBackupPath(
                "Explicit support-root authorization failed for \(rootURL.path): \(error.localizedDescription)"
            )
        }
    }

    func revokeExplicitSupportRootAuthorization(_ rootURL: URL) {
        explicitlyReauthorizedSupportRootPaths.remove(
            rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    /// Preflights a plan item before a transaction directory is created.
    /// Persisted path strings are never themselves treated as authorization.
    func validateRootAuthorization(
        targetBundleIdentifier: String,
        originalPath: String,
        allowedRootPath: String,
        sourceKind: RepairSourceKind
    ) throws {
        try validateAuthorizedOriginal(
            targetBundleIdentifier: targetBundleIdentifier,
            originalURL: URL(fileURLWithPath: originalPath, isDirectory: true),
            allowedRootURL: URL(fileURLWithPath: allowedRootPath, isDirectory: true),
            sourceKind: sourceKind
        )
    }

    func transactionDirectoryURL(transactionID: UUID, creationDate: Date) -> URL {
        BackupLayout.transactionDirectoryURL(
            rootURL: rootURL,
            transactionID: transactionID,
            creationDate: creationDate
        )
    }

    @discardableResult
    func prepareTransaction(transactionID: UUID, creationDate: Date, plannedURL: URL) throws -> URL {
        let expectedURL = transactionDirectoryURL(transactionID: transactionID, creationDate: creationDate)
        guard expectedURL.standardizedFileURL.path == plannedURL.standardizedFileURL.path else {
            throw BackupStoreError.unsafeBackupPath(plannedURL.path)
        }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if try FileSystemMetadataReader.isSymbolicLink(at: rootURL) {
                throw BackupStoreError.unsafeBackupPath(rootURL.path)
            }
            if try FileSystemMetadataReader.metadataIfPresent(at: expectedURL) != nil {
                throw BackupStoreError.transactionAlreadyExists(expectedURL.path)
            }
            try fileManager.createDirectory(at: expectedURL, withIntermediateDirectories: false)
            let itemsURL = expectedURL.appendingPathComponent(BackupLayout.itemsDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: itemsURL, withIntermediateDirectories: false)
            return expectedURL
        } catch let error as BackupStoreError {
            throw error
        } catch {
            throw BackupStoreError.io(error.localizedDescription)
        }
    }

    func save(_ manifest: BackupManifest) throws {
        let transactionURL = URL(fileURLWithPath: manifest.backupDirectoryPath, isDirectory: true)
        do {
            _ = try validateTransactionURL(transactionURL)
            try validateManifestTopology(manifest, transactionURL: transactionURL)
            let manifestURL = transactionURL.appendingPathComponent(BackupLayout.manifestFileName)
            if try FileSystemMetadataReader.isSymbolicLink(at: manifestURL) {
                throw BackupStoreError.unsafeBackupPath(manifestURL.path)
            }
            let data = try Self.encoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch let error as BackupStoreError {
            throw error
        } catch {
            throw BackupStoreError.io(error.localizedDescription)
        }
    }

    func manifest(transactionID: UUID) throws -> BackupManifest? {
        try history().first { $0.transactionID == transactionID }
    }

    func requiredManifest(transactionID: UUID) throws -> BackupManifest {
        guard let manifest = try manifest(transactionID: transactionID) else {
            throw BackupStoreError.manifestNotFound(transactionID)
        }
        return manifest
    }

    func history() throws -> [BackupManifest] {
        guard try FileSystemMetadataReader.metadataIfPresent(at: rootURL) != nil else { return [] }
        if try FileSystemMetadataReader.isSymbolicLink(at: rootURL) {
            throw BackupStoreError.unsafeBackupPath(rootURL.path)
        }
        do {
            let children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var manifests: [BackupManifest] = []
            for child in children {
                if try FileSystemMetadataReader.isSymbolicLink(at: child) {
                    throw BackupStoreError.unsafeBackupPath(child.path)
                }
                guard (try FileSystemMetadataReader.metadataIfPresent(at: child))?.isDirectory == true else { continue }
                let manifestURL = child.appendingPathComponent(BackupLayout.manifestFileName)
                guard let manifestMetadata = try FileSystemMetadataReader.metadataIfPresent(at: manifestURL) else { continue }
                guard !manifestMetadata.isDirectory else {
                    throw BackupStoreError.corruptManifest("manifest.json is not a regular file.")
                }
                if try FileSystemMetadataReader.isSymbolicLink(at: manifestURL) {
                    throw BackupStoreError.unsafeBackupPath(manifestURL.path)
                }
                let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
                let decoded = try Self.decoder().decode(BackupManifest.self, from: data)
                try validateManifestTopology(decoded, transactionURL: child)
                manifests.append(decoded)
            }
            return manifests.sorted { $0.creationDate > $1.creationDate }
        } catch let error as BackupStoreError {
            throw error
        } catch {
            throw BackupStoreError.corruptManifest(error.localizedDescription)
        }
    }

    func totalBackupBytes() throws -> Int64 {
        try history().reduce(0) { $0 + $1.backupByteCount }
    }

    nonisolated func backupURL(for manifest: BackupManifest) -> URL {
        URL(fileURLWithPath: manifest.backupDirectoryPath, isDirectory: true)
    }

    private func validateTransactionURL(_ transactionURL: URL) throws -> ValidatedRepairPath {
        let validated = try validator.validate(source: transactionURL, inside: rootURL)
        let relativeCount = validated.sourceURL.pathComponents.count - validated.allowedRootURL.pathComponents.count
        guard relativeCount == 1 else { throw BackupStoreError.unsafeBackupPath(transactionURL.path) }
        return validated
    }

    /// Treat a persisted manifest as untrusted input. Restore performs fresh
    /// filesystem checks as well, but history loading first verifies that IDs,
    /// dates, original roots, and backup item paths still form the topology that
    /// Signalbox itself would have created.
    private func validateManifestTopology(
        _ manifest: BackupManifest,
        transactionURL: URL
    ) throws {
        let canonicalTransaction = transactionURL.standardizedFileURL
        let expectedTransaction = transactionDirectoryURL(
            transactionID: manifest.transactionID,
            creationDate: manifest.creationDate
        ).standardizedFileURL
        guard canonicalTransaction.path == expectedTransaction.path,
              manifest.backupDirectoryPath == canonicalTransaction.path else {
            throw BackupStoreError.corruptManifest(
                "The transaction identifier, creation date, and backup directory do not match."
            )
        }

        for operation in manifest.operations {
            let originalURL = URL(fileURLWithPath: operation.originalPath, isDirectory: true).standardizedFileURL
            let allowedRootURL = URL(fileURLWithPath: operation.allowedRootPath, isDirectory: true).standardizedFileURL
            guard originalURL.deletingLastPathComponent().path == allowedRootURL.path else {
                throw BackupStoreError.corruptManifest("An original path is not a direct child of its allowed root.")
            }

            let expectedLeaf: Set<String>
            switch operation.sourceKind {
            case .applicationSupportCache:
                expectedLeaf = ElectronCacheDirectory.auditedNameSet
            case .bundleIdentifierCache:
                expectedLeaf = [manifest.targetBundleIdentifier]
            }
            guard expectedLeaf.contains(originalURL.lastPathComponent) else {
                throw BackupStoreError.corruptManifest("An original path has an unaudited cache name.")
            }
            try validateAuthorizedOriginal(
                targetBundleIdentifier: manifest.targetBundleIdentifier,
                originalURL: originalURL,
                allowedRootURL: allowedRootURL,
                sourceKind: operation.sourceKind
            )

            let backupURL = URL(fileURLWithPath: operation.backupPath, isDirectory: true).standardizedFileURL
            let expectedBackup = BackupLayout.backupItemURL(
                transactionURL: canonicalTransaction,
                operationID: operation.id,
                originalURL: originalURL
            ).standardizedFileURL
            guard backupURL.path == expectedBackup.path else {
                throw BackupStoreError.corruptManifest("A backup item path does not match its operation identifier.")
            }
            _ = try validator.validate(source: backupURL, inside: canonicalTransaction)

            if let restoredPath = operation.restoredPath {
                let restoredURL = URL(fileURLWithPath: restoredPath, isDirectory: true).standardizedFileURL
                guard restoredURL.deletingLastPathComponent().path == allowedRootURL.path else {
                    throw BackupStoreError.corruptManifest("A restored path is not a direct child of its allowed root.")
                }
            }
        }
    }

    private func validateAuthorizedOriginal(
        targetBundleIdentifier: String,
        originalURL: URL,
        allowedRootURL: URL,
        sourceKind: RepairSourceKind
    ) throws {
        let recordedRoot = try canonicalAuthorizationRoot(allowedRootURL)
        let allowedLeaves: Set<String>

        switch sourceKind {
        case .bundleIdentifierCache:
            let expectedRoot = try canonicalAuthorizationRoot(authorizedUserCachesRootURL)
            guard recordedRoot.path == expectedRoot.path else {
                throw BackupStoreError.corruptManifest(
                    "A bundle cache root does not match the authorized user Library/Caches root."
                )
            }
            allowedLeaves = [targetBundleIdentifier]

        case .applicationSupportCache:
            allowedLeaves = ElectronCacheDirectory.auditedNameSet
            var isAuthorized = false

            if let recipe = RepairRecipeCatalog.recipe(for: targetBundleIdentifier),
               let directoryName = recipe.applicationSupportDirectoryName {
                let catalogRoot = authorizedApplicationSupportParentURL
                    .appendingPathComponent(directoryName, isDirectory: true)
                let canonicalCatalogRoot = try canonicalAuthorizationRoot(catalogRoot)
                isAuthorized = recordedRoot.path == canonicalCatalogRoot.path
            }

            if !isAuthorized,
               explicitlyReauthorizedSupportRootPaths.contains(recordedRoot.path) {
                // Revalidate the ephemeral selection so replacing it with a
                // symlink cannot extend the earlier authorization.
                let explicitRoot = try validator.validate(
                    source: recordedRoot,
                    inside: authorizedApplicationSupportParentURL,
                    requireExistingDirectory: true
                )
                isAuthorized = explicitRoot.sourceURL.path == recordedRoot.path
            }

            guard isAuthorized else {
                throw BackupStoreError.corruptManifest(
                    "The application-support root is neither the exact catalog root nor an explicitly reauthorized root."
                )
            }
        }

        let validated = try validator.validate(
            source: originalURL,
            inside: recordedRoot,
            allowedLeafNames: allowedLeaves
        )
        let relativeDepth = validated.sourceURL.pathComponents.count
            - validated.allowedRootURL.pathComponents.count
        guard relativeDepth == 1 else {
            throw BackupStoreError.corruptManifest(
                "An original cache path is not a direct child of its authorized root."
            )
        }
    }

    private func canonicalAuthorizationRoot(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.pathComponents.contains(".."),
              !url.path.utf8.contains(0) else {
            throw BackupStoreError.corruptManifest("An authorized root path is malformed.")
        }
        let standardized = url.standardizedFileURL
        if try FileSystemMetadataReader.isSymbolicLink(at: standardized) {
            throw BackupStoreError.corruptManifest("An authorized root is a symbolic link.")
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
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
