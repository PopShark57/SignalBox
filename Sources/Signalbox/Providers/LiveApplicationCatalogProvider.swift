import Foundation

struct LiveApplicationCatalogProvider: ApplicationCatalogProvider {
    let inspector: any BundleInspecting
    let runningProvider: any RunningApplicationProvider
    let reportProvider: any DiagnosticReportProvider
    let searchRoots: [URL]
    let maximumApplications: Int
    let crashLookback: TimeInterval

    init(
        inspector: any BundleInspecting = LiveBundleInspector(),
        runningProvider: any RunningApplicationProvider = LiveRunningApplicationProvider(),
        reportProvider: any DiagnosticReportProvider = LiveDiagnosticReportProvider(),
        searchRoots: [URL] = LiveApplicationCatalogProvider.defaultSearchRoots,
        maximumApplications: Int = 240,
        crashLookback: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.inspector = inspector
        self.runningProvider = runningProvider
        self.reportProvider = reportProvider
        self.searchRoots = searchRoots
        self.maximumApplications = max(1, maximumApplications)
        self.crashLookback = crashLookback
    }

    static var defaultSearchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    func collectApplications(at date: Date) async -> ProviderResult<[InspectedApplication]> {
        async let runningResult = runningProvider.collectRunningApplications(at: date)
        async let reportResult = reportProvider.collectRecentReports(
            since: date.addingTimeInterval(-crashLookback),
            collectedAt: date
        )
        let (running, reports) = await (runningResult, reportResult)

        guard case .available(let runningApplications) = running else {
            if case .unavailable(let reason) = running { return .unavailable(reason: reason) }
            return .unavailable(reason: "Running application evidence was unavailable.")
        }
        guard case .available(let crashes) = reports else {
            if case .unavailable(let reason) = reports { return .unavailable(reason: reason) }
            return .unavailable(reason: "Crash-report evidence was unavailable.")
        }
        return await collectApplications(at: date, runningApplications: runningApplications, crashes: crashes)
    }

    func collectApplications(
        at date: Date,
        runningApplications: [RunningApplicationInfo],
        crashes: [CrashReportRecord]
    ) async -> ProviderResult<[InspectedApplication]> {
        let discovered = await Task.detached(priority: .utility) {
            self.discoverBundleURLs(including: runningApplications.compactMap(\.bundleURL))
        }.value
        if Task.isCancelled { return .unavailable(reason: "Application collection was cancelled.") }
        guard case .available(let bundleURLs) = discovered else {
            if case .unavailable(let reason) = discovered { return .unavailable(reason: reason) }
            return .unavailable(reason: "Installed applications could not be enumerated.")
        }

        let runningIdentifiers = Set(runningApplications.compactMap(\.bundleIdentifier))
        let inspected = await withTaskGroup(of: InspectedApplication?.self) { group in
            let urls = Array(bundleURLs)
            let concurrencyLimit = min(8, urls.count)
            var nextIndex = 0
            for _ in 0..<concurrencyLimit {
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await self.inspector.inspectApplication(
                        at: url,
                        runningBundleIdentifiers: runningIdentifiers,
                        crashes: crashes
                    )
                }
            }

            var applications: [InspectedApplication] = []
            while let application = await group.next() {
                if let application { applications.append(application) }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if nextIndex < urls.count {
                    let url = urls[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.inspector.inspectApplication(
                            at: url,
                            runningBundleIdentifiers: runningIdentifiers,
                            crashes: crashes
                        )
                    }
                }
            }
            return applications
        }

        let deduplicated = Dictionary(inspected.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, second in
            first.isRunning ? first : second
        })
        return .available(deduplicated.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    private func discoverBundleURLs(including runningURLs: [URL]) -> ProviderResult<[URL]> {
        let fileManager = FileManager.default
        var paths = Set(runningURLs.map { $0.standardizedFileURL.path })
        var permissionError: Error?

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    permissionError = error
                    return false
                }
            ) else {
                return .unavailable(reason: "The application directory could not be enumerated.")
            }

            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    paths.insert(url.standardizedFileURL.path)
                    enumerator.skipDescendants()
                    if paths.count >= maximumApplications { break }
                }
            }
            if paths.count >= maximumApplications { break }
        }

        if let permissionError {
            return .unavailable(reason: ProviderFailureReason.readFailure(permissionError, source: "an application directory"))
        }

        return .available(paths.sorted().prefix(maximumApplications).map { URL(fileURLWithPath: $0) })
    }
}
