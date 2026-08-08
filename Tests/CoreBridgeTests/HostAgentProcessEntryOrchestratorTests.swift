@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessEntryOrchestratorTests: XCTestCase {
    func testEveryRejectionSkipsRunnerAndPreservesTypedFailure() {
        let failures: [HostAgentProcessEntryFailure] = [
            .invalidInvocation,
            .invalidLaunchAgent,
            .invalidApplication,
            .invalidCodeSignature,
            .distributionNotarizationRequired,
        ]

        for failure in failures {
            var assessmentCalls = 0
            var runnerCalls = 0

            let result = HostAgentProcessEntryOrchestrator.resolve(
                assess: {
                    assessmentCalls += 1
                    return .rejected(failure)
                },
                run: { _ in
                    runnerCalls += 1
                    return .stopped
                }
            )

            XCTAssertEqual(result, .entryRejected(failure))
            XCTAssertEqual(assessmentCalls, 1)
            XCTAssertEqual(runnerCalls, 0)
        }
    }

    func testEligibleAssessmentInvokesRunnerExactlyOnceWithSameEvidence() {
        let eligibility = HostAgentProcessEntryEligibility(
            buildIdentifier: "202608090001",
            signingChannel: .localDevelopment
        )
        var assessmentCalls = 0
        var receivedEligibility: HostAgentProcessEntryEligibility?
        var runnerCalls = 0

        let result = HostAgentProcessEntryOrchestrator.resolve(
            assess: {
                assessmentCalls += 1
                return .eligible(eligibility)
            },
            run: { received in
                runnerCalls += 1
                receivedEligibility = received
                return .stopped
            }
        )

        XCTAssertEqual(result, .process(.stopped))
        XCTAssertEqual(assessmentCalls, 1)
        XCTAssertEqual(runnerCalls, 1)
        XCTAssertEqual(receivedEligibility, eligibility)
    }

    func testRunnerFailureIsPreservedWithoutASecondAssessmentOrRun() {
        let failure = HostAgentStartupFailure(kind: .configurationUnavailable)
        var assessmentCalls = 0
        var runnerCalls = 0

        let result = HostAgentProcessEntryOrchestrator.resolve(
            assess: {
                assessmentCalls += 1
                return .eligible(HostAgentProcessEntryEligibility(
                    buildIdentifier: "dev-1",
                    signingChannel: .localDevelopment
                ))
            },
            run: { _ in
                runnerCalls += 1
                return .startupFailed(failure)
            }
        )

        XCTAssertEqual(result, .process(.startupFailed(failure)))
        XCTAssertEqual(assessmentCalls, 1)
        XCTAssertEqual(runnerCalls, 1)
    }

    func testForgedEligibilityFailsClosedBeforeRunner() {
        for invalidBuildIdentifier in ["", " bad", "bad/build"] {
            var runnerCalls = 0
            let result = HostAgentProcessEntryOrchestrator.resolve(
                assess: {
                    .eligible(HostAgentProcessEntryEligibility(
                        buildIdentifier: invalidBuildIdentifier,
                        signingChannel: .localDevelopment
                    ))
                },
                run: { _ in
                    runnerCalls += 1
                    return .stopped
                }
            )

            XCTAssertEqual(result, .entryRejected(.invalidApplication))
            XCTAssertEqual(runnerCalls, 0)
        }
    }

    func testEntryFailuresHaveFixedSanitizedSysexitsAndDiagnostics() throws {
        let expected: [(
            HostAgentProcessEntryFailure,
            Int32,
            String
        )] = [
            (
                .invalidInvocation,
                64,
                "FarPane HostAgent invocation is invalid.\n"
            ),
            (
                .invalidLaunchAgent,
                78,
                "FarPane HostAgent launch configuration is invalid.\n"
            ),
            (
                .invalidApplication,
                78,
                "FarPane HostAgent application identity is invalid.\n"
            ),
            (
                .invalidCodeSignature,
                77,
                "FarPane HostAgent code signature is invalid.\n"
            ),
            (
                .distributionNotarizationRequired,
                77,
                "FarPane HostAgent notarization evidence is unavailable.\n"
            ),
        ]

        for (failure, expectedExit, expectedOutput) in expected {
            let pipe = Pipe()
            let exitCode = HostAgentProcessTerminalReporter.report(
                .entryRejected(failure),
                to: pipe.fileHandleForWriting
            )
            try pipe.fileHandleForWriting.close()
            let output = try pipe.fileHandleForReading.readToEnd() ?? Data()

            XCTAssertEqual(exitCode, expectedExit)
            XCTAssertEqual(
                String(decoding: output, as: UTF8.self),
                expectedOutput
            )
            XCTAssertTrue(expectedOutput.dropLast().unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            })
        }
    }

    func testClosedDiagnosticSinkCannotChangeEntryFailureExitCode() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            HostAgentProcessTerminalReporter.report(
                .entryRejected(.invalidCodeSignature),
                to: pipe.fileHandleForWriting
            ),
            77
        )
    }

    func testSourceIsPureAndRealEntryRemainsFailClosed() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentProcessEntryOrchestrator.swift"
            ),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("HostAgentProcess.run("))
        XCTAssertFalse(source.contains("HostAgentProcessRuntime"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
        XCTAssertFalse(source.contains("exit("))

        XCTAssertTrue(appSource.contains("HostAgentBootstrap.failClosed()"))
        XCTAssertFalse(appSource.contains(
            "HostAgentProcessEntryOrchestrator.resolve("
        ))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
    }
}
