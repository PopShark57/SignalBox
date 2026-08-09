import Foundation
import XCTest
@testable import Signalbox

final class PathSafetyValidatorTests: XCTestCase {
    func testRejectsTraversalAndPrefixCollision() throws {
        let temporaryRoot = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(temporaryRoot) }
        let allowed = temporaryRoot.appendingPathComponent("allowed", isDirectory: true)
        let prefixCollision = temporaryRoot.appendingPathComponent("allowed-extra/Cache", isDirectory: true)
        try RepairTestSupport.createDirectory(allowed)
        try RepairTestSupport.createDirectory(prefixCollision)

        let validator = PathSafetyValidator()
        XCTAssertThrowsError(
            try validator.validate(
                source: URL(fileURLWithPath: allowed.path + "/../outside/Cache"),
                inside: allowed
            )
        )
        XCTAssertThrowsError(try validator.validate(source: prefixCollision, inside: allowed))
    }

    func testRejectsSourceAndIntermediateSymlinks() throws {
        let temporaryRoot = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(temporaryRoot) }
        let allowed = temporaryRoot.appendingPathComponent("allowed", isDirectory: true)
        let elsewhere = temporaryRoot.appendingPathComponent("elsewhere", isDirectory: true)
        try RepairTestSupport.createDirectory(allowed)
        try RepairTestSupport.createDirectory(elsewhere)

        let link = allowed.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let validator = PathSafetyValidator()
        XCTAssertThrowsError(try validator.validate(source: link, inside: allowed)) { error in
            guard case PathSafetyError.symbolicLink = error else {
                return XCTFail("Expected a symbolic-link rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try validator.validate(
                source: link.appendingPathComponent("Cache", isDirectory: true),
                inside: allowed
            )
        )
    }

    func testAcceptsOnlyAnAuditedDirectChild() throws {
        let temporaryRoot = try RepairTestSupport.makeTemporaryDirectory()
        defer { RepairTestSupport.removeTemporaryDirectory(temporaryRoot) }
        let allowed = temporaryRoot.appendingPathComponent("allowed", isDirectory: true)
        let cache = allowed.appendingPathComponent("Cache", isDirectory: true)
        try RepairTestSupport.createDirectory(cache)

        let validated = try PathSafetyValidator().validate(
            source: cache,
            inside: allowed,
            allowedLeafNames: ElectronCacheDirectory.auditedNameSet,
            requireExistingDirectory: true
        )
        XCTAssertEqual(validated.sourceURL.lastPathComponent, "Cache")
        XCTAssertThrowsError(
            try PathSafetyValidator().validate(
                source: allowed.appendingPathComponent("Preferences", isDirectory: true),
                inside: allowed,
                allowedLeafNames: ElectronCacheDirectory.auditedNameSet
            )
        )
    }
}
