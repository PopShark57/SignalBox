import Foundation
import XCTest
@testable import Signalbox

final class ProvidersApplicationCatalogTests: XCTestCase {
    func testCatalogDiscoversNestedBundlesAndUsesInjectedInspector() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignalboxCatalog-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root
            .appendingPathComponent("Utilities", isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = InspectedApplication(
            name: "Fixture",
            bundleIdentifier: "com.example.fixture",
            version: "1",
            bundleURL: bundleURL,
            executableArchitecture: .available("Apple silicon"),
            codeSigningStatus: .available("Valid"),
            isRunning: false,
            iconFileURL: nil,
            matchingCrashReports: [],
            suggestedRecipeIDs: [],
            recipeEvidence: []
        )
        let provider = LiveApplicationCatalogProvider(
            inspector: MockBundleInspector(applicationsByURL: [bundleURL: fixture]),
            runningProvider: MockRunningApplicationProvider(applications: []),
            reportProvider: MockDiagnosticReportProvider(reports: []),
            searchRoots: [root],
            maximumApplications: 10
        )

        let result = await provider.collectApplications(at: DemoFixtures.referenceDate)

        guard case .available(let applications) = result else {
            return XCTFail("Expected the injected fixture application.")
        }
        XCTAssertEqual(applications.map(\.bundleIdentifier), ["com.example.fixture"])
    }

    func testCatalogSurfacesMissingCrashEvidence() async {
        let provider = LiveApplicationCatalogProvider(
            inspector: MockBundleInspector(applicationsByURL: [:]),
            runningProvider: MockRunningApplicationProvider(applications: []),
            reportProvider: MockDiagnosticReportProvider(result: .unavailable(reason: "Permission denied")),
            searchRoots: []
        )

        let result = await provider.collectApplications(at: DemoFixtures.referenceDate)

        guard case .unavailable(let reason) = result else {
            return XCTFail("Unavailable crash evidence must not look like an empty healthy result.")
        }
        XCTAssertEqual(reason, "Permission denied")
    }
}
