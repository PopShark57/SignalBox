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
            timelineCSVExporter: TimelineCSVExporter(homeDirectory: URL(fileURLWithPath: "/Users/tester")),
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

    func testHistoryListsRecordedCollectionsNewestFirstAndDerivesTheCapacityTrend() async throws {
        let model = try makeModel()
        await model.start()

        XCTAssertEqual(model.timeline.count, model.historyEntries.count)
        let dates = model.historyEntries.map(\.collectedAt)
        XCTAssertEqual(dates, dates.sorted(by: >), "History reads newest first.")

        let trend = try XCTUnwrap(model.capacityTrend)
        XCTAssertEqual(trend.readingCount, model.timeline.filter { $0.systemVolume != nil }.count)
        XCTAssertGreaterThan(
            trend.notComparableIntervalCount,
            0,
            "The demo timeline deliberately contains a collection that never read the system volume."
        )
    }

    func testComparingTwoCollectionsIsIndependentOfTheOrderTheyWereSelected() async throws {
        let model = try makeModel()
        await model.start()
        let entries = model.historyEntries
        let newest = try XCTUnwrap(entries.first)
        let oldest = try XCTUnwrap(entries.last)

        model.toggleHistorySelection(newest)
        XCTAssertNil(model.comparisonDelta, "One collection is not a comparison.")
        model.toggleHistorySelection(oldest)
        let newestFirst = try XCTUnwrap(model.comparisonDelta)

        model.clearHistorySelection()
        model.toggleHistorySelection(oldest)
        model.toggleHistorySelection(newest)
        let oldestFirst = try XCTUnwrap(model.comparisonDelta)

        XCTAssertEqual(newestFirst, oldestFirst)
        XCTAssertEqual(newestFirst.previousCollectedAt, oldest.collectedAt)
        XCTAssertEqual(newestFirst.currentCollectedAt, newest.collectedAt)
    }

    func testSelectingAThirdCollectionReleasesTheOldestSelection() async throws {
        let model = try makeModel()
        await model.start()
        let entries = model.historyEntries
        try XCTSkipUnless(entries.count >= 3)

        model.toggleHistorySelection(entries[0])
        model.toggleHistorySelection(entries[1])
        model.toggleHistorySelection(entries[2])

        XCTAssertEqual(model.historySelectedIDs, [entries[1].id, entries[2].id])
        XCTAssertFalse(model.isSelectedForComparison(entries[0]))
    }

    func testTimelineCSVCoversEveryRecordedCollection() async throws {
        let model = try makeModel()
        await model.start()

        let rows = model.timelineCSV.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(rows.count, model.timeline.count + 1, "One header plus one row per collection.")
        XCTAssertFalse(
            model.timelineCSV.contains("EXC_BAD_ACCESS"),
            "A report signature must never reach an exported file."
        )
    }

    // MARK: - Fixtures

    private func makeModel() throws -> AppModel {
        let suiteName = "SignalboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // The model reads demo mode during init, so the temporary suite has
        // done its job by the time this function returns. Nothing here ever
        // touches the developer's real defaults.
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: DemoModePreference.defaultsKey)

        let repairClient = DemoRepairStore.client(store: DemoRepairStore())
        return AppModel(dependencies: SignalboxDependencies(
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
            timelineCSVExporter: TimelineCSVExporter(homeDirectory: URL(fileURLWithPath: "/Users/tester")),
            clock: { DemoFixtures.referenceDate },
            defaults: defaults,
            processInfo: .processInfo
        ))
    }
}
