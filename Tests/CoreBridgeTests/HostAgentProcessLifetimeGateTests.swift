import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessLifetimeGateTests: XCTestCase {
    func testRetainsRuntimeUntilFirstTerminationAndStopsExactlyOnce() throws {
        let recorder = LifetimeEventRecorder()
        var runtime: LifetimeTestRuntime? = .init(recorder: recorder)
        weak let weakRuntime = runtime
        let gate = HostAgentProcessLifetimeGate(
            runtime: try XCTUnwrap(runtime),
            stopRuntime: { runtime, reason in
                try runtime.stop(reason: reason)
            }
        )
        runtime = nil

        XCTAssertNotNil(weakRuntime)
        XCTAssertTrue(gate.requestTermination(reason: .userRequest))
        XCTAssertNil(weakRuntime)
        XCTAssertFalse(gate.requestTermination(reason: .error))
        XCTAssertEqual(gate.waitUntilTerminated(), HostAgentProcessTerminationOutcome(
            reason: .userRequest,
            status: .stopped
        ))
        XCTAssertEqual(recorder.events, [
            .stop(.userRequest),
            .runtimeReleased,
        ])
    }

    func testStopFailureProducesSanitizedOutcomeAndCannotRetry() throws {
        let recorder = LifetimeEventRecorder()
        var runtime: LifetimeTestRuntime? = .init(
            recorder: recorder,
            stopFails: true
        )
        weak let weakRuntime = runtime
        let gate = HostAgentProcessLifetimeGate(
            runtime: try XCTUnwrap(runtime),
            stopRuntime: { runtime, reason in
                try runtime.stop(reason: reason)
            }
        )
        runtime = nil

        XCTAssertTrue(gate.requestTermination(reason: .error))
        XCTAssertNil(weakRuntime)
        XCTAssertEqual(gate.waitUntilTerminated(), HostAgentProcessTerminationOutcome(
            reason: .error,
            status: .stopFailed
        ))
        XCTAssertFalse(gate.requestTermination(reason: .appExit))
        XCTAssertEqual(recorder.events.filter {
            if case .stop = $0 { return true }
            return false
        }, [.stop(.error)])
    }

    func testConcurrentDuplicateReturnsWithoutWaitingAndWaitCompletesAfterStop() {
        let recorder = LifetimeEventRecorder()
        let stopEntered = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        var runtime: NSObject? = NSObject()
        weak let weakRuntime = runtime
        let gate = HostAgentProcessLifetimeGate(
            runtime: runtime!,
            stopRuntime: { _, reason in
                recorder.append(.stopEntered(reason))
                stopEntered.signal()
                releaseStop.wait()
                recorder.append(.stopFinished(reason))
            }
        )
        runtime = nil

        let requestFinished = expectation(description: "first request finished")
        DispatchQueue.global().async {
            XCTAssertTrue(gate.requestTermination(reason: .userRequest))
            requestFinished.fulfill()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(weakRuntime)
        XCTAssertFalse(gate.requestTermination(reason: .error))

        let waitFinished = expectation(description: "wait finished")
        DispatchQueue.global().async {
            let outcome = gate.waitUntilTerminated()
            recorder.append(.waitReturned(outcome.reason, outcome.status))
            waitFinished.fulfill()
        }
        releaseStop.signal()
        wait(for: [requestFinished, waitFinished], timeout: 2)

        XCTAssertNil(weakRuntime)
        XCTAssertEqual(recorder.events, [
            .stopEntered(.userRequest),
            .stopFinished(.userRequest),
            .waitReturned(.userRequest, .stopped),
        ])
    }

    func testDeinitStopsRetainedRuntimeWithAppExit() {
        let recorder = LifetimeEventRecorder()
        weak var weakRuntime: LifetimeTestRuntime?

        do {
            var runtime: LifetimeTestRuntime? = .init(recorder: recorder)
            weakRuntime = runtime
            let gate = HostAgentProcessLifetimeGate(
                runtime: runtime!,
                stopRuntime: { runtime, reason in
                    try runtime.stop(reason: reason)
                }
            )
            runtime = nil
            XCTAssertNotNil(weakRuntime)
            withExtendedLifetime(gate) {}
        }

        XCTAssertNil(weakRuntime)
        XCTAssertEqual(recorder.events, [
            .stop(.appExit),
            .runtimeReleased,
        ])
    }

    func testAccessesRuntimeOnlyBeforeTerminationIsClaimed() throws {
        let runtime = NSObject()
        let gate = HostAgentProcessLifetimeGate(
            runtime: runtime,
            stopRuntime: { _, _ in }
        )

        let accessed = try gate.withRunningRuntime { $0 }
        XCTAssertTrue(accessed === runtime)
        XCTAssertTrue(gate.requestTermination(reason: .appExit))
        XCTAssertThrowsError(try gate.withRunningRuntime { $0 }) { error in
            XCTAssertEqual(
                error as? HostAgentProcessLifetimeAccessError,
                .notRunning
            )
        }
    }
}

private enum LifetimeTestFailure: Error {
    case stop
}

private enum LifetimeEvent: Equatable {
    case stop(HostStopReason)
    case stopEntered(HostStopReason)
    case stopFinished(HostStopReason)
    case waitReturned(
        HostStopReason,
        HostAgentProcessTerminationOutcome.Status
    )
    case runtimeReleased
}

private final class LifetimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LifetimeEvent] = []

    var events: [LifetimeEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ event: LifetimeEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }
}

private final class LifetimeTestRuntime {
    private let recorder: LifetimeEventRecorder
    private let stopFails: Bool

    init(recorder: LifetimeEventRecorder, stopFails: Bool = false) {
        self.recorder = recorder
        self.stopFails = stopFails
    }

    func stop(reason: HostStopReason) throws {
        recorder.append(.stop(reason))
        if stopFails { throw LifetimeTestFailure.stop }
    }

    deinit {
        recorder.append(.runtimeReleased)
    }
}
