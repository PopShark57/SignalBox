import Foundation

/// Decides which diagnostic-report family an `.ips` container belongs to.
///
/// `.ips` is a shared envelope: macOS writes crashes, hangs, resource-limit
/// notices, and a long tail of analytics-style reports into the same file
/// format. Signalbox admits a report only when it can name the family with
/// confidence, because mislabeling a hang as a crash would let unrelated
/// evidence be counted as a recurring crash pattern.
///
/// Two rules keep this honest:
///
/// 1. Self-describing payload evidence outranks the numeric `bug_type`. A
///    payload carrying `resourceException` is a resource-limit report no matter
///    what number accompanies it, and a payload carrying `exception` or
///    `termination` is a crash.
/// 2. Anything that matches no rule is **discarded**, never guessed at. Adding a
///    family here is a deliberate, reviewable edit to a small table.
///
/// `309` is verified against real crash reports written by macOS on the
/// development host. The remaining numeric codes are a conservative allowlist
/// consulted only when the payload itself was not self-describing — for example
/// when a bounded read truncated the details object.
enum DiagnosticReportFamilyCatalog {
    static let crashBugTypes: Set<String> = ["309"]
    static let hangBugTypes: Set<String> = ["142", "238"]
    static let resourceLimitBugTypes: Set<String> = ["198", "199"]

    /// Payload keys that name their own family.
    static let resourceLimitDetailKey = "resourceException"
    static let crashDetailKeys: Set<String> = ["exception", "termination"]

    static func kind(bugType: String?, detailKeys: Set<String>) -> DiagnosticReportKind? {
        if detailKeys.contains(resourceLimitDetailKey) { return .resourceLimit }
        if !detailKeys.isDisjoint(with: crashDetailKeys) { return .crash }

        guard let bugType, !bugType.isEmpty else { return nil }
        if crashBugTypes.contains(bugType) { return .crash }
        if hangBugTypes.contains(bugType) { return .hang }
        if resourceLimitBugTypes.contains(bugType) { return .resourceLimit }
        return nil
    }
}
