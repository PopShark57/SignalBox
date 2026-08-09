import Foundation

/// Extracts only fields needed for grouping. Raw report text, file paths,
/// process arguments, thread contents, and unrelated filenames are discarded.
struct BoundedCrashReportParser: Sendable {
    let maximumBytes: Int

    init(maximumBytes: Int = 256 * 1_024) {
        self.maximumBytes = max(4_096, maximumBytes)
    }

    func parse(data: Data, fileURL: URL, fallbackDate: Date) -> CrashReportRecord? {
        guard !data.isEmpty else { return nil }
        let fileExtension = fileURL.pathExtension.lowercased()
        switch fileExtension {
        case "ips":
            return parseIPS(data: data, fileURL: fileURL, fallbackDate: fallbackDate)
        case "crash":
            return parseLegacyCrash(data: data, fileURL: fileURL, fallbackDate: fallbackDate)
        default:
            return nil
        }
    }

    private func parseIPS(data: Data, fileURL: URL, fallbackDate: Date) -> CrashReportRecord? {
        let prefix = Data(data.prefix(maximumBytes))
        let newline = prefix.firstIndex(of: 0x0A)
        let metadataData = newline.map { prefix.prefix(upTo: $0) } ?? prefix[...]
        let metadata = jsonDictionary(Data(metadataData)) ?? [:]

        var details: [String: Any] = [:]
        if let newline {
            let next = prefix.index(after: newline)
            details = jsonDictionary(Data(prefix[next...])) ?? [:]
        } else if metadata["app_name"] == nil {
            details = metadata
        }

        let applicationName = safeName(
            string(metadata["app_name"])
                ?? string(metadata["name"])
                ?? string(details["procName"])
                ?? applicationNameFromFilename(fileURL)
        )
        guard !applicationName.isEmpty else { return nil }

        let bundleIdentifier = safeIdentifier(
            string(metadata["bundleID"])
                ?? string(metadata["bundleIdentifier"])
                ?? nestedString(details, keys: ["bundleInfo", "CFBundleIdentifier"])
        )
        let occurredAt = parsedDate(
            string(metadata["timestamp"])
                ?? string(metadata["captureTime"])
                ?? string(details["captureTime"])
        ) ?? fallbackDate

        // `.ips` is a container used for several diagnostic report families.
        // Name the family before anything else; an unrecognized family is
        // discarded rather than folded into crash evidence.
        let bugType = string(metadata["bug_type"]) ?? string(details["bug_type"])
        guard let kind = DiagnosticReportFamilyCatalog.kind(
            bugType: bugType,
            detailKeys: Set(details.keys)
        ) else {
            return nil
        }

        // `bug_type` identifies a broad report family, not a signature. In
        // particular, a bounded read can truncate the second JSON object in an
        // `.ips` file. Treating every such report as "Report type 309" would
        // make unrelated reports from the same app appear recurrent. Preserve
        // the record, but leave its signature unavailable so CrashGrouper keeps
        // it as an individual observation.
        let signatureParts = signatureParts(for: kind, details: details)

        return CrashReportRecord(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            occurredAt: occurredAt,
            signature: signatureParts.ifEmpty(kind.unavailableSignatureText).joined(separator: " · "),
            kind: kind,
            source: DiagnosticSource.crashReports
        )
    }

    /// Builds a bounded correlation signature from family-specific fields only.
    /// Nothing here can carry a file path, a symbol name, or thread contents.
    private func signatureParts(
        for kind: DiagnosticReportKind,
        details: [String: Any]
    ) -> [String] {
        var parts: [String] = []
        switch kind {
        case .crash:
            if let exception = details["exception"] as? [String: Any] {
                appendSafe(string(exception["type"]), to: &parts)
                appendSafe(string(exception["signal"]), to: &parts)
            }
            if let termination = details["termination"] as? [String: Any] {
                appendSafe(string(termination["namespace"]), to: &parts)
            }
        case .resourceLimit:
            if let resource = details[DiagnosticReportFamilyCatalog.resourceLimitDetailKey] as? [String: Any] {
                appendSafe(string(resource["resource"]), to: &parts)
                appendSafe(string(resource["limit"]), to: &parts)
                appendSafe(string(resource["flags"]), to: &parts)
            }
        case .hang:
            // A hang has no exception. Only these bounded, non-identifying
            // fields are worth correlating on; without them the report stays an
            // individual observation.
            appendSafe(string(details["hangType"]), to: &parts)
            appendSafe(string(details["reason"]), to: &parts)
        }
        return parts
    }

    private func parseLegacyCrash(data: Data, fileURL: URL, fallbackDate: Date) -> CrashReportRecord? {
        // Decode leniently. A strict `String(data:encoding:.utf8)` returns nil
        // for the whole buffer if a single byte is invalid — which happens for
        // a Latin-1 byte in "Application Specific Information", and routinely
        // when the bounded read cuts a multi-byte scalar in half. That silently
        // dropped a real crash report while the provider still reported
        // success, presenting incomplete evidence as complete. Invalid bytes
        // become U+FFFD and are then stripped by `safeComponent`.
        let text = String(decoding: data.prefix(maximumBytes), as: UTF8.self)
        var fields: [String: String] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(500) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard ["Process", "Identifier", "Date/Time", "Exception Type", "Termination Reason"].contains(key) else {
                continue
            }
            fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }

        let processField = fields["Process"]?.components(separatedBy: "[").first
        let applicationName = safeName(processField ?? applicationNameFromFilename(fileURL))
        guard !applicationName.isEmpty else { return nil }

        var signatureParts: [String] = []
        appendSafe(fields["Exception Type"], to: &signatureParts)
        if let termination = fields["Termination Reason"] {
            let namespace = termination.components(separatedBy: ",").first
            appendSafe(namespace, to: &signatureParts)
        }

        // A legacy `.crash` file is only ever written for a crash, so the family
        // is known without consulting the `.ips` catalog.
        return CrashReportRecord(
            applicationName: applicationName,
            bundleIdentifier: safeIdentifier(fields["Identifier"]),
            occurredAt: parsedDate(fields["Date/Time"]) ?? fallbackDate,
            signature: signatureParts.ifEmpty(DiagnosticReportKind.crash.unavailableSignatureText)
                .joined(separator: " · "),
            kind: .crash,
            source: DiagnosticSource.crashReports
        )
    }

    private func jsonDictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func nestedString(_ dictionary: [String: Any], keys: [String]) -> String? {
        var current: Any = dictionary
        for key in keys {
            guard let next = (current as? [String: Any])?[key] else { return nil }
            current = next
        }
        return string(current)
    }

    private func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    private func parsedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        for format in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func applicationNameFromFilename(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.components(separatedBy: "_").first ?? stem
    }

    private func safeName(_ value: String) -> String {
        safeComponent(value, maximumLength: 100)
    }

    private func safeIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let safe = safeComponent(value, maximumLength: 160)
        return safe.isEmpty ? nil : safe
    }

    private func appendSafe(_ value: String?, to parts: inout [String]) {
        guard let value else { return }
        let safe = safeComponent(value, maximumLength: 80)
        if !safe.isEmpty, !parts.contains(safe) { parts.append(safe) }
    }

    private func safeComponent(_ value: String, maximumLength: Int) -> String {
        let allowedPunctuation = CharacterSet(charactersIn: " ._+-()")
        let allowed = CharacterSet.alphanumerics.union(allowedPunctuation)
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : " " }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(maximumLength)
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: String) -> [String] { isEmpty ? [fallback] : self }
}
