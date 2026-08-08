import Foundation
import XCTest

final class HostAgentProcessRealDispatchTests: XCTestCase {
    func testHostAgentDispatchRunsBootstrapAndExitsBeforeAppKit() throws {
        let appSource = try productSource("RustDeskNativeApp.swift")
        let roleDispatch = try XCTUnwrap(appSource.range(
            of: "RustDeskNativeProcessModePolicy.resolve(arguments: CommandLine.arguments)"
        ))
        let bootstrap = try XCTUnwrap(appSource.range(
            of: "exit(HostAgentProcessBootstrap.run())"
        ))
        let appKit = try XCTUnwrap(appSource.range(of: "NSApplication.shared"))
        let delegate = try XCTUnwrap(appSource.range(of: "let delegate = AppDelegate()"))

        XCTAssertLessThan(roleDispatch.lowerBound, bootstrap.lowerBound)
        XCTAssertLessThan(bootstrap.lowerBound, appKit.lowerBound)
        XCTAssertLessThan(bootstrap.lowerBound, delegate.lowerBound)
        XCTAssertFalse(appSource.contains("HostAgentBootstrap.failClosed()"))
        XCTAssertFalse(appSource.contains(
            "HostAgentProcessTerminalReporter.report(.unavailable)"
        ))
    }

    func testProductBootstrapReturnsExitCodeWithoutOwningProcessExit() throws {
        let bootstrapSource = try productSource("HostAgentProcessBootstrap.swift")

        XCTAssertTrue(bootstrapSource.contains("static func run() -> Int32"))
        XCTAssertTrue(bootstrapSource.contains(
            "HostAgentProcessBootstrapOrchestrator.run("
        ))
        XCTAssertFalse(bootstrapSource.contains("exit("))
        XCTAssertFalse(bootstrapSource.contains("NSApplication"))
        XCTAssertFalse(bootstrapSource.contains("import AppKit"))
    }

    private func productSource(_ name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/\(name)"
            ),
            encoding: .utf8
        )
    }
}
