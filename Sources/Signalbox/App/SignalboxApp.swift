import SwiftUI

@main
@MainActor
struct SignalboxApp: App {
    @StateObject private var model = AppModel(dependencies: .production())

    var body: some Scene {
        WindowGroup("Signalbox") {
            SignalboxRootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Snapshot") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRefreshing)
                Button("Preview Diagnostic Report") { model.beginReportPreview() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Toggle("Deterministic Demo Data", isOn: Binding(
                    get: { model.isDemoMode },
                    set: { value in Task { await model.setDemoMode(value) } }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                ForEach(Array(SidebarDestination.allCases.enumerated()), id: \.element) { index, destination in
                    Button(destination.title) { model.destination = destination }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: .command
                        )
                }
            }
        }
    }
}
