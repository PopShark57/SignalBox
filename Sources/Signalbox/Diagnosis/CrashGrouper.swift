import Foundation

enum CrashGrouper {
    static func groups(from reports: [CrashReportRecord]) -> [CrashGroup] {
        struct Key: Hashable {
            let applicationIdentity: String
            let signature: String
            let kind: DiagnosticReportKind
        }

        // A bundle identifier is the stable app identity when available. This
        // intentionally unifies records whose display name changed because of
        // localization or an app rename, and prevents duplicate SwiftUI IDs.
        // Report families are part of the key, so a hang is never merged into a
        // crash group even when both share an app and a signature.
        let groupableReports = reports.filter { !signatureIsUnavailable($0) }
        let buckets = Dictionary(grouping: groupableReports) { report in
            Key(
                applicationIdentity: applicationIdentity(for: report),
                signature: normalized(report.signature),
                kind: report.kind
            )
        }

        var groups: [CrashGroup] = buckets.compactMap { element -> CrashGroup? in
            let (key, records) = element
            guard let latest = records.max(by: { $0.occurredAt < $1.occurredAt }) else { return nil }
            let stableID = [
                key.applicationIdentity,
                key.signature,
                key.kind.rawValue
            ].joined(separator: "|")

            return CrashGroup(
                id: stableID,
                applicationIdentity: key.applicationIdentity,
                applicationName: latest.applicationName,
                bundleIdentifier: latest.bundleIdentifier,
                signature: latest.signature,
                count: records.count,
                mostRecentAt: latest.occurredAt,
                kind: latest.kind,
                reportKind: latest.reportKind
            )
        }

        // Missing signatures are deliberately not correlated. Generate an
        // opaque, structured ID from non-sensitive fields and an occurrence
        // ordinal so even duplicate observations have distinct, deterministic
        // SwiftUI identities without copying filenames or raw report content.
        let individualReports = reports
            .filter { signatureIsUnavailable($0) }
            .sorted(by: individualReportOrder)
        var occurrenceCounts: [String: Int] = [:]

        for report in individualReports {
            let identity = applicationIdentity(for: report)
            let baseID = [
                identity,
                normalized(report.signature),
                report.kind.rawValue,
                String(report.occurredAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            ].joined(separator: "|")
            let ordinal = occurrenceCounts[baseID, default: 0]
            occurrenceCounts[baseID] = ordinal + 1

            groups.append(CrashGroup(
                id: "\(baseID)|individual:\(ordinal)",
                applicationIdentity: identity,
                applicationName: report.applicationName,
                bundleIdentifier: report.bundleIdentifier,
                signature: report.signature,
                count: 1,
                mostRecentAt: report.occurredAt,
                kind: report.kind,
                reportKind: report.reportKind
            ))
        }

        return groups
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.mostRecentAt != $1.mostRecentAt { return $0.mostRecentAt > $1.mostRecentAt }
            let nameOrder = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func applicationIdentity(for report: CrashReportRecord) -> String {
        if let bundleIdentifier = report.bundleIdentifier {
            let normalizedIdentifier = normalized(bundleIdentifier)
            if !normalizedIdentifier.isEmpty { return "bundle:\(normalizedIdentifier)" }
        }
        return "name:\(normalized(report.applicationName))"
    }

    /// A signature is unavailable when it matches the placeholder for its own
    /// family. Checking every family's placeholder keeps a hang whose signature
    /// could not be read from being correlated with other hangs.
    static func signatureIsUnavailable(_ signature: String, kind: DiagnosticReportKind) -> Bool {
        normalized(signature) == normalized(kind.unavailableSignatureText)
    }

    private static func signatureIsUnavailable(_ report: CrashReportRecord) -> Bool {
        DiagnosticReportKind.allCases.contains {
            normalized(report.signature) == normalized($0.unavailableSignatureText)
        }
    }

    private static func individualReportOrder(_ lhs: CrashReportRecord, _ rhs: CrashReportRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        let lhsIdentity = applicationIdentity(for: lhs)
        let rhsIdentity = applicationIdentity(for: rhs)
        if lhsIdentity != rhsIdentity { return lhsIdentity < rhsIdentity }
        let lhsName = normalized(lhs.applicationName)
        let rhsName = normalized(rhs.applicationName)
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
