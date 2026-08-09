import Foundation

protocol HostContextProvider: Sendable {
    func collectHostContext(at date: Date) async -> ProviderResult<HostContext>
}

protocol DiskHealthProvider: Sendable {
    func collectVolumes(at date: Date) async -> ProviderResult<[VolumeCapacity]>
}

protocol MemoryContextProvider: Sendable {
    func collectMemory(at date: Date) async -> ProviderResult<MemoryStatistics>
}

protocol DiagnosticReportProvider: Sendable {
    func collectRecentReports(since date: Date, collectedAt: Date) async -> ProviderResult<[CrashReportRecord]>
}

protocol RunningApplicationProvider: Sendable {
    func collectRunningApplications(at date: Date) async -> ProviderResult<[RunningApplicationInfo]>
}

protocol ApplicationCatalogProvider: Sendable {
    func collectApplications(at date: Date) async -> ProviderResult<[InspectedApplication]>
}

protocol BundleInspecting: Sendable {
    func inspectApplication(at bundleURL: URL, runningBundleIdentifiers: Set<String>, crashes: [CrashReportRecord]) async -> InspectedApplication?
}

@MainActor
protocol ApplicationControlling: AnyObject {
    func isRunning(bundleIdentifier: String) -> Bool
    func requestQuit(bundleIdentifier: String) -> Bool
}

