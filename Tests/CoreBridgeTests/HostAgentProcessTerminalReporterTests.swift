import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessTerminalReporterTests: XCTestCase {
    func testUnavailableEntryWritesOneFixedLineAndReturnsEXUnavailable() throws {
        let pipe = Pipe()

        let exitCode = HostAgentProcessTerminalReporter.report(
            .unavailable,
            to: pipe.fileHandleForWriting
        )
        try pipe.fileHandleForWriting.close()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()

        XCTAssertEqual(exitCode, 69)
        XCTAssertEqual(
            String(decoding: output, as: UTF8.self),
            "FarPane HostAgent runtime is not available in this build.\n"
        )
    }

    func testStoppedResultWritesNothingAndReturnsSuccess() throws {
        let pipe = Pipe()

        let exitCode = HostAgentProcessTerminalReporter.report(
            .process(.stopped),
            to: pipe.fileHandleForWriting
        )
        try pipe.fileHandleForWriting.close()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.isEmpty)
    }

    func testClosedDiagnosticSinkDoesNotChangeFailureExitCode() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        let exitCode = HostAgentProcessTerminalReporter.report(
            .process(.startupFailed(HostAgentStartupFailure(
                kind: .configurationUnavailable
            ))),
            to: pipe.fileHandleForWriting
        )

        XCTAssertEqual(exitCode, 78)
    }
}
