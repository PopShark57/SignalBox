import Foundation

enum RepairPlanningError: LocalizedError, Equatable, Sendable {
    case bundleIdentifierMismatch
    case recipeRequiresExplicitSupportRoot
    case invalidSupportDirectoryName(String)
    case unauditedCacheName(String)

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierMismatch:
            return "The repair recipe does not exactly match the selected application's bundle identifier."
        case .recipeRequiresExplicitSupportRoot:
            return "This recipe requires an explicitly selected application-support folder."
        case .invalidSupportDirectoryName(let name):
            return "The recipe contains an invalid application-support directory name: \(name)"
        case .unauditedCacheName(let name):
            return "The recipe contains a cache name outside Signalbox's audited list: \(name)"
        }
    }
}

enum BackupLayout {
    static let manifestFileName = "manifest.json"
    static let itemsDirectoryName = "Items"

    static func transactionDirectoryURL(rootURL: URL, transactionID: UUID, creationDate: Date) -> URL {
        let epochSeconds = Int64(creationDate.timeIntervalSince1970.rounded(.down))
        return rootURL
            .appendingPathComponent("\(epochSeconds)-\(transactionID.uuidString.lowercased())", isDirectory: true)
            .standardizedFileURL
    }

    static func backupItemURL(transactionURL: URL, operationID: UUID, originalURL: URL) -> URL {
        let safeLeaf = originalURL.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return transactionURL
            .appendingPathComponent(itemsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(operationID.uuidString.lowercased())-\(safeLeaf)", isDirectory: true)
    }
}

struct RepairPlanner: Sendable {
    let backupRootURL: URL
    private let validator = PathSafetyValidator()

    init(backupRootURL: URL) {
        self.backupRootURL = backupRootURL.standardizedFileURL
    }

    func makePlan(
        for application: InspectedApplication,
        recipe: RepairRecipe,
        supportRoot: RepairSupportRoot,
        userCachesRootURL: URL,
        createdAt: Date = Date(),
        suggestionReason: String
    ) async throws -> RepairPlan {
        guard recipe.bundleIdentifier == application.bundleIdentifier else {
            throw RepairPlanningError.bundleIdentifierMismatch
        }
        for name in recipe.allowedCacheDirectoryNames where !ElectronCacheDirectory.auditedNameSet.contains(name) {
            throw RepairPlanningError.unauditedCacheName(name)
        }

        let applicationSupportRootURL: URL
        switch supportRoot {
        case .recipeResolved(let applicationSupportParentURL):
            guard let directoryName = recipe.applicationSupportDirectoryName else {
                throw RepairPlanningError.recipeRequiresExplicitSupportRoot
            }
            guard isSinglePathComponent(directoryName) else {
                throw RepairPlanningError.invalidSupportDirectoryName(directoryName)
            }
            applicationSupportRootURL = applicationSupportParentURL
                .appendingPathComponent(directoryName, isDirectory: true)
        case .explicitlySelected(let selectedURL):
            applicationSupportRootURL = selectedURL
        }

        var specifications: [PreviewSpecification] = recipe.allowedCacheDirectoryNames.map { name in
            PreviewSpecification(
                sourceURL: applicationSupportRootURL.appendingPathComponent(name, isDirectory: true),
                allowedRootURL: applicationSupportRootURL,
                sourceKind: .applicationSupportCache,
                allowedLeafNames: [name]
            )
        }
        if recipe.includesBundleIdentifierCache {
            guard isSinglePathComponent(application.bundleIdentifier) else {
                throw RepairPlanningError.invalidSupportDirectoryName(application.bundleIdentifier)
            }
            specifications.append(
                PreviewSpecification(
                    sourceURL: userCachesRootURL.appendingPathComponent(application.bundleIdentifier, isDirectory: true),
                    allowedRootURL: userCachesRootURL,
                    sourceKind: .bundleIdentifierCache,
                    allowedLeafNames: [application.bundleIdentifier]
                )
            )
        }

        let pathValidator = validator
        let items = await withTaskGroup(of: (Int, RepairPlanItem).self, returning: [RepairPlanItem].self) { group in
            for (index, specification) in specifications.enumerated() {
                group.addTask {
                    (index, Self.preview(specification, validator: pathValidator))
                }
            }
            var indexedItems: [(Int, RepairPlanItem)] = []
            for await item in group { indexedItems.append(item) }
            return indexedItems.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let transactionID = UUID()
        return RepairPlan(
            id: transactionID,
            createdAt: createdAt,
            targetApplication: application,
            recipe: recipe,
            backupDirectoryPath: BackupLayout.transactionDirectoryURL(
                rootURL: backupRootURL,
                transactionID: transactionID,
                creationDate: createdAt
            ).path,
            items: items,
            suggestionReason: suggestionReason
        )
    }

    private static func preview(
        _ specification: PreviewSpecification,
        validator: PathSafetyValidator
    ) -> RepairPlanItem {
        do {
            let validated = try validator.validate(
                source: specification.sourceURL,
                inside: specification.allowedRootURL,
                allowedLeafNames: specification.allowedLeafNames
            )
            guard let metadata = try FileSystemMetadataReader.metadataIfPresent(at: validated.sourceURL) else {
                return RepairPlanItem(
                    sourcePath: validated.sourceURL.path,
                    displayPath: validated.sourceURL.path,
                    allowedRootPath: validated.allowedRootURL.path,
                    sourceKind: specification.sourceKind,
                    exists: false
                )
            }
            guard metadata.isDirectory else {
                return RepairPlanItem(
                    sourcePath: validated.sourceURL.path,
                    displayPath: validated.sourceURL.path,
                    allowedRootPath: validated.allowedRootURL.path,
                    sourceKind: specification.sourceKind,
                    exists: true,
                    previewMetadata: metadata,
                    unavailableReason: PathSafetyError.notDirectory(validated.sourceURL.path).localizedDescription
                )
            }
            let summary = try FileSystemMetadataReader.directorySummary(at: validated.sourceURL)
            return RepairPlanItem(
                sourcePath: validated.sourceURL.path,
                displayPath: validated.sourceURL.path,
                allowedRootPath: validated.allowedRootURL.path,
                sourceKind: specification.sourceKind,
                exists: true,
                fileCount: summary.fileCount,
                byteCount: summary.byteCount,
                previewMetadata: metadata
            )
        } catch {
            return RepairPlanItem(
                sourcePath: specification.sourceURL.standardizedFileURL.path,
                displayPath: specification.sourceURL.standardizedFileURL.path,
                allowedRootPath: specification.allowedRootURL.standardizedFileURL.path,
                sourceKind: specification.sourceKind,
                exists: (try? FileSystemMetadataReader.metadataIfPresent(at: specification.sourceURL)) != nil,
                unavailableReason: error.localizedDescription
            )
        }
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains(":")
            && !value.utf8.contains(0)
    }
}

private struct PreviewSpecification: Sendable {
    let sourceURL: URL
    let allowedRootURL: URL
    let sourceKind: RepairSourceKind
    let allowedLeafNames: Set<String>
}
