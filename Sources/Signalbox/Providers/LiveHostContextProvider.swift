import Darwin
import Foundation

/// Collects the first-line "which Mac is this" context that makes every other
/// piece of evidence interpretable.
///
/// Everything read here is a property of the *model* of machine, not of the
/// individual machine or its owner. Signalbox deliberately never reads the
/// serial number (`IOPlatformSerialNumber`), the hardware UUID, the host name,
/// the computer name, or the user name, because a diagnostic report is meant to
/// be shareable and none of those values help explain a crash.
struct LiveHostContextProvider: HostContextProvider {
    init() {}

    func collectHostContext(at date: Date) async -> ProviderResult<HostContext> {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion

        return .available(HostContext(
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: Self.inspected("kern.osversion", source: "the macOS build number"),
            hardwareModelIdentifier: Self.inspected("hw.model", source: "the hardware model identifier"),
            architecture: Self.architecture(),
            physicalMemoryBytes: processInfo.physicalMemory,
            collectedAt: date
        ))
    }

    /// Reports the architecture of the *machine*, not of this process. Reading
    /// `hw.machine` alone would report `x86_64` for a translated process and
    /// quietly mislabel an Apple silicon Mac as Intel.
    private static func architecture() -> InspectionValue {
        if Self.integer("hw.optional.arm64") == 1 {
            return .available("Apple silicon (arm64)")
        }
        return inspected("hw.machine", source: "the machine architecture")
    }

    private static func inspected(_ name: String, source: String) -> InspectionValue {
        guard let value = string(name), !value.isEmpty else {
            return .unavailable("macOS did not report \(source).")
        }
        return .available(value)
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // The kernel returns a NUL-terminated C string; refuse anything that is
        // not, rather than reading past the buffer.
        guard buffer.contains(0) else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
