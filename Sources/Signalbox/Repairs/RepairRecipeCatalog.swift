import Foundation

/// The only Electron cache directory names Signalbox will offer to move.
/// Keeping this list closed prevents a recipe from accidentally expanding into
/// preferences, sessions, databases, or user-created content.
enum ElectronCacheDirectory {
    static let auditedNames = [
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache"
    ]

    static let auditedNameSet = Set(auditedNames)
}

/// A deliberately small, local, auditable catalog. Matching is exact on the
/// bundle identifier; app names are never used to guess support folders.
enum RepairRecipeCatalog {
    static let allRecipes: [RepairRecipe] = [
        RepairRecipe(
            id: "electron-cache-only.claude",
            name: "Rebuild disposable Electron caches",
            bundleIdentifier: "com.anthropic.claudefordesktop",
            applicationSupportDirectoryName: "Claude",
            allowedCacheDirectoryNames: ElectronCacheDirectory.auditedNames,
            includesBundleIdentifierCache: true,
            rationale: "Claude uses Chromium/Electron caches that can be recreated. Moving only these caches is a reversible experiment, not a guaranteed fix."
        ),
        RepairRecipe(
            id: "electron-cache-only.slack",
            name: "Rebuild disposable Electron caches",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            applicationSupportDirectoryName: "Slack",
            allowedCacheDirectoryNames: ElectronCacheDirectory.auditedNames,
            includesBundleIdentifierCache: true,
            rationale: "Slack uses Chromium/Electron caches that can be recreated. Moving only these caches is a reversible experiment, not a guaranteed fix."
        ),
        RepairRecipe(
            id: "electron-cache-only.discord",
            name: "Rebuild disposable Electron caches",
            bundleIdentifier: "com.hnc.Discord",
            applicationSupportDirectoryName: "discord",
            allowedCacheDirectoryNames: ElectronCacheDirectory.auditedNames,
            includesBundleIdentifierCache: true,
            rationale: "Discord uses Chromium/Electron caches that can be recreated. Moving only these caches is a reversible experiment, not a guaranteed fix."
        ),
        RepairRecipe(
            id: "electron-cache-only.vscode",
            name: "Rebuild disposable Electron caches",
            bundleIdentifier: "com.microsoft.VSCode",
            applicationSupportDirectoryName: "Code",
            allowedCacheDirectoryNames: ElectronCacheDirectory.auditedNames,
            includesBundleIdentifierCache: true,
            rationale: "Visual Studio Code uses Chromium/Electron caches that can be recreated. Moving only these caches is a reversible experiment, not a guaranteed fix."
        )
    ]

    private static let recipesByBundleIdentifier = Dictionary(
        uniqueKeysWithValues: allRecipes.map { ($0.bundleIdentifier, $0) }
    )

    static func recipe(for bundleIdentifier: String) -> RepairRecipe? {
        recipesByBundleIdentifier[bundleIdentifier]
    }

    /// Creates a cache-only recipe only after the caller has obtained an
    /// explicit folder selection. The planner still validates every path.
    static func explicitRecipe(for bundleIdentifier: String) -> RepairRecipe {
        RepairRecipe(
            id: "electron-cache-only.explicit.\(bundleIdentifier)",
            name: "Rebuild disposable Electron caches",
            bundleIdentifier: bundleIdentifier,
            applicationSupportDirectoryName: nil,
            allowedCacheDirectoryNames: ElectronCacheDirectory.auditedNames,
            includesBundleIdentifierCache: true,
            rationale: "Only the explicitly selected support folder's known disposable Electron caches will be moved. This is a reversible experiment, not a guaranteed fix."
        )
    }
}
