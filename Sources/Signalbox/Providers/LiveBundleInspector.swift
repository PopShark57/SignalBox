import Foundation
import MachO
import Security

struct LiveBundleInspector: BundleInspecting {
    let recipeIDsByBundleIdentifier: [String: String]

    init(recipeIDsByBundleIdentifier: [String: String] = Dictionary(
        uniqueKeysWithValues: RepairRecipeCatalog.allRecipes.map { ($0.bundleIdentifier, $0.id) }
    )) {
        self.recipeIDsByBundleIdentifier = recipeIDsByBundleIdentifier
    }

    func inspectApplication(
        at bundleURL: URL,
        runningBundleIdentifiers: Set<String>,
        crashes: [CrashReportRecord]
    ) async -> InspectedApplication? {
        let canonicalURL = bundleURL.standardizedFileURL
        guard canonicalURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: canonicalURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        let info = bundle.infoDictionary ?? [:]
        let name = [
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
            ?? canonicalURL.deletingPathExtension().lastPathComponent
        let version = [
            info["CFBundleShortVersionString"] as? String,
            info[kCFBundleVersionKey as String] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
            ?? "Unknown"
        let matchingCrashes = crashes.filter {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
                || ($0.bundleIdentifier == nil
                    && $0.applicationName.caseInsensitiveCompare(name) == .orderedSame)
        }

        let recipeID = recipeIDsByBundleIdentifier[bundleIdentifier]
        var recipeEvidence: [String] = []
        if recipeID != nil {
            recipeEvidence.append("A bundled, auditable cache-only recipe exactly matches this bundle identifier.")
            let groups = CrashGrouper.groups(from: matchingCrashes)
            if let recurring = groups.first(where: { $0.count >= 2 }) {
                recipeEvidence.append("\(recurring.count) matching recent reports share a crash signature; this correlation does not prove a cache fault.")
            }
        }

        return InspectedApplication(
            name: name,
            bundleIdentifier: bundleIdentifier,
            version: version,
            bundleURL: canonicalURL,
            executableArchitecture: architecture(for: bundle),
            codeSigningStatus: signingStatus(for: canonicalURL),
            isRunning: runningBundleIdentifiers.contains(bundleIdentifier),
            iconFileURL: iconURL(for: bundle, info: info),
            matchingCrashReports: matchingCrashes.sorted { $0.occurredAt > $1.occurredAt },
            suggestedRecipeIDs: recipeID.map { [$0] } ?? [],
            recipeEvidence: recipeEvidence
        )
    }

    private func architecture(for bundle: Bundle) -> InspectionValue {
        guard let values = bundle.executableArchitectures, !values.isEmpty else {
            return .unavailable("The executable architecture was not declared by the bundle.")
        }

        let labels = Set(values.map { architectureLabel(cpuType: $0.int32Value) })
        let ordered = ["Apple silicon", "Intel 64-bit", "ARM", "Intel 32-bit", "Unknown"]
            .filter(labels.contains)
        if ordered.count > 1 {
            return .available("Universal (\(ordered.joined(separator: ", ")))")
        }
        return .available(ordered.first ?? "Unknown")
    }

    private func architectureLabel(cpuType: Int32) -> String {
        switch cpuType {
        case CPU_TYPE_ARM64: return "Apple silicon"
        case CPU_TYPE_X86_64: return "Intel 64-bit"
        case CPU_TYPE_ARM: return "ARM"
        case CPU_TYPE_X86: return "Intel 32-bit"
        default: return "Unknown"
        }
    }

    private func signingStatus(for bundleURL: URL) -> InspectionValue {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .unavailable("macOS could not create a code-signing inspection object (status \(createStatus)).")
        }

        // A basic validation establishes signature presence and executable
        // validity without walking every resource in every installed app. This
        // keeps a dashboard refresh bounded; Signalbox is not a notarization or
        // malware-verification tool.
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly)),
            nil
        )
        if validationStatus == errSecSuccess {
            return .available("Valid")
        }
        return .available("Invalid or unsigned (status \(validationStatus))")
    }

    private func iconURL(for bundle: Bundle, info: [String: Any]) -> URL? {
        guard var iconName = info["CFBundleIconFile"] as? String,
              let resources = bundle.resourceURL else {
            return nil
        }
        if URL(fileURLWithPath: iconName).pathExtension.isEmpty {
            iconName += ".icns"
        }
        let url = resources.appendingPathComponent(iconName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
