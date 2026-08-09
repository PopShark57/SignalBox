import Foundation
import XCTest
@testable import Signalbox

@MainActor
final class AppModelTests: XCTestCase {
    func testSuccessfulDemoRepairClearsPreviewAndReportsHonestOutcome() async throws {
        let suiteName = "SignalboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: DemoModePreference.defaultsKey)

        let repairClient = DemoRepairStore.client(store: DemoRepairStore())
        let dependencies = SignalboxDependencies(
            data: SignalboxDataClient { _, _ in
                SignalboxLoadResult(
                    snapshot: DemoFixtures.snapshot(),
                    applications: DemoFixtures.applications()
                )
            },
            liveRepairs: repairClient,
            demoRepairs: repairClient,
            liveTimeline: .demo(),
            demoTimeline: .demo(),
            applications: SignalboxApplicationClient(
                isRunning: { _ in false },
                requestQuit: { _ in true },
                reveal: { _ in false }
            ),
            reportExporter: ReportExporter(homeDirectory: URL(fileURLWithPath: "/Users/tester")),
            clock: { DemoFixtures.referenceDate },
            defaults: defaults,
            processInfo: .processInfo
        )
        let model = AppModel(dependencies: dependencies)

        await model.start()
        let application = try XCTUnwrap(model.selectedApplication)
        let recipe = try XCTUnwrap(model.selectedApplicationRecipes.first)
        await model.prepareRepair(using: recipe)
        await model.requestQuit(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.name
        )
        let item = try XCTUnwrap(model.repairPlan?.items.first { $0.exists })
        model.toggleRepairItem(item)
        model.hasConfirmedRepair = true

        await model.executeRepair()

        XCTAssertNil(model.repairPlan, "A completed repair must dismiss and clear its preview.")
        XCTAssertTrue(model.selectedRepairItemIDs.isEmpty)
        XCTAssertEqual(model.issue?.title, "Cache backup completed")
        XCTAssertEqual(model.repairHistory.first?.state, .completed)
    }
}
