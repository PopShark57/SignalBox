import Darwin
import Foundation

/// All repair and restore mutations are isolated here. Calls against a single
/// executor are serialized by the actor, and moves use POSIX rename only.
actor RepairExecutor {
    private let backupStore: BackupStore
    private let applicationRunningCheck: @Sendable (String) async -> Bool
    private let validator = PathSafetyValidator()

    init(
        backupStore: BackupStore,
        applicationRunningCheck: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) {
        self.backupStore = backupStore
        self.applicationRunningCheck = applicationRunningCheck
    }

    func execute(
        plan: RepairPlan,
        selectedItemIDs: Set<UUID>,
        applicationIsRunning: Bool,
        signalboxVersion: String
    ) async throws -> BackupManifest {
        guard !applicationIsRunning,
              !(await applicationRunningCheck(plan.targetApplication.bundleIdentifier)) else {
            throw RepairExecutionError.applicationRunning
        }
        guard !selectedItemIDs.isEmpty else { throw RepairExecutionError.noItemsSelected }

        let selectedItems = plan.items.filter { selectedItemIDs.contains($0.id) }
        guard !selectedItems.isEmpty else { throw RepairExecutionError.noItemsSelected }

        // The plan is data, not authority. Re-derive catalog and bundle-cache
        // roots (or require a live explicit-folder authorization) before even
        // creating the transaction directory.
        for item in selectedItems {
            do {
                try await backupStore.validateRootAuthorization(
                    targetBundleIdentifier: plan.targetApplication.bundleIdentifier,
                    originalPath: item.sourcePath,
                    allowedRootPath: item.allowedRootPath,
                    sourceKind: item.sourceKind
                )
            } catch {
                throw RepairExecutionError.unsafePath(error.localizedDescription)
            }
        }

        let transactionURL = URL(fileURLWithPath: plan.backupDirectoryPath, isDirectory: true)
        _ = try await backupStore.prepareTransaction(
            transactionID: plan.id,
            creationDate: plan.createdAt,
            plannedURL: transactionURL
        )

        var preparationErrors: [String] = []
        var operations: [RepairOperation] = []
        for item in selectedItems {
            guard item.exists, item.unavailableReason == nil, let metadata = item.previewMetadata else {
                preparationErrors.append("\(item.sourcePath): \(item.unavailableReason ?? "the item was unavailable during preview")")
                continue
            }
            let operationID = UUID()
            operations.append(
                RepairOperation(
                    id: operationID,
                    originalPath: item.sourcePath,
                    backupPath: BackupLayout.backupItemURL(
                        transactionURL: transactionURL,
                        operationID: operationID,
                        originalURL: URL(fileURLWithPath: item.sourcePath, isDirectory: true)
                    ).path,
                    allowedRootPath: item.allowedRootPath,
                    sourceKind: item.sourceKind,
                    originalMetadata: metadata,
                    fileCount: item.fileCount,
                    byteCount: item.byteCount,
                    state: .planned
                )
            )
        }

        var manifest = BackupManifest(
            transactionID: plan.id,
            creationDate: plan.createdAt,
            targetBundleIdentifier: plan.targetApplication.bundleIdentifier,
            targetApplicationName: plan.targetApplication.name,
            targetApplicationVersion: plan.targetApplication.version,
            backupDirectoryPath: transactionURL.path,
            operations: operations,
            state: operations.isEmpty ? .failed : .planned,
            errors: preparationErrors,
            signalboxVersion: signalboxVersion
        )
        try await persist(manifest)

        let itemsDirectoryURL = transactionURL.appendingPathComponent(BackupLayout.itemsDirectoryName, isDirectory: true)
        let backupDevice = try FileSystemMetadataReader.metadata(at: itemsDirectoryURL).device

        for index in manifest.operations.indices {
            let originalURL = URL(fileURLWithPath: manifest.operations[index].originalPath, isDirectory: true)
            let allowedRootURL = URL(fileURLWithPath: manifest.operations[index].allowedRootPath, isDirectory: true)
            let backupURL = URL(fileURLWithPath: manifest.operations[index].backupPath, isDirectory: true)
            do {
                guard !(await applicationRunningCheck(manifest.targetBundleIdentifier)) else {
                    throw RepairExecutionError.applicationRunning
                }
                let allowedLeaves = allowedLeafNames(
                    sourceKind: manifest.operations[index].sourceKind,
                    targetBundleIdentifier: manifest.targetBundleIdentifier
                )
                let validated = try validator.validate(
                    source: originalURL,
                    inside: allowedRootURL,
                    allowedLeafNames: allowedLeaves,
                    requireExistingDirectory: true
                )
                let currentMetadata = try FileSystemMetadataReader.metadata(at: validated.sourceURL)
                guard currentMetadata == manifest.operations[index].originalMetadata else {
                    throw RepairExecutionError.sourceChanged(validated.sourceURL.path)
                }
                let validatedBackup = try validator.validate(
                    source: backupURL,
                    inside: transactionURL
                )
                let backupRelativeComponents = validatedBackup.sourceURL.pathComponents.dropFirst(
                    validatedBackup.allowedRootURL.pathComponents.count
                )
                guard backupRelativeComponents.count == 2,
                      backupRelativeComponents.first == BackupLayout.itemsDirectoryName else {
                    throw RepairExecutionError.unsafePath(backupURL.path)
                }
                guard currentMetadata.device == backupDevice else {
                    throw RepairExecutionError.crossVolumeMove(validated.sourceURL.path)
                }
                guard try FileSystemMetadataReader.metadataIfPresent(at: validatedBackup.sourceURL) == nil else {
                    throw RepairExecutionError.destinationExists(validatedBackup.sourceURL.path)
                }
                guard posixRenameExclusive(from: validated.sourceURL, to: validatedBackup.sourceURL) == 0 else {
                    if errno == EXDEV { throw RepairExecutionError.crossVolumeMove(validated.sourceURL.path) }
                    throw RepairExecutionError.sourceUnavailable("\(validated.sourceURL.path): \(posixMessage())")
                }

                manifest.operations[index].state = .moved
                manifest.operations[index].error = nil
                do {
                    try await persist(manifest)
                } catch {
                    let persistenceDescription = error.localizedDescription
                    if posixRenameExclusive(from: validatedBackup.sourceURL, to: validated.sourceURL) == 0 {
                        manifest.operations[index].state = .failed
                        manifest.operations[index].error = "The manifest update failed, so the move was rolled back: \(persistenceDescription)"
                        manifest.errors.append(manifest.operations[index].error!)
                        try await persist(manifest)
                    } else {
                        manifest.operations[index].error = "The item was moved, but the manifest update and rollback both failed: \(persistenceDescription)"
                        manifest.errors.append(manifest.operations[index].error!)
                        manifest.state = .partial
                        try? await backupStore.save(manifest)
                        throw RepairExecutionError.manifestWriteFailed(manifest.operations[index].error!)
                    }
                }
            } catch let error as RepairExecutionError {
                if case .manifestWriteFailed = error {
                    // A failed rollback can mean the source is already in the
                    // backup. Do not relabel that operation as an ordinary
                    // filesystem failure.
                    throw error
                }
                manifest.operations[index].state = .failed
                manifest.operations[index].error = error.localizedDescription
                manifest.errors.append(error.localizedDescription)
                try await persist(manifest)
            } catch {
                manifest.operations[index].state = .failed
                manifest.operations[index].error = error.localizedDescription
                manifest.errors.append(error.localizedDescription)
                try await persist(manifest)
            }
        }

        let movedCount = manifest.operations.filter { $0.state == .moved }.count
        let failedCount = manifest.operations.filter { $0.state == .failed }.count + preparationErrors.count
        if movedCount == manifest.operations.count, failedCount == 0 {
            manifest.state = .completed
        } else if movedCount > 0 {
            manifest.state = .partial
        } else {
            manifest.state = .failed
        }
        try await persist(manifest)
        return manifest
    }

    func restore(
        transactionID: UUID,
        applicationIsRunning: Bool,
        destinationPolicy: RestoreDestinationPolicy = .originalOnly
    ) async throws -> RestoreOutcome {
        guard !applicationIsRunning else { throw RepairExecutionError.applicationRunning }
        var manifest = try await backupStore.requiredManifest(transactionID: transactionID)
        guard !(await applicationRunningCheck(manifest.targetBundleIdentifier)) else {
            throw RepairExecutionError.applicationRunning
        }
        try await reconcileInterruptedRestores(in: &manifest)
        let eligibleIndices = manifest.operations.indices.filter {
            manifest.operations[$0].state == .moved || manifest.operations[$0].state == .restoreConflict
        }
        if eligibleIndices.isEmpty {
            return manifest.state == .restored ? .restored(manifest) : .partial(manifest)
        }

        var destinations: [Int: URL] = [:]
        var persistenceWasLostAfterMove = false
        var restoreFailureOccurred = false
        for index in eligibleIndices {
            let operation = manifest.operations[index]
            let originalURL = URL(fileURLWithPath: operation.originalPath, isDirectory: true)
            if try FileSystemMetadataReader.metadataIfPresent(at: originalURL) != nil {
                let alternateURL = availableAlternateURL(for: originalURL, transactionID: manifest.transactionID)
                if destinationPolicy == .originalOnly {
                    // Nothing has been moved yet, so nothing about the
                    // transaction has actually changed. Persisting
                    // `.restorePartial` here would claim a restore was
                    // attempted when the user has not even been asked, and
                    // appending an error on every attempt would grow the
                    // manifest without bound each time the dialog is opened.
                    // The conflict is a fact about the filesystem right now and
                    // is re-derived on every attempt, so it is reported rather
                    // than recorded.
                    return .conflict(originalPath: originalURL.path, suggestedAlternatePath: alternateURL.path)
                }
                destinations[index] = alternateURL
            } else {
                destinations[index] = originalURL
            }
        }

        for index in eligibleIndices {
            let operation = manifest.operations[index]
            let originalURL = URL(fileURLWithPath: operation.originalPath, isDirectory: true)
            let backupURL = URL(fileURLWithPath: operation.backupPath, isDirectory: true)
            let transactionURL = URL(fileURLWithPath: manifest.backupDirectoryPath, isDirectory: true)
            let destinationURL = destinations[index]!
            do {
                guard !(await applicationRunningCheck(manifest.targetBundleIdentifier)) else {
                    throw RepairExecutionError.applicationRunning
                }
                let expectedBackupURL = BackupLayout.backupItemURL(
                    transactionURL: transactionURL,
                    operationID: operation.id,
                    originalURL: originalURL
                ).standardizedFileURL
                guard expectedBackupURL.path == backupURL.standardizedFileURL.path else {
                    throw RepairExecutionError.unsafePath(backupURL.path)
                }
                _ = try validator.validate(
                    source: backupURL,
                    inside: transactionURL,
                    requireExistingDirectory: true
                )
                let backupMetadata = try FileSystemMetadataReader.metadata(at: backupURL)
                guard backupMetadata == operation.originalMetadata else {
                    throw RepairExecutionError.sourceChanged(backupURL.path)
                }

                let allowedRootURL = URL(fileURLWithPath: operation.allowedRootPath, isDirectory: true)
                let originalValidated = try validator.validate(
                    source: originalURL,
                    inside: allowedRootURL,
                    allowedLeafNames: allowedLeafNames(
                        sourceKind: operation.sourceKind,
                        targetBundleIdentifier: manifest.targetBundleIdentifier
                    )
                )
                let destinationValidated: ValidatedRepairPath
                if destinationURL.standardizedFileURL == originalURL.standardizedFileURL {
                    destinationValidated = originalValidated
                } else {
                    destinationValidated = try validator.validate(source: destinationURL, inside: allowedRootURL)
                    let relativeDepth = destinationValidated.sourceURL.pathComponents.count
                        - destinationValidated.allowedRootURL.pathComponents.count
                    guard relativeDepth == 1 else { throw RepairExecutionError.unsafePath(destinationURL.path) }
                }
                guard try FileSystemMetadataReader.metadataIfPresent(at: destinationValidated.sourceURL) == nil else {
                    throw RepairExecutionError.destinationExists(destinationValidated.sourceURL.path)
                }
                let allowedRootMetadata = try FileSystemMetadataReader.metadata(at: destinationValidated.allowedRootURL)
                guard allowedRootMetadata.device == backupMetadata.device else {
                    throw RepairExecutionError.crossVolumeMove(destinationValidated.sourceURL.path)
                }

                // Persist the intended destination before the rename. If the
                // process or manifest write fails immediately after the move,
                // the next history load can reconcile the two paths without
                // guessing or falsely claiming that the backup is still moved.
                manifest.operations[index].state = .restoring
                manifest.operations[index].restoredPath = destinationValidated.sourceURL.path
                manifest.operations[index].error = nil
                manifest.state = .restorePartial
                try await persist(manifest)

                guard posixRenameExclusive(from: backupURL, to: destinationValidated.sourceURL) == 0 else {
                    if errno == EXDEV { throw RepairExecutionError.crossVolumeMove(destinationValidated.sourceURL.path) }
                    throw RepairExecutionError.sourceUnavailable("\(backupURL.path): \(posixMessage())")
                }
                manifest.operations[index].state = .restored
                manifest.operations[index].restoredPath = destinationValidated.sourceURL.path
                manifest.operations[index].error = nil
                do {
                    try await persist(manifest)
                } catch {
                    let message = "The item was restored, but the manifest update failed: \(error.localizedDescription)"
                    if posixRenameExclusive(from: destinationValidated.sourceURL, to: backupURL) == 0 {
                        manifest.operations[index].state = .moved
                        manifest.operations[index].restoredPath = nil
                        manifest.operations[index].error = message + " The restore was rolled back."
                        manifest.errors.append(manifest.operations[index].error!)
                        do {
                            try await persist(manifest)
                        } catch {
                            // The on-disk pre-move `.restoring` record is still
                            // sufficient for deterministic reconciliation.
                            persistenceWasLostAfterMove = true
                        }
                    } else {
                        manifest.operations[index].state = .restoring
                        manifest.operations[index].error = message + " The rollback also failed; Signalbox will reconcile both paths next time history is loaded."
                        manifest.errors.append(manifest.operations[index].error!)
                        persistenceWasLostAfterMove = true
                    }
                }
            } catch {
                // Keep `.moved` so a safe restore can be retried later.
                restoreFailureOccurred = true
                manifest.operations[index].state = .moved
                manifest.operations[index].restoredPath = nil
                manifest.operations[index].error = error.localizedDescription
                manifest.errors.append("Restore: \(error.localizedDescription)")
                manifest.state = .restorePartial
                try await persist(manifest)
            }
            if persistenceWasLostAfterMove { break }
        }

        if persistenceWasLostAfterMove {
            manifest.state = .restorePartial
            return .partial(manifest)
        }

        let hasPendingBackup = manifest.operations.contains {
            $0.state == .moved || $0.state == .restoring || $0.state == .restoreConflict
        }
        // Only failures from *this restore* make the restore partial. An
        // operation that failed during the original repair was never moved, so
        // it has no backup to put back; counting it here meant a `.partial`
        // transaction could never reach `.restored` even after every backed-up
        // item was returned, and the user was told "some items could not be
        // restored" about a backup directory that was already empty.
        if !hasPendingBackup && !restoreFailureOccurred {
            manifest.state = .restored
            try await persist(manifest)
            return .restored(manifest)
        }
        manifest.state = .restorePartial
        try await persist(manifest)
        return .partial(manifest)
    }

    /// History, with any interrupted restore reconciled first.
    ///
    /// Reconciliation used to run only inside `restore()`, so a transaction
    /// whose restore was interrupted kept showing its item as still occupying
    /// backup space until the user happened to start another restore — the
    /// opposite of what the executor's own comments promised. Loading history
    /// is the moment the claim is made, so it is the moment to verify it.
    func reconciledHistory() async throws -> [BackupManifest] {
        var results: [BackupManifest] = []
        for manifest in try await backupStore.history() {
            guard manifest.operations.contains(where: { $0.state == .restoring }) else {
                results.append(manifest)
                continue
            }
            var reconciled = manifest
            do {
                try await reconcileInterruptedRestores(in: &reconciled)
                results.append(reconciled)
            } catch {
                // A transaction that cannot be reconciled is still real
                // evidence; show it as recorded rather than hiding it.
                results.append(manifest)
            }
        }
        return results
    }

    func suggestedAlternatePath(originalPath: String, transactionID: UUID) -> String {
        availableAlternateURL(
            for: URL(fileURLWithPath: originalPath, isDirectory: true),
            transactionID: transactionID
        ).path
    }

    private func persist(_ manifest: BackupManifest) async throws {
        do {
            try await backupStore.save(manifest)
        } catch {
            throw RepairExecutionError.manifestWriteFailed(error.localizedDescription)
        }
    }

    private func reconcileInterruptedRestores(in manifest: inout BackupManifest) async throws {
        var changed = false
        for index in manifest.operations.indices where manifest.operations[index].state == .restoring {
            let operation = manifest.operations[index]
            let backupURL = URL(fileURLWithPath: operation.backupPath, isDirectory: true)
            let destinationURL = URL(
                fileURLWithPath: operation.restoredPath ?? operation.originalPath,
                isDirectory: true
            )
            let backupMetadata = try FileSystemMetadataReader.metadataIfPresent(at: backupURL)
            let destinationMetadata = try FileSystemMetadataReader.metadataIfPresent(at: destinationURL)

            switch (backupMetadata, destinationMetadata) {
            case (.some, .none):
                manifest.operations[index].state = .moved
                manifest.operations[index].restoredPath = nil
                manifest.operations[index].error = "A previously interrupted restore was reconciled before retrying."
            // Identity, not full metadata. A rename preserves the device and
            // inode, but the moment the app reopens the restored cache its
            // modification time and size change. Demanding full equality
            // labelled a successful restore as `.failed` as soon as the cache
            // was used again, and nothing could move it back to `.restored`.
            case (.none, .some(let metadata))
                where metadata.device == operation.originalMetadata.device
                    && metadata.inode == operation.originalMetadata.inode:
                manifest.operations[index].state = .restored
                manifest.operations[index].error = nil
            case (.some, .some):
                manifest.operations[index].state = .restoreConflict
                manifest.operations[index].error = "Both the backup and intended restore destination exist after an interrupted restore. Nothing was overwritten."
            case (.none, .none):
                manifest.operations[index].state = .failed
                manifest.operations[index].error = "Neither the backup nor intended restore destination exists after an interrupted restore."
            case (.none, .some):
                manifest.operations[index].state = .failed
                manifest.operations[index].error = "The intended restore destination exists, but its metadata does not match the backup manifest."
            }
            if let error = manifest.operations[index].error {
                manifest.errors.append(error)
            }
            changed = true
        }

        if changed {
            let hasPending = manifest.operations.contains {
                $0.state == .moved || $0.state == .restoring || $0.state == .restoreConflict
            }
            let hasFailure = manifest.operations.contains { $0.state == .failed || $0.state == .skipped }
            manifest.state = (!hasPending && !hasFailure) ? .restored : .restorePartial
            try await persist(manifest)
        }
    }

    private func allowedLeafNames(
        sourceKind: RepairSourceKind,
        targetBundleIdentifier: String
    ) -> Set<String> {
        switch sourceKind {
        case .applicationSupportCache: return ElectronCacheDirectory.auditedNameSet
        case .bundleIdentifierCache: return [targetBundleIdentifier]
        }
    }

    private func availableAlternateURL(for originalURL: URL, transactionID: UUID) -> URL {
        let parent = originalURL.deletingLastPathComponent()
        let shortID = transactionID.uuidString.prefix(8).lowercased()
        let baseName = "\(originalURL.lastPathComponent) (Signalbox Restore \(shortID))"
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while (try? FileSystemMetadataReader.metadataIfPresent(at: candidate)) != nil {
            candidate = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// `RENAME_EXCL` makes the no-overwrite guarantee atomic. The preceding
    /// existence checks are only for clearer errors; they are not trusted for
    /// safety because another process can create a destination concurrently.
    private func posixRenameExclusive(from sourceURL: URL, to destinationURL: URL) -> Int32 {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
    }

    private func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
