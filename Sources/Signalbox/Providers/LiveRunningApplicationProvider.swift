import AppKit
import Foundation

struct LiveRunningApplicationProvider: RunningApplicationProvider {
    func collectRunningApplications(at date: Date) async -> ProviderResult<[RunningApplicationInfo]> {
        let applications = await MainActor.run { () -> [RunningApplicationInfo] in
            var byApplication: [String: RunningApplicationInfo] = [:]

            for application in NSWorkspace.shared.runningApplications
                where !application.isTerminated && application.activationPolicy == .regular {
                let bundleURL = application.bundleURL?.standardizedFileURL
                let name = application.localizedName
                    ?? bundleURL?.deletingPathExtension().lastPathComponent
                    ?? "Unknown application"
                let identity = application.bundleIdentifier
                    ?? bundleURL?.path
                    ?? "pid:\(application.processIdentifier)"
                let info = RunningApplicationInfo(
                    id: identity,
                    name: name,
                    bundleIdentifier: application.bundleIdentifier,
                    bundleURL: bundleURL,
                    processIdentifier: application.processIdentifier,
                    isActive: application.isActive,
                    observedAt: date
                )

                if byApplication[identity]?.isActive != true {
                    byApplication[identity] = info
                }
            }

            return byApplication.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return .available(applications)
    }
}
