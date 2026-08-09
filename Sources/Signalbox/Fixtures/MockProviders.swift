import Foundation

struct MockHostContextProvider: HostContextProvider {
    let result: ProviderResult<HostContext>
    init(result: ProviderResult<HostContext>) { self.result = result }
    init(hostContext: HostContext = DemoFixtures.demoHostContext) { result = .available(hostContext) }
    func collectHostContext(at date: Date) async -> ProviderResult<HostContext> { result }
}

struct MockDiskHealthProvider: DiskHealthProvider {
    let result: ProviderResult<[VolumeCapacity]>
    init(result: ProviderResult<[VolumeCapacity]>) { self.result = result }
    init(volumes: [VolumeCapacity]) { result = .available(volumes) }
    func collectVolumes(at date: Date) async -> ProviderResult<[VolumeCapacity]> { result }
}

struct MockMemoryContextProvider: MemoryContextProvider {
    let result: ProviderResult<MemoryStatistics>
    init(result: ProviderResult<MemoryStatistics>) { self.result = result }
    init(memory: MemoryStatistics) { result = .available(memory) }
    func collectMemory(at date: Date) async -> ProviderResult<MemoryStatistics> { result }
}

struct MockDiagnosticReportProvider: DiagnosticReportProvider {
    let result: ProviderResult<[CrashReportRecord]>
    init(result: ProviderResult<[CrashReportRecord]>) { self.result = result }
    init(reports: [CrashReportRecord]) { result = .available(reports) }
    func collectRecentReports(since date: Date, collectedAt: Date) async -> ProviderResult<[CrashReportRecord]> { result }
}

struct MockRunningApplicationProvider: RunningApplicationProvider {
    let result: ProviderResult<[RunningApplicationInfo]>
    init(result: ProviderResult<[RunningApplicationInfo]>) { self.result = result }
    init(applications: [RunningApplicationInfo]) { result = .available(applications) }
    func collectRunningApplications(at date: Date) async -> ProviderResult<[RunningApplicationInfo]> { result }
}

struct MockApplicationCatalogProvider: ApplicationCatalogProvider {
    let result: ProviderResult<[InspectedApplication]>
    init(result: ProviderResult<[InspectedApplication]>) { self.result = result }
    init(applications: [InspectedApplication]) { result = .available(applications) }
    func collectApplications(at date: Date) async -> ProviderResult<[InspectedApplication]> { result }
}

struct MockBundleInspector: BundleInspecting {
    let applicationsByPath: [String: InspectedApplication]

    init(applicationsByURL: [URL: InspectedApplication]) {
        applicationsByPath = Dictionary(uniqueKeysWithValues: applicationsByURL.map {
            ($0.key.standardizedFileURL.path, $0.value)
        })
    }

    func inspectApplication(
        at bundleURL: URL,
        runningBundleIdentifiers: Set<String>,
        crashes: [CrashReportRecord]
    ) async -> InspectedApplication? {
        applicationsByPath[bundleURL.standardizedFileURL.path]
    }
}
