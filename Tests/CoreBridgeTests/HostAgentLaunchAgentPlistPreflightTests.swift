@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentLaunchAgentPlistPreflightTests: XCTestCase {
    func testAcceptsExactProductIdentityAndLifecyclePolicy() throws {
        XCTAssertNoThrow(
            try HostAgentLaunchAgentPlistPreflight.validate(
                data(for: validPropertyList())
            )
        )
    }

    func testRequiresExactAquaCrashOnlyLifecyclePolicy() throws {
        let mutations: [(String, Any)] = [
            ("LimitLoadToSessionType", "Background"),
            ("LimitLoadToSessionType", ["Aqua"]),
            ("KeepAlive", true),
            ("KeepAlive", ["Crashed": false]),
            ("KeepAlive", ["SuccessfulExit": false]),
            ("KeepAlive", ["Crashed": true, "SuccessfulExit": false]),
            ("ThrottleInterval", 9),
            ("ThrottleInterval", true),
            ("ExitTimeOut", 0),
            ("ExitTimeOut", true),
        ]

        for (key, value) in mutations {
            try assertRejected(
                replacing: key,
                with: value,
                as: .invalidLifecyclePolicy
            )
        }

        for missingKey in [
            "LimitLoadToSessionType",
            "KeepAlive",
            "ThrottleInterval",
            "ExitTimeOut",
        ] {
            var propertyList = validPropertyList()
            propertyList.removeValue(forKey: missingKey)
            XCTAssertThrowsError(
                try HostAgentLaunchAgentPlistPreflight.validate(
                    data(for: propertyList)
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentLaunchAgentPlistPreflightError,
                    .invalidLifecyclePolicy
                )
            }
        }
    }

    func testRejectsEveryUnfrozenTopLevelCapability() throws {
        for (key, value) in [
            ("RunAtLoad", true),
            ("EnvironmentVariables", ["SERVER": "unexpected"]),
            ("StandardOutPath", "/tmp/farpane.out"),
            ("StandardErrorPath", "/tmp/farpane.err"),
            ("WatchPaths", ["/tmp"]),
            ("ProcessType", "Interactive"),
            ("Disabled", false),
        ] as [(String, Any)] {
            try assertRejected(
                replacing: key,
                with: value,
                as: .forbiddenConfiguration
            )
        }
    }

    func testRepositoryAssetMatchesFrozenPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = repositoryRoot.appendingPathComponent(
            "App/LaunchAgents/io.rustdesknative.viewer.host-agent.plist"
        )
        let asset = try Data(contentsOf: assetURL)

        XCTAssertNoThrow(try HostAgentLaunchAgentPlistPreflight.validate(asset))
        let decoded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: asset,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(decoded.keys.count, 8)
        XCTAssertNil(decoded["RunAtLoad"])
        XCTAssertEqual(decoded["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(decoded["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(decoded["ExitTimeOut"] as? Int, 10)
        XCTAssertEqual(
            (decoded["KeepAlive"] as? [String: Any])?["Crashed"] as? Bool,
            true
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
            with: ["FarPaneHostAgent", "--host-agent", "--unsafe-override"],
            as: .invalidProgramArguments
        )
        try assertRejected(
            replacing: "ProgramArguments",
            with: ["FarPaneHostAgent", "--host-agent\u{0}"],
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
            "BundleProgram": "Contents/MacOS/FarPaneHostAgent",
            "ProgramArguments": ["FarPaneHostAgent", "--host-agent"],
            "MachServices": ["io.rustdesknative.viewer.host-agent": true],
            "LimitLoadToSessionType": "Aqua",
            "KeepAlive": ["Crashed": true],
            "ThrottleInterval": 10,
            "ExitTimeOut": 10,
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
