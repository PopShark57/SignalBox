import AppKit
import SwiftUI

/// Presentation primitives shared by every screen.
///
/// These live apart from the screens themselves so a new section cannot drift
/// into its own card style, its own byte formatting, or its own severity
/// colours — a diagnostic tool that renders the same value two ways has already
/// undermined the evidence it is showing.
struct SignalCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage).font(.title3.bold())
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }
}

struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(); accessory
        }
    }
}

struct SheetHeader: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text(title).font(.title2.bold()); Text(subtitle).foregroundStyle(.secondary) }
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close")
        }
        .padding()
        .background(.bar)
    }
}

struct DemoBadge: View {
    var body: some View {
        Label("Demo Data", systemImage: "sparkles")
            .font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5)
            .background(.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
            .accessibilityLabel("Deterministic demo data is active")
    }
}

/// A count of findings by severity.
///
/// Deliberately *not* a health score: it reports how many observations exist at
/// each labeled severity and says so, rather than reducing the Mac to a number.
struct SeveritySummary: View {
    let findings: [Finding]

    var body: some View {
        let counts = Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
        HStack(spacing: 10) {
            ForEach(Severity.allCases.reversed(), id: \.self) { severity in
                if let count = counts[severity], count > 0 {
                    Label("\(count) \(severity.rawValue)", systemImage: severity.icon)
                        .font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(severity.tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(severity.tint)
                }
            }
            Spacer()
            Text("Counts of labeled observations, not a health score.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finding counts by severity. These are counts of labeled observations, not a health score.")
    }
}

/// One comparison between two collections.
///
/// Overview and History both describe a `SnapshotDelta`, so they share this
/// view: two screens wording the same comparison differently would be two
/// answers to one question. The trailing slot exists for the stat that is
/// genuinely specific to a screen, not for a second interpretation.
struct DeltaSummary<Trailing: View>: View {
    let delta: SnapshotDelta
    let trailing: Trailing

    init(delta: SnapshotDelta, @ViewBuilder trailing: () -> Trailing) {
        self.delta = delta
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Compared with the collection \(Format.elapsed(delta.elapsed)) earlier, on \(Format.date(delta.previousCollectedAt)).")
                .font(.caption).foregroundStyle(.secondary)
            if delta.isUnchanged {
                Label("Nothing Signalbox tracks changed between these two collections.", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                if let change = delta.systemVolumeAvailableByteChange {
                    Stat("System volume free", Format.signedBytes(change))
                } else {
                    Stat("System volume free", "Not comparable")
                }
                Stat("Reports in window", Format.signedCount(delta.reportCountChange))
                trailing
            }
            if delta.systemVolumeAvailableByteChange == nil {
                Text("A capacity change is shown only when both collections read the system volume. One of them did not, so the change is unknown rather than zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(delta.newlyUnavailableSources, id: \.self) { source in
                Label("\(source) became unavailable.", systemImage: "questionmark.circle").font(.callout)
            }
            ForEach(delta.resolvedUnavailableSources, id: \.self) { source in
                Label("\(source) became available again.", systemImage: "checkmark.circle").font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

struct Stat: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
    var body: some View { VStack(alignment: .leading) { Text(value).font(.headline); Text(name).font(.caption).foregroundStyle(.secondary) } }
}

struct DetailRow: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
    var body: some View { HStack(alignment: .firstTextBaseline) { Text(name).foregroundStyle(.secondary).frame(width: 130, alignment: .leading); Text(value).textSelection(.enabled) } }
}

struct AppIcon: View {
    let application: InspectedApplication
    let size: CGFloat
    var body: some View {
        Group {
            if let url = application.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit).frame(width: size, height: size)
        .accessibilityLabel("\(application.name) icon")
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }
    static func bytes(_ value: UInt64) -> String { bytes(Int64(clamping: value)) }
    static func date(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .shortened) }
    static func shortDate(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .omitted) }

    static func signedBytes(_ value: Int64) -> String {
        guard value != 0 else { return "Unchanged" }
        return "\(value > 0 ? "+" : "−")\(bytes(value.magnitude))"
    }

    static func signedCount(_ value: Int) -> String {
        guard value != 0 else { return "Unchanged" }
        return "\(value > 0 ? "+" : "−")\(abs(value))"
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((max(0, interval) / 60).rounded())
        if totalMinutes < 1 { return "moments" }
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "3 min ago" style text for the last successful refresh.
    static func since(_ value: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(value)
        guard interval >= 60 else { return "just now" }
        return "\(elapsed(interval)) ago"
    }
}

extension DiagnosticReportKind {
    var systemImage: String {
        switch self {
        case .crash: "exclamationmark.bubble"
        case .hang: "hourglass"
        case .resourceLimit: "gauge.with.needle"
        }
    }
}

extension InspectionValue {
    var display: String {
        switch self { case .available(let value): value; case .unavailable(let reason): "Unavailable — \(reason)" }
    }
}

extension Severity {
    var icon: String { switch self { case .informational: "info.circle"; case .notice: "bell"; case .warning: "exclamationmark.triangle"; case .critical: "xmark.octagon" } }
    var tint: Color { switch self { case .informational: .blue; case .notice: .indigo; case .warning: .orange; case .critical: .red } }
}

extension RepairTransactionState {
    var display: String { rawValue.replacingOccurrences(of: "restore", with: "restore ").capitalized }
    var tint: Color { switch self { case .completed, .restored: .green; case .planned: .blue; case .partial, .restorePartial: .orange; case .failed: .red } }
}

extension RepairOperationState {
    var display: String { rawValue.replacingOccurrences(of: "restore", with: "restore ").capitalized }

    /// Green is reserved for an item that is back where it started. An item
    /// sitting in the backup is orange, not green: the transaction is halfway
    /// through, whatever the overall manifest state says.
    var tint: Color {
        switch self {
        case .restored: .green
        case .planned: .blue
        case .moved, .restoring, .restoreConflict, .skipped: .orange
        case .failed: .red
        }
    }
}

extension String {
    func replacingHomeWithTilde() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if self == home { return "~" }
        return replacingOccurrences(of: home + "/", with: "~/")
    }
}
