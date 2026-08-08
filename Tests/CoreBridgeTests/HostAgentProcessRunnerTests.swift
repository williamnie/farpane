import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessRunnerTests: XCTestCase {
    func testInstallsIngressBeforeStartupThenBindsWaitsAndCancels() {
        let recorder = ProcessRunRecorder()
        let ingress = ProcessRunIngress()
        let runtime = ProcessRunRuntime()

        let result = HostAgentProcessRunner.run(
            installTerminationIngress: {
                recorder.append(.install)
                return ingress
            },
            startRuntime: {
                recorder.append(.start)
                return .success(runtime)
            },
            bindTermination: { boundIngress, boundRuntime in
                XCTAssertTrue(boundIngress === ingress)
                XCTAssertTrue(boundRuntime === runtime)
                recorder.append(.bind)
                return true
            },
            requestTermination: { _, reason in
                recorder.append(.request(reason))
                return true
            },
            waitUntilTerminated: { waitedRuntime in
                XCTAssertTrue(waitedRuntime === runtime)
                recorder.append(.wait)
                return HostAgentProcessTerminationOutcome(
                    reason: .appExit,
                    status: .stopped
                )
            },
            cancelTerminationIngress: { cancelledIngress in
                XCTAssertTrue(cancelledIngress === ingress)
                recorder.append(.cancel)
            }
        )

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.diagnostic)
        XCTAssertEqual(recorder.events, [
            .install,
            .start,
            .bind,
            .wait,
            .cancel,
        ])
    }

    func testStartupFailureCancelsIngressWithoutBindingOrWaiting() {
        let recorder = ProcessRunRecorder()
        let failure = HostAgentStartupFailure(kind: .configurationUnavailable)

        let result = HostAgentProcessRunner.run(
            installTerminationIngress: {
                recorder.append(.install)
                return ProcessRunIngress()
            },
            startRuntime: {
                recorder.append(.start)
                return Result<ProcessRunRuntime, HostAgentStartupFailure>
                    .failure(failure)
            },
            bindTermination: { _, _ in
                recorder.append(.bind)
                return true
            },
            requestTermination: { _, reason in
                recorder.append(.request(reason))
                return true
            },
            waitUntilTerminated: { _ in
                recorder.append(.wait)
                return HostAgentProcessTerminationOutcome(
                    reason: .error,
                    status: .stopped
                )
            },
            cancelTerminationIngress: { _ in
                recorder.append(.cancel)
            }
        )

        XCTAssertEqual(result, .startupFailed(failure))
        XCTAssertEqual(result.exitCode, 78)
        XCTAssertEqual(result.diagnostic, failure.diagnostic)
        XCTAssertEqual(recorder.events, [.install, .start, .cancel])
    }

    func testIngressInstallationFailureDoesNotStartRuntimeOrCancelAbsentIngress() {
        let recorder = ProcessRunRecorder()

        let result = HostAgentProcessRunner.run(
            installTerminationIngress: { () throws -> ProcessRunIngress in
                recorder.append(.install)
                throw ProcessRunError.install
            },
            startRuntime: {
                recorder.append(.start)
                return Result<ProcessRunRuntime, HostAgentStartupFailure>
                    .success(ProcessRunRuntime())
            },
            bindTermination: { _, _ in
                recorder.append(.bind)
                return true
            },
            requestTermination: { _, reason in
                recorder.append(.request(reason))
                return true
            },
            waitUntilTerminated: { _ in
                recorder.append(.wait)
                return HostAgentProcessTerminationOutcome(
                    reason: .error,
                    status: .stopped
                )
            },
            cancelTerminationIngress: { _ in
                recorder.append(.cancel)
            }
        )

        XCTAssertEqual(result, .internalFailure)
        XCTAssertEqual(result.exitCode, 70)
        XCTAssertEqual(
            result.diagnostic,
            "FarPane HostAgent encountered an internal lifecycle error."
        )
        XCTAssertEqual(recorder.events, [.install])
    }

    func testBindFailureRequestsOrderedCleanupBeforeCancellingIngress() {
        let recorder = ProcessRunRecorder()

        let result = HostAgentProcessRunner.run(
            installTerminationIngress: {
                recorder.append(.install)
                return ProcessRunIngress()
            },
            startRuntime: {
                recorder.append(.start)
                return .success(ProcessRunRuntime())
            },
            bindTermination: { _, _ in
                recorder.append(.bind)
                return false
            },
            requestTermination: { _, reason in
                recorder.append(.request(reason))
                return true
            },
            waitUntilTerminated: { _ in
                recorder.append(.wait)
                return HostAgentProcessTerminationOutcome(
                    reason: .error,
                    status: .stopped
                )
            },
            cancelTerminationIngress: { _ in
                recorder.append(.cancel)
            }
        )

        XCTAssertEqual(result, .internalFailure)
        XCTAssertEqual(recorder.events, [
            .install,
            .start,
            .bind,
            .request(.error),
            .wait,
            .cancel,
        ])
    }

    func testBindFailureWaitsWhenCleanupRequestWasAlreadyClaimed() {
        let recorder = ProcessRunRecorder()

        let result = HostAgentProcessRunner.run(
            installTerminationIngress: { ProcessRunIngress() },
            startRuntime: { .success(ProcessRunRuntime()) },
            bindTermination: { _, _ in false },
            requestTermination: { _, reason in
                recorder.append(.request(reason))
                return false
            },
            waitUntilTerminated: { _ in
                recorder.append(.wait)
                return HostAgentProcessTerminationOutcome(
                    reason: .error,
                    status: .stopped
                )
            },
            cancelTerminationIngress: { _ in recorder.append(.cancel) }
        )

        XCTAssertEqual(result, .internalFailure)
        XCTAssertEqual(recorder.events, [.request(.error), .wait, .cancel])
    }

    func testStopFailureHasFixedSoftwareExitAndSanitizedDiagnostic() {
        let result = HostAgentProcessRunner.run(
            installTerminationIngress: { ProcessRunIngress() },
            startRuntime: { .success(ProcessRunRuntime()) },
            bindTermination: { _, _ in true },
            requestTermination: { _, _ in true },
            waitUntilTerminated: { _ in
                HostAgentProcessTerminationOutcome(
                    reason: .appExit,
                    status: .stopFailed
                )
            },
            cancelTerminationIngress: { _ in }
        )

        XCTAssertEqual(result, .stopFailed)
        XCTAssertEqual(result.exitCode, 70)
        XCTAssertEqual(
            result.diagnostic,
            "FarPane HostAgent failed to stop cleanly."
        )
        XCTAssertTrue(result.diagnostic?.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        } == true)
    }
}

private enum ProcessRunError: Error {
    case install
}

private enum ProcessRunEvent: Equatable {
    case install
    case start
    case bind
    case request(HostStopReason)
    case wait
    case cancel
}

private final class ProcessRunRecorder {
    private(set) var events: [ProcessRunEvent] = []

    func append(_ event: ProcessRunEvent) {
        events.append(event)
    }
}

private final class ProcessRunIngress {}
private final class ProcessRunRuntime {}
