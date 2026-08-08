@testable import CoreBridge
import Foundation
import Security
import XCTest

final class HostAgentXPCListenerFactoryTests: XCTestCase {
    func testUsesOneMachServiceAndProductSigningRequirement() {
        XCTAssertEqual(
            HostAgentXPCListenerFactory.machServiceName,
            "io.rustdesknative.viewer.host-agent"
        )
        XCTAssertEqual(
            HostAgentRegistrationCodeSignaturePreflight.productRequirement,
            """
            identifier "io.rustdesknative.viewer" and anchor apple generic and \
            certificate leaf[subject.OU] = "3J43F8H829"
            """
        )
    }

    func testProductRequirementCompilesAndMatchesInstalledProduct() throws {
        let requirement = try makeProductRequirement()
        let productURL = URL(
            fileURLWithPath: "/Applications/FarPane.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: productURL.path) else {
            throw XCTSkip("installed FarPane product is unavailable")
        }

        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(
                productURL as CFURL,
                SecCSFlags(),
                &staticCode
            ),
            errSecSuccess
        )
        let code = try XCTUnwrap(staticCode)
        XCTAssertEqual(
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
            ),
            errSecSuccess
        )
    }

    func testProductRequirementRejectsAnotherAppleAuthority() throws {
        let requirement = try makeProductRequirement()
        let systemAppURL = URL(
            fileURLWithPath: "/System/Applications/Calculator.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: systemAppURL.path) else {
            throw XCTSkip("system comparison app is unavailable")
        }

        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(
                systemAppURL as CFURL,
                SecCSFlags(),
                &staticCode
            ),
            errSecSuccess
        )
        let code = try XCTUnwrap(staticCode)
        XCTAssertNotEqual(
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
            ),
            errSecSuccess
        )
    }

    func testFactoryConfiguresButDoesNotActivateTheListener() throws {
        let listener = HostAgentXPCListenerFactory.makeListener()
        XCTAssertNil(listener.delegate)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentXPCListenerFactory.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("NSXPCListener(machServiceName:"))
        XCTAssertTrue(source.contains(
            ".setConnectionCodeSigningRequirement("
        ))
        XCTAssertFalse(source.contains(".anonymous"))
        XCTAssertFalse(source.contains("serviceListener"))
        XCTAssertFalse(source.contains(".activate()"))
        XCTAssertFalse(source.contains(".resume()"))
        XCTAssertFalse(source.contains("ProcessInfo.processInfo.environment"))
    }

    private func makeProductRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                HostAgentRegistrationCodeSignaturePreflight
                    .productRequirement as CFString,
                SecCSFlags(),
                &requirement
            ),
            errSecSuccess
        )
        return try XCTUnwrap(requirement)
    }
}
