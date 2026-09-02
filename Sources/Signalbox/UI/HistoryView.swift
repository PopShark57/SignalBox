import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The recorded snapshot timeline, shown in full.
///
/// Signalbox already stored every collection it made, but the interface only
/// ever surfaced two derivations of it: the change since the previous
/// collection, and patterns that recurred. Everything else — sixty collections
/// of capacity, report counts, and evidence availability — was written to disk
/// and never shown to the person it describes. This screen is that record.
///
/// It shows only what `SnapshotSummary` actually holds. There is no list of
/// which applications were open on a given day, because that was never
/// recorded, and this screen is the most tempting place to start recording it.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "History", subtitle: subtitle) {
                    if model.isDemoMode { DemoBadge() }
                }

                if let reason = model.timelineUnavailableReason {
                    SignalCard(title: "Snapshot Timeline Unavailable", systemImage: "exclamationmark.triangle") {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Diagnostics for the current collection are unaffected, and Signalbox left any existing timeline file untouched.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.timeline.isEmpty {
                    ContentUnavailableView(
                        "No collections recorded yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Refresh to record a collection. Signalbox compares collections it made itself; it does not read a history from anywhere else.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    capacity()
                    comparison()
                    collections()
                    export()
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("History")
    }

    private var subtitle: String {
        let count = model.timeline.count
        if count == 0 { return "Nothing has been recorded on this Mac yet." }
        let noun = count == 1 ? "collection" : "collections"
        let limit = SnapshotTimelineStore.defaultMaximumEntries
        if model.isDemoMode {
            return "\(count) fixed demo \(noun). Demo mode writes nothing to this Mac."
        }
        return "\(count) \(noun) recorded on this Mac, of a maximum \(limit)."
    }

    @ViewBuilder
    private func capacity() -> some View {
        SignalCard(title: "System-Volume Capacity", systemImage: "internaldrive") {
            if let trend = model.capacityTrend {
                CapacityStrip(entries: model.timeline)
                HStack(spacing: 22) {
                    Stat("Latest", Format.bytes(trend.latestReading.availableBytes))
                    Stat("Lowest recorded", Format.bytes(trend.lowestReading.availableBytes))
                    Stat("Highest recorded", Format.bytes(trend.highestReading.availableBytes))
                    if let net = trend.netChangeBytes {
                        Stat("First to latest", Format.signedBytes(net))
                    } else {
                        Stat("First to latest", "Not comparable")
                    }
                }
                Text(movementSentence(trend))
                if trend.notComparableIntervalCount > 0 {
                    Label(
                        "\(trend.notComparableIntervalCount) interval\(trend.notComparableIntervalCount == 1 ? "" : "s") could not be compared, because a collection did not read the system volume.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.callout)
                }
                Text(CapacityTrend.samplingCaveat)
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.timeline.count < 2 {
                Text("One collection is a measurement, not a movement. Refresh again later to compare.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Fewer than two of the recorded collections read the system volume, so there is no movement to describe. A missing reading is unknown, not zero.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func movementSentence(_ trend: CapacityTrend) -> String {
        guard trend.comparableIntervalCount > 0 else {
            return "No two consecutive collections both read the system volume, so no movement could be counted."
        }
        let intervals = trend.comparableIntervalCount == 1 ? "interval" : "intervals"
        return "Available capacity fell in \(trend.fallingIntervalCount) of \(trend.comparableIntervalCount) comparable \(intervals) between collections, rose in \(trend.risingIntervalCount), and was unchanged in \(trend.unchangedIntervalCount)."
    }

    @ViewBuilder
    private func comparison() -> some View {
        SignalCard(title: "Compare Two Collections", systemImage: "arrow.left.arrow.right") {
            if let delta = model.comparisonDelta {
                DeltaSummary(delta: delta) {
                    Stat("Apart", Format.elapsed(delta.elapsed))
                }
                Button("Clear Selection") { model.clearHistorySelection() }
                    .accessibilityHint("Stops comparing the two selected collections")
            } else {
                Text("Select two collections below to compare them. Signalbox orders them by collection time, so the change always reads forwards regardless of which you pick first.")
                    .foregroundStyle(.secondary)
                if model.historySelectedIDs.count == 1 {
                    Label("One collection selected. Choose a second.", systemImage: "1.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func collections() -> some View {
        SignalCard(title: "Recorded Collections", systemImage: "list.bullet.rectangle") {
            Text("Newest first. Each row is the reduced summary Signalbox stored: capacity, memory totals, grouped report counts, unavailable source names, and finding counts.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.historyEntries) { entry in
                Button { model.toggleHistorySelection(entry) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.isSelectedForComparison(entry) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(model.isSelectedForComparison(entry) ? Color.accentColor : .secondary)
                        CollectionRow(entry: entry)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.isSelectedForComparison(entry) ? "Selected" : "Not selected") collection from \(Format.date(entry.collectedAt))")
                .accessibilityHint("Select two collections to compare them")
                Divider()
            }
        }
    }

    @ViewBuilder
    private func export() -> some View {
        SignalCard(title: "Export Timeline", systemImage: "tablecells") {
            Text("Writes one row per recorded collection as CSV, so the same evidence can be graphed in a spreadsheet.")
            Label("Included: collection time, system-volume capacity, memory totals, report counts, unavailable source names, finding counts", systemImage: "checkmark.circle")
            Label("Excluded: report signatures, which apps were open, report contents, and file names", systemImage: "xmark.circle")
            Text("A value that was never read is written as an empty cell, never as a zero: a chart would draw the zero.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export CSV…") { exportCSV() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Export the snapshot timeline as a CSV file")
                Button("Copy CSV") { copyCSV() }
                    .accessibilityHint("Copies exactly the CSV that Export writes")
            }
        }
    }

    private func copyCSV() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.timelineCSV, forType: .string)
        model.timelineCSVCopied()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Signalbox Snapshot Timeline"
        panel.nameFieldStringValue = "Signalbox-Snapshot-Timeline.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.timelineCSV.write(to: url, atomically: true, encoding: .utf8)
            model.timelineCSVExported(to: url)
        } catch {
            model.timelineCSVExportFailed(error)
        }
    }
}

/// One recorded collection, described only from what was stored.
private struct CollectionRow: View {
    let entry: SnapshotSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.date(entry.collectedAt)).font(.headline)
            if let volume = entry.systemVolume {
                Text("\(Format.bytes(volume.availableBytes)) available of \(Format.bytes(volume.totalBytes)) on \(volume.name)")
                    .font(.callout)
            } else {
                Text("The system volume was not read in this collection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(reportSummary).font(.caption).foregroundStyle(.secondary)
                ForEach(severityPills) { pill in
                    StatusPill(text: "\(pill.count) \(pill.severity.rawValue)", color: pill.severity.tint)
                }
            }
            if !entry.unavailableSources.isEmpty {
                Text("Unavailable: \(entry.unavailableSources.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var reportSummary: String {
        let groups = entry.reportGroups.count
        guard groups > 0 else { return "No grouped reports recorded" }
        let total = entry.reportGroups.reduce(0) { $0 + $1.count }
        return "\(groups) grouped pattern\(groups == 1 ? "" : "s") · \(total) report\(total == 1 ? "" : "s") in the window"
    }

    private var severityPills: [SeverityCount] {
        Severity.allCases.reversed().compactMap { severity in
            guard let count = entry.findingCountsBySeverity[severity.rawValue], count > 0 else { return nil }
            return SeverityCount(severity: severity, count: count)
        }
    }
}

private struct SeverityCount: Identifiable {
    var id: String { severity.rawValue }
    let severity: Severity
    let count: Int
}

/// System-volume capacity across the recorded collections, drawn as one bar per
/// collection.
///
/// Bars are spaced evenly because collections are, and the axis is deliberately
/// not time: Signalbox is refreshed by hand, so an evenly spaced strip is an
/// honest picture of "the collections I made", while a time axis would imply a
/// sampling regularity that does not exist. A collection with no reading is
/// drawn as an outline, never as a zero-height bar.
private struct CapacityStrip: View {
    let entries: [SnapshotSummary]

    private let maximumHeight: CGFloat = 64

    var body: some View {
        let peak = entries.compactMap { $0.systemVolume?.availableBytes }.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(entries) { entry in
                    bar(for: entry, peak: peak)
                }
            }
            .frame(height: maximumHeight)
            HStack {
                Text("Oldest recorded").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Most recent").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(peak: peak))
    }

    @ViewBuilder
    private func bar(for entry: SnapshotSummary, peak: Int64) -> some View {
        if let available = entry.systemVolume?.availableBytes, peak > 0 {
            // A floor keeps a very small reading visible as a bar rather than
            // vanishing into the baseline, where it would read as "no data".
            let fraction = max(0.05, CGFloat(Double(max(0, available)) / Double(peak)))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor.opacity(0.75))
                .frame(height: maximumHeight * fraction)
                .frame(maxWidth: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .foregroundStyle(.secondary)
                .frame(height: maximumHeight * 0.2)
                .frame(maxWidth: .infinity)
        }
    }

    private func accessibilityDescription(peak: Int64) -> String {
        let readings = entries.compactMap { $0.systemVolume?.availableBytes }
        guard let latest = readings.last, peak > 0 else {
            return "System-volume capacity across recorded collections. No collection read the system volume."
        }
        let missing = entries.count - readings.count
        let missingText = missing > 0
            ? " \(missing) collection\(missing == 1 ? "" : "s") did not read the system volume and are drawn as outlines."
            : ""
        return "System-volume capacity across \(entries.count) recorded collections, oldest first. Latest \(Format.bytes(latest)) available, highest recorded \(Format.bytes(peak)).\(missingText)"
    }
}
