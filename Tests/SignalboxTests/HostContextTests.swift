import Foundation
import XCTest
@testable import Signalbox

final class HostContextTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testLiveProviderDescribesTheMachineWithoutIdentifyingIt() async throws {
        let result = await LiveHostContextProvider().collectHostContext(at: date)

        guard case .available(let context) = result else {
            return XCTFail("The host description should be available on a normal Mac.")
        }
        XCTAssertEqual(context.collectedAt, date)
        XCTAssertGreaterThan(context.physicalMemoryBytes, 0)
        XCTAssertFalse(context.operatingSystemVersion.isEmpty)

        // Nothing that identifies this particular Mac or its owner may appear.
        let rendered = [
            context.operatingSystemVersion,
            context.operatingSystemBuild.plainText,
            context.hardwareModelIdentifier.plainText,
            context.architecture.plainText
        ].joined(separator: " ")
        let userName = NSUserName()
        let hostName = ProcessInfo.processInfo.hostName
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains(userName), "The user name must never be collected.")
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains(hostName), "The host name must never be collected.")
        XCTAssertFalse(rendered.contains("/Users/"), "No path may appear in the host description.")
    }

    func testCollectorPopulatesHostContextAndSurfacesItAsEvidence() async throws {
        let snapshot = await collector(host: .available(DemoFixtures.demoHostContext)).collect(at: date)

        let context = try XCTUnwrap(snapshot.hostContext)
        XCTAssertEqual(context, DemoFixtures.demoHostContext)
        XCTAssertTrue(snapshot.evidence.contains { $0.title == "This Mac" })
        XCTAssertFalse(snapshot.unavailableEvidence.contains { $0.source == DiagnosticSource.host })
    }

    func testUnavailableHostContextIsReportedRatherThanFabricated() async {
        let snapshot = await collector(
            host: .unavailable(reason: "The test denied the host description.")
        ).collect(at: date)

        XCTAssertNil(snapshot.hostContext)
        XCTAssertTrue(snapshot.unavailableEvidence.contains { $0.source == DiagnosticSource.host })
        XCTAssertTrue(snapshot.findings.contains { $0.title == "Some evidence could not be inspected" })
        XCTAssertFalse(
            snapshot.evidence.contains { $0.title == "This Mac" },
            "A failed host lookup must not be represented as an observed description."
        )
    }

    private func collector(host: ProviderResult<HostContext>) -> SystemSnapshotCollector {
        SystemSnapshotCollector(
            hostProvider: MockHostContextProvider(result: host),
            diskProvider: MockDiskHealthProvider(volumes: [DemoFixtures.demoVolume]),
            memoryProvider: MockMemoryContextProvider(memory: DemoFixtures.demoMemory),
            reportProvider: MockDiagnosticReportProvider(reports: []),
            runningApplicationProvider: MockRunningApplicationProvider(applications: [])
        )
    }
}
