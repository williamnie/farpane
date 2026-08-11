@testable import CoreBridge
import Foundation
import XCTest

final class HostMicrophoneAuthorizationOwnerTests: XCTestCase {
    func testOnlyNotDeterminedStatusAdmitsOneRequest() {
        let state = State(.notDetermined)
        let owner = makeOwner(state)
        let completions = ResultBox<[HostMicrophoneAuthorizationStatus]>([])

        XCTAssertEqual(
            owner.requestAuthorization { status in
                completions.mutate { $0.append(status) }
            },
            .admitted
        )
        XCTAssertTrue(owner.isRequestPending())
        XCTAssertEqual(
            owner.requestAuthorization { status in
                completions.mutate { $0.append(status) }
            },
            .busy
        )
        XCTAssertEqual(state.requestCount, 1)

        state.status = .authorized
        state.complete(granted: true)
        XCTAssertFalse(owner.isRequestPending())
        XCTAssertEqual(completions.value, [.authorized])
    }

    func testBackendBooleanCannotOverrideObservedDeniedStatus() {
        let state = State(.notDetermined)
        let owner = makeOwner(state)
        let completion = ResultBox<HostMicrophoneAuthorizationStatus?>(nil)

        XCTAssertEqual(
            owner.requestAuthorization { completion.value = $0 },
            .admitted
        )
        state.status = .denied
        state.complete(granted: true)

        XCTAssertEqual(completion.value, .denied)
        XCTAssertFalse(owner.isRequestPending())
    }

    func testKnownStatusNeverInvokesPromptingBackend() {
        for (status, expected) in [
            (
                HostMicrophoneAuthorizationStatus.authorized,
                HostMicrophoneAuthorizationRequestResult.alreadyAuthorized
            ),
            (.denied, .unavailable(.denied)),
            (.restricted, .unavailable(.restricted)),
        ] {
            let state = State(status)
            let owner = makeOwner(state)
            XCTAssertEqual(owner.requestAuthorization { _ in }, expected)
            XCTAssertEqual(state.requestCount, 0)
            XCTAssertFalse(owner.isRequestPending())
        }
    }

    private func makeOwner(_ state: State)
        -> HostMicrophoneAuthorizationOwner
    {
        HostMicrophoneAuthorizationOwner(
            operations: HostMicrophoneAuthorizationOperations(
                observe: { state.status },
                requestAccess: { completion in
                    state.register(completion)
                }
            )
        )
    }
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: HostMicrophoneAuthorizationStatus
    private var completion: (@Sendable (Bool) -> Void)?
    private var storedRequestCount = 0

    init(_ status: HostMicrophoneAuthorizationStatus) {
        storedStatus = status
    }

    var status: HostMicrophoneAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedStatus
        }
        set {
            lock.lock()
            storedStatus = newValue
            lock.unlock()
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    func register(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        storedRequestCount += 1
        self.completion = completion
        lock.unlock()
    }

    func complete(granted: Bool) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(granted)
    }
}

private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    func mutate(_ mutation: (inout Value) -> Void) {
        lock.lock()
        mutation(&storedValue)
        lock.unlock()
    }
}
