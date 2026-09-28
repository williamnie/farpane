import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentProcessBootstrapOrchestratorTests: XCTestCase {
    func testRejectedEntryAssessesThenReportsOnceWithoutRunning() {
        var calls: [String] = []
        var reported: HostAgentProcessTerminalResult?

        let exitCode = HostAgentProcessBootstrapOrchestrator.run(
            assess: {
                calls.append("assess")
                return .rejected(.invalidApplication)
            },
            run: { _ in
                calls.append("run")
                return .stopped
            },
            report: { result in
                calls.append("report")
                reported = result
                return 78
            })

        XCTAssertEqual(exitCode, 78)
        XCTAssertEqual(calls, ["assess", "report"])
        XCTAssertEqual(reported, .entryRejected(.invalidApplication))
    }

    func testEligibleEntryAssessesRunsAndReportsExactlyOnceInOrder() {
        let eligibility = HostAgentProcessEntryEligibility(
            buildIdentifier: "202608090003", signingChannel: .localDevelopment)
        var calls: [String] = []
        var receivedEligibility: HostAgentProcessEntryEligibility?
        var reported: HostAgentProcessTerminalResult?

        let exitCode = HostAgentProcessBootstrapOrchestrator.run(
            assess: {
                calls.append("assess")
                return .eligible(eligibility)
            },
            run: { received in
                calls.append("run")
                receivedEligibility = received
                return .startupFailed(HostAgentStartupFailure(kind: .configurationUnavailable))
            },
            report: { result in
                calls.append("report")
                reported = result
                return 78
            })

        XCTAssertEqual(exitCode, 78)
        XCTAssertEqual(calls, ["assess", "run", "report"])
        XCTAssertEqual(receivedEligibility, eligibility)
        XCTAssertEqual(
            reported,
            .process(.startupFailed(HostAgentStartupFailure(kind: .configurationUnavailable))))
    }

    func testCompositionUsesTerminalReporterForSanitizedOutput() throws {
        let pipe = Pipe()

        let exitCode = HostAgentProcessBootstrapOrchestrator.run(
            assess: { .rejected(.invalidCodeSignature) }, run: { _ in .stopped },
            report: { result in
                HostAgentProcessTerminalReporter.report(result, to: pipe.fileHandleForWriting)
            })
        try pipe.fileHandleForWriting.close()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()

        XCTAssertEqual(exitCode, 77)
        XCTAssertEqual(
            String(decoding: output, as: UTF8.self),
            "FarPane HostAgent code signature is invalid.\n")
    }

}
