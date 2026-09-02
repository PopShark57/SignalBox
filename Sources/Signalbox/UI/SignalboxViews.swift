import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SignalboxRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: destinationBinding) {
                ForEach(SidebarDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                        .accessibilityLabel(destination.title)
                }
            }
            .navigationTitle("Signalbox")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            Group {
                switch model.destination {
                case .overview: OverviewView()
                case .history: HistoryView()
                case .applications: ApplicationsView()
                case .repairHistory: RepairHistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.beginReportPreview() } label: {
                    Label("Preview Report", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("Preview diagnostic report")
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .accessibilityLabel(model.isRefreshing ? "Refreshing snapshot" : "Refresh snapshot")
            }
        }
        .task { await model.start() }
        .sheet(isPresented: repairSheetBinding) { RepairPreviewView() }
        .sheet(isPresented: restoreSheetBinding) { RestorePreviewView() }
        .sheet(isPresented: $model.isShowingReportPreview) { ReportPreviewView() }
        .alert(item: $model.issue) { issue in
            Alert(title: Text(issue.title), message: Text(issue.message), dismissButton: .default(Text("OK")))
        }
    }

    private var destinationBinding: Binding<SidebarDestination?> {
        Binding(get: { model.destination }, set: { if let value = $0 { model.destination = value } })
    }

    private var repairSheetBinding: Binding<Bool> {
        Binding(get: { model.repairPlan != nil }, set: { if !$0 { model.cancelRepairPreview() } })
    }

    private var restoreSheetBinding: Binding<Bool> {
        Binding(get: { model.restoreManifest != nil }, set: { if !$0 { model.cancelRestore() } })
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    /// Drives only the "x minutes ago" text, so the snapshot itself is never
    /// silently re-collected behind the user's back.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Overview",
                    subtitle: model.snapshot.map {
                        "Snapshot collected \(Format.date($0.collectedAt)) · \(Format.since($0.collectedAt, now: now))"
                    } ?? "Collecting a system snapshot…"
                ) {
                    if model.isDemoMode { DemoBadge() }
                }

                if let snapshot = model.snapshot, !snapshot.findings.isEmpty {
                    SeveritySummary(findings: snapshot.findings + model.timelineFindings)
                }

                if model.isRefreshing && model.snapshot == nil {
                    ProgressView("Collecting evidence…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .accessibilityLabel("Collecting system evidence")
                } else if let snapshot = model.snapshot {
                    host(snapshot)
                    sinceLastCollection()
                    volumes(snapshot)
                    memory(snapshot)
                    findings(snapshot)
                    recurring()
                    reportFamilies(snapshot)
                    recentlyRunning(snapshot)
                    unavailable(snapshot)
                } else {
                    ContentUnavailableView("Snapshot unavailable", systemImage: "waveform.path.ecg", description: Text("Try refreshing. Missing evidence is never treated as a healthy result."))
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Overview")
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private func host(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "This Mac", systemImage: "laptopcomputer") {
            if let context = snapshot.hostContext {
                HStack(spacing: 22) {
                    Stat("macOS", context.operatingSystemVersion)
                    Stat("Build", context.operatingSystemBuild.display)
                    Stat("Model", context.hardwareModelIdentifier.display)
                    Stat("Architecture", context.architecture.display)
                    Stat("Memory", Format.bytes(context.physicalMemoryBytes))
                }
                Text("Model and OS only. Signalbox never reads the serial number, hardware UUID, computer name, or your user name.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The host description was unavailable for this snapshot.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sinceLastCollection() -> some View {
        if let reason = model.timelineUnavailableReason {
            SignalCard(title: "Snapshot Timeline", systemImage: "chart.line.uptrend.xyaxis") {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Diagnostics for this collection are unaffected. Signalbox left any existing timeline file untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let delta = model.snapshotDelta {
            SignalCard(title: "Since Your Last Snapshot", systemImage: "chart.line.uptrend.xyaxis") {
                DeltaSummary(delta: delta) {
                    Stat("Collections recorded", String(model.timeline.count))
                }
                Button("View Full History") { model.destination = .history }
                    .accessibilityHint("Shows every recorded collection, and compares any two of them")
            }
        } else if model.timeline.count == 1 {
            SignalCard(title: "Since Your Last Snapshot", systemImage: "chart.line.uptrend.xyaxis") {
                Text("This is the first collection Signalbox has recorded. Refresh again later to compare.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func recurring() -> some View {
        let findings = model.timelineFindings
        if !findings.isEmpty {
            SignalCard(title: "Recurring Across Snapshots", systemImage: "arrow.triangle.2.circlepath") {
                Text("Counts are not added up across collections; each collection re-reads the same rolling window of reports.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: finding.severity.icon).foregroundStyle(finding.severity.tint)
                            Text(finding.title).font(.headline)
                            Spacer()
                            StatusPill(text: finding.confidence.rawValue.capitalized, color: .gray)
                        }
                        Text(finding.explanation)
                        if let step = finding.recommendedNextStep {
                            Text("Next step: \(step)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func volumes(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "Local Storage", systemImage: "internaldrive") {
            if snapshot.volumes.filter(\.isLocal).isEmpty {
                Text("No local-volume evidence was available.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.volumes.filter(\.isLocal)) { volume in
                VStack(alignment: .leading, spacing: 5) {
                    Text(volume.name).font(.headline)
                    Text("\(Format.bytes(volume.availableBytes)) available of \(Format.bytes(volume.totalBytes))")
                    ProgressView(value: Double(max(0, volume.totalBytes - volume.availableBytes)), total: Double(max(1, volume.totalBytes)))
                        .accessibilityLabel("Storage used on \(volume.name)")
                    Text(volume.mountPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Text("Storage warnings use labeled headroom heuristics; they are not a health score.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func memory(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "Memory Context", systemImage: "memorychip") {
            if let memory = snapshot.memory {
                HStack(spacing: 22) {
                    Stat("Physical", Format.bytes(memory.physicalBytes))
                    Stat("Active", Format.bytes(memory.activeBytes))
                    Stat("Compressed", Format.bytes(memory.compressedBytes))
                    Stat("Free", Format.bytes(memory.freeBytes))
                }
                Text("Low free memory alone does not prove memory exhaustion.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Memory evidence was unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    private func findings(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "Findings", systemImage: "text.magnifyingglass") {
            if snapshot.findings.isEmpty {
                Text("No findings were produced. This is not a guarantee that no problem exists.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.findings) { finding in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: finding.severity.icon).foregroundStyle(finding.severity.tint)
                        Text(finding.title).font(.headline)
                        Spacer()
                        StatusPill(text: finding.severity.rawValue.capitalized, color: finding.severity.tint)
                        StatusPill(text: finding.confidence.rawValue.capitalized, color: .gray)
                    }
                    Text(finding.explanation)
                    Label(finding.evidenceSource, systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Collected \(Format.date(finding.collectedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let step = finding.recommendedNextStep {
                        Text("Next step: \(step)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// One card per observed report family. Families are never totalled
    /// together, so a hang can never be read as a crash.
    @ViewBuilder
    private func reportFamilies(_ snapshot: SystemSnapshot) -> some View {
        let observed = snapshot.observedReportKinds
        if observed.isEmpty {
            SignalCard(title: "Recent Diagnostic Reports", systemImage: "exclamationmark.bubble") {
                Text("No grouped recent diagnostic reports were observed. This is not a guarantee that nothing went wrong.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(observed, id: \.self) { kind in
                SignalCard(title: kind.sectionTitle, systemImage: kind.systemImage) {
                    Text(kind.sectionCaption).font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.groups(of: kind)) { group in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(group.applicationName).font(.headline)
                                Text("Most recent " + Format.date(group.mostRecentAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(group.count > 1 ? "\(group.count) similar" : "1 report")
                                .font(.callout.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func recentlyRunning(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "Running at Snapshot", systemImage: "app.badge.checkmark") {
            if snapshot.runningApplications.isEmpty {
                Text("No running-application evidence was available.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.runningApplications.prefix(12)) { application in
                HStack {
                    Text(application.name)
                    Spacer()
                    if application.isActive { Text("Active").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func unavailable(_ snapshot: SystemSnapshot) -> some View {
        SignalCard(title: "Unavailable Evidence", systemImage: "questionmark.folder") {
            if snapshot.unavailableEvidence.isEmpty {
                Label("All configured evidence sources reported a result.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.unavailableEvidence) { unavailable in
                VStack(alignment: .leading, spacing: 3) {
                    Text(unavailable.source).font(.headline)
                    Text(unavailable.reason).foregroundStyle(.secondary)
                    Text(Format.date(unavailable.collectedAt)).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.visibleApplications, selection: $model.selectedApplicationID) { application in
                    HStack(spacing: 10) {
                        AppIcon(application: application, size: 30)
                        VStack(alignment: .leading) {
                            Text(application.name)
                            Text(application.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !application.matchingCrashReports.isEmpty {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Has matching diagnostic reports")
                        }
                        if model.isApplicationRunning(bundleIdentifier: application.bundleIdentifier) {
                            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Running")
                        }
                    }
                    .tag(application.id)
                }
                .accessibilityLabel("Applications")

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Only apps with First Aid or reports", isOn: $model.showsOnlyActionableApplications)
                        .font(.caption)
                        .accessibilityHint("Limits the list to apps with an audited recipe or matching diagnostic reports")
                    Text(model.applicationFilterSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 250, idealWidth: 290)
            .searchable(
                text: $model.applicationSearchText,
                placement: .sidebar,
                prompt: "Search name or bundle identifier"
            )

            if let application = model.selectedApplication {
                applicationDetail(application)
            } else {
                ContentUnavailableView("Select an app", systemImage: "app.dashed", description: Text("Choose an installed or running application to inspect its evidence."))
                    .frame(minWidth: 440)
            }
        }
        .navigationTitle("Apps")
    }

    private func applicationDetail(_ application: InspectedApplication) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    AppIcon(application: application, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(application.name).font(.largeTitle.bold())
                        Text(application.bundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
                        StatusPill(
                            text: model.isApplicationRunning(bundleIdentifier: application.bundleIdentifier) ? "Running" : "Closed",
                            color: model.isApplicationRunning(bundleIdentifier: application.bundleIdentifier) ? .green : .secondary
                        )
                    }
                }

                SignalCard(title: "Application Details", systemImage: "info.circle") {
                    DetailRow("Version", application.version)
                    DetailRow("Architecture", application.executableArchitecture.display)
                    DetailRow("Code signing", application.codeSigningStatus.display)
                }

                SignalCard(title: "Matching Crash Reports", systemImage: "doc.text.magnifyingglass") {
                    if application.matchingCrashReports.isEmpty {
                        Text("No matching recent crash reports were found.").foregroundStyle(.secondary)
                    }
                    ForEach(application.matchingCrashReports) { report in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.reportKind).font(.headline)
                            Text(report.signature).lineLimit(2)
                            Text(Format.date(report.occurredAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                SignalCard(title: "App First Aid", systemImage: "cross.case") {
                    if model.selectedApplicationRecipes.isEmpty {
                        Text("No audited First Aid recipe is available for this app.").foregroundStyle(.secondary)
                    }
                    ForEach(model.selectedApplicationRecipes) { recipe in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recipe.name).font(.headline)
                            Text(recipe.rationale).foregroundStyle(.secondary)
                            ForEach(application.recipeEvidence, id: \.self) { evidence in
                                Label(evidence, systemImage: "checkmark.circle").font(.callout)
                            }
                            Text("This is a safe experiment, not a guaranteed fix. Preferences, sessions, databases, and user content are excluded.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Preview Cache-Only Repair") { Task { await model.prepareRepair(using: recipe) } }
                                .disabled(model.isPreparingRepair)
                                .accessibilityLabel("Preview reversible cache-only repair for \(application.name)")
                        }
                    }
                    if model.isPreparingRepair { ProgressView("Calculating file counts and sizes…") }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 440)
    }
}

private struct RepairHistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Repair History", subtitle: "Backups are kept until you choose what to do with them.") { EmptyView() }
                if model.repairHistory.isEmpty {
                    ContentUnavailableView("No repair history", systemImage: "clock.arrow.circlepath", description: Text("Completed and incomplete cache backups will appear here."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
                ForEach(model.repairHistory) { manifest in
                    SignalCard(title: manifest.targetApplicationName, systemImage: "shippingbox") {
                        HStack {
                            StatusPill(text: manifest.state.display, color: manifest.state.tint)
                            Text(Format.date(manifest.creationDate)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(manifest.backupByteCount)).font(.headline)
                        }
                        Text("\(manifest.movedItemCount) items moved or restored · \(manifest.operations.count) operations recorded")
                        Text(manifest.backupDirectoryPath.replacingHomeWithTilde())
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if !manifest.errors.isEmpty {
                            Label("\(manifest.errors.count) recorded issue(s); the backup was retained.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            ForEach(Array(manifest.errors.enumerated()), id: \.offset) { recorded in
                                Text(recorded.element.replacingHomeWithTilde())
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        operations(manifest)
                        HStack {
                            Button("Restore…") { model.beginRestore(manifest) }
                                .disabled(manifest.state == .restored)
                                .accessibilityLabel("Restore backup for \(manifest.targetApplicationName)")
                            Button("Reveal Backup in Finder") { model.revealBackup(manifest) }
                                .accessibilityLabel("Reveal backup for \(manifest.targetApplicationName) in Finder")
                            Button("Copy Recovery Steps") { copyRecoverySteps(manifest) }
                                .accessibilityLabel("Copy manual recovery steps for \(manifest.targetApplicationName)")
                                .accessibilityHint("Plain-text steps to move each backed-up item back by hand, without Signalbox")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Repair History")
    }

    /// Every recorded operation, with the state it is actually in.
    ///
    /// The card previously showed only totals, so a partial transaction could
    /// say "2 items moved or restored" without saying which two. Recovering by
    /// hand needs the per-item paths, and so does deciding whether a restore is
    /// worth attempting at all.
    @ViewBuilder
    private func operations(_ manifest: BackupManifest) -> some View {
        DisclosureGroup("Recorded operations (\(manifest.operations.count))") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(manifest.operations) { operation in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            StatusPill(text: operation.state.display, color: operation.state.tint)
                            Text("\(operation.fileCount) files · \(Format.bytes(operation.byteCount))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(operation.originalPath.replacingHomeWithTilde())
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("Backup: \(operation.backupPath.replacingHomeWithTilde())")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if let restoredPath = operation.restoredPath, restoredPath != operation.originalPath {
                            Text("Restored to: \(restoredPath.replacingHomeWithTilde())")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let error = operation.error {
                            Text(error.replacingHomeWithTilde())
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .accessibilityHint("Lists each recorded item, its state, and where it currently is")
    }

    private func copyRecoverySteps(_ manifest: BackupManifest) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.manualRecoverySteps(for: manifest), forType: .string)
        model.manualRecoveryStepsCopied(for: manifest)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClearTimeline = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Settings", subtitle: "Privacy-first diagnostics and cautious, reversible repairs.") { EmptyView() }
                SignalCard(title: "Demo Mode", systemImage: "sparkles.rectangle.stack") {
                    Toggle("Use deterministic demo data", isOn: Binding(
                        get: { model.isDemoMode },
                        set: { value in Task { await model.setDemoMode(value) } }
                    ))
                    .accessibilityHint("Shows fixed fixtures and simulates repairs without touching files")
                    Text("Launch with `--demo` or `--demo-mode` for a repeatable full-interface demonstration. Demo repairs never touch files or quit real apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SignalCard(title: "Snapshot Timeline", systemImage: "chart.line.uptrend.xyaxis") {
                    Text("Signalbox stores a reduced summary of each collection on this Mac so it can answer whether a problem has recurred. Nothing is transmitted.")
                    Label("Recorded: capacity, memory totals, grouped report signatures, unavailable source names, finding counts", systemImage: "checkmark.circle")
                    Label("Never recorded: which apps were open, report contents, file names, or provider messages", systemImage: "xmark.circle")
                    Text("Collections stored: \(model.timeline.count) of a maximum \(SnapshotTimelineStore.defaultMaximumEntries). \(model.isDemoMode ? "Demo mode uses a fixed in-memory timeline and writes nothing." : "Oldest collections are discarded automatically.")")
                        .font(.callout.bold())
                    if let reason = model.timelineUnavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    HStack {
                        Button("View History") { model.destination = .history }
                            .disabled(model.timeline.isEmpty)
                            .accessibilityHint("Shows every recorded collection and exports them as CSV")
                        Button("Forget Snapshot History…") { confirmClearTimeline = true }
                            .disabled(model.timeline.isEmpty)
                            .accessibilityHint("Deletes only Signalbox's own snapshot summaries; backups are not affected")
                    }
                }
                SignalCard(title: "Privacy", systemImage: "hand.raised") {
                    Label("No telemetry, analytics, accounts, cloud service, or network requirement", systemImage: "checkmark.circle")
                    Label("Raw crash-report contents stay out of exported reports", systemImage: "checkmark.circle")
                    Label("Home-directory paths are exported with `~`", systemImage: "checkmark.circle")
                    Label("Host details are limited to model, OS, and architecture", systemImage: "checkmark.circle")
                }
                SignalCard(title: "Repair Safety", systemImage: "lock.shield") {
                    Text("Signalbox only offers audited cache paths, requires the app to be closed, revalidates before moving, and writes a JSON backup manifest. It never uses administrator access or force-quits an app.")
                    Text("Stored backup data represented by history: \(Format.bytes(model.repairHistory.reduce(0) { $0 + $1.backupByteCount }))")
                        .font(.callout.bold())
                }
                SignalCard(title: "Diagnostic Report", systemImage: "doc.text") {
                    Text("Choose which app metadata and repair transactions to include, preview the sanitized Markdown, then save it locally.")
                    Button("Preview Report…") { model.beginReportPreview() }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Forget Signalbox's snapshot history?",
            isPresented: $confirmClearTimeline
        ) {
            Button("Forget History", role: .destructive) { Task { await model.clearTimeline() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes only Signalbox's own snapshot summaries. Cache backups, repair manifests, and everything else on this Mac are left untouched. Recurrence detection starts over from the next collection.")
        }
    }
}

private struct RepairPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmQuit = false
    @State private var confirmExecution = false

    var body: some View {
        if let plan = model.repairPlan {
            VStack(spacing: 0) {
                SheetHeader(title: "Preview Cache-Only Repair", subtitle: plan.targetApplication.name) { model.cancelRepairPreview() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SignalCard(title: "Why this is suggested", systemImage: "lightbulb") {
                            Text(plan.suggestionReason)
                            Text("This is a reversible experiment, not a guaranteed fix.")
                                .font(.callout.bold())
                        }
                        SignalCard(title: "Proposed Cache Paths", systemImage: "folder") {
                            Text("Nothing is selected by default. File counts and approximate sizes were calculated asynchronously during preview.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(plan.items) { item in
                                Button { model.toggleRepairItem(item) } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: model.selectedRepairItemIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.displayPath.replacingHomeWithTilde()).font(.callout.monospaced()).textSelection(.enabled)
                                            Text(item.exists ? "\(item.fileCount) files · \(Format.bytes(item.byteCount))" : "Does not exist")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if let reason = item.unavailableReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!item.exists || item.unavailableReason != nil)
                                .accessibilityLabel("\(model.selectedRepairItemIDs.contains(item.id) ? "Selected" : "Not selected"), \(item.displayPath)")
                            }
                        }
                        SignalCard(title: "Backup Destination", systemImage: "shippingbox") {
                            Text(plan.backupDirectoryPath.replacingHomeWithTilde()).font(.callout.monospaced()).textSelection(.enabled)
                            Text("Selected size: \(Format.bytes(model.selectedRepairByteCount)). Signalbox moves items; it never deletes them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SignalCard(title: "Application Must Be Closed", systemImage: "power") {
                            let running = model.isApplicationRunning(bundleIdentifier: plan.targetApplication.bundleIdentifier)
                            Label(running ? "\(plan.targetApplication.name) is running" : "\(plan.targetApplication.name) is closed", systemImage: running ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(running ? .orange : .green)
                            if running {
                                Button("Ask App to Quit…") { confirmQuit = true }
                                    .accessibilityHint("Uses the normal macOS quit request and never force-quits")
                            }
                        }
                        Toggle("I understand this is a reversible experiment and may not fix the issue.", isOn: $model.hasConfirmedRepair)
                            .accessibilityLabel("Confirm repair experiment")
                    }
                    .padding(20)
                }
                Divider()
                HStack {
                    Button("Cancel") { model.cancelRepairPreview() }
                    Spacer()
                    Button("Move Selected Caches to Backup…") { confirmExecution = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canExecuteRepair)
                }
                .padding()
            }
            .frame(width: 720, height: 680)
            .confirmationDialog("Ask \(plan.targetApplication.name) to quit?", isPresented: $confirmQuit) {
                Button("Quit App") { Task { await model.requestQuit(bundleIdentifier: plan.targetApplication.bundleIdentifier, applicationName: plan.targetApplication.name) } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Save your work first. Signalbox sends a normal quit request and never force-kills a process.") }
            .confirmationDialog("Move the selected cache folders into the shown backup?", isPresented: $confirmExecution) {
                Button("Move to Backup") { Task { await model.executeRepair() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Signalbox will revalidate every path immediately before moving it.") }
        }
    }
}

private struct RestorePreviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmQuit = false
    @State private var confirmRestore = false

    var body: some View {
        if let manifest = model.restoreManifest {
            VStack(spacing: 0) {
                SheetHeader(title: "Restore Cache Backup", subtitle: manifest.targetApplicationName) { model.cancelRestore() }
                VStack(alignment: .leading, spacing: 16) {
                    SignalCard(title: "Backup", systemImage: "shippingbox") {
                        Text("\(manifest.operations.count) recorded items · \(Format.bytes(manifest.backupByteCount))")
                        Text(manifest.backupDirectoryPath.replacingHomeWithTilde()).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    SignalCard(title: "Safe Restore", systemImage: "arrow.uturn.backward") {
                        Text("Signalbox never overwrites a newly created destination. A conflict will offer an alternate folder or cancellation.")
                        let running = model.isApplicationRunning(bundleIdentifier: manifest.targetBundleIdentifier)
                        Label(running ? "\(manifest.targetApplicationName) is running" : "The app is closed", systemImage: running ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(running ? .orange : .green)
                        if running { Button("Ask App to Quit…") { confirmQuit = true } }
                    }
                    Toggle("I have closed the app and want to restore this backup.", isOn: $model.hasConfirmedRestore)
                    Spacer()
                    HStack {
                        Button("Cancel") { model.cancelRestore() }
                        Spacer()
                        Button("Restore…") { confirmRestore = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canRestore)
                    }
                }
                .padding(20)
            }
            .frame(width: 600, height: 440)
            .confirmationDialog("Ask \(manifest.targetApplicationName) to quit?", isPresented: $confirmQuit) {
                Button("Quit App") { Task { await model.requestQuit(bundleIdentifier: manifest.targetBundleIdentifier, applicationName: manifest.targetApplicationName) } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Signalbox sends a normal quit request and never force-quits.") }
            .confirmationDialog("Restore this cache backup?", isPresented: $confirmRestore) {
                Button("Restore") { Task { await model.executeRestore() } }
                Button("Cancel", role: .cancel) { }
            }
            .alert(item: $model.restoreConflict) { conflict in
                Alert(
                    title: Text("Restore location is occupied"),
                    message: Text("Signalbox will not overwrite \(conflict.originalPath). Restore to \(conflict.suggestedAlternatePath) instead?"),
                    primaryButton: .default(Text("Restore to Alternate")) {
                        // Capture the conflict by value: the binding is set to
                        // nil as the alert dismisses, before this Task runs.
                        Task { await model.restoreToSuggestedAlternate(conflict) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

private struct ReportPreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Diagnostic Report", subtitle: "Choose, preview, and export sanitized Markdown") { model.closeReportPreview() }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Include").font(.headline)
                        Toggle("System snapshot", isOn: $model.reportIncludesSnapshot)
                        Toggle("Snapshot timeline", isOn: $model.reportIncludesTimeline)
                        Divider()
                        Text("Applications").font(.headline)
                        if model.applications.isEmpty { Text("None available").foregroundStyle(.secondary) }
                        ForEach(model.applications) { application in
                            Toggle(application.name, isOn: setBinding(application.id, in: $model.reportApplicationIDs))
                        }
                        Divider()
                        Text("Repair History").font(.headline)
                        if model.repairHistory.isEmpty { Text("None available").foregroundStyle(.secondary) }
                        ForEach(model.repairHistory) { manifest in
                            Toggle("\(manifest.targetApplicationName) · \(Format.shortDate(manifest.creationDate))", isOn: setBinding(manifest.transactionID, in: $model.reportTransactionIDs))
                        }
                        Text("Raw report contents, report signatures, unrelated filenames, and operation paths are excluded. Home paths become `~`. Host details are limited to model, OS, and architecture.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .frame(minWidth: 260, idealWidth: 300)
                ScrollView([.vertical, .horizontal]) {
                    Text(model.reportMarkdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityLabel("Markdown report preview")
            }
            Divider()
            HStack {
                Button("Close") { model.closeReportPreview() }
                Spacer()
                Button("Copy to Clipboard") { copyMarkdown() }
                    .accessibilityHint("Copies exactly the sanitized Markdown shown in the preview")
                Button("Export Markdown…") { exportMarkdown() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 980, height: 700)
    }

    /// Copies the same sanitized text that is shown and exported. There is no
    /// second, richer representation that could leak more than the preview.
    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.reportMarkdown, forType: .string)
        model.reportCopied()
    }

    private func setBinding<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { selected in
                if selected { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
            }
        )
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.title = "Export Signalbox Diagnostic Report"
        panel.nameFieldStringValue = "Signalbox-Diagnostic-Report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.reportMarkdown.write(to: url, atomically: true, encoding: .utf8)
            model.reportExported(to: url)
        } catch {
            model.reportExportFailed(error)
        }
    }
}
