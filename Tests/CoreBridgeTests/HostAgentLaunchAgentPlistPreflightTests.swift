@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentLaunchAgentPlistPreflightTests: XCTestCase {
    func testAcceptsExactProductIdentityWithoutFreezingLifecycleKeys() throws {
        var propertyList = validPropertyList()
        propertyList["RunAtLoad"] = true

        XCTAssertNoThrow(
            try HostAgentLaunchAgentPlistPreflight.validate(
                data(for: propertyList)
            )
        )
    }

    func testRejectsMalformedAndOversizedPayloadsBeforeTrustingFields() throws {
        XCTAssertThrowsError(
            try HostAgentLaunchAgentPlistPreflight.validate(Data("not a plist".utf8))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentPlistPreflightError,
                .malformedPropertyList
            )
        }

        XCTAssertThrowsError(
            try HostAgentLaunchAgentPlistPreflight.validate(
                Data(repeating: 0, count: 65_537)
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentPlistPreflightError,
                .payloadTooLarge
            )
        }
    }

    func testRequiresExactProductLabelAndBundleRelativeExecutable() throws {
        try assertRejected(
            replacing: "Label",
            with: "io.rustdesknative.viewer.host-agent.other",
            as: .invalidLabel
        )
        try assertRejected(
            replacing: "BundleProgram",
            with: "/Applications/FarPane.app/Contents/MacOS/RustDeskNative",
            as: .invalidBundleProgram
        )
        try assertRejected(
            replacing: "BundleProgram",
            with: "Contents/MacOS/OtherExecutable",
            as: .invalidBundleProgram
        )
    }

    func testRequiresOnlyTheHostAgentModeInTheCompleteArgumentVector() throws {
        try assertRejected(
            replacing: "ProgramArguments",
            with: ["--host-agent"],
            as: .invalidProgramArguments
        )
        try assertRejected(
            replacing: "ProgramArguments",
            with: ["RustDeskNative", "--host-agent", "--unsafe-override"],
            as: .invalidProgramArguments
        )
        try assertRejected(
            replacing: "ProgramArguments",
            with: ["RustDeskNative", "--host-agent\u{0}"],
            as: .invalidProgramArguments
        )
    }

    func testRequiresOneExactEnabledMachService() throws {
        try assertRejected(
            replacing: "MachServices",
            with: ["io.rustdesknative.viewer.host-agent": false],
            as: .invalidMachServices
        )
        try assertRejected(
            replacing: "MachServices",
            with: ["io.rustdesknative.viewer.host-agent": 1],
            as: .invalidMachServices
        )
        try assertRejected(
            replacing: "MachServices",
            with: [
                "io.rustdesknative.viewer.host-agent": true,
                "io.rustdesknative.viewer.host-agent.extra": true,
            ],
            as: .invalidMachServices
        )
    }

    func testRejectsAbsoluteProgramAndPrivilegedSystemDomainIdentityKeys() throws {
        for key in ["Program", "UserName", "GroupName"] {
            var propertyList = validPropertyList()
            propertyList[key] = "unexpected"

            XCTAssertThrowsError(
                try HostAgentLaunchAgentPlistPreflight.validate(
                    data(for: propertyList)
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentLaunchAgentPlistPreflightError,
                    .forbiddenConfiguration
                )
            }
        }
    }

    private func assertRejected(
        replacing key: String,
        with value: Any,
        as expectedError: HostAgentLaunchAgentPlistPreflightError
    ) throws {
        var propertyList = validPropertyList()
        propertyList[key] = value

        XCTAssertThrowsError(
            try HostAgentLaunchAgentPlistPreflight.validate(data(for: propertyList))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentPlistPreflightError,
                expectedError
            )
        }
    }

    private func validPropertyList() -> [String: Any] {
        [
            "Label": "io.rustdesknative.viewer.host-agent",
            "BundleProgram": "Contents/MacOS/RustDeskNative",
            "ProgramArguments": ["RustDeskNative", "--host-agent"],
            "MachServices": ["io.rustdesknative.viewer.host-agent": true],
        ]
    }

    private func data(for propertyList: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
